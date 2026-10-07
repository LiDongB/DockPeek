import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Raising and focusing other applications' windows through the Accessibility API.
enum WindowActions {

    struct AXWindowInfo {
        let title: String
        let bounds: CGRect
        let isMain: Bool
        let isMinimized: Bool
        let identity: String
        let windowID: CGWindowID
    }

    private struct RegisteredWindow {
        let element: AXUIElement
        let identity: String
        var windowID: CGWindowID
        var bounds: CGRect
    }
    private static var registry: [pid_t: [RegisteredWindow]] = [:]

    static func forget(pid: pid_t) { registry[pid] = nil }

    static func bind(identity: String, pid: pid_t, windowID: CGWindowID) {
        guard let index = registry[pid]?.firstIndex(where: { $0.identity == identity }) else { return }
        registry[pid]?[index].windowID = windowID
    }

    // MARK: - Reading

    /// Windows as Accessibility sees them (includes minimised ones the window server hides).
    static func accessibilityWindows(pid: pid_t) -> [AXWindowInfo]? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        guard let windows: [AXUIElement] = copy(app, kAXWindowsAttribute) else { return nil }
        guard !windows.isEmpty else { return [] }
        let previous = registry[pid] ?? []
        registry[pid] = windows.map { element in
            previous.first(where: { CFEqual($0.element, element) })
                ?? RegisteredWindow(element: element, identity: "\(pid)|ax:\(UUID().uuidString)", windowID: 0, bounds: .zero)
        }
        return windows.map { window in
            var bounds = CGRect.zero
            if let position: AXValue = copy(window, kAXPositionAttribute),
               let size: AXValue = copy(window, kAXSizeAttribute) {
                var origin = CGPoint.zero
                var dimensions = CGSize.zero
                if AXValueGetValue(position, .cgPoint, &origin), AXValueGetValue(size, .cgSize, &dimensions) {
                    bounds = CGRect(origin: origin, size: dimensions)
                }
            }
            let index = registry[pid]!.firstIndex(where: { CFEqual($0.element, window) })!
            let minimized = (copy(window, kAXMinimizedAttribute) as Bool?) ?? false
            if bounds.width >= 80 && bounds.height >= 60 {
                registry[pid]?[index].bounds = bounds
            } else if minimized {
                let remembered = registry[pid]![index].bounds
                bounds = remembered.isEmpty ? CGRect(x: 0, y: 0, width: 640, height: 400) : remembered
            }
            return AXWindowInfo(
                title: (copy(window, kAXTitleAttribute) as String?) ?? "",
                bounds: bounds,
                isMain: (copy(window, kAXMainAttribute) as Bool?) ?? false,
                isMinimized: minimized,
                identity: registry[pid]!.first(where: { CFEqual($0.element, window) })!.identity,
                windowID: registry[pid]!.first(where: { CFEqual($0.element, window) })!.windowID
            )
        }
    }

    /// The `CGWindowID` of the app's focused window, or 0 when unknown.
    ///
    /// Note: `kAXWindowNumberAttribute` is not public, so the private `_AXUIElementGetWindow` is not
    /// used here; instead the focused window is matched by geometry against the window-server list.
    static func focusedWindowID(pid: pid_t) -> CGWindowID {
        guard let focusedRect = focusedWindowBounds(pid: pid) else { return 0 }
        guard let raw = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return 0 }

        for info in raw {
            guard let rawPID = info[kCGWindowOwnerPID as String] as? Int, rawPID == Int(pid) else { continue }
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
            guard let number = info[kCGWindowNumber as String] as? Int else { continue }
            guard let boundsDict = info[kCGWindowBounds as String] as? [String: Any] else { continue }
            var bounds = CGRect.zero
            guard CGRectMakeWithDictionaryRepresentation(boundsDict as CFDictionary, &bounds) else { continue }
            if abs(bounds.minX - focusedRect.minX) < 2, abs(bounds.minY - focusedRect.minY) < 2,
               abs(bounds.width - focusedRect.width) < 2, abs(bounds.height - focusedRect.height) < 2 {
                return CGWindowID(number)
            }
        }
        return 0
    }

    private static func focusedWindowBounds(pid: pid_t) -> CGRect? {
        let app = AXUIElementCreateApplication(pid)
        guard let window: AXUIElement = copy(app, kAXFocusedWindowAttribute) else { return nil }
        guard let position: AXValue = copy(window, kAXPositionAttribute),
              let size: AXValue = copy(window, kAXSizeAttribute) else { return nil }
        var origin = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(position, .cgPoint, &origin), AXValueGetValue(size, .cgSize, &dimensions) else {
            return nil
        }
        return CGRect(origin: origin, size: dimensions)
    }

    // MARK: - Raising

    /// Bring `target` to the front and give it keyboard focus.
    ///
    /// The window is first matched in the Accessibility window list by geometry (window ids are not
    /// exposed publicly), then raised with the `kAXRaiseAction` action.
    @discardableResult
    static func activate(_ target: WindowTarget) -> Bool {
        let appElement = AXUIElementCreateApplication(target.pid)
        AXUIElementSetMessagingTimeout(appElement, 0.25)
        guard let window = accessibilityWindow(matching: target, appElement: appElement) else { return false }
        var raised = false

        do {
            if (copy(window, kAXMinimizedAttribute) as Bool?) == true {
                AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            }
            let raiseResult = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            if raiseResult == .success { raised = true }

            AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
            AXUIElementSetAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, window)
        }

        // Activate the process itself so the window server puts it in front.
        if let running = NSRunningApplication(processIdentifier: target.pid) {
            let options: NSApplication.ActivationOptions = []
            running.activate(options: options)
            // A second, delayed pass fixes cases where the app was in another Space or minimised.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                if let running = NSRunningApplication(processIdentifier: target.pid) {
                    running.activate(options: options)
                }
                if let window = accessibilityWindow(matching: target, appElement: AXUIElementCreateApplication(target.pid)) {
                    AXUIElementPerformAction(window, kAXRaiseAction as CFString)
                }
            }
        }

        Log.info("activate window \(target.windowID) of pid \(target.pid) raised=\(raised)")
        return raised
    }

    private static func accessibilityWindow(
        matching target: WindowTarget,
        appElement: AXUIElement
    ) -> AXUIElement? {
        guard let windows: [AXUIElement] = copy(appElement, kAXWindowsAttribute) else { return nil }
        if let registered = registry[target.pid]?.first(where: { $0.identity == target.identity }) {
            return windows.first(where: { CFEqual($0, registered.element) })
        }

        // Best match: identical geometry (works with multiple displays and Spaces).
        for window in windows {
            guard let position: AXValue = copy(window, kAXPositionAttribute),
                  let size: AXValue = copy(window, kAXSizeAttribute) else { continue }
            var origin = CGPoint.zero
            var dimensions = CGSize.zero
            guard AXValueGetValue(position, .cgPoint, &origin), AXValueGetValue(size, .cgSize, &dimensions) else {
                continue
            }
            if abs(origin.x - target.bounds.minX) < 2, abs(origin.y - target.bounds.minY) < 2,
               abs(dimensions.width - target.bounds.width) < 2,
               abs(dimensions.height - target.bounds.height) < 2 {
                return window
            }
        }

        // An ambiguous title must never select an unrelated window.
        let matching = windows.filter { (copy($0, kAXTitleAttribute) as String?) == target.title }
        return !target.title.isEmpty && matching.count == 1 ? matching.first : nil
    }

    /// Only minimize the existing focused window of the already-active application.
    @discardableResult
    static func minimizeFocusedWindow(pid: pid_t) -> Bool {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return false }
        let focused = WindowEnumerator.windows(pid: pid, ownerName: "").first { $0.isMain }
        guard let focused, isOnCurrentDesktop(focused) else { return false }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        guard let window: AXUIElement = copy(app, kAXFocusedWindowAttribute),
              (copy(window, kAXMinimizedAttribute) as Bool?) == false else { return false }
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(window, kAXMinimizedAttribute as CFString, &settable) == .success,
              settable.boolValue else { return false }
        return AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanTrue) == .success
    }

    /// A single user action submits all standard-window close requests as one batch.
    /// AXPress preserves each app's own unsaved-document handling; it never force-quits the app.
    static func closeAll(pid: pid_t, completion: @escaping (Int) -> Void) {
        // In-process AX actions execute AppKit directly; these must stay on the main thread.
        if pid == ProcessInfo.processInfo.processIdentifier {
            DispatchQueue.main.async {
                NSApp.windows.filter { $0.isVisible && $0.styleMask.contains(.closable) }
                    .forEach { $0.performClose(nil) }
                completion(0)
            }
            return
        }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        guard let windows: [AXUIElement] = copy(app, kAXWindowsAttribute) else { completion(1); return }
        var unavailable = 0
        let requests = windows.compactMap { window -> CloseRequest? in
            let subrole: String? = copy(window, kAXSubroleAttribute)
            guard subrole == nil || subrole == kAXStandardWindowSubrole as String else { return nil }
            guard let button: AXUIElement = copy(window, kAXCloseButtonAttribute) else {
                unavailable += 1
                return nil
            }
            AXUIElementSetMessagingTimeout(button, 0.25)
            return CloseRequest(button: button)
        }
        let unavailableCount = unavailable
        DispatchQueue.global(qos: .userInitiated).async {
            DispatchQueue.concurrentPerform(iterations: requests.count) { index in requests[index].perform() }
            let failed = unavailableCount + requests.filter { !$0.succeeded }.count
            DispatchQueue.main.async { WindowEnumerator.invalidateCache(); completion(failed) }
        }
    }
    private final class CloseRequest: @unchecked Sendable {
        let button: AXUIElement
        var succeeded = false
        init(button: AXUIElement) { self.button = button }
        func perform() { succeeded = AXUIElementPerformAction(button, kAXPressAction as CFString) == .success }
    }

    static func isOnCurrentDesktop(_ target: WindowTarget) -> Bool {
        guard !target.isMinimized else { return false }
        let raw = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
        return raw.contains { ($0[kCGWindowNumber as String] as? UInt32) == target.windowID }
    }

    // MARK: - AX helper

    private static func copy<T>(_ element: AXUIElement, _ attribute: String) -> T? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success, let value else { return nil }
        return value as? T
    }
}
