import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// A single capturable window belonging to some running application.
struct WindowTarget: Identifiable, Sendable {
    let pid: pid_t
    let windowID: CGWindowID
    let ownerName: String
    let title: String
    /// Quartz global bounds (top-left origin).
    let bounds: CGRect
    /// True for the window that currently has keyboard focus in that app.
    let isMain: Bool
    /// True when the window is minimised — previews are still shown, and clicking un-minimises.
    let isMinimized: Bool

    var id: CGWindowID { windowID }

    /// Stable identity for this window, used to anchor cached thumbnails.
    ///
    /// It must survive the window being minimised. A minimised window leaves the window server's
    /// display list, so it can only be described through the Accessibility list — and the numeric
    /// id used for it there is not the real `CGWindowID`. Anchoring the cache on the raw id
    /// therefore lost the picture the moment a window was minimised, which is exactly the bug this
    /// property exists to prevent.
    ///
    /// The value is computed at enumeration time, where the real id and the Accessibility entry are
    /// both available, and is carried on the target so it cannot drift between passes.
    let identity: String

    /// Cache key for thumbnails. Derived from `identity`, never from geometry, so resizing or
    /// minimising a window keeps the same cached entry.
    var cacheKey: String { "win-\(identity)" }

    /// Builds the stable identity string.
    static func makeIdentity(pid: pid_t, ownerName: String, title: String, slot: Int) -> String {
        "\(pid)|cg:\(slot)"
    }

    /// Whether this looks like a real, user-facing window.
    ///
    /// The only case that needs special care is the *desktop* window. macOS keeps an accessibility
    /// window alive for applications that are running with nothing open — Finder is the notorious
    /// case, since it can never be quit — and previewing it produces an empty tile that reads as
    /// "still loading".
    ///
    /// The rule is deliberately narrow: a window the size of a whole display is only treated as the
    /// desktop when it has no title. Genuine full-screen windows are a normal way to work, so
    /// rejecting them by size alone would hide real windows (which is exactly what an earlier
    /// version of this check did).
    var isPlausibleWindow: Bool {
        guard bounds.width >= 80, bounds.height >= 60 else { return false }

        // Only Finder owns the desktop; documents in other apps can be named Desktop.
        guard NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == "com.apple.finder" else { return true }
        // Finder's desktop element titles itself "Desktop" — unambiguous.
        if title.compare("Desktop", options: .caseInsensitive) == .orderedSame { return false }

        // Untitled + exactly a full display is the other shape the desktop takes.
        if title.isEmpty, NSScreen.screens.contains(where: { screen in
            abs(screen.frame.width - bounds.width) < 2 && abs(screen.frame.height - bounds.height) < 2
        }) {
            return false
        }

        return true
    }
}

/// Enumerates on-screen windows and the application that owns them.
///
/// Uses `CGWindowListCopyWindowInfo`, which requires no permission, for window ids and geometry;
/// Accessibility is only used to identify the focused window and to raise windows later.
///
/// Results are cached per application for a very short window so that sweeping the pointer along
/// the Dock does not re-query the window server for every icon — that repeated query was a visible
/// part of the hover lag.
enum WindowEnumerator {

    private struct CacheEntry {
        let windows: [WindowTarget]
        let storedAt: Date
    }

    /// Short enough that a newly opened or closed window shows up almost immediately.
    private static let cacheTTL: TimeInterval = 0.5
    private static var cache: [String: CacheEntry] = [:]
    private static var discovered: [pid_t: [CaptureService.DiscoveredWindow]] = [:]
    private static var discoveryTime: [pid_t: Date] = [:]
    private static var discovering: Set<pid_t> = []
    static func refreshOtherDesktops(pid: pid_t) async {
        guard Permissions.hasScreenRecording, !discovering.contains(pid),
              Date().timeIntervalSince(discoveryTime[pid] ?? .distantPast) > 2 else { return }
        discovering.insert(pid)
        defer { discovering.remove(pid) }
        if let result = try? await CaptureService.shared.discoverWindows(pid: pid) {
            discovered[pid] = result
            discoveryTime[pid] = Date()
            cache["\(pid)"] = nil
        }
        let live = Set(NSWorkspace.shared.runningApplications.map(\.processIdentifier))
        discovered = discovered.filter { live.contains($0.key) }
        discoveryTime = discoveryTime.filter { live.contains($0.key) }
    }

    private static var discoveryTasks: [pid_t: Task<Void, Never>] = [:]
    private static func scheduleDiscovery(pid: pid_t) {
        guard discoveryTasks[pid] == nil, NSRunningApplication(processIdentifier: pid) != nil,
              Date().timeIntervalSince(discoveryTime[pid] ?? .distantPast) > 2 else { return }
        discoveryTasks[pid] = Task { @MainActor in
            await refreshOtherDesktops(pid: pid)
            discoveryTasks[pid] = nil
        }
    }

    /// Forces the next lookup to hit the window server, used when we know the window list changed.
    static func invalidateCache() {
        cache.removeAll(keepingCapacity: true)
    }

