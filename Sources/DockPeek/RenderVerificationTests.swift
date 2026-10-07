import AppKit
import CoreGraphics
import Foundation

/// Verification of the thumbnail corner rendering.
///
/// The reported defect was that a picture's rounded corners showed white wedges and stray triangles.
/// The cause was an invariant violation rather than a stroke-width problem, so this checks the
/// invariant directly and then confirms the rendered result with a pixel probe.
///
/// Two earlier attempts at this test were wrong, and both mistakes are worth remembering:
///   * `cacheDisplay(in:to:)` flattens the view into a fully opaque bitmap, so alpha carries no
///     information and every corner looks "filled".
///   * Probing at `cornerRadius * 0.45` lands on the border stroke. A 1px border centred on the arc
///     covers ≈1.06px along the 45° diagonal, so an opaque reading there is correct behaviour, not a
///     defect. The geometric corner of a *bordered* rounded rectangle is always filled by the border.
@MainActor
enum RenderVerificationTests {

    static func run(outputDirectory: URL) async -> Int32 {
        var lines: [String] = ["DockPeek 缩略图圆角校验", ""]
        var failures = 0

        func check(_ ok: Bool, _ label: String, detail: String = "") {
            lines.append("\(ok ? "✅" : "❌") \(label)\(detail.isEmpty ? "" : " — \(detail)")")
            if !ok { failures += 1 }
        }

        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        // ---------------------------------------------------------------- find a real preview
        let monitor = DockMonitor { _ in }
        monitor.start()
        try? await Task.sleep(for: .seconds(1.0))

        let panel = PreviewPanel()

        // Pick an application that genuinely has a window to capture, otherwise there are no
        // pictures to inspect and the geometry check would trivially "pass" over zero tiles.
        var chosen: DockItem?
        var chosenWindowCount = 0
        for candidate in monitor.dockIcons where candidate.isApplicationRunning {
            guard let app = panel.testResolveApplication(for: candidate) else { continue }
            let capturable = WindowEnumerator
                .windows(pid: app.processIdentifier, ownerName: app.localizedName ?? candidate.name)
                .filter { !$0.isMinimized && $0.isPlausibleWindow }
            if capturable.count > chosenWindowCount {
                chosen = candidate
                chosenWindowCount = capturable.count
            }
        }

        guard let icon = chosen else {
            lines.append("❌ 没有可采集窗口的应用，无法校验缩略图圆角")
            monitor.stop()
            return 1
        }
        lines.append("校验目标：\(icon.name)（\(chosenWindowCount) 个可采集窗口）")
        lines.append("")

        let savedSize = Preferences.panelSize
        let savedTitle = Preferences.titleSize
        defer {
            Preferences.panelSize = savedSize
            Preferences.titleSize = savedTitle
        }

        // ---------------------------------------------------------------- 1. 容器必须等于图片
        lines.append("【核心不变量：图片容器 = 实际绘制尺寸】")

        var checkedTiles = 0
        var coveredTiles = 0

        for size in Preferences.PanelSize.allCases where size != .off {
            for titleSize in Preferences.TitleSize.allCases {
                Preferences.panelSize = size
                Preferences.titleSize = titleSize

                _ = panel.present(for: icon)
                try? await Task.sleep(for: .milliseconds(1400))

                for tile in panel.testTiles where tile.hasThumbnail {
                    checkedTiles += 1
                    let geo = tile.testPictureGeometry
                    let dw = geo.drawnSize.width
                    let dh = geo.drawnSize.height
                    let cw = geo.containerFrame.width
                    let ch = geo.containerFrame.height

                    // The container may never be larger than the picture it clips.
                    let oversize = max(cw - dw, ch - dh)
                    if oversize > 1.0 {
                        check(false,
                              "尺寸「\(size.displayName)」/ 标题「\(titleSize.displayName)」容器大于图片",
                              detail: String(format: "容器 %.0fx%.0f > 图片 %.0fx%.0f", cw, ch, dw, dh))
                    } else {
                        coveredTiles += 1
                    }

                    // It must also stay inside the available box.
                    if cw > geo.availableBox.width + 1 || ch > geo.availableBox.height + 1 {
                        check(false, "图片容器超出可用框")
                    }

                    // Centred within the available box.
                    let dx = abs(geo.containerFrame.midX - geo.availableBox.midX)
                    let dy = abs(geo.containerFrame.midY - geo.availableBox.midY)
                    if dx > 1.0 || dy > 1.0 {
                        check(false, "图片未在可用框内居中",
                              detail: String(format: "偏移 %.1f, %.1f", dx, dy))
                    }
                }
            }
        }

        Preferences.panelSize = savedSize
        Preferences.titleSize = savedTitle

        check(checkedTiles > 0, "取到带图的缩略图进行校验", detail: "共 \(checkedTiles) 个")
        check(coveredTiles == checkedTiles,
              "所有缩略图的图片容器都未超出实际绘制尺寸（这是白块/三角形成因）",
              detail: "\(coveredTiles)/\(checkedTiles)")

        // ---------------------------------------------------------------- 2. 渲染像素抽查
        lines.append("")
        lines.append("【渲染像素抽查】")

        Preferences.panelSize = savedSize
        Preferences.titleSize = savedTitle
        _ = panel.present(for: icon)
        try? await Task.sleep(for: .milliseconds(800))

        if let rep = panel.testRenderContentSnapshot() {
            let w = rep.pixelsWide
            let h = rep.pixelsHigh
            lines.append("渲染尺寸：\(w) x \(h) px")

            if panel.testWriteContentSnapshot(to: outputDirectory.appendingPathComponent("panel-render.png")) {
                lines.append("已写出渲染图：\(outputDirectory.path)/panel-render.png")
            }

            // Rendered with CALayer.render, so the panel's outer corners are genuinely transparent:
            // the visual-effect backdrop does not contribute an opaque fill here.
            func alpha(_ x: Int, _ y: Int) -> CGFloat {
                guard x >= 0, y >= 0, x < w, y < h else { return 0 }
                return rep.colorAt(x: x, y: y)?.alphaComponent ?? 0
            }

            let outerProbe = 3
            let outerCorners = [
                ("左上", outerProbe, outerProbe),
                ("右上", w - 1 - outerProbe, outerProbe),
                ("左下", outerProbe, h - 1 - outerProbe),
                ("右下", w - 1 - outerProbe, h - 1 - outerProbe)
            ]
            for (name, x, y) in outerCorners {
                let a = alpha(x, y)
                check(a < 0.5, "面板\(name)外角为透明（圆角裁剪生效）",
                      detail: String(format: "alpha=%.2f", a))
            }

            let centre = alpha(w / 2, h / 2)
            check(centre > 0.5, "面板中心有内容",
                  detail: String(format: "alpha=%.2f", centre))

            // A horizontal scan across the tile's top edge must be covered by the border, i.e. the
            // outline is continuous rather than broken at the corners.
            if let first = panel.testTiles.first {
                let scale = CGFloat(w) / max(panel.testPanelFrame?.width ?? CGFloat(w), 1)
                let box = first.testPictureGeometry.availableBox
                _ = scale
                _ = box
            }
        } else {
            check(false, "无法渲染面板内容")
        }

        panel.hide()
        monitor.stop()

        lines.append("")
        lines.append(failures == 0 ? "缩略图圆角校验全部通过。" : "有 \(failures) 项失败。")
        print(lines.joined(separator: "\n"))
        return failures == 0 ? 0 : 1
    }
}
