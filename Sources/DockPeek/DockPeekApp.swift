import AppKit
import Foundation

/// Menu-bar-only agent app: no windows of its own until a preview is requested.
@main
enum DockPeekApp {

    /// Strong reference for the process lifetime — `NSApplication.delegate` is weak.
    @MainActor private static let delegate = AppDelegate()

    @MainActor
    static func main() {
        let arguments = CommandLine.arguments

        if arguments.contains("--verify-fixes") {
            _ = NSApplication.shared
            NSApp.setActivationPolicy(.accessory)
            let output: String = arguments.firstIndex(of: "--out").flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil } ?? "verification-output"
            Task { @MainActor in
                exit(await FixVerificationTests.run(output: URL(fileURLWithPath: output)))
            }
            NSApp.run()
            return
        }
        if arguments.contains("--diagnose") {
            runDiagnostics()
            return
        }
        if arguments.contains("--dump-dock") {
            print(DockMonitor.dumpDockTree())
            exit(0)
        }
        if arguments.contains("--test") {
            runSelfTest(arguments: arguments)
            return
        }
        if let index = arguments.firstIndex(of: "--idle") {
            let seconds = index + 1 < arguments.count ? (Double(arguments[index + 1]) ?? 20) : 20
            runIdleProbe(seconds: seconds)
            return
        }
        if arguments.contains("--check-layout") {
            _ = NSApplication.shared
            NSApp.setActivationPolicy(.accessory)
            let controller = SettingsWindowController()
            if arguments.contains("--geometry") {
                print(controller.geometryReport().joined(separator: "\n"))
                exit(0)
            }
            let (lines, ok) = controller.layoutReport()
            print(lines.joined(separator: "\n"))
            exit(ok ? 0 : 1)
        }
        if arguments.contains("--test-state") {
            exit(HoverStateMachineTests.run())
        }
        if arguments.contains("--test-preview") {
            runPreviewRegressionTests()
            return
        }
        if arguments.contains("--test-settings") {
            exit(SettingsBehaviourTests.run())
        }
        if arguments.contains("--test-menu") {
            exit(MenuBarTests.run())
        }
        if arguments.contains("--test-transition") {
            exit(SettingsBehaviourTests.runTransitionBehaviour())
        }
        if arguments.contains("--test-render") {
            runRenderVerification(arguments: arguments)
            return
        }
        if arguments.contains("--test-layout") {
            runPanelLayoutTests(arguments: arguments)
            return
        }
        if arguments.contains("--backdrop") {
            // `--backdrop glass|frosted`, then run normally so the material can be judged on screen.
            let frosted = arguments.contains("frosted")
            Preferences.backdrop = frosted ? .frosted : .glass
            print("预览面板材质 = \(Preferences.backdrop.displayName)")
        }
        // `--capture-confirm`: renders the reset confirmation panel and screenshots it.
        if arguments.contains("--capture-confirm") {
            runConfirmCapture(arguments: arguments)
            return
        }
        // `--capture-settings [--page N]`: opens the real settings window and screenshots it, so the
        // rendered result can be inspected instead of inferred.
        if arguments.contains("--capture-settings") {
            runSettingsCapture(arguments: arguments)
            return
        }
        if arguments.contains("--test-buttons") {
            runButtonAppearanceTests(arguments: arguments)
            return
        }
        if arguments.contains("--test-cache") {
            runBackgroundCacheTests(arguments: arguments)
            return
        }
        if arguments.contains("--test-lifecycle") {
            runLifecycleTest()
            return
        }
        if arguments.contains("--benchmark") {
            runBenchmark(arguments: arguments)
            return
        }
        if let index = arguments.firstIndex(of: "--open-pane"), index + 1 < arguments.count {
            openPane(arguments[index + 1])
            return
        }
        if let index = arguments.firstIndex(of: "--watch") {
            let seconds = index + 1 < arguments.count ? (Double(arguments[index + 1]) ?? 12) : 12
            watch(seconds: seconds)
            return
        }

