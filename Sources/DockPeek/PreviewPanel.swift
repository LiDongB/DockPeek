import AppKit
import CoreGraphics

/// The floating preview panel shown next to a Dock icon.
///
/// It is a non-activating `NSPanel`: clicking a thumbnail must not steal focus from the app the user
/// is switching *to*, so the panel deliberately never becomes the key window.
@MainActor
final class PreviewPanel {

    var onCloseAllWindows: ((pid_t) -> Void)?
    var onSelectWindow: ((WindowTarget) -> Void)?
    /// Invoked when the panel closes, so the Dock monitor can drop its "keep hovering" region.
    var onHide: (() -> Void)?
    /// Asked when an app appears to have no windows. Returning `false` keeps the current preview on
    /// screen, which absorbs the occasional empty read from the window server instead of flickering
    /// the panel away.
    var shouldAcceptEmptyWindowList: (() -> Bool)?

    private var panel: NSPanel?
    private var gridView: PreviewGridView?
    private var scrollView: NSScrollView?
    private var materialView: NSView?
    private var installedBackdrop: Preferences.Backdrop?
    private var captureGeneration = 0
    private var syntheticPresentation = false
    private var currentItem: DockItem?
    private var currentTargets: [WindowTarget] = []
    private var escapeMonitor: Any?
    private var outsideClickMonitor: Any?
    private var pendingCapture: Task<Void, Never>?
    /// Coarse poll that keeps an already-visible preview in step with the real window list.
    private var refreshTimer: Timer?
    /// Guards against a hide animation finishing after a newer show has started.
    private var animationGeneration = 0
    private var hideAnimationIsRunning = false
    private var contextMenuIsOpen = false

    private let cornerRadius: CGFloat = 14

    // MARK: - Present / hide

    /// Shows the preview for `item`.
    ///
    /// Returns `true` when the panel ended up showing this icon's windows. Returns `false` — after
    /// hiding any previous preview — when the app is not running or has no real windows. Leaving
    /// the *previous* icon's preview on screen in that case is what makes the panel look like it is
    /// showing the wrong application.
    @discardableResult
    func present(for item: DockItem) -> Bool {
        guard let app = runningApplication(for: item) else {
            Log.debug("present: no running application for \(item.name)")
            hide()
            return false
        }

        let targets = WindowEnumerator.windows(pid: app.processIdentifier, ownerName: app.localizedName ?? item.name)

        return present(for: item, targets: targets)
    }

    @discardableResult
    private func present(for item: DockItem, targets: [WindowTarget], force: Bool = false, captureOnlyVisible: Bool = false) -> Bool {
        guard !targets.isEmpty else {
            // Only tolerate a transient empty read for the application already being previewed.
            // A different application must never inherit the previous application's pictures.
            if currentItem != item || (shouldAcceptEmptyWindowList?() ?? true) { hide() }
            return false
        }
        // Re-hovering the same icon with the same windows: keep what is already on screen.
        //
        // Compared by stable identity, not by window id: a minimised window's id is a synthetic
        // value that changes on every enumeration, so an id comparison would rebuild the panel (and
        // re-capture everything) on every poll while a window stays minimised.
        if !force, currentItem == item,
           Self.signature(currentTargets) == Self.signature(targets),
           panel?.isVisible == true {
            return true
        }

        pendingCapture?.cancel()
        hideAnimationIsRunning = false
        captureGeneration += 1
        currentItem = item
        currentTargets = targets

        // Give the layout the real space the panel has on the Dock's screen, so the grid can never
        // be built larger than the panel it will be shown in.
        let ceiling = availableContentSize(for: item)
        let layout = PreviewGridView.Layout.make(
            for: targets,
            size: Preferences.panelSize,
            titleSize: Preferences.titleSize,
            screen: NSScreen.screens.first {
                $0.frame.contains(CoordinateConversion.cocoaRect(fromQuartz: item.frame).center)
            }?.visibleFrame,
            maxContentSize: ceiling
        )
        let tiles = targets.map { target -> WindowTileView in
            let tile = WindowTileView(target: target, tileSize: layout.tileSize)
            tile.onSelect = { [weak self] _ in self?.select(target) }
            tile.onCloseAll = { [weak self] in
                self?.contextMenuIsOpen = false
                self?.hide()
                self?.onCloseAllWindows?(target.pid)
            }
            tile.onMenuTracking = { [weak self] open in self?.contextMenuIsOpen = open }
            return tile
        }

        let grid = ensureGridView()
        grid.setTiles(tiles, layout: layout)
        applyAppearance(Preferences.themeMode.appearance)
        grid.layoutSubtreeIfNeeded()
        // The panel hugs the grid exactly — no fixed padding, no letterboxing around it.
        showPanel(above: item, contentSize: layout.viewportSize(tileCount: targets.count))

        installOutsideClickMonitors()
        if !syntheticPresentation { startRefreshTimer(for: item) }

        // Paint anything already captured *synchronously* so a remembered window appears with no
        // perceptible loading at all, then capture only what is genuinely missing.
        for (target, tile) in zip(targets, tiles) {
            if let cached = ThumbnailProvider.shared.cached(for: target) { tile.setThumbnail(cached) }
        }
        if Preferences.panelSize.showsThumbnails && !syntheticPresentation {
            startCaptures(for: targets, tiles: tiles, captureOnlyVisible: captureOnlyVisible)
        }

        return true
    }

