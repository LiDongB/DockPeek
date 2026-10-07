import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: - State

    private var statusItem: NSStatusItem?
    private weak var enabledMenuItem: NSMenuItem?
    private weak var statsMenuItem: NSMenuItem?

    private var dockMonitor: DockMonitor?
    private var previewPanel: PreviewPanel?
    private var settingsWindow: SettingsWindowController?

    private var statusTimer: Timer?
    private let windowInteractions = WindowInteractionController()
    /// Keeps thumbnails warm so a window is previewable even if it was never hovered before being
    /// minimised. Separate from the hover path on purpose.
    private let cacheWarmer = BackgroundCacheWarmer()
    private var lastTheme: Preferences.ThemeMode = Preferences.themeMode
    private var lastBackdrop: Preferences.Backdrop = Preferences.backdrop
    /// True once a status item has been created. Kept separate from the preference so "hidden"
    /// can be undone without recreating state.
    private var statusItemInstalled = false

    /// Mirrors `Preferences.previewEnabled` so the menu checkmark and the preferences checkbox agree.
    private var isEnabled: Bool {
        get { Preferences.previewEnabled }
        set { Preferences.previewEnabled = newValue }
    }

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // menu-bar-only, no Dock icon of ourselves

        buildStatusItem()

        let panel = PreviewPanel()
        panel.onSelectWindow = { target in
            WindowActions.activate(target)
        }
        panel.onCloseAllWindows = { pid in
            WindowActions.closeAll(pid: pid) { failed in
                if failed > 0 {
                    let alert = NSAlert()
                    alert.messageText = L10n.text("部分窗口未能关闭")
                    alert.informativeText = L10n.text("应用可能需要处理未保存的内容；请查看应用中的提示。")
                    alert.addButton(withTitle: L10n.text("好"))
                    alert.runModal()
                }
            }
        }
        panel.onHide = { [weak self] in
            self?.dockMonitor?.retentionRect = nil
        }
        panel.shouldAcceptEmptyWindowList = { [weak self] in
            self?.dockMonitor?.shouldAcceptEmptyWindowList() ?? true
        }
        previewPanel = panel

        let monitor = DockMonitor { [weak self] icon in
            self?.handleDockHover(icon)
        }
        dockMonitor = monitor
        // Without this the poll loop never runs and hovering does nothing at all.
        monitor.start()
        windowInteractions.dockItemAtPoint = { [weak monitor] point in monitor?.icon(at: point) }
        windowInteractions.onMinimize = { [weak panel] in panel?.hide() }
        _ = windowInteractions.configure()

        applyTheme()
        // KVO on the app's effective appearance: the system switches theme at sunset, and the
        // caption colour has to follow. AppKit offers no notification for this.
        NSApp.addObserver(self, forKeyPath: "effectiveAppearance", options: [.new], context: nil)

        Permissions.logStatus()
        // Ask for both permissions immediately, with explicit navigation for anything missing.
        Permissions.requestAllAtLaunch()
        // Start warming thumbnails in the background, so the cache does not depend on hovering.
        cacheWarmer.start()

        applyMenuBarIconVisibility()
        startStatusTimer()
        Log.info("DockPeek started — \(Version.summary)")
    }

    /// Reopening the running app (double-clicking it in Finder, or `open -a`) brings the settings
    /// window forward.
    ///
    /// This is the recovery path for a hidden menu-bar icon: with the icon gone there may be no
    /// other way back into the app.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !Preferences.showMenuBarIcon || !flag {
            openSettings()
        }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        dockMonitor?.stop()
        cacheWarmer.stop()
        statusTimer?.invalidate()
        windowInteractions.stop()
        NSApp.removeObserver(self, forKeyPath: "effectiveAppearance")
    }

    // MARK: - Menu bar

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = NSImage(
                systemSymbolName: "rectangle.on.rectangle.angled",
                accessibilityDescription: "DockPeek"
            )
            button.image?.isTemplate = true
            button.toolTip = "DockPeek — 悬停程序坞预览窗口"
        }

        let menu = NSMenu()

        // 快捷操作可按偏好整体隐藏；此时菜单只保留必需项，图标仍存在但菜单为空。
        if Preferences.showMenuBarQuickActions {
            let enabled = NSMenuItem(title: "启用悬停预览", action: #selector(toggleEnabled), keyEquivalent: "")
            enabled.target = self
            enabled.state = isEnabled ? .on : .off
            menu.addItem(enabled)
            enabledMenuItem = enabled

            let settings = NSMenuItem(title: "设置…", action: #selector(openSettings), keyEquivalent: ",")
            settings.target = self
            menu.addItem(settings)

            let login = NSMenuItem(title: "登录时启动", action: #selector(toggleLoginItem), keyEquivalent: "")
            login.target = self
            login.state = LoginItem.isEnabled ? .on : .off
            menu.addItem(login)

            menu.addItem(.separator())

            let hideIcon = NSMenuItem(
                title: "隐藏菜单栏图标",
                action: #selector(hideMenuBarIcon),
                keyEquivalent: ""
            )
            hideIcon.target = self
            menu.addItem(hideIcon)

            menu.addItem(.separator())

            let permissions = NSMenuItem(title: "检查权限…", action: #selector(checkPermissions), keyEquivalent: "")
            permissions.target = self
            menu.addItem(permissions)

            let about = NSMenuItem(title: "关于 DockPeek", action: #selector(showAbout), keyEquivalent: "")
            about.target = self
            menu.addItem(about)

            menu.addItem(.separator())

            let quit = NSMenuItem(title: "退出 DockPeek", action: #selector(quit), keyEquivalent: "q")
            quit.target = self
            menu.addItem(quit)
        } else {
            // 快捷操作隐藏时仍需保留一个可退出、可回到设置的最小入口。
            let settings = NSMenuItem(title: "设置…", action: #selector(openSettings), keyEquivalent: ",")
            settings.target = self
            menu.addItem(settings)

            let quit = NSMenuItem(title: "退出 DockPeek", action: #selector(quit), keyEquivalent: "q")
            quit.target = self
            menu.addItem(quit)
        }

        // Read-only memory readout, controlled independently of the quick-action switch.
        if Preferences.showMemoryUsage {
            let stats = NSMenuItem(title: "内存占用：—", action: nil, keyEquivalent: "")
            stats.isEnabled = false
            menu.addItem(stats)
            statsMenuItem = stats
        }

        menu.items.forEach { $0.title = L10n.text($0.title) }
        item.button?.toolTip = L10n.text("DockPeek — 悬停程序坞预览窗口")
        item.menu = menu
        statusItem = item
        statusItemInstalled = true
    }

    /// Shows or hides the menu-bar icon on request.
    ///
    /// Hiding only removes the icon: previews keep running, the Dock monitor keeps polling, and the
    /// app stays alive in the background.
    private func applyMenuBarIconVisibility() {
        if Preferences.showMenuBarIcon {
            if !statusItemInstalled || statusItem == nil { buildStatusItem() }
        } else {
            if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
            statusItem = nil
            statusItemInstalled = false
        }
    }

    private func startStatusTimer() {
        refreshStats()
        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshStats() }
        }
        RunLoop.main.add(timer, forMode: .common)
        statusTimer = timer
    }

    private func refreshStats() {
        statsMenuItem?.title = L10n.text("内存占用：\(MemoryFootprint.formatted())")
        _ = windowInteractions.configure()
        // Keep the checkmark honest if the value was changed from the settings window.
        enabledMenuItem?.state = isEnabled ? .on : .off
    }

    /// Applies the theme preference to the whole app, including the preview panel.
    private func applyTheme() {
        let appearance = Preferences.themeMode.appearance
        NSApp.appearance = appearance
        previewPanel?.applyAppearance(appearance)
    }

    override func observeValue(
        forKeyPath keyPath: String?,
        of object: Any?,
        change: [NSKeyValueChangeKey: Any]?,
        context: UnsafeMutableRawPointer?
    ) {
        guard keyPath == "effectiveAppearance" else {
            super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
            return
        }
        previewPanel?.refreshCaptionColors()
        if Preferences.themeMode == .system { cacheWarmer.resampleVisibleWindows() }
    }

    // MARK: - Hover plumbing

    private func handleDockHover(_ icon: DockItem?) {
        guard isEnabled else { return }
        guard let icon else {
            previewPanel?.hide()
            return
        }

        guard previewPanel?.present(for: icon) == true else {
            dockMonitor?.retentionRect = nil
            dockMonitor?.retryCurrentHover()
            return
        }

        // Recompute the "pointer may travel into the panel" region from the panel's *actual* state
        // every time. Deriving it only from an `onHide` callback risks a stale rectangle that would
        // hide the preview the moment the pointer left the icon.
        if let frame = previewPanel?.windowFrame {
            dockMonitor?.retentionRect = CoordinateConversion.quartzRect(fromCocoa: frame)
        } else {
            dockMonitor?.retentionRect = nil
        }
    }

    // MARK: - Actions

    @objc private func toggleEnabled(_ sender: NSMenuItem) {
        isEnabled.toggle()
        sender.state = isEnabled ? .on : .off
        if !isEnabled { previewPanel?.hide() }
        // Nothing needs a warm cache while previews are switched off.
        if isEnabled { cacheWarmer.start() } else { cacheWarmer.stop() }
    }

    @objc private func checkPermissions() {
        Permissions.showPermissionMenuAction()
        refreshStats()
    }

    @objc private func hideMenuBarIcon() {
        Preferences.showMenuBarIcon = false
        applyMenuBarIconVisibility()
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let controller = SettingsWindowController()
            controller.onChange = { [weak self] in
                guard let self else { return }
                // Changes apply live; if previews were switched off, close any open one.
                if !Preferences.previewEnabled {
                    self.previewPanel?.hide()
                    self.cacheWarmer.stop()
                } else if !self.cacheWarmer.isRunning {
                    self.cacheWarmer.start()
                }
                let appearanceChanged = self.lastTheme != Preferences.themeMode || self.lastBackdrop != Preferences.backdrop
                self.lastTheme = Preferences.themeMode
                self.lastBackdrop = Preferences.backdrop
                self.applyTheme()
                if appearanceChanged { self.cacheWarmer.resampleVisibleWindows() }
                self.previewPanel?.refreshPreferences(resampleVisibleOnly: appearanceChanged)
                self.rebuildMenuBar()
                if !self.windowInteractions.configure(), Preferences.switcherEnabled {
                    Preferences.switcherEnabled = false
                    let alert = NSAlert()
                    alert.messageText = L10n.text("快捷键不可用")
                    alert.informativeText = L10n.text("这个快捷键已被系统或其他应用占用，请选择另一个。")
                    alert.addButton(withTitle: L10n.text("好"))
                    alert.runModal()
                    self.settingsWindow?.refreshValues()
                }
                self.refreshStats()
            }
            settingsWindow = controller
        }
        settingsWindow?.show()
    }

    @objc private func toggleLoginItem(_ sender: NSMenuItem) {
        LoginItem.setEnabled(!LoginItem.isEnabled)
        sender.state = LoginItem.isEnabled ? .on : .off
    }

    @objc private func showAbout() {
        openSettings()
        settingsWindow?.selectPage(2)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Test surface

    /// Exposed for the lifecycle self test, which asserts the monitor was actually started.
    var dockMonitorIsRunning: Bool { dockMonitor?.isRunning ?? false }

    /// Background cache warmer, exposed for verification (test surface).
    var cacheWarmerForTesting: BackgroundCacheWarmer { cacheWarmer }

    /// Whether a menu-bar icon is currently installed (test surface).
    var hasMenuBarIcon: Bool { statusItem != nil }

    /// Titles of the current menu items, in order (test surface).
    var currentMenuTitles: [String] {
        (statusItem?.menu?.items ?? []).map(\.title)
    }

    /// Applies the menu-bar icon preference immediately (test surface for the menu switches).
    func reapplyMenuBarIcon() { applyMenuBarIconVisibility() }

    /// Rebuilds the status item so preference changes to the menu contents take effect (test surface).
    func rebuildMenuBar() {
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
        statusItemInstalled = false
        if Preferences.showMenuBarIcon { buildStatusItem() }
    }

    /// Poll cycles executed so far — proves the loop advances, not just that a timer object exists.
    var dockTickCount: Int { dockMonitor?.tickCount ?? 0 }

    /// Dock icons resolved by the most recent poll cycle.
    var dockIconCount: Int { dockMonitor?.lastTickIconCount ?? 0 }

    /// Whether the monitor currently considers a preview to be on screen (idle probe only).
    var previewReportedForDiagnostics: Bool { dockMonitor?.previewIsReported ?? false }
}
