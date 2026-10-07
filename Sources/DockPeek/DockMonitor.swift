import AppKit
import ApplicationServices
import Foundation

/// One icon in the Dock, resolved to a running application.
struct DockItem: Equatable, Sendable {
    /// Localised app name as shown by the Dock.
    let name: String
    /// Icon frame in *Quartz global* coordinates (origin top-left, y grows downwards).
    let frame: CGRect
    /// The app bundle the icon points at, from the dock item's `AXURL` attribute when available.
    let bundleURL: URL?
    /// Bundle identifier derived from `bundleURL`.
    let bundleID: String?
    /// The Dock's own answer to "is this app running?" (`AXIsApplicationRunning`).
    let isApplicationRunning: Bool

    init(name: String, frame: CGRect, bundleURL: URL?, isApplicationRunning: Bool) {
        self.name = name
        self.frame = frame
        self.bundleURL = bundleURL
        self.bundleID = bundleURL.flatMap { Bundle(url: $0)?.bundleIdentifier }
        self.isApplicationRunning = isApplicationRunning
    }

    /// Identity, **not** geometry.
    ///
    /// Dock magnification changes an icon's frame continuously while the pointer moves across it.
    /// Comparing frames therefore made "the same icon, slightly larger" look like "a different
    /// icon", which reset the dwell timer and made the preview flicker whenever the hand moved a
    /// few pixels. Only the app the icon points at matters.
    static func == (lhs: DockItem, rhs: DockItem) -> Bool {
        lhs.name == rhs.name && lhs.bundleID == rhs.bundleID
    }
}

/// Watches the Dock and reports which icon the pointer is resting on.
///
/// Detection is a cheap 20 Hz hit-test of the cursor against cached icon frames, so the app
/// stays idle-expensive-free: no polling of window lists, no capture, until a dwell completes.
@MainActor
final class DockMonitor {

    /// Dwell time before a preview appears.
    ///
    /// Read from preferences on every poll so a change in the preferences window takes effect
    /// immediately, without restarting the app.
    static var dwellTime: TimeInterval { Preferences.dwellTime }

    /// Dwell used once a preview is already on screen. Sweeping along the Dock should switch
    /// instantly instead of making the user wait through the full delay again.
    static var switchDelay: TimeInterval { Preferences.switchDelay }
    private let pollInterval: TimeInterval = 0.05
    /// Dock geometry is re-read on this cadence to pick up magnification and layout changes.
    private let geometryRefreshInterval: TimeInterval = 1.0

    private let onHover: (DockItem?) -> Void

    private var frames: [DockItem] = []
    private var lastGeometryRefresh = Date.distantPast
    private var cachedRunningApps: [String: NSRunningApplication] = [:]
    private var lastRunningAppRefresh = Date.distantPast

    private var pollTimer: Timer?
    private var currentHover: DockItem?
    private var hoverBeganAt: Date?
    private var reportedItem: DockItem?

    /// Region (Quartz-global, i.e. top-left origin) that counts as "still on the preview".
    ///
    /// Without this the panel would vanish the instant the pointer left the icon, making it
    /// impossible to travel from the Dock into the preview and click a thumbnail.
    var retentionRect: CGRect?

    init(onHover: @escaping (DockItem?) -> Void) {
        self.onHover = onHover
    }

    // MARK: - Lifecycle

    func start() {
        stop()

        let timer = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        // .common so detection keeps working while a menu is tracking.
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(windowsMayHaveChanged),
                                                         name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        // Workspace changes mean the window list moved on: drop the cached enumeration so the next
        // hover sees reality, then re-read the Dock's icon geometry.
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(activeApplicationChanged(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        // Window moved/resized: the cached picture is the wrong shape now.
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(windowGeometryChanged(_:)),
            name: NSWindow.didResizeNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(windowGeometryChanged(_:)),
            name: NSWindow.didMoveNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(windowsMayHaveChanged),
            name: NSWorkspace.didHideApplicationNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(windowsMayHaveChanged),
            name: NSWorkspace.didUnhideApplicationNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(windowsMayHaveChanged),
            name: NSWorkspace.didLaunchApplicationNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(applicationTerminated(_:)),
            name: NSWorkspace.didTerminateApplicationNotification,
            object: nil
        )
        // The Dock is relaunched whenever display or Dock settings change.
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(dockRestarted),
            name: NSWorkspace.didLaunchApplicationNotification,
            object: nil
        )

        refreshGeometry(force: true)
        Log.info("dock monitor started, \(frames.count) icons resolved")
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        resetHover(notify: false)
    }

