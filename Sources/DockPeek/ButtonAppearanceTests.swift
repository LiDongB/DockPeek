import AppKit
import CoreGraphics
import Foundation

/// Renders the button styles side by side so the one that actually looks like a button can be chosen
/// from evidence rather than from the documentation.
///
/// The reported problem was that the 恢复默认 control "looks like clickable text, not a button". A
/// button that draws no bezel is indistinguishable from a label, so this compares the candidates.
@MainActor
enum ButtonAppearanceTests {

    static func run(outputDirectory: URL) async -> Int32 {
        var lines: [String] = ["DockPeek 按钮外观对比", ""]
        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let candidates: [(String, NSButton.BezelStyle)] = [
            ("Automatic", .automatic),
            ("Push", .push),
            ("Glass", glassStyle()),
            ("FlexiblePush", .flexiblePush)
        ]

        let width = 420
        let rowHeight = 44
        let height = rowHeight * candidates.count + 24

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        panel.title = "按钮外观对比"
        panel.level = .floating
        panel.isOpaque = true
        panel.backgroundColor = .windowBackgroundColor

        let content = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        // Plain (unflipped) view: lay the rows out from the top by counting down.
        for (index, candidate) in candidates.enumerated() {
            let y = CGFloat(height - rowHeight * (index + 1)) + 9

            let label = NSTextField(labelWithString: candidate.0)
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            label.frame = NSRect(x: 12, y: y + 8, width: 90, height: 16)
            content.addSubview(label)

            // Exactly how the settings window builds it.
            let button = NSButton(title: "恢复默认", target: nil, action: nil)
            button.bezelStyle = candidate.1
            button.controlSize = .regular
            button.font = .systemFont(ofSize: 12)
            button.sizeToFit()
            button.frame = NSRect(x: 110, y: y, width: max(110, button.frame.width), height: 26)
            content.addSubview(button)

            lines.append(String(format: "  %-12@ 尺寸 %.0f×%.0f  bezelStyle=%d",
                                candidate.0 as NSString, button.frame.width, button.frame.height,
                                candidate.1.rawValue))
        }

        panel.contentView = content
        panel.orderFrontRegardless()
        panel.displayIfNeeded()
        try? await Task.sleep(for: .milliseconds(700))

        let url = outputDirectory.appendingPathComponent("button-styles.png")
        var captured = false

        // `screencapture -l <windowNumber>` goes through the system capture service, which is more
        // reliable here than the deprecated `CGWindowListCreateImage` (that returned nil for our own
        // window).
        if panel.windowNumber > 0 {
            try? FileManager.default.removeItem(at: url)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = ["-x", "-o", "-l", String(panel.windowNumber), url.path]
            try? process.run()
            process.waitUntilExit()
            captured = FileManager.default.fileExists(atPath: url.path)
        }

        if captured {
            let size = (try? Data(contentsOf: url)).map { "\($0.count) 字节" } ?? ""
            lines.append("")
            lines.append("已写出对比图：\(url.path)  \(size)")
        } else {
            lines.append("")
            lines.append("⚠️  无法捕获窗口，无法给出图像证据")
        }

        panel.orderOut(nil)
        lines.append("")
        lines.append("请查看对比图，选择外观正确的档位。")
        print(lines.joined(separator: "\n"))
        return 0
    }

    private static func glassStyle() -> NSButton.BezelStyle {
        if #available(macOS 26.0, *) { return .glass }
        return .rounded
    }

}