    /// All capturable windows of the given application, ordered as users expect them:
    /// the focused window first, then largest to smallest.
    static func windows(pid: pid_t, ownerName: String) -> [WindowTarget] {
        scheduleDiscovery(pid: pid)
        let key = "\(pid)"
        if let entry = cache[key], Date().timeIntervalSince(entry.storedAt) < cacheTTL {
            return entry.windows
        }

        let resolved = query(pid: pid, ownerName: ownerName)
        cache[key] = CacheEntry(windows: resolved, storedAt: Date())
        if cache.count > 32 { cache.removeAll(keepingCapacity: true) }
        return resolved
    }

    /// Number of windows the app owns, used to decide whether a preview is worth showing.
    static func windowCount(pid: pid_t) -> Int {
        windows(pid: pid, ownerName: "").count
    }

    /// Every capturable window belonging to a regular (Dock-visible) application.
    ///
    /// Used by the background cache warmer, which needs the whole picture rather than one app's
    /// windows. Applications with no windows are skipped before any window-server query, which keeps
    /// an idle pass cheap.
    static func allCapturableWindows() -> [WindowTarget] {
        let apps = NSWorkspace.shared.runningApplications.filter { app in
            app.activationPolicy == .regular
                && !app.isTerminated
                && app.bundleIdentifier != Bundle.main.bundleIdentifier
        }

        var result: [WindowTarget] = []
        // Fresh data for a background sweep: the short-lived cache exists to serve rapid hovering,
        // and a stale list here would mean a new window goes unnoticed.
        invalidateCache()

        for app in apps {
            let pid = app.processIdentifier
            guard pid > 0 else { continue }
            let windows = windows(pid: pid, ownerName: app.localizedName ?? "")
            guard !windows.isEmpty else { continue }
            result.append(contentsOf: windows)
        }
        return result
    }

    // MARK: - Window server query

    private struct ServerWindow {
        let id: CGWindowID
        let title: String
        let bounds: CGRect
        let onScreen: Bool
    }

    private static func query(pid: pid_t, ownerName: String) -> [WindowTarget] {
        guard let raw = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return [] }
        var server: [ServerWindow] = raw.compactMap { info in
            guard (info[kCGWindowOwnerPID as String] as? Int) == Int(pid),
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0.01,
                  let number = info[kCGWindowNumber as String] as? UInt32,
                  let dictionary = info[kCGWindowBounds as String] as? [String: Any] else { return nil }
            var bounds = CGRect.zero
            guard CGRectMakeWithDictionaryRepresentation(dictionary as CFDictionary, &bounds),
                  bounds.width >= 80, bounds.height >= 60 else { return nil }
            return ServerWindow(id: number, title: info[kCGWindowName as String] as? String ?? "",
                                bounds: bounds, onScreen: info[kCGWindowIsOnscreen as String] as? Bool ?? false)
        }
        let ids = Set(server.map(\.id))
        for window in discovered[pid] ?? [] where !ids.contains(window.id) && window.bounds.width >= 80 && window.bounds.height >= 60 {
            server.append(ServerWindow(id: window.id, title: window.title, bounds: window.bounds, onScreen: window.onScreen))
        }
        var used: Set<CGWindowID> = []
        var targets: [WindowTarget] = []
        for window in WindowActions.accessibilityWindows(pid: pid) ?? [] {
            let candidates = server.filter { !used.contains($0.id) }
            let titles = candidates.filter { !window.title.isEmpty && $0.title == window.title }
            let match = candidates.first(where: { $0.id == window.windowID && window.windowID != 0 })
                ?? candidates.first(where: { approximatelyEqual($0.bounds, window.bounds) && $0.title == window.title })
                ?? candidates.first(where: { approximatelyEqual($0.bounds, window.bounds) })
                ?? (titles.count == 1 ? titles.first : nil)
            let id = match?.id ?? window.windowID
            if let match { used.insert(match.id); WindowActions.bind(identity: window.identity, pid: pid, windowID: match.id) }
            let target = WindowTarget(pid: pid, windowID: id, ownerName: ownerName, title: window.title,
                                      bounds: window.bounds, isMain: window.isMain,
                                      isMinimized: window.isMinimized, identity: window.identity)
            if target.isPlausibleWindow { targets.append(target) }
        }
        for window in server where !used.contains(window.id) {
            let target = WindowTarget(pid: pid, windowID: window.id, ownerName: ownerName, title: window.title,
                                      bounds: window.bounds, isMain: false, isMinimized: false,
                                      identity: WindowTarget.makeIdentity(pid: pid, ownerName: ownerName, title: window.title, slot: Int(window.id)))
            if target.isPlausibleWindow { targets.append(target) }
        }
        return targets.sorted {
            if $0.isMain != $1.isMain { return $0.isMain }
            if $0.isMinimized != $1.isMinimized { return !$0.isMinimized }
            if $0.bounds.width * $0.bounds.height != $1.bounds.width * $1.bounds.height {
                return $0.bounds.width * $0.bounds.height > $1.bounds.width * $1.bounds.height
            }
            return $0.identity < $1.identity
        }
    }

    static func approximatelyEqual(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 2 && abs(a.minY - b.minY) < 2
            && abs(a.width - b.width) < 2 && abs(a.height - b.height) < 2
    }
}
