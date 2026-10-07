import AppKit
import CoreGraphics
import Foundation

/// Deterministic tests for the hover state machine.
///
/// These use injected icons, injected timestamps and injected resolution results — no real Dock, no
/// real cursor, no sleeping. That is deliberate: the earlier live-Dock hover checks were flaky
/// because Dock geometry, magnification and the real pointer all move underneath them, which made
/// real behaviour indistinguishable from test noise.
@MainActor
enum HoverStateMachineTests {

    private static func icon(_ name: String, y: CGFloat = 100) -> DockItem {
        DockItem(
            name: name,
            frame: CGRect(x: 0, y: y, width: 60, height: 60),
            bundleURL: URL(fileURLWithPath: "/Applications/\(name).app"),
            isApplicationRunning: true
        )
    }

    static func run() -> Int32 {
        var lines: [String] = ["DockPeek 悬停状态机（确定性测试）", ""]
        var failures = 0

        func check(_ ok: Bool, _ label: String) {
            lines.append("\(ok ? "✅" : "❌") \(label)")
            if !ok { failures += 1 }
        }

        let a = icon("Alpha")
        let b = icon("Beta", y: 200)
        let resolveAll: (DockItem) -> DockItem? = { $0 }
        let dwell = 0.25
        let switchDelay = 0.05
        let grace = 0.22
        let t0 = Date()

        /// Drives one step with explicit state and time.
        func step(
            _ state: inout DockMonitor.HoverState,
            hit: DockItem?,
            at seconds: TimeInterval,
            retained: Bool = false,
            resolve: @escaping (DockItem) -> DockItem? = resolveAll
        ) -> DockMonitor.HoverAction {
            DockMonitor.hoverStep(
                state: &state,
                hit: hit,
                now: t0.addingTimeInterval(seconds),
                dwellTime: dwell,
                switchDelay: switchDelay,
                gracePeriod: grace,
                isRetained: retained,
                resolve: resolve
            )
        }

        // ---------------------------------------------------------------- 1. first hover
        var state = DockMonitor.HoverState()
        check(step(&state, hit: a, at: 0) == .nothing, "第一次落到图标上不立即弹出（建立停留计时）")
        check(step(&state, hit: a, at: 0.1) == .nothing, "停留不足 dwell 时不弹出")
        check(step(&state, hit: a, at: 0.3) == .show(hit: a, resolved: a), "停留超过 dwell 后弹出")

        // ---------------------------------------------------------------- 2. idle while shown
        check(step(&state, hit: a, at: 0.5) == .nothing, "已显示且仍停在同一个图标上时不重复弹出")

        // ---------------------------------------------------------------- 3. switch to another icon
        check(step(&state, hit: b, at: 0.6) == .nothing, "移到另一个图标时先重新计时")
        check(step(&state, hit: b, at: 0.62) == .nothing, "切换延迟未到时仍不弹出")
        check(step(&state, hit: b, at: 0.66) == .show(hit: b, resolved: b), "切换延迟很小时立即切换到新图标")
        check(state.reportedItem == b, "记录已切换到新图标")

        // ---------------------------------------------------------------- 4. leaving the dock
        check(step(&state, hit: nil, at: 0.8) == .nothing,
              "刚离开程序坞时先进入宽限期，不立即收起")
        check(step(&state, hit: nil, at: 1.1) == .hide, "离开超过宽限期后收起预览")
        check(state.reportedItem == nil, "收起后清空已上报状态")
        check(step(&state, hit: nil, at: 1.2) == .nothing, "已收起后不重复发收起事件")

        // ---------------------------------------------------------------- 5. repeat hover (the regression)
        check(step(&state, hit: a, at: 1.3) == .nothing, "重新落回图标时重新计时")
        check(step(&state, hit: a, at: 1.7) == .show(hit: a, resolved: a),
              "收起后再次悬停必须能重新弹出（此前的回归点）")

        // ---------------------------------------------------------------- 6. travelling into the panel
        var retainedState = DockMonitor.HoverState()
        _ = step(&retainedState, hit: a, at: 0)
        check(step(&retainedState, hit: a, at: 0.3) == .show(hit: a, resolved: a), "先弹出")
        check(step(&retainedState, hit: nil, at: 0.4, retained: true) == .nothing,
              "鼠标移入预览面板时保持显示")
        check(retainedState.reportedItem == a, "保留期间仍记录该图标")
        check(step(&retainedState, hit: nil, at: 0.5, retained: false) == .nothing,
              "离开面板后先进入宽限期")
        check(step(&retainedState, hit: nil, at: 0.8, retained: false) == .hide,
              "离开面板与程序坞超过宽限期后收起")

        // ---------------------------------------------------------------- 7. app that cannot be resolved
        var unresolvable = DockMonitor.HoverState()
        _ = step(&unresolvable, hit: a, at: 0)
        check(step(&unresolvable, hit: a, at: 0.4, resolve: { _ in nil }) == .nothing,
              "应用不可解析时不弹出")
        check(unresolvable.reportedItem == nil, "不可解析时不记录为已上报")

        // ---------------------------------------------------------------- 8. switch delay honoured exactly
        var timing = DockMonitor.HoverState()
        _ = step(&timing, hit: a, at: 0)
        _ = step(&timing, hit: a, at: 0.3)
        _ = step(&timing, hit: b, at: 0.4)
        check(step(&timing, hit: b, at: 0.44) == .nothing, "切换延迟 0.05s：0.04s 时还不切换")
        check(step(&timing, hit: b, at: 0.451) == .show(hit: b, resolved: b), "切换延迟 0.05s：超过后切换")

        // ---------------------------------------------------------------- 9. hand tremor / magnification
        // This is the flicker regression: the pointer drifts a few pixels, magnification changes the
        // icon's frame, and the identical icon must NOT be treated as a new one.
        var tremor = DockMonitor.HoverState()
        _ = step(&tremor, hit: a, at: 0)
        check(step(&tremor, hit: a, at: 0.3) == .show(hit: a, resolved: a), "抖动测试：先弹出预览")
        let magnified = DockItem(
            name: a.name,
            frame: CGRect(x: 0, y: 100, width: 74, height: 74),   // same icon, magnified
            bundleURL: a.bundleURL,
            isApplicationRunning: true
        )
        check(step(&tremor, hit: magnified, at: 0.35) == .nothing,
              "抖动测试：图标被悬停放大（frame 变了）不应重新弹出")
        check(step(&tremor, hit: a, at: 0.40) == .nothing, "抖动测试：frame 变回来也不重新弹出")
        check(tremor.reportedItem != nil, "抖动测试：预览始终保持上报状态")

        // ---------------------------------------------------------------- 10. grace period
        var gracey = DockMonitor.HoverState()
        _ = step(&gracey, hit: a, at: 0)
        _ = step(&gracey, hit: a, at: 0.3)
        check(gracey.reportedItem == a, "宽限期测试：先弹出预览")
        check(step(&gracey, hit: nil, at: 0.5) == .nothing,
              "宽限期测试：短暂脱离图标（如落在图标间隙）不立即收起")
        check(step(&gracey, hit: nil, at: 0.6, retained: true) == .nothing,
              "宽限期测试：移入预览面板保持显示")
        // The grace clock restarts on every retained/on-icon step, so the very first miss after
        // 0.75 becomes the new baseline and the hide lands one grace period later.
        check(step(&gracey, hit: nil, at: 0.75) == .nothing,
              "宽限期测试：脱离未超过宽限期仍不收起")
        check(step(&gracey, hit: nil, at: 0.85) == .nothing,
              "宽限期测试：宽限期内继续不收起")
        check(step(&gracey, hit: nil, at: 1.02) == .hide,
              "宽限期测试：脱离超过宽限期后收起")
        check(gracey.reportedItem == nil, "宽限期测试：收起后清空状态")

        // Returning within the grace window must cancel the pending hide.
        var rescue = DockMonitor.HoverState()
        _ = step(&rescue, hit: a, at: 0)
        _ = step(&rescue, hit: a, at: 0.3)
        _ = step(&rescue, hit: nil, at: 0.5)
        check(step(&rescue, hit: a, at: 0.6) == .nothing, "宽限期测试：回到同一图标不重新弹出")
        check(rescue.reportedItem == a, "宽限期测试：回到图标后仍保持显示")
        check(step(&rescue, hit: nil, at: 0.7) == .nothing,
              "宽限期测试：再次脱离时宽限期重新计时")

        lines.append("")
        lines.append(failures == 0 ? "状态机全部通过。" : "有 \(failures) 项失败。")
        print(lines.joined(separator: "\n"))
        return failures == 0 ? 0 : 1
    }
}