    func hide() {
        guard !contextMenuIsOpen else { return }
        captureGeneration += 1
        pendingCapture?.cancel()
        pendingCapture = nil
        stopRefreshTimer()
        removeMonitors()
        currentItem = nil
        currentTargets = []
        // Thumbnails are intentionally *not* purged here: keeping them is what makes the next hover
        // instant. The provider enforces its own memory ceiling.
        fadeOutAndOrderOut()
        onHide?()
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    /// Panel frame in Cocoa-global coordinates, or `nil` when no panel is up.
    ///
    /// Deliberately **not** conditioned on `alphaValue`: the panel fades in from 0, and requiring a
    /// visible alpha meant the caller's "pointer may travel into the panel" region was never set
    /// during the fade — which is why the preview used to vanish as soon as the pointer left the
    /// icon to go and click it.
    var windowFrame: CGRect? {
        guard let panel, panel.isVisible else { return nil }
        return panel.frame
    }

    // MARK: - Actions

    private func select(_ target: WindowTarget) {
        hide()
        onSelectWindow?(target)
    }

    // MARK: - Capture

    private func startCaptures(for targets: [WindowTarget], tiles: [WindowTileView], captureOnlyVisible: Bool = false) {
        pendingCapture?.cancel()

        let generation = captureGeneration
        pendingCapture = Task { @MainActor [weak self] in
            await withTaskGroup(of: Void.self) { group in
                for (target, tile) in zip(targets, tiles) {
                    if captureOnlyVisible && !WindowActions.isOnCurrentDesktop(target) { continue }
                    group.addTask { @MainActor in
                        guard let image = await ThumbnailProvider.shared.thumbnail(for: target) else { return }
                        guard !Task.isCancelled else { return }
                        // The preview may have moved on to a different icon by now.
                        guard let self, self.captureGeneration == generation, self.currentTargets.contains(where: { $0.identity == target.identity }) else { return }
                        tile.setThumbnail(image, animated: true)
                    }
                }
                await group.waitForAll()
            }
        }
    }

    // MARK: - Live refresh

    /// Re-evaluates the window list while the preview is on screen.
    ///
    /// Without this the panel is only ever built at the moment of hover, so a window that is
    /// minimised, restored or closed while the preview is already showing would not be reflected
    /// until the pointer left and came back. The interval is deliberately coarse — this is a safety
    /// net, not a live video feed.
    private func startRefreshTimer(for item: DockItem) {
        stopRefreshTimer()
        let timer = Timer(timeInterval: 0.6, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshIfChanged(item) }
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    private func stopRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    /// Rebuilds only when the set of windows (or their minimised state) actually changed.
    private func refreshIfChanged(_ item: DockItem) {
        guard panel?.isVisible == true, currentItem == item else { return }
        guard let app = runningApplication(for: item) else { hide(); return }

        let targets = WindowEnumerator.windows(pid: app.processIdentifier, ownerName: app.localizedName ?? item.name)
        if targets.isEmpty {
            if shouldAcceptEmptyWindowList?() ?? true { hide() }
            return
        }
        guard Self.signature(targets) != Self.signature(currentTargets) else { return }

        Log.debug("window set changed while previewing \(item.name); rebuilding")
        _ = present(for: item)
    }

    private static func signature(_ targets: [WindowTarget]) -> [String] {
        targets.map { "\($0.identity):\($0.windowID):\($0.isMinimized):\($0.isMain):\($0.title):\($0.bounds)" }
    }

    /// Apply current settings to an existing panel, including replacing the actual material view.
    func refreshPreferences(resampleVisibleOnly: Bool = false) {
        guard let item = currentItem, panel?.isVisible == true else { return }
        _ = present(for: item, targets: currentTargets, force: true, captureOnlyVisible: resampleVisibleOnly)
    }

    // MARK: - Appearance

    /// Applies an explicit appearance to the panel, or clears it so the panel follows the app.
    func applyAppearance(_ appearance: NSAppearance?) {
        panel?.appearance = appearance
    }

    /// Re-reads the caption colours after a theme change.
    func refreshCaptionColors() {
        gridView?.tiles.forEach { $0.refreshCaptionColor() }
    }

    // MARK: - Layout

    private func showPanel(above item: DockItem, contentSize: CGSize) {
        let panel = ensurePanel()

        let bounds = NSRect(origin: .zero, size: contentSize)
        panel.setFrame(NSRect(origin: panelOrigin(for: item, contentSize: contentSize), size: contentSize), display: false)
        panel.contentView?.frame = bounds
        updateMaterial()
        materialView?.frame = bounds
        scrollView?.frame = bounds
        gridView?.frame = NSRect(origin: .zero, size: gridView?.intrinsicContentSize ?? .zero)
        scrollView?.hasVerticalScroller = (gridView?.intrinsicContentSize.height ?? 0) > contentSize.height + 1
        panel.layoutIfNeeded()
        panel.contentView?.layoutSubtreeIfNeeded()
        gridView?.layoutSubtreeIfNeeded()
        scrollView?.contentView.scroll(to: .zero)
        scrollView?.reflectScrolledClipView(scrollView!.contentView)
        panel.invalidateShadow()
        // Clear any scale left over from a previous pop transition.
        panel.contentView?.layer?.removeAllAnimations()
        applyPopScale(1.0)

        animationGeneration += 1
        hideAnimationIsRunning = false

        // The transition preference decides the出场 animation. Reading it here (rather than only
        // reading the fade durations) is what makes 「关闭动画」 actually skip the animation —
        // previously the panel always faded whenever the durations were non-zero, so the setting
        // had no effect on the panel itself.
        switch Preferences.transition {
        case .none:
            panel.alphaValue = 1
            panel.contentView?.layer?.removeAllAnimations()
            applyPopScale(1.0)
            panel.orderFrontRegardless()

        case .fade:
            let duration = Preferences.fadeInDuration
            panel.alphaValue = duration > 0 ? 0 : 1
            panel.orderFrontRegardless()
            guard duration > 0 else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = duration
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
            }

        case .pop:
            panel.alphaValue = 1
            applyPopScale(Self.popStartScale)
            panel.orderFrontRegardless()
            animatePopScale(from: Self.popStartScale, to: 1.0, duration: Self.popInDuration)
        }
    }

    // MARK: - 弹出动画

    /// Starting scale for the pop transition.
    ///
    /// 0.12 s in / 0.09 s out, ease-out / ease-in, no overshoot, no spring. These figures are the
    /// proposed values and are kept in one place so they can be tuned without touching the logic.
    static let popStartScale: CGFloat = 0.88
    static let popInDuration: TimeInterval = 0.12
    static let popOutDuration: TimeInterval = 0.14
    static let popEndScale: CGFloat = 0.02

    /// Scales the panel's content around its centre. A layer transform is used instead of a frame
    /// change so the window's shadow and position stay put while the content grows.
    private func scaleTransform(_ scale: CGFloat, layer: CALayer) -> CATransform3D {
        let center = CGPoint(x: layer.bounds.width * (0.5 - layer.anchorPoint.x),
                             y: layer.bounds.height * (0.5 - layer.anchorPoint.y))
        var transform = CATransform3DMakeScale(scale, scale, 1)
        transform.m41 = (1 - scale) * center.x
        transform.m42 = (1 - scale) * center.y
        return transform
    }

    private func applyPopScale(_ scale: CGFloat) {
        guard let layer = panel?.contentView?.layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.transform = scaleTransform(scale, layer: layer)
        CATransaction.commit()
    }

    private func animatePopScale(from fromScale: CGFloat, to scale: CGFloat, duration: TimeInterval) {
        guard let layer = panel?.contentView?.layer, duration > 0 else { applyPopScale(scale); return }
        let animation = CABasicAnimation(keyPath: "transform")
        animation.fromValue = NSValue(caTransform3D: scaleTransform(fromScale, layer: layer))
        animation.toValue = NSValue(caTransform3D: scaleTransform(scale, layer: layer))
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: scale == 1 ? .easeOut : .easeIn)
        applyPopScale(scale)
        layer.add(animation, forKey: "popScale")
        lastPopAnimation = (from: fromScale, to: scale, duration: duration)
    }

