import AppKit
import Foundation

/// Behavioural tests for the settings window's conditional rules.
///
/// These are the rules that are easy to get wrong because they are invisible in a static screenshot:
/// the fade-duration rows must appear only for the 淡入淡出 transition, and 缩略图清晰度 must be
/// unavailable while thumbnails are switched off. They drive the real controller, so a regression in
/// the window's own logic is caught rather than a duplicated copy of it.
@MainActor
enum SettingsBehaviourTests {

    static func run() -> Int32 {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)

        var lines: [String] = ["DockPeek 设置行为测试", ""]
        var failures = 0

        func check(_ ok: Bool, _ label: String, detail: String = "") {
            lines.append("\(ok ? "✅" : "❌") \(label)\(detail.isEmpty ? "" : " — \(detail)")")
            if !ok { failures += 1 }
        }

        // Remember the user's real settings and restore them at the end.
        let savedTransition = Preferences.transition
        let savedFadeIn = Preferences.fadeInDuration
        let savedFadeOut = Preferences.fadeOutDuration
        let savedPanelSize = Preferences.panelSize

        let controller = SettingsWindowController()
        controller.show()

        // ================================================================ 淡入/淡出仅在该模式显示
        lines.append("【过渡动画的条件显示】")

        Preferences.transition = .fade
        controller.refreshConditionalRows()
        check(controller.fadeRowsAreVisible, "选择「淡入淡出」时显示淡入/淡出时长")

        Preferences.set(Preferences.Key.fadeInDuration, to: 0.33, in: Preferences.fadeRange)
        Preferences.set(Preferences.Key.fadeOutDuration, to: 0.21, in: Preferences.fadeRange)

        for mode in [Preferences.Transition.none, .pop] {
            Preferences.transition = mode
            controller.refreshConditionalRows()
            check(!controller.fadeRowsAreVisible,
                  "选择「\(mode.displayName)」时隐藏淡入/淡出时长")
            check(Preferences.fadeInDuration == 0.33 && Preferences.fadeOutDuration == 0.21,
                  "切换到「\(mode.displayName)」不丢失已设置的时长",
                  detail: String(format: "%.2f / %.2f", Preferences.fadeInDuration, Preferences.fadeOutDuration))
        }

        Preferences.transition = .fade
        controller.refreshConditionalRows()
        check(controller.fadeRowsAreVisible, "切回「淡入淡出」后时长设置重新出现并保留原值")
        check(Preferences.fadeInDuration == 0.33 && Preferences.fadeOutDuration == 0.21,
              "往返切换后时长仍未被改写",
              detail: String(format: "%.2f / %.2f", Preferences.fadeInDuration, Preferences.fadeOutDuration))

        // ================================================================ 清晰度在关闭缩略图时不可用
        lines.append("")
        lines.append("【缩略图清晰度的可用性】")

        for size in Preferences.PanelSize.allCases where size != .off {
            Preferences.panelSize = size
            controller.refreshConditionalRows()
            check(controller.clarityRowIsEnabled,
                  "预览尺寸「\(size.displayName)」时清晰度可用")
        }

        Preferences.panelSize = .off
        controller.refreshConditionalRows()
        check(!controller.clarityRowIsEnabled, "预览尺寸「关闭」时清晰度不可用")

        Preferences.panelSize = .medium
        controller.refreshConditionalRows()
        check(controller.clarityRowIsEnabled, "从「关闭」切回后清晰度恢复可用")

        // ================================================================ 尺寸独立于整个预览
        lines.append("")
        lines.append("【关闭缩略图 ≠ 关闭悬停预览】")

        Preferences.panelSize = .off
        let layout = PreviewGridView.Layout.make(
            for: [WindowTarget(
                pid: 1,
                windowID: 42,
                ownerName: "App",
                title: "一个窗口",
                bounds: CGRect(x: 0, y: 0, width: 1200, height: 800),
                isMain: false,
                isMinimized: false,
                identity: "1|一个窗口"
            )],
            size: .off,
            titleSize: .medium,
            screen: NSRect(x: 0, y: 0, width: 1440, height: 900)
        )
        check(!layout.showsPictures, "关闭缩略图后不再采集图片")
        check(layout.tileSize.height > 10,
              "窗口标题列表仍保留，可用于选择窗口",
              detail: "每项高 \(Int(layout.tileSize.height))pt")

        // Restore the user's settings.
        Preferences.transition = savedTransition
        Preferences.set(Preferences.Key.fadeInDuration, to: savedFadeIn, in: Preferences.fadeRange)
        Preferences.set(Preferences.Key.fadeOutDuration, to: savedFadeOut, in: Preferences.fadeRange)
        Preferences.panelSize = savedPanelSize

        lines.append("")
        lines.append(failures == 0 ? "设置行为测试全部通过。" : "有 \(failures) 项失败。")
        print(lines.joined(separator: "\n"))
        return failures == 0 ? 0 : 1
    }
}

// MARK: - 过渡动画是否真的生效

extension SettingsBehaviourTests {

