import AppKit

/// Refresh visible windows gradually, retry failed captures, and retain minimized snapshots.
@MainActor
final class BackgroundCacheWarmer {
    private var timer: Timer?
    private var generation = 0
    private var appearanceTask: Task<Void, Never>?
    private var passTask: Task<Void, Never>?
    private var knownPids: Set<pid_t> = []
    private var attempts: [String: Date] = [:]
    private(set) var passCount = 0
    private(set) var captureCount = 0
    private(set) var lastPassDuration: TimeInterval = 0
    var isRunning: Bool { timer != nil }

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pass() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
    func stop() { generation += 1; timer?.invalidate(); timer = nil; passTask?.cancel(); passTask = nil; appearanceTask?.cancel(); appearanceTask = nil }
    /// Only windows visible on the current desktop are resampled for appearance changes.
    func resampleVisibleWindows() {
        appearanceTask?.cancel()
        let targets = WindowEnumerator.allCapturableWindows().filter { WindowActions.isOnCurrentDesktop($0) }
        targets.forEach { ThumbnailProvider.shared.requestRefresh($0) }
        appearanceTask = Task { @MainActor in
            for target in targets {
                guard !Task.isCancelled else { return }
                _ = await ThumbnailProvider.shared.thumbnail(for: target)
            }
        }
    }
    func reset() { attempts.removeAll(); knownPids.removeAll() }

    private func pass() {
        guard passTask == nil, Preferences.previewEnabled, Preferences.panelSize.showsThumbnails,
              Permissions.hasScreenRecording else { return }
        let started = Date()
        passCount += 1
        // Hidden apps and apps with no currently visible windows are still running.
        let livePids = Set(NSWorkspace.shared.runningApplications.filter { !$0.isTerminated }.map(\.processIdentifier))
        for pid in knownPids.subtracting(livePids) { ThumbnailProvider.shared.invalidateApp(pid: pid) }
        knownPids = livePids
        let windows = WindowEnumerator.allCapturableWindows()
        lastPassDuration = Date().timeIntervalSince(started)
        let identities = Set(windows.map(\.identity))
        attempts = attempts.filter { identities.contains($0.key) }
        let targets = windows.filter {
            ThumbnailProvider.shared.needsRefresh($0)
                && started.timeIntervalSince(attempts[$0.identity] ?? .distantPast) > 5
        }.sorted { (attempts[$0.identity] ?? .distantPast) < (attempts[$1.identity] ?? .distantPast) }.prefix(2)
        guard !targets.isEmpty else { return }
        for target in targets { attempts[target.identity] = started }
        captureCount += targets.count
        let passGeneration = generation
        passTask = Task { @MainActor [weak self] in
            for target in targets {
                guard !Task.isCancelled else { break }
                _ = await ThumbnailProvider.shared.thumbnail(for: target)
            }
            if self?.generation == passGeneration { self?.passTask = nil }
        }
    }
    var summary: String { "预热：\(passCount) 轮，已排入 \(captureCount) 个窗口，最近一轮枚举 \(Int(lastPassDuration * 1000)) ms" }
}