    @objc private func screenParametersChanged() {
        invalidateGeometry()
    }

    @objc private func workspaceChanged() {
        lastRunningAppRefresh = .distantPast
        invalidateGeometry()
    }

    /// A window was opened, closed, hidden or focused: the cached window list is stale.
    @objc private func windowsMayHaveChanged() {
        WindowEnumerator.invalidateCache()
        lastRunningAppRefresh = .distantPast
    }

    /// The active application changed, so whatever it was showing is now different from the last
    /// remembered picture. Dropping its thumbnails keeps previews current without re-capturing
    /// everything.
    @objc private func activeApplicationChanged(_ notification: Notification) {
        WindowEnumerator.invalidateCache()
        lastRunningAppRefresh = .distantPast

        // Keep the last good frame. The provider refreshes it without deleting minimized snapshots.
    }

    /// The window server reports a window moving or resizing; drop the affected thumbnail so a
    /// changed shape is not shown at the old shape.
    @objc private func windowGeometryChanged(_ notification: Notification) {
        WindowEnumerator.invalidateCache()
        // The window list is re-read, so the new frame shape is picked up on the next hover. The
        // cached picture is deliberately NOT dropped here: a resize does not invalidate the content,
        // and discarding it just makes the next hover re-capture for no visible benefit.
    }

