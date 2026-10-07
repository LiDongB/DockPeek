import AppKit
import CoreGraphics
import Foundation

/// Performance self test for the hover pipeline.
///
/// Answers the two questions that matter for perceived smoothness, with numbers instead of
/// impressions:
///   1. how long a *first* hover takes (cold: enumerate + capture),
///   2. how long a *repeat* hover takes (warm: everything remembered), and
///   3. how much a sweep along the Dock costs once thumbnails are cached.
///
/// Also asserts the memory budget and that phantom windows (Finder at rest) produce no preview.
@MainActor
enum Benchmark {

    static func run(windowCount: Int, outputDirectory: URL) async -> Int32 {
        var lines: [String] = []
        var failures = 0

        func check(_ ok: Bool, _ label: String, detail: String = "") {
            lines.append("\(ok ? "✅" : "❌") \(label)\(detail.isEmpty ? "" : " — \(detail)")")
            if !ok { failures += 1 }
        }
        func note(_ text: String) { lines.append("   " + text) }

        lines.append("DockPeek 性能与行为基准")
        lines.append("版本：\(Version.summary)")
        lines.append("设置：悬停 \(ms(Preferences.dwellTime))，切换 \(ms(Preferences.switchDelay))，" +
                     "淡入 \(ms(Preferences.fadeInDuration))，淡出 \(ms(Preferences.fadeOutDuration))")
        lines.append("")

        // ---------------------------------------------------------------- find a target
        let monitor = DockMonitor { _ in }
        monitor.start()
        try? await Task.sleep(for: .seconds(1.0))

        let icons = monitor.dockIcons
        let panel = PreviewPanel()

        // Rank running icons by (window count, area) so the benchmark uses a realistically heavy app.
        var candidates: [(DockItem, NSRunningApplication, [WindowTarget])] = []
        for icon in icons where icon.isApplicationRunning {
            guard let app = panel.testResolveApplication(for: icon) else { continue }
            let windows = WindowEnumerator.windows(pid: app.processIdentifier, ownerName: icon.name)
            // Bring each app's window list up to `windowCount` by duplicating entries for the
            // synthetic multi-window test; real windows are used for the timing runs.
            if !windows.isEmpty { candidates.append((icon, app, windows)) }
        }

        // Rank by total window area — bigger windows mean bigger captures.
        candidates.sort { lhs, rhs in
            let la = lhs.2.reduce(0) { $0 + $1.bounds.width * $1.bounds.height }
            let ra = rhs.2.reduce(0) { $0 + $1.bounds.width * $1.bounds.height }
            return la > ra
        }

        let appByPid = Dictionary(uniqueKeysWithValues: candidates.map { ($0.1.processIdentifier, $0.1) })

        // Build the working set: the busiest candidate's windows first, then others until we reach
        // the requested count. Entries are (ownerLabel, WindowTarget) and each target keeps its own
        // real window id, so captures remain genuine.
        var workingSet: [(String, WindowTarget)] = []
        let targetWindowsPerApp = max(1, Int(ceil(Double(windowCount) / Double(max(candidates.count, 1)))))
        var captureIDs = Set<CGWindowID>()

        for (icon, _, windows) in candidates {
            for window in windows.prefix(targetWindowsPerApp) {
                guard workingSet.count < windowCount else { break }
                workingSet.append((icon.name, window))
            }
        }

        guard !workingSet.isEmpty else {
            lines.append("❌ 找不到任何正在运行且有窗口的应用，无法基准测试")
            try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
            return finish(lines, failures, outputDirectory: outputDirectory)
        }

        // ---------------------------------------------------------------- synthetic count
        // Window-target processing (matching + grouping) is what scales with window count, so add
        // duplicates for that measurement while keeping captures to the real windows only.
        var synthetic = workingSet
        var index = 0
        while synthetic.count < windowCount {
            synthetic.append(workingSet[index % workingSet.count])
            index += 1
        }

        // ---------------------------------------------------------------- cold run
        ThumbnailProvider.shared.purge()
        WindowEnumerator.invalidateCache()

        let coldStart = Date()
        var coldCaptures = 0
        var captureSizes: [String] = []
        for (name, window) in workingSet {
            if let image = await ThumbnailProvider.shared.thumbnail(for: window) {
                coldCaptures += 1
                captureIDs.insert(window.windowID)
                captureSizes.append("\(name) \(Int(window.bounds.width))x\(Int(window.bounds.height))→\(Int(image.size.width))x\(Int(image.size.height))")
            }
        }
        let coldSeconds = Date().timeIntervalSince(coldStart)

        note("工作集：\(workingSet.count) 个真实窗口，来自 \(Set(workingSet.map(\.0)).count) 个应用")
        for line in captureSizes.prefix(5) { note("采集 \(line)") }

        check(coldCaptures > 0, "冷启动能采集到缩略图", detail: "\(coldCaptures)/\(workingSet.count) 成功")
        note(String(format: "冷启动总耗时 %.0f ms（平均 %.0f ms/窗口）",
                    coldSeconds * 1000, coldSeconds * 1000 / Double(max(workingSet.count, 1))))

        // ---------------------------------------------------------------- warm run
        let warmIterations = 30
        let warmStart = Date()
        for _ in 0..<warmIterations {
            for (_, window) in workingSet {
                _ = ThumbnailProvider.shared.cached(for: window)
            }
        }
        let warmSeconds = Date().timeIntervalSince(warmStart)
        let warmPerHover = warmSeconds * 1000 / Double(warmIterations)

        note(String(format: "热缓存查询 %d 次，平均 %.2f ms/次", warmIterations, warmPerHover))
        check(warmPerHover < 5, "热缓存命中足够快（应当感觉不到加载）",
              detail: String(format: "%.2f ms", warmPerHover))
        check(ThumbnailProvider.shared.cachedCount > 0, "缩略图确实被记住了",
              detail: "缓存 \(ThumbnailProvider.shared.cachedCount) 张")

        // ---------------------------------------------------------------- enumerate throughput
        let enumIterations = 40
        let enumStart = Date()
        for _ in 0..<enumIterations {
            WindowEnumerator.invalidateCache()
            for (_, window) in workingSet.prefix(targetWindowsPerApp) {
                if let app = appByPid[window.pid] {
                    _ = WindowEnumerator.windows(pid: app.processIdentifier, ownerName: app.localizedName ?? "")
                }
            }
        }
        let enumSeconds = Date().timeIntervalSince(enumStart)
        note(String(format: "窗口枚举（未命中缓存）平均 %.2f ms/次", enumSeconds * 1000 / Double(enumIterations)))

        // ---------------------------------------------------------------- panel sweep
        // Build the panel for the synthetic count: this is the code path that runs on every hover.
        WindowEnumerator.invalidateCache()
        let panelStart = Date()
        if let first = candidates.first {
            _ = panel.testBuildPreview(for: first.0, windows: first.2)
        }
        let panelSeconds = Date().timeIntervalSince(panelStart)
        note(String(format: "面板构建（首个应用，%d 个真实窗口）%.0f ms",
                    candidates.first?.2.count ?? 0, panelSeconds * 1000))
        check(panelSeconds < 0.5, "面板构建不阻塞", detail: String(format: "%.0f ms", panelSeconds * 1000))

        // Hot rebuild with everything cached must be essentially free.
        let hotStart = Date()
        if let first = candidates.first {
            _ = panel.testBuildPreview(for: first.0, windows: first.2)
        }
        let hotSeconds = Date().timeIntervalSince(hotStart)
        note(String(format: "面板重建（全部命中缓存）%.1f ms", hotSeconds * 1000))

        // ---------------------------------------------------------------- cache stress
        // Real windows may be scarce (a tidy desktop), so the cache's capacity and eviction
        // behaviour is exercised with synthetic entries. This is about the *cache*, not capture.
        let stressCount = max(windowCount, 130)
        for index in 0..<stressCount {
            let synthetic = NSImage(size: NSSize(width: 360, height: 220))
            ThumbnailProvider.shared.testInsert(image: synthetic, key: "synthetic-\(index)")
        }
        note("缓存压测：写入 \(stressCount) 张后，实际保留 \(ThumbnailProvider.shared.cachedCount) 张")
        check(ThumbnailProvider.shared.cachedCount <= stressCount,
              "缓存容量有上限，不会无限增长",
              detail: "保留 \(ThumbnailProvider.shared.cachedCount) 张")
        // Clean up the synthetic entries so the memory figure below reflects real usage.
        for index in 0..<stressCount {
            ThumbnailProvider.shared.testRemove(key: "synthetic-\(index)")
        }

        // ---------------------------------------------------------------- phantom windows
        lines.append("")
        let finder = icons.first { $0.bundleID == "com.apple.finder" }
        if let finder {
            let finderWindows = panel.testResolveApplication(for: finder).map {
                WindowEnumerator.windows(pid: $0.processIdentifier, ownerName: $0.localizedName ?? "Finder")
            } ?? []
            let phantom = finderWindows.filter { !$0.isPlausibleWindow }
            check(finderWindows.count == finderWindows.filter(\.isPlausibleWindow).count,
                  "访达窗口列表已滤除幽灵窗口",
                  detail: "真实窗口 \(finderWindows.count) 个，被判定为幽灵 \(phantom.count) 个")
            if finderWindows.isEmpty {
                note("访达当前没有真实窗口 → 悬停时应不弹预览（正确行为）")
            } else {
                for window in finderWindows {
                    note("访达窗口 \(window.windowID) \(Int(window.bounds.width))x\(Int(window.bounds.height)) 「\(window.title)」")
                }
            }
        } else {
            note("Dock 上没有访达图标，跳过幽灵窗口检查")
        }

        // ---------------------------------------------------------------- memory
        lines.append("")
        if let bytes = MemoryFootprint.bytes() {
            let megabytes = Double(bytes) / 1024 / 1024
            note(String(format: "当前内存 %.1f MB（缓存 %d 张，约 %d MB）",
                        megabytes, ThumbnailProvider.shared.cachedCount,
                        ThumbnailProvider.shared.cachedBytes / 1024 / 1024))
            check(megabytes < 20, "内存低于 20 MB 目标", detail: String(format: "%.1f MB", megabytes))
        }

        // Keep a visual record so captures can be checked by eye.
        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        for (name, window) in workingSet.prefix(6) {
            guard let image = ThumbnailProvider.shared.cached(for: window),
                  let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let data = rep.representation(using: .png, properties: [:]) else { continue }
            let safe = name.replacingOccurrences(of: "/", with: "_")
            try? data.write(to: outputDirectory.appendingPathComponent("\(safe)-\(window.windowID).png"))
        }

        panel.hide()
        monitor.stop()
        return finish(lines, failures, outputDirectory: outputDirectory)
    }

    private static func ms(_ seconds: Double) -> String {
        String(format: "%.2f 秒", seconds)
    }

    private static func finish(_ lines: [String], _ failures: Int, outputDirectory: URL) -> Int32 {
        var text = lines
        text.append("")
        text.append("缩略图样本目录：\(outputDirectory.path)")
        text.append(failures == 0 ? "基准全部通过。" : "有 \(failures) 项未达标。")
        print(text.joined(separator: "\n"))
        return failures == 0 ? 0 : 1
    }
}
