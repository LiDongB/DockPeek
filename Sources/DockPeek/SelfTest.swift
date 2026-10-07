import AppKit
import CoreGraphics
import Foundation

/// End-to-end self test: exercises the *entire* hover → enumerate → capture → panel pipeline
/// without requiring anyone to move the mouse.
///
/// Run with `--test [appName]`, e.g. `--test 访达`. This exists because the interesting failures in
/// this app happen between components (Dock parsing → window enumeration → capture → panel), and a
/// unit test of any single component would not have caught them.
@MainActor
enum SelfTest {

    struct Result {
        var lines: [String] = []
        var passed = 0
        var failed = 0

        mutating func check(_ ok: Bool, _ label: String, detail: String = "") {
            let mark = ok ? "✅" : "❌"
            lines.append("\(mark) \(label)\(detail.isEmpty ? "" : " — \(detail)")")
            if ok { passed += 1 } else { failed += 1 }
        }

        mutating func note(_ text: String) {
            lines.append("   \(text)")
        }
    }

    static func run(appName: String?, outputDirectory: URL, activate: Bool) async -> Int32 {
        var result = Result()
        result.lines.append("DockPeek 端到端自检")
        result.lines.append("目录：\(outputDirectory.path)")
        result.lines.append("")

        // ---------------------------------------------------------------- 1. permissions
        result.check(Permissions.hasDeviceAccess, "设备控制和数据访问权限")
        let screenRecording = Permissions.hasScreenRecording
        result.check(screenRecording, "屏幕录制权限（预检结果）")

        // ---------------------------------------------------------------- 2. Dock parsing
        let monitor = DockMonitor { _ in }
        monitor.start()
        // Let the first geometry read happen (it is throttled to 1 Hz).
        try? await Task.sleep(for: .seconds(1.2))
        monitor.tickForDiagnostics()

        let icons = monitor.dockIcons
        result.check(!icons.isEmpty, "解析 Dock 图标", detail: "\(icons.count) 个")
        for icon in icons.prefix(3) {
            result.note("\(icon.name)：\(icon.bundleID ?? "无 bundleID")，运行中=\(icon.isApplicationRunning)")
        }
        guard !icons.isEmpty else {
            return finish(result, outputDirectory: outputDirectory)
        }

        // ---------------------------------------------------------------- 3. pick a target
        let running = icons.filter { $0.isApplicationRunning }
        result.check(!running.isEmpty, "存在运行中的应用图标", detail: "\(running.count) 个")

        let chosen: DockItem?
        if let appName {
            chosen = icons.first { $0.name == appName }
            result.check(chosen != nil, "找到指定应用「\(appName)」")
        } else {
            // Prefer an app that actually has windows, so the preview chain can be exercised.
            // (An app with none — Finder at rest — is a valid state, checked separately below.)
            chosen = icons
                .filter { $0.isApplicationRunning }
                .max { windowScore($0) < windowScore($1) }
            if let chosen {
                result.note("自动选择目标：\(chosen.name)（\(windowScore(chosen)) 个窗口）")
            }
        }

        guard let icon = chosen else {
            return finish(result, outputDirectory: outputDirectory)
        }

        // Apps that report as running but own no real windows must not produce a preview at all.
        if windowScore(icon) == 0 {
            result.note("「\(icon.name)」没有真实窗口 —— 直接验证「不弹预览」这一行为")
            let emptyPanel = PreviewPanel()
            let accepted = emptyPanel.testBuildPreview(for: icon, windows: [])
            result.check(!accepted, "无窗口时不弹预览（访达静置的情形）")
            result.check(!emptyPanel.testPanelIsOrderedIn, "无窗口时面板保持隐藏")
            emptyPanel.hide()
            return finish(result, outputDirectory: outputDirectory)
        }

        // ---------------------------------------------------------------- 4. hover hit test
        // The transitions themselves are covered deterministically by `--test-state`; what can only
        // be checked here is that a real Dock icon's geometry actually registers as a hit.
        let hoverMonitor = DockMonitor { _ in }
        hoverMonitor.start()
        try? await Task.sleep(for: .seconds(1.2))
        hoverMonitor.refreshGeometryNow()

        let probePoint = CGPoint(x: icon.frame.midX, y: icon.frame.midY)
        let probed = hoverMonitor.icon(at: probePoint)
        result.check(probed != nil, "真实 Dock 图标坐标能命中",
                     detail: probed.map { "命中「\($0.name)」" } ?? "未命中（monitor 解析到 \(hoverMonitor.resolvedIconCount) 个图标）")
        hoverMonitor.stop()

        // ---------------------------------------------------------------- 5. resolve app
        let panel = PreviewPanel()
        let app = panel.testResolveApplication(for: icon)
        result.check(app != nil, "把 Dock 图标解析为运行中的应用",
                     detail: app.map { "\($0.localizedName ?? "?") pid=\($0.processIdentifier)" } ?? "失败")
        guard let app else {
            return finish(result, outputDirectory: outputDirectory)
        }

        // ---------------------------------------------------------------- 5. enumerate windows
        let windows = WindowEnumerator.windows(pid: app.processIdentifier,
                                               ownerName: app.localizedName ?? icon.name)
        result.check(!windows.isEmpty, "枚举到窗口", detail: "\(windows.count) 个")
        for window in windows.prefix(6) {
            result.note("win \(window.windowID) \(Int(window.bounds.width))x\(Int(window.bounds.height)) " +
                        (window.title.isEmpty ? "(无标题)" : "「\(window.title)」") +
                        (window.isMain ? " [焦点]" : ""))
        }
        // Prefer an on-screen window. A minimized window may still be available through
        // ScreenCaptureKit; otherwise the provider keeps its last good frame when one exists.
        let capturable = windows.first { !$0.isMinimized } ?? windows.first
        let minimizedCount = windows.filter(\.isMinimized).count
        if minimizedCount > 0 {
            result.note("其中 \(minimizedCount) 个是最小化窗口（保留已有画面，点击时自动还原）")
        }
        guard let firstWindow = capturable else {
            result.note("该应用没有可枚举的窗口 —— 悬停时不会弹预览（这是设计行为，不是 bug）")
            return finish(result, outputDirectory: outputDirectory)
        }

        // ---------------------------------------------------------------- 6. capture
        let captured = await ThumbnailProvider.shared.thumbnail(for: firstWindow)
        if firstWindow.isMinimized {
            if captured != nil {
                result.check(true, "最小化窗口仍能获取缩略图")
            } else {
                result.note("本次进程没有该窗口的旧画面，系统也未提供最小化画面；保留窗口条目等待还原")
            }
        } else {
            result.check(captured != nil, "截取窗口缩略图",
                         detail: captured.map { "\(Int($0.size.width))x\(Int($0.size.height)) pt" } ?? "失败")
        }
        if let captured {
            let png = outputDirectory.appendingPathComponent("capture-\(firstWindow.windowID).png")
            if writePNG(captured, to: png) {
                result.note("缩略图已写出：\(png.path)")
            }
        } else if firstWindow.isMinimized {
            result.note("该窗口已最小化，且本次进程没有可用旧画面")
        } else {
            result.note("ScreenCaptureKit 与 CG 兜底都失败了 —— 屏幕录制权限很可能实际未生效")
        }

        // ---------------------------------------------------------------- 7. panel pipeline
        stage("构建预览面板（真实 present 路径）") {
            let accepted = panel.testBuildPreview(for: icon, windows: windows)
            result.check(accepted, "面板接受了预览请求",
                         detail: "请求 \(windows.count) 个窗口，面板持有 \(panel.testAcceptedWindowCount) 个")
            result.note(panel.testGridIdentity)
            // Read the tiles back immediately: `present` may legitimately clear them later if the
            // pointer has already moved away, so this must not be sampled after a delay.
            let immediate = panel.testRenderedTileWindows()
            result.check(!immediate.isEmpty, "面板内已生成缩略图视图",
                         detail: "grid tiles=\(panel.testGridTileCount)，返回 \(immediate.count) 个")
            for line in panel.testGridTrace {
                result.note("trace: " + line.prefix(160))
            }
        }

        result.check(panel.testPanelIsOrderedIn, "面板已显示（orderFront）")
        let frame = panel.testPanelFrame
        result.check(frame != nil, "面板有有效位置", detail: frame.map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height))" } ?? "nil")
        if let frame {
            let onScreen = NSScreen.screens.contains { $0.frame.intersects(frame) }
            result.check(onScreen, "面板落在某个显示器范围内")
        }