    /// Parameters of the most recent pop animation. Recorded explicitly because reading the layer
    /// back cannot distinguish the animation's start from its end — Core Animation's model layer
    /// jumps straight to the target value.
    private(set) var lastPopAnimation: (from: CGFloat, to: CGFloat, duration: TimeInterval)?

    private func fadeOutAndOrderOut() {
        guard let panel, panel.isVisible, !hideAnimationIsRunning else { return }
        hideAnimationIsRunning = true
        animationGeneration += 1
        let generation = animationGeneration

        switch Preferences.transition {
        case .none:
            panel.alphaValue = 0
            applyPopScale(1.0)
            panel.orderOut(nil)

        case .fade:
            let duration = Preferences.fadeOutDuration
            guard duration > 0 else {
                panel.alphaValue = 0
                panel.orderOut(nil)
                return
            }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = duration
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                panel.animator().alphaValue = 0
            } completionHandler: { [weak self] in
                // `finish()` is main-actor isolated and this handler is not; hop explicitly.
                Task { @MainActor in self?.runHideCompletion(generation: generation, panel: panel) }
            }

        case .pop:
            guard let layer = panel.contentView?.layer else {
                runHideCompletion(generation: generation, panel: panel)
                return
            }
            let startTransform = layer.presentation()?.transform ?? layer.transform
            let start = CGFloat(startTransform.m11)
            let animation = CAKeyframeAnimation(keyPath: "transform")
            animation.values = (0...60).map { index in
                let t = CGFloat(index) / 60
                let scale = start + (Self.popEndScale - start) * t * t
                return NSValue(caTransform3D: scaleTransform(scale, layer: layer))
            }
            animation.keyTimes = (0...60).map { NSNumber(value: Double($0) / 60) }
            animation.calculationMode = .linear
            animation.duration = Self.popOutDuration
            CATransaction.begin()
            CATransaction.setCompletionBlock { [weak self, weak panel] in
                DispatchQueue.main.async {
                    guard let panel else { return }
                    self?.runHideCompletion(generation: generation, panel: panel)
                }
            }
            applyPopScale(Self.popEndScale)
            layer.add(animation, forKey: "popScale")
            CATransaction.commit()
            lastPopAnimation = (from: start, to: Self.popEndScale, duration: Self.popOutDuration)
        }
    }

    /// Completes a hide after its animation, unless a newer preview has appeared meanwhile.
    private func runHideCompletion(generation: Int, panel: NSPanel) {
        guard animationGeneration == generation else { return }
        panel.orderOut(nil)
        hideAnimationIsRunning = false
        panel.alphaValue = 1
        applyPopScale(1.0)
    }

    private func ensureGridView() -> PreviewGridView {
        if let gridView { return gridView }
        let grid = PreviewGridView(frame: .zero)
        gridView = grid
        return grid
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 120),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.animationBehavior = .none // we do our own fade
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.alphaValue = 0

        let bounds = NSRect(x: 0, y: 0, width: 220, height: 120)
        let host = NSView(frame: bounds)
        host.wantsLayer = true
        panel.contentView = host
        let scroll = NSScrollView(frame: bounds)
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = cornerRadius
        scroll.layer?.masksToBounds = true
        scroll.documentView = ensureGridView()
        scrollView = scroll
        self.panel = panel
        updateMaterial()
        return panel
    }

    private func updateMaterial() {
        guard let host = panel?.contentView, let scroll = scrollView else { return }
        guard materialView == nil || installedBackdrop != Preferences.backdrop else { return }
        if #available(macOS 26, *), let oldGlass = materialView as? NSGlassEffectView {
            oldGlass.contentView = nil
        }
        scroll.removeFromSuperview()
        materialView?.removeFromSuperview()
        materialView = nil
        let backdrop: NSView
        if #available(macOS 26, *), Preferences.backdrop == .glass {
            let glass = NSGlassEffectView(frame: host.bounds)
            glass.style = .regular
            glass.cornerRadius = cornerRadius
            if #available(macOS 27, *) { glass.effectIsInteractive = true }
            // AppKit owns the glass container. Only the scroll viewport follows its size;
            // the grid document retains its independently calculated natural size.
            glass.contentView = scroll
            backdrop = glass
        } else {
            let effect = NSVisualEffectView(frame: host.bounds)
            effect.material = .hudWindow
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.wantsLayer = true
            effect.layer?.cornerRadius = cornerRadius
            effect.layer?.masksToBounds = true
            backdrop = effect
        }
        backdrop.autoresizingMask = [.width, .height]
        scroll.autoresizingMask = [.width, .height]
        host.addSubview(backdrop)
        if backdrop is NSVisualEffectView { host.addSubview(scroll) }
        materialView = backdrop
        installedBackdrop = Preferences.backdrop
    }

    /// Places the panel beside the dock icon, on whichever side of the screen the Dock sits.
    ///
    /// Everything here is computed in Cocoa-global coordinates: the icon frame arrives in Quartz
    /// coordinates and is flipped once, then clamped against `NSScreen.visibleFrame` (also global).
    private func panelOrigin(for item: DockItem, contentSize: CGSize) -> CGPoint {
        let iconRect = CoordinateConversion.cocoaRect(fromQuartz: item.frame)
        let iconCenter = CGPoint(x: iconRect.midX, y: iconRect.midY)

        let screen = NSScreen.screens.first { $0.frame.contains(iconCenter) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        let edge = dockEdge(for: iconRect, visible: visible) ?? .bottom

        let separation = dockLabelSpacing(for: item, edge: edge)
        var x = iconRect.midX - contentSize.width / 2
        var y = iconRect.maxY + separation

        switch edge {
        case .bottom:
            y = iconRect.maxY + separation
        case .top:
            y = iconRect.minY - separation - contentSize.height
        case .left:
            x = iconRect.maxX + separation
            y = iconRect.midY - contentSize.height / 2
        case .right:
            x = iconRect.minX - separation - contentSize.width
            y = iconRect.midY - contentSize.height / 2
        }

        let rawX = x
        let rawY = y
        x = min(max(x, visible.minX + 4), max(visible.minX + 4, visible.maxX - contentSize.width - 4))
        y = min(max(y, visible.minY + 4), max(visible.minY + 4, visible.maxY - contentSize.height - 4))

        testLastOriginMath = String(
            format: "icon=(%.0f,%.0f,%.0f,%.0f) edge=%@ 面板=%.0f×%.0f raw=(%.0f,%.0f) clamped=(%.0f,%.0f) visible=(%.0f,%.0f,%.0f,%.0f)",
            iconRect.minX, iconRect.minY, iconRect.width, iconRect.height,
            String(describing: edge),
            contentSize.width, contentSize.height,
            rawX, rawY, x, y,
            visible.minX, visible.minY, visible.width, visible.height
        )
        return CGPoint(x: x, y: y)
    }

    private enum DockEdge { case top, bottom, left, right }

    /// Reserve space for the system-owned Dock name bubble instead of trying to move it.
    private func dockLabelSpacing(for item: DockItem, edge: DockEdge) -> CGFloat {
        switch edge {
        case .bottom, .top: return 38
        case .left, .right:
            let width = (item.name as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13)]).width
            return min(max(width + 32, 70), 240)
        }
    }

    /// Largest panel content size that still fits on the Dock's screen, with a small safety margin.
    private func availableContentSize(for item: DockItem) -> CGSize {
        let iconRect = CoordinateConversion.cocoaRect(fromQuartz: item.frame)
        let screen = NSScreen.screens.first { $0.frame.contains(iconRect.center) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        // Leave room on every side so the panel never touches a screen edge.
        let margin: CGFloat = 12
        return CGSize(
            width: max(visible.width - margin * 2, 160),
            height: max(visible.height - margin * 2, 120)
        )
    }

    /// Which screen edge the Dock occupies, judged by the icon's distance to each edge.
    ///
    /// Uses the screen's **full** frame, not `visibleFrame`: `visibleFrame` is already inset by the
    /// Dock, so with a left-side Dock its `minX` sits at the Dock's right edge and the icon looks
    /// far from the left edge — which made a left Dock be misread as a top Dock.
    private func dockEdge(for iconRect: CGRect, visible: NSRect) -> DockEdge? {
        switch UserDefaults(suiteName: "com.apple.dock")?.string(forKey: "orientation") {
        case "left": return .left
        case "right": return .right
        case "bottom": return .bottom
        default: break
        }
        let bounds = screenBounds(for: iconRect)
        let distances: [(edge: DockEdge, distance: CGFloat)] = [
            (.bottom, abs(iconRect.minY - bounds.minY)),
            (.top, abs(bounds.maxY - iconRect.maxY)),
            (.left, abs(iconRect.minX - bounds.minX)),
            (.right, abs(bounds.maxX - iconRect.maxX))
        ]
        return distances.min { $0.distance < $1.distance }?.edge
    }

    /// Full frame of the screen the icon lives on.
    private func screenBounds(for iconRect: CGRect) -> CGRect {
        let screen = NSScreen.screens.first { $0.frame.contains(iconRect.center) } ?? NSScreen.main
        return screen?.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
    }

    // MARK: - Dismissal

    private func installOutsideClickMonitors() {
        removeMonitors()

        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in self?.hide() }
        }

        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            if event.keyCode == 53 { // Escape
                Task { @MainActor in self?.hide() }
            }
            return event
        }
    }

    private func removeMonitors() {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        outsideClickMonitor = nil
        escapeMonitor = nil
    }

    // MARK: - Helpers

    /// Resolves the running application behind a Dock icon.
    ///
    /// `AXURL` gives the exact bundle, which is the reliable route; the name match is a fallback for
    /// icons that do not expose it.
    private func runningApplication(for item: DockItem) -> NSRunningApplication? {
        if let bundleURL = item.bundleURL {
            if let match = NSWorkspace.shared.runningApplications.first(where: { $0.bundleURL == bundleURL }) {
                return match
            }
        }
        if let bundleID = item.bundleID,
           let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            return app
        }
        return NSWorkspace.shared.runningApplications.first { app in
            app.activationPolicy == .regular
                && (app.localizedName == item.name
                    || app.bundleURL?.deletingPathExtension().lastPathComponent == item.name)
        }
    }

    // MARK: - Test surface

    /// Exposed for `SelfTest`; the real hover path uses the same resolution logic.
    func testResolveApplication(for item: DockItem) -> NSRunningApplication? {
        runningApplication(for: item)
    }

    /// Drives the real presentation path (no synthesised events, no shortcuts).
    func testBuildPreview(for item: DockItem, windows: [WindowTarget]) -> Bool {
        syntheticPresentation = true
        return present(for: item, targets: windows, force: true)
    }

    func testRenderedTileWindows() -> [CGWindowID] {
        gridView?.tiles.map(\.windowID) ?? []
    }

    var testMaterialName: String { materialView.map { String(describing: type(of: $0)) } ?? "none" }
    var testScrollView: NSScrollView? { scrollView }
    var testContentLayer: CALayer? { panel?.contentView?.layer }

    var testPanelIsOrderedIn: Bool { panel?.isVisible ?? false }

    /// Window count the panel actually ended up holding (diagnostic for the self test).
    var testAcceptedWindowCount: Int { currentTargets.count }

    /// The windows the panel is currently showing, for layout reconstruction in tests.
    var testCurrentTargets: [WindowTarget] { currentTargets }

    /// The tiles currently laid out inside the grid.
    var testTiles: [WindowTileView] { gridView?.tiles ?? [] }

    /// Screen-space facts about the panel as currently shown.
    ///
    /// Used by `--test-layout` to assert the preview is *fully* on screen. A position clamp alone is
    /// not enough: if the content is larger than the screen, clamping the origin still leaves the
    /// far side cut off.
    struct PlacementFacts {
        let panelRect: CGRect
        let visibleFrame: CGRect
        let gridRect: CGRect
        let contentRect: CGRect
        let dockEdge: String
        var fitsHorizontally: Bool { panelRect.minX >= visibleFrame.minX - 0.5 && panelRect.maxX <= visibleFrame.maxX + 0.5 }
        var fitsVertically: Bool { panelRect.minY >= visibleFrame.minY - 0.5 && panelRect.maxY <= visibleFrame.maxY + 0.5 }
        var panelFits: Bool { fitsHorizontally && fitsVertically }
        /// The grid must be inside the panel, otherwise content is clipped by its own container.
        /// The grid must be laid out exactly inside the panel's content area. If it is larger, the
        /// overflow is clipped and the preview looks truncated.
        var gridInsidePanel: Bool {
            gridRect.width <= contentRect.width + 0.5 && gridRect.height <= contentRect.height + 0.5
        }
    }

    /// Human-readable container chain captured by `testPlacementFacts`, for diagnosing a mismatch.
    private(set) var testDebugChain: [String] = []

    /// Numbers behind the last `panelOrigin` call, for diagnosing out-of-bounds placements.
    private(set) var testLastOriginMath: String = ""

    /// The panel's window number, so it can be captured through the window server.
    var testWindowNumber: Int? { panel?.windowNumber }

    /// Captures the panel exactly as the window server composites it.
    ///
    /// This is the only way to see what the user actually sees: a layer render can differ from the
    /// on-screen result (the glass effect in particular does not reproduce faithfully), and the
    /// self-test process cannot take a screenshot through the usual route.
    func testCaptureOnScreenPanel() -> CGImage? {
        guard let panel, panel.isVisible, panel.windowNumber > 0 else { return nil }

        typealias CreateImage = @convention(c) (CGRect, CGWindowListOption, CGWindowID, CGWindowImageOption) -> Unmanaged<CGImage>?
        guard let handle = dlopen(nil, RTLD_LAZY),
              let symbol = dlsym(handle, "CGWindowListCreateImage") else { return nil }
        let createImage = unsafeBitCast(symbol, to: CreateImage.self)

        return createImage(
            .null,
            .optionIncludingWindow,
            CGWindowID(panel.windowNumber),
            [.boundsIgnoreFraming, .bestResolution]
        )?.takeRetainedValue()
    }

    /// Writes the on-screen capture to disk.
    func testWriteOnScreenCapture(to url: URL) -> Bool {
        guard let image = testCaptureOnScreenPanel() else { return false }
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        do { try data.write(to: url); return true } catch { return false }
    }

    var testPlacementFacts: PlacementFacts? {
        guard let panel, panel.isVisible else { return nil }
        let panelRect = panel.frame
        let centre = CGPoint(x: panelRect.midX, y: panelRect.midY)
        let screen = NSScreen.screens.first { $0.frame.contains(centre) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero

        func toPanelCoordinates(_ view: NSView) -> CGRect {
            guard let content = panel.contentView else { return view.frame }
            return view.convert(view.bounds, to: content)
        }

        // Compared against the panel's own content rect below, so this must stay in the panel's
        // local coordinate space. Converting it to *screen* space here and comparing with
        // `panelRect` was a mistake in an earlier version of this check and made every panel look
        // like it overflowed.
        let gridRect = scrollView?.frame ?? gridView?.frame ?? .zero
        let gridFrame = gridView?.frame ?? .zero
        let contentBounds = panel.contentView?.bounds ?? .zero
        let gridSuper = gridView?.superview.map { String(describing: type(of: $0)) } ?? "nil"
        let gridSize = gridView?.bounds.size ?? .zero
        let gridIntrinsic = gridView.map { $0.intrinsicContentSize } ?? .zero
        var chain: [String] = []
        chain.append("panel.frame = \(panel.frame)")
        chain.append("panel.contentView = \(panel.contentView.map { String(describing: type(of: $0)) } ?? "nil") frame=\(panel.contentView?.frame ?? .zero) bounds=\(panel.contentView?.bounds ?? .zero)")
        if let host = panel.contentView {
            for (i, sub) in host.subviews.enumerated() {
                chain.append("  host.subviews[\(i)] = \(type(of: sub)) frame=\(sub.frame) bounds=\(sub.bounds) hidden=\(sub.isHidden) alpha=\(sub.alphaValue)")
                for (j, inner) in sub.subviews.enumerated() {
                    chain.append("      [\(i)].subviews[\(j)] = \(type(of: inner)) frame=\(inner.frame) bounds=\(inner.bounds) hidden=\(inner.isHidden)")
                }
            }
        }
        chain.append("grid superview = \(gridSuper)")
        chain.append("grid.frame = \(gridFrame)  bounds = \(gridSize)  intrinsic = \(gridIntrinsic)")
        chain.append("grid in content coords = \(gridRect)")
        chain.append("panel.alphaValue = \(panel.alphaValue)  isOpaque=\(panel.isOpaque)  level=\(panel.level.rawValue)")
        testDebugChain = chain

        let iconRect = currentItem.map { CoordinateConversion.cocoaRect(fromQuartz: $0.frame) } ?? .zero
        let edge = dockEdge(for: iconRect, visible: visible).map(String.init(describing:)) ?? "?"

        return PlacementFacts(
            panelRect: panelRect,
            visibleFrame: visible,
            gridRect: gridRect,
            contentRect: contentBounds,
            dockEdge: edge
        )
    }

    func testTilesWithThumbnails() -> Int {
        gridView?.tiles.filter { $0.hasThumbnail }.count ?? 0
    }

    /// The grid the panel believes it owns, and how many tiles it holds — used to prove that the
    /// test and the panel are looking at the same object.
    var testGridIdentity: String {
        guard let gridView else { return "grid=nil" }
        return "grid=\(ObjectIdentifier(gridView).debugDescription) tiles=\(gridView.tiles.count) superview=\(gridView.superview != nil)"
    }

    var testGridTileCount: Int { gridView?.tiles.count ?? -1 }

    /// Panel frame even when hidden, so the self test can assert geometry was computed.
    var testPanelFrame: CGRect? { panel?.frame }

    /// Renders the panel's layer tree into a bitmap for pixel-level inspection.
    ///
    /// `cacheDisplay(in:to:)` is unsuitable for this: it flattens the whole view into a fully opaque
    /// bitmap, so alpha carries no information and every corner looks "filled". Rendering the layer
    /// tree with `CALayer.render(in:)` leaves the bitmap transparent wherever nothing was drawn,
    /// which is exactly the signal needed — the panel itself paints no opaque background, so any
    /// opaque pixel in a rounded corner is a rendering defect rather than a false positive.
    func testRenderContentSnapshot() -> NSBitmapImageRep? {
        guard let content = panel?.contentView, content.bounds.width > 1 else { return nil }
        content.layoutSubtreeIfNeeded()

        let width = Int(content.bounds.width)
        let height = Int(content.bounds.height)
        guard width > 1, height > 1,
              let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: width,
                pixelsHigh: height,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
              ),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.clear(CGRect(x: 0, y: 0, width: width, height: height))
        content.layer?.render(in: context.cgContext)
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    /// Dumps the rendered panel to a PNG so it can be inspected by eye as well.
    func testWriteContentSnapshot(to url: URL) -> Bool {
        guard let rep = testRenderContentSnapshot(),
              let data = rep.representation(using: .png, properties: [:]) else { return false }
        do {
            try data.write(to: url)
            return true
        } catch {
            return false
        }
    }

    /// Immediate presentation state after a `present`, used to assert the transition behaviour.
    /// Sampled synchronously so it captures the state the animation *starts* from.
    var testPresentationState: (visible: Bool, alpha: CGFloat, scale: CGFloat) {
        let contentScale = panel?.contentView?.layer?.transform.m11 ?? 1
        return (panel?.isVisible ?? false, panel?.alphaValue ?? 0, contentScale)
    }

    /// History of grid mutations, for pinpointing who emptied the preview.
    var testGridTrace: [String] { gridView?.setTilesTrace ?? [] }

    /// Panel geometry plus every tile frame, so layout bugs are visible as numbers.
    func testLayoutDescription() -> [String] {
        var lines: [String] = []
        if let panel {
            lines.append("panel frame=\(rect(panel.frame)) alpha=\(String(format: "%.2f", panel.alphaValue)) visible=\(panel.isVisible)")
            if let content = panel.contentView {
                lines.append("content frame=\(rect(content.frame))")
            }
        }
        if let gridView {
            lines.append("grid frame=\(rect(gridView.frame)) tiles=\(gridView.tiles.count) intrinsic=\(rect(CGRect(origin: .zero, size: gridView.intrinsicContentSize)))")
            for (index, tile) in gridView.tiles.enumerated().prefix(6) {
                lines.append("  tile[\(index)] frame=\(rect(tile.frame)) 有图=\(tile.hasThumbnail)")
            }
        }
        return lines
    }

    private func rect(_ value: CGRect) -> String {
        "\(Int(value.minX)),\(Int(value.minY)) \(Int(value.width))x\(Int(value.height))"
    }
}