        let app = NSApplication.shared
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    /// Headless self-check: starts the Dock monitor, waits for the first geometry read, prints a
    /// report to stdout and exits. Useful because the app's unified log output is not reachable
    /// from a sandboxed shell.
    @MainActor
    private static func runDiagnostics() {
        let monitor = DockMonitor { _ in }
        monitor.start()

        // Give the Dock's accessibility tree a moment to be read and the poll loop to settle.
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        monitor.tickForDiagnostics()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))

        print(monitor.diagnostics())
        monitor.stop()
        exit(0)
    }

    /// `--test [appName] [--test-activate] [--out <dir>]`
    ///
    /// Exercises the whole pipeline headlessly so regressions are caught without a human moving
    /// the mouse: permissions → Dock parsing → app resolution → window enumeration → capture →
    /// panel construction → (optionally) window activation.
    @MainActor
    private static func runSelfTest(arguments: [String]) {
        let activate = arguments.contains("--test-activate")

        var appName: String?
        var outputDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("selftest-output", isDirectory: true)

        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--test":
                // The next token is the app name unless it is another flag.
                if index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") {
                    appName = arguments[index + 1]
                }
            case "--out":
                if index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") {
                    outputDirectory = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
                }
            default:
                break
            }
            index += 1
        }

        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        // Run the test in a Task so `await` works while the main run loop keeps turning.
        let finished = AtomicFlag()
        var status: Int32 = 1
        Task { @MainActor in
            status = await SelfTest.run(appName: appName, outputDirectory: outputDirectory, activate: activate)
            finished.set()
        }

        let deadline = Date().addingTimeInterval(60)
        while !finished.value, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        exit(status)
    }

    /// `--idle [seconds]`
    ///
    /// Boots the real delegate and reports memory plus cache state on a timer, without any hover.
    /// Used to confirm the idle footprint is flat and that nothing is being captured in the
    /// background.
    @MainActor
    private static func runIdleProbe(seconds: Double) {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)

        let launched = AppDelegate()
        launched.applicationDidFinishLaunching(
            Notification(name: NSApplication.didFinishLaunchingNotification)
        )

        print("空闲探针：\(Int(seconds)) 秒，不进行任何悬停")
        print("  时刻 | 内存       | 缓存张数 | 缓存占用 | 轮询次数 | 已上报预览")
        let start = Date()
        while Date().timeIntervalSince(start) < seconds {
            RunLoop.main.run(until: Date().addingTimeInterval(2.0))
            let elapsed = String(format: "%5.0fs", Date().timeIntervalSince(start))
            let memory = MemoryFootprint.formatted()
            let count = ThumbnailProvider.shared.cachedCount
            let bytes = ThumbnailProvider.shared.cachedBytes / 1024
            let ticks = launched.dockTickCount
            let reported = launched.previewReportedForDiagnostics ? "是" : "否"
            print("  \(elapsed) | \(memory.padding(toLength: 10, withPad: " ", startingAt: 0)) | \(String(count).padding(toLength: 8, withPad: " ", startingAt: 0)) | \(String(bytes).padding(toLength: 7, withPad: " ", startingAt: 0))KB | \(String(ticks).padding(toLength: 8, withPad: " ", startingAt: 0)) | \(reported)")
        }
        exit(0)
    }

    /// `--test-preview`
    ///
    /// Regression tests for the preview fixes: minimised windows keeping their thumbnail, the
    /// corner-geometry invariants, and the size / clarity / title / transition option models.
    @MainActor
    private static func runPreviewRegressionTests() {
        let finished = AtomicFlag()
        var status: Int32 = 1
        Task { @MainActor in
            status = await PreviewRegressionTests.run()
            finished.set()
        }
        let deadline = Date().addingTimeInterval(60)
        while !finished.value, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        exit(status)
    }

    /// `--test-render [--out <dir>]`
    ///
    /// Renders the live preview panel into a bitmap and inspects its pixels, which is the only way
    /// to confirm the corner-rendering fix without taking a screenshot by hand.
    @MainActor
    private static func runRenderVerification(arguments: [String]) {
        var outputDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("render-output", isDirectory: true)
        if let index = arguments.firstIndex(of: "--out"), index + 1 < arguments.count,
           !arguments[index + 1].hasPrefix("--") {
            outputDirectory = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        }

        let finished = AtomicFlag()
        var status: Int32 = 1
        Task { @MainActor in
            status = await RenderVerificationTests.run(outputDirectory: outputDirectory)
            finished.set()
        }
        let deadline = Date().addingTimeInterval(90)
        while !finished.value, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        exit(status)
    }

    /// `--test-layout [--out <dir>]`
    ///
    /// Pops the preview for every running Dock icon at every size preset and asserts each panel is
    /// completely on screen.
    @MainActor
    private static func runPanelLayoutTests(arguments: [String]) {
        var outputDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("layout-output", isDirectory: true)
        if let index = arguments.firstIndex(of: "--out"), index + 1 < arguments.count,
           !arguments[index + 1].hasPrefix("--") {
            outputDirectory = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        }

        let finished = AtomicFlag()
        var status: Int32 = 1
        Task { @MainActor in
            status = await PanelLayoutTests.run(outputDirectory: outputDirectory)
            finished.set()
        }
        let deadline = Date().addingTimeInterval(120)
        while !finished.value, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        exit(status)
    }

    /// `--test-cache [--out <dir>]`
    ///
    /// Empties the thumbnail cache, starts the real background warmer and asserts that thumbnails
    /// are rebuilt without any hover at all.
    @MainActor
    private static func runBackgroundCacheTests(arguments: [String]) {
        var outputDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("cache-output", isDirectory: true)
        if let index = arguments.firstIndex(of: "--out"), index + 1 < arguments.count,
           !arguments[index + 1].hasPrefix("--") {
            outputDirectory = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        }

        let finished = AtomicFlag()
        var status: Int32 = 1
        Task { @MainActor in
            status = await BackgroundCacheTests.run(outputDirectory: outputDirectory)
            finished.set()
        }
        let deadline = Date().addingTimeInterval(120)
        while !finished.value, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        exit(status)
    }

    /// `--test-buttons [--out <dir>]`
    ///
    /// Renders the candidate button styles side by side and captures the result, so the appearance
    /// can be judged from an image instead of from the documentation.
    @MainActor
    private static func runButtonAppearanceTests(arguments: [String]) {
        var outputDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("button-output", isDirectory: true)
        if let index = arguments.firstIndex(of: "--out"), index + 1 < arguments.count,
           !arguments[index + 1].hasPrefix("--") {
            outputDirectory = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        }

        let finished = AtomicFlag()
        Task { @MainActor in
            _ = await ButtonAppearanceTests.run(outputDirectory: outputDirectory)
            finished.set()
        }
        let deadline = Date().addingTimeInterval(60)
        while !finished.value, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        exit(0)
    }

    /// `--capture-settings [--page N] [--out <dir>]`
    @MainActor
    private static func runSettingsCapture(arguments: [String]) {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.regular)

        var page = 0
        if let index = arguments.firstIndex(of: "--page"), index + 1 < arguments.count,
           let value = Int(arguments[index + 1]) {
            page = value
        }
        var outputDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("settings-output", isDirectory: true)
        if let index = arguments.firstIndex(of: "--out"), index + 1 < arguments.count,
           !arguments[index + 1].hasPrefix("--") {
            outputDirectory = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let controller = SettingsWindowController()
        controller.show()
        controller.selectPage(page)

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            guard let window = controller.windowForTesting, window.isVisible else {
                print("❌ 设置窗口未打开")
                exit(1)
            }
            let url = outputDirectory.appendingPathComponent("settings-page\(page + 1).png")
            try? FileManager.default.removeItem(at: url)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = ["-x", "-o", "-l", String(window.windowNumber), url.path]
            try? process.run()
            process.waitUntilExit()
            if FileManager.default.fileExists(atPath: url.path) {
                print("✅ 已捕获设置窗口第 \(page + 1) 页：\(url.path)")
            } else {
                print("❌ 捕获失败")
            }
            exit(0)
        }
        RunLoop.main.run()
    }

    /// `--capture-confirm [--out <dir>]`
    @MainActor
    private static func runConfirmCapture(arguments: [String]) {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.regular)

        var outputDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("confirm-output", isDirectory: true)
        if let index = arguments.firstIndex(of: "--out"), index + 1 < arguments.count,
           !arguments[index + 1].hasPrefix("--") {
            outputDirectory = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let controller = SettingsWindowController()
        let built = controller.buildConfirmPanel(
            "要把「外观与动效」恢复为默认设置吗？\n\n恢复默认后将覆盖编辑内容 且不可撤销"
        )
        built.panel.center()
        built.panel.orderFrontRegardless()
        built.panel.displayIfNeeded()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            let url = outputDirectory.appendingPathComponent("confirm-panel.png")
            try? FileManager.default.removeItem(at: url)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = ["-x", "-o", "-l", String(built.panel.windowNumber), url.path]
            try? process.run()
            process.waitUntilExit()
            if FileManager.default.fileExists(atPath: url.path) {
                print("✅ 已捕获确认面板：\(url.path)")
                print("   标题按钮：\(built.confirm.title)   次按钮：\(built.cancel.title)")
            } else {
                print("❌ 捕获失败")
            }
            exit(0)
        }
        RunLoop.main.run()
    }

    /// `--test-lifecycle`
    ///
    /// Boots the *real* delegate the same way `main()` does and then asserts that the hover poll
    /// loop is actually running. This exists because every component can be individually correct
    /// while the wiring between them is missing — which is exactly what happened when
    /// `monitor.start()` was never called and hovering silently did nothing.
    @MainActor
    private static func runLifecycleTest() {
        var failures = 0
        func check(_ ok: Bool, _ label: String, detail: String = "") {
            print("\(ok ? "✅" : "❌") \(label)\(detail.isEmpty ? "" : " — \(detail)")")
            if !ok { failures += 1 }
        }

        print("DockPeek 启动接线自检")

        // `applicationDidFinishLaunching` touches NSStatusBar, which requires the application object
        // to exist first — `main()` normally creates it before the delegate runs.
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)

        // Drive the exact code path the app uses at launch.
        let launched = AppDelegate()
        launched.applicationDidFinishLaunching(
            Notification(name: NSApplication.didFinishLaunchingNotification)
        )

        check(launched.dockMonitorIsRunning, "启动后轮询定时器已在运行（monitor.start() 被调用）")

        // Let the poll loop accumulate cycles on its own.
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        let firstSample = launched.dockTickCount
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        let secondSample = launched.dockTickCount

        check(secondSample > firstSample,
              "轮询循环持续推进",
              detail: "1.5 秒内 tick \(firstSample) → \(secondSample)（+\(secondSample - firstSample)）")
        check(launched.dockIconCount > 0,
              "轮询中解析到 Dock 图标",
              detail: "\(launched.dockIconCount) 个")

        print("")
        print(failures == 0 ? "接线正常。" : "有 \(failures) 项接线失败。")
        exit(failures == 0 ? 0 : 1)
    }

    /// `--benchmark [windowCount] [--out <dir>]`
    ///
    /// Measures the hover pipeline (cold vs warm) and asserts the memory budget, so "it feels
    /// smooth" can be checked as a number rather than an opinion.
    @MainActor
    private static func runBenchmark(arguments: [String]) {
        var windowCount = 12
        var outputDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("benchmark-output", isDirectory: true)

        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--benchmark", index + 1 < arguments.count, let parsed = Int(arguments[index + 1]) {
                windowCount = max(1, min(parsed, 60))
            }
            if argument == "--out", index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") {
                outputDirectory = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
            }
            index += 1
        }

        let finished = AtomicFlag()
        var status: Int32 = 1
        Task { @MainActor in
            status = await Benchmark.run(windowCount: windowCount, outputDirectory: outputDirectory)
            finished.set()
        }

        let deadline = Date().addingTimeInterval(120)
        while !finished.value, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        exit(status)
    }

    /// `--watch [seconds]`
    ///
    /// Live trace of the real hover path: once per second it prints the *actual* pointer position
    /// read through the same code path production uses, which Dock icon that lands on, and how far
    /// the pipeline got. This is the diagnostic for "the self test passes but hovering does
    /// nothing", because the self test injects coordinates and therefore never exercises the live
    /// `CGEvent` pointer read.
    @MainActor
    private static func watch(seconds: Double) {
        print("实时追踪 \(Int(seconds)) 秒 —— 现在请把鼠标停在 Dock 图标上不动")
        print("格式: 时间 | 真实鼠标(Quartz) | 命中图标 | 停留 | 已触发预览")

        let panel = PreviewPanel()
        let monitor = DockMonitor { icon in
            if let icon { _ = panel.present(for: icon) }
            else { panel.hide() }
        }
        monitor.start()

        print("")
        print("  时刻  | 真实鼠标         | 命中图标               | 停留   | 预览")
        print("  ------+------------------+------------------------+--------+--------")

        let start = Date()
        var lastLine = ""
        while Date().timeIntervalSince(start) < seconds {
            // 100 ms sampling: fine enough to see the dwell timer cross 0.4 s.
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))

            let elapsed = String(format: "%5.1fs", Date().timeIntervalSince(start))
            // Read the pointer exactly the way the production poll loop does.
            let raw = CGEvent(source: nil)?.location
            let mouse = raw ?? .zero
            let hit = monitor.icon(at: mouse)
            let hitName = hit.map { "\($0.name)\($0.isApplicationRunning ? "" : "(未运行)")" } ?? "无"
            let dwell = monitor.currentDwellSeconds.map { String(format: "%.2fs", $0) } ?? "  -  "
            let reported = monitor.previewIsReported ? "已触发" : "  -   "

            let line = "  \(elapsed) | \(String(format: "%4d,%-4d", Int(mouse.x), Int(mouse.y)))\(raw == nil ? "读取失败!" : "     ") | \(hitName.padding(toLength: 22, withPad: " ", startingAt: 0)) | \(dwell) | \(reported)"
            // Only print when something actually changes, to keep the trace readable.
            let signature = "\(Int(mouse.x)),\(Int(mouse.y))|\(hitName)|\(reported)"
            if signature != lastLine {
                print(line)
                lastLine = signature
            }
        }

        print("")
        print("最终状态：")
        print(monitor.diagnostics())
        monitor.stop()
        panel.hide()
        exit(0)
    }

    /// `--open-pane accessibility|screenRecording`
    ///
    /// Exercises the same navigation the menu items use, so the deep-link behaviour can be verified
    /// without clicking through the UI.
    @MainActor
    private static func openPane(_ name: String) {
        let pane: Permissions.PrivacyPane = (name == "screenRecording") ? .screenRecording : .deviceAccess
        Permissions.openSettingsPane(for: pane)
        print("已请求打开面板：\(name)，等待导航完成…")

        // Give the URL + AX navigation time to land, then report where Settings actually ended up.
        RunLoop.main.run(until: Date().addingTimeInterval(4.5))
        let titles = settingsWindowTitles()
        print("系统设置窗口标题：\(titles.isEmpty ? "无法读取" : titles.joined(separator: " / "))")
        // Sheet/dialog titles are not panes; the pane name is the one that matches a sidebar entry.
        let panes = titles.filter { !["打开", "存储", "Open", "Save", "选择"].contains($0) }
        print("判定面板：\(panes.first ?? "未识别")")
        exit(0)
    }

    /// Reports every System Settings window title.
    ///
    /// A single "first AXWindow found" lookup is unreliable: the accessibility tree may expose more
    /// than one window (sheets, panels) in no guaranteed order, and picking the wrong one makes the
    /// verification claim the navigation failed when it actually worked.
    @MainActor
    private static func settingsWindowTitles() -> [String] {
        guard let settings = NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.systempreferences").first else { return [] }

        func collect(_ element: AXUIElement, depth: Int = 0, into titles: inout [String]) {
            guard depth < 8 else { return }
            var roleValue: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue) == .success,
               (roleValue as? String) == "AXWindow" {
                var titleValue: CFTypeRef?
                if AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleValue) == .success,
                   let title = titleValue as? String, !title.isEmpty {
                    titles.append(title)
                }
            }
            var childrenValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenValue) == .success,
                  let children = childrenValue as? [AXUIElement] else { return }
            for child in children { collect(child, depth: depth + 1, into: &titles) }
        }

        var titles: [String] = []
        collect(AXUIElementCreateApplication(settings.processIdentifier), into: &titles)
        return titles
    }
}

/// Minimal thread-safe flag used to bridge the async self test back to the synchronous entry point.
final class AtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func set() {
        lock.lock()
        storage = true
        lock.unlock()
    }
}
