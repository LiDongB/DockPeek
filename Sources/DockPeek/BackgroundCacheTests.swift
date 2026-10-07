import AppKit
import CoreGraphics
import Foundation

/// Verifies that thumbnails are cached without any hover.
///
/// This is the regression test for the reported gap: the cache used to be built only as a side
/// effect of showing a preview, so a window that was never hovered had nothing cached when it was
/// minimised. The test drives the real `BackgroundCacheWarmer`, with the cache deliberately emptied
/// first, and never calls `PreviewPanel.present`.
@MainActor
enum BackgroundCacheTests {

    static func run(outputDirectory: URL) async -> Int32 {
        var lines: [String] = ["DockPeek 后台缓存预热校验", ""]
        var failures = 0

        func check(_ ok: Bool, _ label: String, detail: String = "") {
            lines.append("\(ok ? "✅" : "❌") \(label)\(detail.isEmpty ? "" : " — \(detail)")")
            if !ok { failures += 1 }
        }

        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        // ---------------------------------------------------------------- 找到一个可采集的窗口
        let targets = WindowEnumerator.allCapturableWindows().filter { !$0.isMinimized }
        lines.append("发现 \(targets.count) 个可采集窗口")
        for target in targets.prefix(5) {
            lines.append("  \(target.ownerName)：\(target.title.isEmpty ? "(无标题)" : target.title) \(Int(target.bounds.width))×\(Int(target.bounds.height))")
        }
        lines.append("")

        guard let sample = targets.first else {
            lines.append("❌ 当前没有可采集窗口，无法校验（请先打开一个应用窗口）")
            return 1
        }

        // ---------------------------------------------------------------- 清空缓存，确认真的空了
        lines.append("【清空缓存后由后台预热重建】")
        ThumbnailProvider.shared.purge()
        check(ThumbnailProvider.shared.cachedCount == 0,
              "清空后缓存为 0 张",
              detail: "\(ThumbnailProvider.shared.cachedCount) 张")

        let warmer = BackgroundCacheWarmer()
        warmer.start()
        check(warmer.isRunning, "后台预热已启动")

        // Wait for the warmer to do its work. It runs once per second and captures at most two
        // windows per pass, so a few seconds is plenty for a handful of windows.
        var waited: TimeInterval = 0
        while waited < 12, ThumbnailProvider.shared.cachedCount == 0 {
            try? await Task.sleep(for: .milliseconds(250))
            waited += 0.25
        }

        let afterWarm = ThumbnailProvider.shared.cachedCount
        check(afterWarm > 0,
              "未进行任何悬停，后台已建立缩略图缓存",
              detail: "\(afterWarm) 张，用时约 \(String(format: "%.1f", waited)) 秒")
        lines.append("  \(warmer.summary)")

        // ---------------------------------------------------------------- 采样窗口的缓存可命中
        check(ThumbnailProvider.shared.cached(for: sample) != nil,
              "抽样窗口的缓存可命中",
              detail: "\(sample.ownerName) \(sample.title)")

        // ---------------------------------------------------------------- 模拟最小化：仍能取到画面
        lines.append("")
        lines.append("【最小化后仍能取到画面】")

        let minimized = WindowTarget(
            pid: sample.pid,
            windowID: CGWindowID(bitPattern: Int32(-9999)),
            ownerName: sample.ownerName,
            title: sample.title,
            bounds: sample.bounds,
            isMain: false,
            isMinimized: true,
            identity: sample.identity          // same window, same identity
        )

        check(minimized.identity == sample.identity,
              "最小化不改变窗口身份", detail: minimized.identity)
        check(ThumbnailProvider.shared.cached(for: minimized) != nil,
              "最小化状态下缓存仍可命中（不依赖悬停）")

        let image = await ThumbnailProvider.shared.thumbnail(for: minimized)
        check(image != nil,
              "最小化状态下 thumbnail() 返回最后一次有效画面",
              detail: image.map { "\(Int($0.size.width))×\(Int($0.size.height)) pt" } ?? "nil")

        if let image,
           let tiff = image.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let data = rep.representation(using: .png, properties: [:]) {
            let url = outputDirectory.appendingPathComponent("warmed-thumbnail.png")
            try? data.write(to: url)
            lines.append("  已写出该缩略图：\(url.path)")
        }

        // ---------------------------------------------------------------- 资源占用
        lines.append("")
        lines.append("【资源占用】")

        // The warmer captures at most `maxCapturesPerPass` windows per pass, so a backlog is worked
        // off over several passes. First wait for it to settle, then assert that a settled warmer
        // stops capturing — that is the property that matters (no repeated captures of known
        // windows), and asserting earlier would just be measuring the rate limit.
        var stableCount = warmer.captureCount
        var settled = false
        for _ in 0..<20 {
            try? await Task.sleep(for: .seconds(1))
            if warmer.captureCount == stableCount { settled = true; break }
            stableCount = warmer.captureCount
        }
        check(settled, "预热在若干轮后进入稳定状态",
              detail: "共排入 \(warmer.captureCount) 个窗口")
        check(warmer.captureCount <= targets.count,
              "排入的窗口数不超过实际可采集窗口数（没有重复采集）",
              detail: "排入 \(warmer.captureCount)，可采集 \(targets.count)")

        let settledCount = warmer.captureCount
        try? await Task.sleep(for: .seconds(3))
        check(warmer.captureCount == settledCount,
              "稳定后不再重复采集已缓存窗口",
              detail: "3 秒内新增排入 \(warmer.captureCount - settledCount) 个")

        check(warmer.lastPassDuration < 0.1,
              "单轮枚举耗时可忽略",
              detail: String(format: "%.1f ms", warmer.lastPassDuration * 1000))

        warmer.stop()
        check(!warmer.isRunning, "预热可正常停止")

        lines.append("")
        lines.append(failures == 0 ? "后台预热校验全部通过。" : "有 \(failures) 项失败。")
        print(lines.joined(separator: "\n"))
        return failures == 0 ? 0 : 1
    }
}