    /// An application quit: its windows are gone for good, so both the window list and the cached
    /// pictures for that app are dropped.
    @objc private func applicationTerminated(_ notification: Notification) {
        WindowEnumerator.invalidateCache()
        lastRunningAppRefresh = .distantPast
        if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
            ThumbnailProvider.shared.invalidateApp(pid: app.processIdentifier)
        }
    }

    @objc private func dockRestarted(_ notification: Notification) {
        if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
           app.bundleIdentifier == "com.apple.dock" {
            Log.info("Dock restarted; re-reading icon geometry")
            invalidateGeometry()
        }
    }

    /// Tolerance when hit-testing the retention rect, in points.
    private let retentionTolerance: CGFloat = 2

    func invalidateGeometry() {
        lastGeometryRefresh = .distantPast
    }

    // MARK: - Hover state machine (pure, injectable)

    /// Outcome of one hover-state-machine step.
    enum HoverAction: Equatable {
        /// Nothing visible changes.
        case nothing
        /// Show the preview for `resolved`; `hit` is the icon the pointer is on.
        case show(hit: DockItem, resolved: DockItem)
        /// Take the preview down.
        case hide
    }

    /// State of the hover machine. Extracted so the transitions can be tested deterministically,
    /// without depending on the live Dock, real cursor positions or wall-clock timing.
    struct HoverState {
        var currentHover: DockItem?
        var hoverBeganAt: Date?
        var reportedItem: DockItem?
        /// When the pointer last failed to register on any icon, or `nil` while it is on one.
        var missBeganAt: Date?
    }

    /// One step of the hover machine.
    ///
    /// `dwellTime` applies when nothing is showing; once a preview is up the much shorter
    /// `switchDelay` applies, so gliding along the Dock switches instantly instead of making the
    /// user wait through the full delay again.
    static func hoverStep(
        state: inout HoverState,
        hit: DockItem?,
        now: Date,
        dwellTime: TimeInterval,
        switchDelay: TimeInterval,
        gracePeriod: TimeInterval,
        isRetained: Bool,
        resolve: (DockItem) -> DockItem?
    ) -> HoverAction {
        guard let hit else {
            state.currentHover = nil
            state.hoverBeganAt = nil

            // Travelling into the preview panel keeps it alive indefinitely.
            if isRetained {
                state.missBeganAt = nil
                return .nothing
            }
            guard state.reportedItem != nil else {
                state.missBeganAt = nil
                return .nothing
            }
            // Start (or continue) the grace window before actually hiding.
            let began = state.missBeganAt ?? now
            state.missBeganAt = began
            guard now.timeIntervalSince(began) >= gracePeriod else { return .nothing }

            state.reportedItem = nil
            state.missBeganAt = nil
            return .hide
        }

        // Back on an icon: any pending grace window is cancelled.
        state.missBeganAt = nil

        if state.currentHover != hit {
            state.currentHover = hit
            state.hoverBeganAt = now
            return .nothing
        }

        guard let began = state.hoverBeganAt else {
            state.hoverBeganAt = now
            return .nothing
        }

        let required = state.reportedItem == nil ? dwellTime : switchDelay
        guard now.timeIntervalSince(began) >= required else { return .nothing }
        guard state.reportedItem != hit else { return .nothing }
        guard let resolved = resolve(hit) else { return .nothing }

        state.reportedItem = hit
        return .show(hit: hit, resolved: resolved)
    }

    // MARK: - Diagnostics

    /// Number of Dock icons currently resolved; `0` means the Accessibility permission is missing
    /// (the Dock's children are invisible to us without it) or the Dock layout could not be read.
    var resolvedIconCount: Int { frames.count }

    /// The resolved icons themselves, exposed for the self test.
    var dockIcons: [DockItem] { frames }

    var isRunning: Bool { pollTimer != nil }

    /// Number of poll cycles executed. A steadily increasing value is the only proof that the
    /// hover loop is actually alive in the running app (as opposed to merely constructed).
    private(set) var tickCount = 0

    /// Resolved count so far, for the self test's long-run assertion.
    var lastTickHadIcons: Bool { lastTickIconCount > 0 }
    private(set) var lastTickIconCount = 0

    /// Runs one poll cycle on demand, so `--diagnose` can report the pointer/Dock state
    /// immediately instead of waiting for the timer to fire.
    func tickForDiagnostics() {
        tick()
    }

    /// Runs a poll cycle against a synthetic pointer location. Used by the self test, which cannot
    /// move the real mouse, to prove that the hover hit test and dwell detection actually work.
    ///
    /// While `syntheticPointer` is set the timer is suppressed, otherwise the live pointer position
    /// (which is somewhere else entirely) would keep resetting the state machine under test.
    private(set) var syntheticPointer = false

    func tick(at point: CGPoint, synthetic: Bool = true) {
        syntheticPointer = synthetic
        tick(point: point)
    }

    /// True when a resolved preview was reported for the pointer position (i.e. the hover fired).
    var hasReportedPreview: Bool { reportedItem != nil }

    /// The icon under a given point, or `nil` when the point is not on the Dock.
    ///
    /// Dock icons are drawn with a gap between them (and magnification changes their frames as the
    /// pointer moves). A strict `contains` check makes the preview flicker off whenever the pointer
    /// crosses that gap, so a point that is close to exactly one icon snaps to it.
    func icon(at point: CGPoint) -> DockItem? {
        if let exact = frames.first(where: { $0.frame.contains(point) }) { return exact }

        // Snap across the inter-icon gap, but only when one icon is unambiguously nearest.
        let slop: CGFloat = 8
        let nearest = frames
            .map { ($0, $0.frame.insetBy(dx: -slop, dy: -slop)) }
            .filter { $0.1.contains(point) }
        return nearest.count == 1 ? nearest[0].0 : nil
    }

    /// The freshest known frame for a named icon. Dock geometry is re-read periodically, so callers
    /// that need to inject a pointer position must ask for it right before use rather than caching
    /// a coordinate read earlier.
    func icon(named name: String) -> DockItem? {
        frames.first { $0.name == name }
    }

    /// Re-reads the Dock's icon geometry immediately.
    ///
    /// The poll loop refreshes geometry on its own cadence, which means a pointer position computed
    /// from an older read can be stale by the time it is tested. Production never cares (the real
    /// cursor is always compared against the newest frames), but anything injecting coordinates must
    /// refresh first or it will be intermittently wrong.
    func refreshGeometryNow() {
        refreshGeometry(force: true)
    }

    /// How long the pointer has been resting on the current icon, for live diagnostics.
    var currentDwellSeconds: TimeInterval? {
        hoverBeganAt.map { Date().timeIntervalSince($0) }
    }

    /// True while the preview for the hovered icon is considered shown.
    var previewIsReported: Bool { reportedItem != nil }

    /// Consecutive poll cycles for which the reported icon resolved to no windows.
    ///
    /// `present(for:)` must not tear the preview down the instant a window list comes back empty:
    /// enumeration can momentarily return nothing while a window is being created, resized or
    /// re-layered, and reacting to that makes the preview flicker. Reverting is only believed once
    /// it has been seen repeatedly.
    private var emptyChecksForReportedIcon = 0
    private let emptyChecksBeforeHiding = 4

    /// How long a preview survives after the pointer stops registering on any icon.
    ///
    /// Hand tremor, the few pixels of gap between Dock icons and Dock magnification all produce
    /// momentary misses. Hiding on the first one is what made the panel blink; a short grace period
    /// absorbs them while still hiding promptly when the pointer really leaves.
    private let missGrace: TimeInterval = 0.22
    private var missBeganAt: Date?

    /// Dumps the Dock's full Accessibility tree. Used by `--dump-dock` to discover the real
    /// element structure on this macOS version instead of guessing at attribute names.
    static func dumpDockTree() -> String {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first
        else { return "找不到 Dock 进程" }

        let root = AXUIElementCreateApplication(dock.processIdentifier)
        // The Dock can be slow to answer; do not let a single call hang the dump.
        AXUIElementSetMessagingTimeout(root, 2.0)

        var output: [String] = ["Dock AX 树（pid \(dock.processIdentifier)）"]
        walk(root, depth: 0, into: &output, limit: 900)
        return output.joined(separator: "\n")
    }

    private static func walk(_ element: AXUIElement, depth: Int, into output: inout [String], limit: Int) {
        guard output.count < limit else { return }
        let indent = String(repeating: "  ", count: depth)

        let role = string(element, kAXRoleAttribute) ?? "?"
        let subrole = string(element, kAXSubroleAttribute) ?? ""
        let identifier = string(element, kAXIdentifierAttribute)
        let title = string(element, kAXTitleAttribute)
        let description = string(element, kAXDescriptionAttribute)

        var line = "\(indent)\(role)"
        if !subrole.isEmpty { line += "/\(subrole)" }
        if let title, !title.isEmpty { line += " title=\(sanitise(title))" }
        if let identifier, !identifier.isEmpty { line += " id=\(sanitise(identifier))" }
        if let description, !description.isEmpty { line += " desc=\(sanitise(description))" }
        if let frame = frameOf(element) {
            line += " frame=\(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))x\(Int(frame.height))"
        }
        output.append(line)

        // Dump every attribute name for dock items: the Dock does not expose a bundle id through the
        // documented ones, so this reveals whether a private attribute carries the app path.
        if role == "AXDockItem" {
            var names: CFArray?
            if AXUIElementCopyAttributeNames(element, &names) == .success,
               let list = names as? [String] {
                output.append("\(indent)  attrs: \(list.joined(separator: ", "))")
                for key in list where key == "AXURL" || key == "AXFilename" || key == "AXBundleIdentifier" {
                    if let value = string(element, key) {
                        output.append("\(indent)  \(key) = \(sanitise(value))")
                    }
                }
            }
        }

        // Do not descend into menu-bar extras; the icons live in the main list.
        if depth > 6 { return }
        guard let children: [AXUIElement] = copyAttribute(element, kAXChildrenAttribute) else { return }
        for child in children { walk(child, depth: depth + 1, into: &output, limit: limit) }
    }

    private static func sanitise(_ text: String) -> String {
        let single = text.replacingOccurrences(of: "\n", with: "\\n")
        return single.count > 90 ? String(single.prefix(90)) + "…" : single
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value else { return nil }
        return value as? String
    }

    /// Human readable snapshot of everything that can go wrong, for support requests.
    func diagnostics() -> String {
        var lines: [String] = []
        lines.append("DockPeek 诊断")
        lines.append(Version.detail)
        lines.append("时间：\(Date())")
        lines.append("轮询运行中：\(isRunning ? "是" : "否")")
        lines.append("Dock 进程：\(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").isEmpty ? "未找到" : "已找到")")
        lines.append("识别到的 Dock 图标数：\(frames.count)")
        lines.append("当前悬停：\(currentHover.map { "\($0.name) [\($0.bundleID ?? "?")]" } ?? "无")")
        lines.append("已上报预览：\(reportedItem.map { "\($0.name)" } ?? "无")")
        lines.append("保留区域：\(retentionRect.map { "\($0)" } ?? "无")")
        lines.append("设备控制和数据访问：\(Permissions.hasDeviceAccess ? "已授权" : "未授权")")
        lines.append("屏幕录制权限：\(Permissions.hasScreenRecording ? "已授权" : "未授权")")
        lines.append("内存占用：\(MemoryFootprint.formatted())")

        let mouse = CGEvent(source: nil)?.location ?? .zero
        let hit = frames.first { $0.frame.contains(mouse) }
        lines.append("鼠标位置（Quartz）：\(Int(mouse.x)),\(Int(mouse.y))")
        lines.append("命中图标：\(hit.map { "\($0.name)" } ?? "无")")

        lines.append("")
        lines.append("图标明细（Quartz 坐标）：")
        if frames.isEmpty {
            lines.append("  （空 — 若权限已授权，说明 Dock 未能读取到图标）")
        } else {
            for (index, item) in frames.enumerated() {
                lines.append("  \(index + 1). \(item.name) | \(item.bundleID ?? "无 bundleID") | \(item.bundleURL?.path ?? "无 AXURL") | \(Int(item.frame.minX)),\(Int(item.frame.minY)) \(Int(item.frame.width))x\(Int(item.frame.height)) | Dock报告运行中:\(item.isApplicationRunning ? "是" : "否")")
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Poll loop

    private func tick() {
        guard !syntheticPointer else { return }
        let mouse = CGEvent(source: nil)?.location ?? .zero
        tick(point: mouse)
    }

    /// The whole hover state machine, driven by an explicit pointer position.
    ///
    /// `mouse` is the pointer in Quartz-global coordinates. It must be the *parameter*, not a fresh
    /// `CGEvent` read: the self test injects synthetic positions, and reading the live pointer here
    /// would silently ignore them and make the test depend on where the real mouse happens to be.
    private func tick(point mouse: CGPoint) {
        tickCount += 1
        refreshGeometry(force: false)
        lastTickIconCount = frames.count

        // The decision itself lives in `hoverStep`, which is pure and unit-tested. This method only
        // gathers the inputs and performs the resulting side effects.
        var state = HoverState(
            currentHover: currentHover,
            hoverBeganAt: hoverBeganAt,
            reportedItem: reportedItem,
            missBeganAt: missBeganAt
        )

        let retained = isRetained(mouse)
        let hit = icon(at: mouse)
        let action = Self.hoverStep(
            state: &state,
            hit: hit,
            now: Date(),
            dwellTime: Self.dwellTime,
            switchDelay: Self.switchDelay,
            gracePeriod: missGrace,
            isRetained: retained,
            resolve: { [weak self] item in self?.resolve(item) }
        )

        currentHover = state.currentHover
        hoverBeganAt = state.hoverBeganAt
        reportedItem = state.reportedItem
        missBeganAt = state.missBeganAt

        switch action {
        case .nothing:
            break
        case .hide:
            onHover(nil)
        case let .show(_, resolved):
            emptyChecksForReportedIcon = 0
            onHover(resolved)
        }
    }

    /// Called when the panel finds no windows for the hovered app.
    ///
    /// Returns `true` when that should be acted on (the preview hidden). Occasional empty reads are
    /// treated as noise: enumeration can momentarily return nothing while a window is being
    /// created, resized or re-layered, and hiding on the first such read makes the preview flicker
    /// and breaks repeat hovers.
    func shouldAcceptEmptyWindowList() -> Bool {
        emptyChecksForReportedIcon += 1
        let accept = emptyChecksForReportedIcon >= emptyChecksBeforeHiding
        Log.debug("empty window list for \(reportedItem?.name ?? "?") — \(emptyChecksForReportedIcon)/\(emptyChecksBeforeHiding)\(accept ? " → hide" : " → keep preview")")
        return accept
    }

    /// A running app may open its first window after the pointer has already reached its icon.
    func retryCurrentHover() { resetHover(notify: false) }

    private func resetHover(notify: Bool) {
        currentHover = nil
        hoverBeganAt = nil
        missBeganAt = nil
        if notify, reportedItem != nil { onHover(nil) }
        reportedItem = nil
    }

    /// True while the pointer is inside the preview panel that belongs to the current hover.
    private func isRetained(_ point: CGPoint) -> Bool {
        guard reportedItem != nil, let rect = retentionRect else { return false }
        return rect.insetBy(dx: -retentionTolerance, dy: -retentionTolerance).contains(point)
    }

    // MARK: - Dock geometry

    private func refreshGeometry(force: Bool) {
        let now = Date()
        guard force || now.timeIntervalSince(lastGeometryRefresh) >= geometryRefreshInterval else { return }
        lastGeometryRefresh = now

        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first
        else {
            if !frames.isEmpty {
                frames = []
                Log.info("Dock process not found; icon cache cleared")
            }
            return
        }

        let dockElement = AXUIElementCreateApplication(dock.processIdentifier)
        // The Dock can be unresponsive while it animates; never block the UI on it.
        AXUIElementSetMessagingTimeout(dockElement, 1.0)

        frames = Self.scanDockIcons(dockElement, depth: 0)
    }

    /// Collects the app icons out of the Dock's Accessibility tree.
    ///
    /// The icons are **not** direct children of the dock application element: on current macOS they
    /// live inside an `AXList`, each one an `AXDockItem` carrying:
    ///   * `AXSubrole` = `AXApplicationDockItem` (distinguishes apps from Trash/folders/separators)
    ///   * `AXTitle`   = the app's display name — there is **no** `AXIdentifier` on Dock icons
    ///   * `AXPosition` + `AXSize` = the icon frame in Quartz-global coordinates
    ///
    /// The tree is walked a few levels deep rather than assuming a fixed shape, so this keeps
    /// working if the Dock nests its list differently.
    private static func scanDockIcons(_ element: AXUIElement, depth: Int) -> [DockItem] {
        guard depth <= 4 else { return [] }
        guard let children: [AXUIElement] = copyAttribute(element, kAXChildrenAttribute) else { return [] }

        var found: [DockItem] = []
        for child in children {
            let role = string(child, kAXRoleAttribute) ?? ""
            let subrole = string(child, kAXSubroleAttribute) ?? ""

            if role == "AXDockItem" {
                // Only application tiles get a preview; Trash, folders and separators are skipped.
                guard subrole == "AXApplicationDockItem" else { continue }
                guard let frame = frameOf(child), frame.width > 4, frame.height > 4 else { continue }
                let name = string(child, kAXTitleAttribute) ?? ""
                guard !name.isEmpty else { continue }

                found.append(
                    DockItem(
                        name: name,
                        frame: frame,
                        bundleURL: url(child, "AXURL"),
                        isApplicationRunning: bool(child, "AXIsApplicationRunning") ?? false
                    )
                )
            } else {
                found.append(contentsOf: scanDockIcons(child, depth: depth + 1))
            }
        }
        return found
    }

    /// Reads an `AXURL` style attribute. Some accessibility values surface as `URL` and others as
    /// `String`, so both are accepted.
    private static func url(_ element: AXUIElement, _ attribute: String) -> URL? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value else { return nil }
        if let url = value as? URL { return url }
        if let string = value as? String { return URL(string: string) }
        return nil
    }

    private static func bool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value else { return nil }
        return value as? Bool
    }

    private func resolve(_ icon: DockItem) -> DockItem? {
        // The Dock tells us directly whether the app is running; that is the cheapest gate and
        // avoids showing a preview for a launch-only icon.
        if icon.isApplicationRunning { return icon }

        // Fallback for the (rare) case where the Dock did not report the flag.
        let running = NSWorkspace.shared.runningApplications.contains { app in
            guard app.activationPolicy == .regular else { return false }
            if let bundleID = icon.bundleID, app.bundleIdentifier == bundleID { return true }
            if let bundleURL = icon.bundleURL, app.bundleURL == bundleURL { return true }
            return app.localizedName == icon.name
                || app.bundleURL?.deletingPathExtension().lastPathComponent == icon.name
        }
        return running ? icon : nil
    }

    private func runningApp(bundleID: String) -> NSRunningApplication? {
        let now = Date()
        if now.timeIntervalSince(lastRunningAppRefresh) > 2 {
            lastRunningAppRefresh = now
            cachedRunningApps = Dictionary(
                NSWorkspace.shared.runningApplications
                    .filter { $0.activationPolicy == .regular }
                    .compactMap { app in app.bundleIdentifier.map { ($0, app) } },
                uniquingKeysWith: { first, _ in first }
            )
        }
        return cachedRunningApps[bundleID]
    }

    // MARK: - AX helpers

    private static func copyAttribute<T>(_ element: AXUIElement, _ attribute: String) -> T? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success, let value else { return nil }
        return value as? T
    }

    private static func frameOf(_ element: AXUIElement) -> CGRect? {
        guard let positionValue: AXValue = copyAttribute(element, kAXPositionAttribute),
              let sizeValue: AXValue = copyAttribute(element, kAXSizeAttribute)
        else { return nil }

        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue, .cgPoint, &origin),
              AXValueGetValue(sizeValue, .cgSize, &size)
        else { return nil }

        return CGRect(origin: origin, size: size)
    }
}