    /// Verifies that the transition preference actually drives the panel, not just the settings UI.
    ///
    /// This is a regression test for a real defect: `PreviewPanel` used to read only the fade
    /// *durations*, never the transition mode, so choosing 「关闭动画」 still played a fade whenever
    /// the durations happened to be non-zero — the option had no effect on the panel at all.
    @MainActor
    static func runTransitionBehaviour() -> Int32 {
        var lines: [String] = ["DockPeek 过渡动画行为测试", ""]
        var failures = 0

        func check(_ ok: Bool, _ label: String, detail: String = "") {
            lines.append("\(ok ? "✅" : "❌") \(label)\(detail.isEmpty ? "" : " — \(detail)")")
            if !ok { failures += 1 }
        }

        let savedTransition = Preferences.transition
        let savedFadeIn = Preferences.fadeInDuration
        let savedFadeOut = Preferences.fadeOutDuration
        defer {
            Preferences.transition = savedTransition
            Preferences.set(Preferences.Key.fadeInDuration, to: savedFadeIn, in: Preferences.fadeRange)
            Preferences.set(Preferences.Key.fadeOutDuration, to: savedFadeOut, in: Preferences.fadeRange)
        }

        // Fade durations deliberately non-zero throughout: that is what used to force an animation
        // regardless of the selected mode.
        Preferences.set(Preferences.Key.fadeInDuration, to: 0.30, in: Preferences.fadeRange)
        Preferences.set(Preferences.Key.fadeOutDuration, to: 0.30, in: Preferences.fadeRange)

        let item = DockItem(
            name: "过渡测试",
            frame: CGRect(x: 0, y: 800, width: 60, height: 60),
            bundleURL: URL(fileURLWithPath: "/System/Applications/Calculator.app"),
            isApplicationRunning: false
        )

        func state(for mode: Preferences.Transition) -> (visible: Bool, alpha: CGFloat, scale: CGFloat) {
            Preferences.transition = mode
            let panel = PreviewPanel()
            // No running application behind this icon, so `present` returns early without showing.
            // The transition decision is therefore exercised through the show/hide helpers via a
            // synthetic item that does resolve: use a real one instead.
            _ = panel.present(for: item)
            let snapshot = panel.testPresentationState
            panel.hide()
            return snapshot
        }

        // The synthetic icon above has no running app, so build a panel through the real path using
        // whichever Dock icon is available; fall back to asserting the decision logic only.
        lines.append("【过渡动画是否驱动面板】")

        let realItem = DockItem(
            name: "Finder",
            frame: CGRect(x: 0, y: 800, width: 60, height: 60),
            bundleURL: URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app"),
            isApplicationRunning: true
        )

        func presentState(_ mode: Preferences.Transition) -> (visible: Bool, alpha: CGFloat, scale: CGFloat) {
            Preferences.transition = mode
            let panel = PreviewPanel()
            _ = panel.present(for: realItem)
            let snapshot = panel.testPresentationState
            panel.hide()
            return snapshot
        }

        let noneState = presentState(.none)
        check(noneState.visible, "「关闭动画」时面板仍然显示")
        check(noneState.alpha >= 0.99,
              "「关闭动画」时直接以完全不透明出现（不播放淡入）",
              detail: String(format: "alpha=%.2f", noneState.alpha))
        check(abs(noneState.scale - 1) < 0.001,
              "「关闭动画」时不应用缩放",
              detail: String(format: "scale=%.3f", noneState.scale))

        let fadeState = presentState(.fade)
        check(fadeState.visible, "「淡入淡出」时面板显示")
        check(fadeState.alpha < 0.99,
              "「淡入淡出」时从透明开始（确实在播放淡入）",
              detail: String(format: "alpha=%.2f", fadeState.alpha))

        Preferences.transition = .pop
        let popPanel = PreviewPanel()
        _ = popPanel.present(for: realItem)
        check(popPanel.testPresentationState.visible, "「弹出动画」时面板显示")
        // Assert the registered animation, not the layer's model value: Core Animation sets the
        // model straight to the target, so reading it back cannot show the starting scale.
        if let pop = popPanel.lastPopAnimation {
            check(abs(pop.from - PreviewPanel.popStartScale) < 0.02,
                  "「弹出动画」时从缩小状态开始",
                  detail: String(format: "from=%.3f（期望 %.2f）", pop.from, PreviewPanel.popStartScale))
            check(abs(pop.to - 1.0) < 0.02,
                  "「弹出动画」结束时回到原始尺寸",
                  detail: String(format: "to=%.2f", pop.to))
            check(pop.duration > 0 && pop.duration <= 0.2,
                  "弹出动画时长足够短",
                  detail: String(format: "%.2fs", pop.duration))
            check(pop.from > 0.5,
                  "弹出起始缩放不过小（不是从几乎不可见开始）",
                  detail: String(format: "%.2f", pop.from))
        } else {
            check(false, "「弹出动画」应注册一个缩放动画")
        }
        popPanel.hide()
        check(PreviewPanel.popInDuration <= 0.2 && PreviewPanel.popOutDuration <= 0.2,
              "弹出动画时长足够短",
              detail: String(format: "%.2fs / %.2fs", PreviewPanel.popInDuration, PreviewPanel.popOutDuration))

        // 关闭动画 must not have altered the stored fade durations.
        check(Preferences.fadeInDuration == 0.30 && Preferences.fadeOutDuration == 0.30,
              "播放/关闭动画都不改写淡入淡出时长",
              detail: String(format: "%.2f / %.2f", Preferences.fadeInDuration, Preferences.fadeOutDuration))

        lines.append("")
        lines.append(failures == 0 ? "过渡动画行为测试全部通过。" : "有 \(failures) 项失败。")
        print(lines.joined(separator: "\n"))
        return failures == 0 ? 0 : 1
    }
}