        // Let the async captures resolve, then confirm thumbnails actually attached.
        try? await Task.sleep(for: .seconds(1.5))
        let withImages = panel.testTilesWithThumbnails()
        // On-screen windows should have pictures; minimized windows may additionally have one.
        let visibleCount = windows.filter { !$0.isMinimized }.count
        result.check(withImages >= visibleCount,
                     "缩略图已挂到面板单元上",
                     detail: "\(withImages)/\(windows.count) 个有图（其中 \(visibleCount) 个非最小化）")

        for line in panel.testLayoutDescription() {
            result.note(line)
        }

        // ---------------------------------------------------------------- 8. activation (opt-in)
        if activate {
            result.note("执行窗口激活（会真的切换前台应用）")
            let ok = WindowActions.activate(firstWindow)
            try? await Task.sleep(for: .seconds(0.6))
            let front = NSWorkspace.shared.frontmostApplication
            result.check(ok || front?.processIdentifier == app.processIdentifier,
                         "目标窗口被激活",
                         detail: "前台应用=\(front?.localizedName ?? "?")")
        } else {
            result.note("跳过激活测试（需要时加 --test-activate）")
        }

        panel.hide()
        monitor.stop()

        // The panel was really shown during the test; make sure it does not linger on screen.
        try? await Task.sleep(for: .milliseconds(300))
        return finish(result, outputDirectory: outputDirectory)
    }

    // MARK: - Helpers

    private static func stage(_ label: String, _ body: () -> Void) {
        print("   … \(label)")
        body()
    }

    private static func windowScore(_ icon: DockItem) -> Int {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: icon.bundleID ?? "").first
                ?? NSWorkspace.shared.runningApplications.first(where: { $0.bundleURL == icon.bundleURL })
        else { return 0 }
        return WindowEnumerator.windowCount(pid: app.processIdentifier)
    }

    private static func writePNG(_ image: NSImage, to url: URL) -> Bool {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .png, properties: [:]) else { return false }
        do {
            try data.write(to: url)
            return true
        } catch {
            return false
        }
    }

    private static func finish(_ result: Result, outputDirectory: URL) -> Int32 {
        var text = result.lines
        text.append("")
        text.append("结果：通过 \(result.passed) 项，失败 \(result.failed) 项")
        if result.failed == 0 {
            text.append("整条链路正常。")
        } else {
            text.append("有失败项，上面标 ❌ 的地方就是断点。")
        }
        print(text.joined(separator: "\n"))
        return result.failed == 0 ? 0 : 1
    }
}
