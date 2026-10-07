import AppKit
import CoreGraphics
import Foundation

/// Screen-placement checks for the preview panel.
///
/// Verifies, for every Dock icon and every size preset, that the panel it produces is *completely*
/// inside the Dock's screen. Clamping the origin is not sufficient on its own: if the content is
/// taller or wider than the screen, the clamp still leaves the far side cut off, which is what
/// produced the "only a corner is visible" report.
@MainActor
enum PanelLayoutTests {

    static func run(outputDirectory: URL) async -> Int32 {
        var lines: [String] = ["DockPeek 预览位置校验", ""]
        var failures = 0

        func check(_ ok: Bool, _ label: String, detail: String = "") {
            lines.append("\(ok ? "✅" : "❌") \(label)\(detail.isEmpty ? "" : " — \(detail)")")
            if !ok { failures += 1 }
        }

        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let monitor = DockMonitor { _ in }
        monitor.start()
        try? await Task.sleep(for: .seconds(1.0))

        let icons = monitor.dockIcons.filter(\.isApplicationRunning)
        guard !icons.isEmpty else {
            lines.append("❌ 没有正在运行的 Dock 图标，无法校验")
            monitor.stop()
            return 1
        }

        // Report the screen setup so the numbers below can be interpreted.
        for (index, screen) in NSScreen.screens.enumerated() {
            let f = screen.frame
            let v = screen.visibleFrame
            lines.append(String(format: "屏幕%d：frame (%.0f,%.0f) %.0f×%.0f，可用区 (%.0f,%.0f) %.0f×%.0f",
                                index, f.minX, f.minY, f.width, f.height,
                                v.minX, v.minY, v.width, v.height))
        }
        lines.append("")

        let savedSize = Preferences.panelSize
        let panel = PreviewPanel()
        defer { Preferences.panelSize = savedSize }

        var checked = 0
        var fits = 0

        for size in Preferences.PanelSize.allCases {
            Preferences.panelSize = size

            var sizeFailures: [String] = []
            var sampleRect: CGRect = .zero
            var sampleVisible: CGRect = .zero
            var sampleEdge = "?"

            for icon in icons {
                _ = panel.present(for: icon)
                // Let the layout settle without waiting on captures.
                try? await Task.sleep(for: .milliseconds(60))

                guard let facts = panel.testPlacementFacts else { continue }
                checked += 1

                if facts.panelFits && facts.gridInsidePanel {
                    fits += 1
                } else {
                    if sampleRect == .zero {
                        sampleRect = facts.panelRect
                        sampleVisible = facts.visibleFrame
                        sampleEdge = facts.dockEdge
                    }
                    var why: [String] = []
                    if !facts.fitsHorizontally { why.append("水平越界") }
                    if !facts.fitsVertically { why.append("垂直越界") }
                    if !facts.gridInsidePanel { why.append("网格超出面板") }
                    sizeFailures.append(String(format: "%@(%@) 面板%.0f×%.0f 网格%.0f×%.0f",
                                               icon.name, why.joined(separator: "+"),
                                               facts.panelRect.width, facts.panelRect.height,
                                               facts.gridRect.width, facts.gridRect.height))
                    // Dump the origin maths for the first few failures only.
                    if sizeFailures.count <= 2 {
                        lines.append("      [\(icon.name)] \(panel.testLastOriginMath)")



                    }
                }
            }
            panel.hide()

            let label = "尺寸「\(size.displayName)」下预览完整落在屏幕内"
            if sizeFailures.isEmpty {
                check(true, label, detail: "\(icons.count)/\(icons.count) 个图标")
            } else {
                lines.append("      " + panel.testLastOriginMath)
                check(false, label,
                      detail: "\(sizeFailures.count)/\(icons.count) 失败：\(sizeFailures.prefix(2).joined(separator: "、"))"
                          + String(format: "；例 面板 (%.0f,%.0f) %.0f×%.0f，可用区 (%.0f,%.0f) %.0f×%.0f，Dock 边=%@",
                                   sampleRect.minX, sampleRect.minY, sampleRect.width, sampleRect.height,
                                   sampleVisible.minX, sampleVisible.minY,
                                   sampleVisible.width, sampleVisible.height,
                                   sampleEdge as NSString))
            }
        }

        Preferences.panelSize = savedSize
        check(checked > 0, "实际弹出并检查了面板", detail: "\(checked) 次")
        check(fits == checked, "所有组合下预览都完整可见", detail: "\(fits)/\(checked)")

        // ---------------------------------------------------------------- 真实截屏诊断
        lines.append("")
        lines.append("【真实画面捕获】")
        _ = panel.present(for: icons[0])
        try? await Task.sleep(for: .milliseconds(900))
        if let facts = panel.testPlacementFacts {
            lines.append(String(format: "  面板 (%.0f,%.0f) %.0f×%.0f 网格 %.0f×%.0f 内容 %.0f×%.0f",
                                facts.panelRect.minX, facts.panelRect.minY,
                                facts.panelRect.width, facts.panelRect.height,
                                facts.gridRect.width, facts.gridRect.height,
                                facts.contentRect.width, facts.contentRect.height))
        }
        let shot = outputDirectory.appendingPathComponent("panel-onscreen.png")
        if panel.testWriteOnScreenCapture(to: shot) {
            let size = panel.testCaptureOnScreenPanel().map { "\($0.width)×\($0.height) px" } ?? "?"
            lines.append("  ✅ 已捕获真实画面：\(shot.path)  \(size)")
        } else {
            lines.append("  ❌ 无法捕获面板窗口（可能缺少屏幕录制权限）")
        }
        panel.hide()

        // ---------------------------------------------------------------- 容器链诊断
        lines.append("")
        lines.append("【容器链诊断】")
        _ = panel.present(for: icons[0])
        try? await Task.sleep(for: .milliseconds(60))
        _ = panel.testPlacementFacts
        for line in panel.testDebugChain { lines.append("  " + line) }
        panel.hide()

        // ---------------------------------------------------------------- 记录一张实拍位置
        lines.append("")
        lines.append("【位置记录】")
        for icon in icons.prefix(4) {
            _ = panel.present(for: icon)
            try? await Task.sleep(for: .milliseconds(60))
            if let facts = panel.testPlacementFacts {
                lines.append(String(format: "  %@：图标(Dock 边=%@) → 面板 (%.0f,%.0f) %.0f×%.0f  %@",
                                    icon.name, facts.dockEdge,
                                    facts.panelRect.minX, facts.panelRect.minY,
                                    facts.panelRect.width, facts.panelRect.height,
                                    facts.panelFits ? "完整在屏" : "越界"))
            }
        }
        panel.hide()

        monitor.stop()
        lines.append("")
        lines.append(failures == 0 ? "预览位置校验全部通过。" : "有 \(failures) 项失败。")
        print(lines.joined(separator: "\n"))
        return failures == 0 ? 0 : 1
    }
}
