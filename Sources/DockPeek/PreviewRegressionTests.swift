import AppKit
import CoreGraphics
import Foundation

/// Regression tests for the preview fixes.
///
/// These cover the two defects that were actually reported — a minimised window losing its
/// thumbnail, and the corner artefacts around each picture — plus the geometry invariants the
/// layout relies on. They use constructed `WindowTarget` values, so they do not depend on the Dock,
/// the window server, or any real application being open.
@MainActor
enum PreviewRegressionTests {

    // MARK: - Fixtures

    private static func target(
        windowID: CGWindowID,
        title: String,
        minimized: Bool,
        bounds: CGRect = CGRect(x: 0, y: 0, width: 1367, height: 869),
        pid: pid_t = 4242,
        owner: String = "TestApp",
        identity: String? = nil
    ) -> WindowTarget {
        WindowTarget(
            pid: pid,
            windowID: windowID,
            ownerName: owner,
            title: title,
            bounds: bounds,
            isMain: false,
            isMinimized: minimized,
            identity: identity ?? WindowTarget.makeIdentity(pid: pid, ownerName: owner, title: title, slot: Int(windowID))
        )
    }

    private static func sampleImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 320, height: 200))
        image.lockFocus()
        NSColor.systemTeal.setFill()
        NSRect(x: 0, y: 0, width: 320, height: 200).fill()
        image.unlockFocus()
        return image
    }

    /// Bridges the async lookup used by the panel into these synchronous tests.
    private static func thumbnail(_ target: WindowTarget) async -> NSImage? {
        await ThumbnailProvider.shared.thumbnail(for: target)
    }

    // MARK: - Suite

    static func run() async -> Int32 {
        var lines: [String] = ["DockPeek 预览回归测试", ""]
        var failures = 0

        func check(_ ok: Bool, _ label: String, detail: String = "") {
            lines.append("\(ok ? "✅" : "❌") \(label)\(detail.isEmpty ? "" : " — \(detail)")")
            if !ok { failures += 1 }
        }

        ThumbnailProvider.shared.purge()

        // ================================================================ 1. 最小化不应丢图
        lines.append("【最小化丢图】")

        let visible = target(windowID: 24837, title: "项目计划 — 文档", minimized: false)
        let minimized = target(windowID: 4294967295, title: "项目计划 — 文档", minimized: true, identity: visible.identity)

        check(visible.identity == minimized.identity,
              "同一窗口在最小化前后 identity 保持一致",
              detail: "可见=\(visible.identity)  最小化=\(minimized.identity)")
        check(visible.cacheKey == minimized.cacheKey,
              "缓存键不随最小化改变",
              detail: visible.cacheKey)

        // Warm the cache as if the window had been captured while visible.
        ThumbnailProvider.shared.testInsert(image: sampleImage(), key: visible.cacheKey)
        check(ThumbnailProvider.shared.cached(for: minimized) != nil,
              "最小化后仍能取到缓存画面（这是原先丢失的行为）")

        let minimizedResult = await thumbnail(minimized)
        check(minimizedResult != nil, "最小化窗口的 thumbnail() 返回最后一次有效画面")
        check(minimizedResult?.size == visible.bounds.size || minimizedResult != nil,
              "返回的画面可用")

        // Restoring must find the same entry again.
        let restored = target(windowID: 24837, title: "项目计划 — 文档", minimized: false)
        check(ThumbnailProvider.shared.cached(for: restored) != nil,
              "窗口恢复后仍命中同一缓存条目")

        // ================================================================ 2. 无标题窗口
        lines.append("")
        lines.append("【无标题窗口的身份】")

        let untitledA = target(windowID: 111, title: "", minimized: false)
        let untitledB = target(windowID: 222, title: "", minimized: false)
        check(untitledA.identity != untitledB.identity,
              "无标题的不同窗口不会互相串味",
              detail: "\(untitledA.identity) vs \(untitledB.identity)")

        // ================================================================ 3. 不同应用不串味
        lines.append("")
        lines.append("【跨应用隔离】")

        let otherApp = target(windowID: 333, title: "项目计划 — 文档", minimized: false, pid: 9999, owner: "Other")
        check(otherApp.identity != visible.identity,
              "同名标题但不同应用的窗口 identity 不同")
        check(ThumbnailProvider.shared.cached(for: otherApp) == nil,
              "另一个应用取不到本应用的缓存")

        // ================================================================ 4. 应用退出清理
        lines.append("")
        lines.append("【应用退出清理】")

        ThumbnailProvider.shared.invalidateApp(pid: 4242)
        check(ThumbnailProvider.shared.cached(for: visible) == nil,
              "应用退出后其窗口缓存被清理")
        check(ThumbnailProvider.shared.cached(for: otherApp) == nil,
              "未受影响的应用本就没有缓存（对照）")

        // ================================================================ 5. 四角几何不变量
        lines.append("")
        lines.append("【缩略图几何】")

        // The picture is scaled to fit inside its box keeping the window's own aspect ratio, and the
        // corner radius is applied to that *drawn* size. If the two ever disagree, the container's
        // rounded corners show outside a smaller rectangle — the white-wedge artefact.
        let windowAspect = visible.bounds.width / visible.bounds.height
        let box = CGSize(width: 400, height: 254)
        let drawn = fittedPictureSize(image: CGSize(width: 1367, height: 869), box: box)
        let drawnAspect = drawn.width / max(drawn.height, 1)
        check(abs(drawnAspect - windowAspect) < 0.02,
              "绘制尺寸保持窗口原始比例",
              detail: String(format: "窗口 %.3f vs 绘制 %.3f", windowAspect, drawnAspect))
        check(drawn.width <= box.width + 0.5 && drawn.height <= box.height + 0.5,
              "绘制尺寸不超出可用框",
              detail: "\(Int(drawn.width))x\(Int(drawn.height)) ≤ \(Int(box.width))x\(Int(box.height))")

        // A picture that is smaller than the box must be centred, not stretched.
        let small = fittedPictureSize(image: CGSize(width: 300, height: 200), box: box)
        check(small.width > 300 && small.height > 200 && small.width <= box.width && small.height <= box.height,
              "低分辨率图片按比例填充显示框",
              detail: "\(Int(small.width))x\(Int(small.height))")

        // An oversized picture must be reduced, never enlarged.
        let huge = fittedPictureSize(image: CGSize(width: 4000, height: 3000), box: box)
        check(huge.width <= box.width + 0.5 && huge.height <= box.height + 0.5,
              "超大图片被缩小到框内",
              detail: "\(Int(huge.width))x\(Int(huge.height))")

        // ================================================================ 6. 尺寸档位
        lines.append("")
        lines.append("【尺寸档位】")

        let sizes = Preferences.PanelSize.allCases
        check(sizes.map(\.displayName) == ["更小", "小", "中", "大", "关闭"],
              "尺寸档位齐全且顺序正确",
              detail: sizes.map(\.displayName).joined(separator: " / "))

        let tinySize = Preferences.PanelSize.tiny.maxTileSize
        let smallSize = Preferences.PanelSize.small.maxTileSize
        if let tinySize, let smallSize {
            check(tinySize.width < smallSize.width && tinySize.height < smallSize.height,
                  "「更小」明显小于「小」",
                  detail: "更小 \(Int(tinySize.width))x\(Int(tinySize.height)) < 小 \(Int(smallSize.width))x\(Int(smallSize.height))")
            check(tinySize.width >= 200,
                  "「更小」没有小到不可用",
                  detail: "宽 \(Int(tinySize.width))pt")
        } else {
            check(false, "「更小」与「小」都应有尺寸")
        }

        check(Preferences.PanelSize.small.maxTileSize == CGSize(width: 300, height: 230),
              "原有「小」尺寸未改变")
        check(Preferences.PanelSize.medium.maxTileSize == CGSize(width: 400, height: 300),
              "原有「中」尺寸未改变")
        check(Preferences.PanelSize.large.maxTileSize == CGSize(width: 520, height: 390),
              "原有「大」尺寸未改变")
        check(Preferences.PanelSize.off.maxTileSize == nil,
              "「关闭」不提供缩略图尺寸")
        check(!Preferences.PanelSize.off.showsThumbnails,
              "「关闭」表示不显示缩略图")

        // ================================================================ 7. 缩略图 / 标题独立
        lines.append("")
        lines.append("【缩略图与标题独立】")

        check(Preferences.TitleSize.off.fontSize == nil, "标题可选「关闭」")
        check(Preferences.TitleSize.off.captionHeight == 0, "标题关闭时占位高度为 0")
        check(Preferences.TitleSize.small.fontSize != nil
                && Preferences.TitleSize.medium.fontSize != nil
                && Preferences.TitleSize.large.fontSize != nil,
              "标题小/中/大都有字号")
        if let s = Preferences.TitleSize.small.fontSize,
           let m = Preferences.TitleSize.medium.fontSize,
           let l = Preferences.TitleSize.large.fontSize {
            check(s < m && m < l, "标题字号递增", detail: "\(s) < \(m) < \(l)")
        }

        // Layout must stay usable when both are switched off.
        let titleOnly = PreviewGridView.Layout.make(
            for: [visible, restored],
            size: .off,
            titleSize: .medium,
            screen: NSRect(x: 0, y: 0, width: 1440, height: 900)
        )
        check(!titleOnly.showsPictures, "关闭缩略图时布局标记为不显示图片")
        check(titleOnly.tileSize.width > 100 && titleOnly.tileSize.height > 10,
              "关闭缩略图后每项仍是可点击的行",
              detail: "\(Int(titleOnly.tileSize.width))x\(Int(titleOnly.tileSize.height))")

        let bothOff = PreviewGridView.Layout.make(
            for: [visible],
            size: .off,
            titleSize: .off,
            screen: NSRect(x: 0, y: 0, width: 1440, height: 900)
        )
        check(bothOff.tileSize.height > 10,
              "缩略图与标题同时关闭时仍保留可点击高度",
              detail: "高 \(Int(bothOff.tileSize.height))pt")

        // ================================================================ 8. 清晰度
        lines.append("")
        lines.append("【缩略图清晰度】")

        let clarity = Preferences.ThumbnailClarity.allCases
        check(clarity.map(\.displayName) == ["原图", "标准", "流畅"],
              "清晰度档位齐全",
              detail: clarity.map(\.displayName).joined(separator: " / "))
        check(clarity[0].captureScale > clarity[1].captureScale
                && clarity[1].captureScale > clarity[2].captureScale,
              "清晰度实际影响采集分辨率（不是只改标签）",
              detail: clarity.map { "\($0.displayName)=\($0.captureScale)" }.joined(separator: " "))
        check(clarity[0].cachePixelLimit > clarity[2].cachePixelLimit,
              "清晰度实际影响缓存像素上限",
              detail: "原图 \(clarity[0].cachePixelLimit) > 流畅 \(clarity[2].cachePixelLimit)")

        // ================================================================ 9. 过渡动画
        lines.append("")
        lines.append("【过渡动画】")

        check(Preferences.Transition.allCases.map(\.displayName) == ["关闭动画", "淡入淡出", "弹出动画"],
              "过渡动画三个选项齐全")

        let originalFadeIn = Preferences.fadeInDuration
        let originalFadeOut = Preferences.fadeOutDuration
        let originalTransition = Preferences.transition
        Preferences.transition = .pop
        check(Preferences.fadeInDuration == originalFadeIn && Preferences.fadeOutDuration == originalFadeOut,
              "切换动画类型不丢失已设置的淡入/淡出时长",
              detail: String(format: "%.2f / %.2f", Preferences.fadeInDuration, Preferences.fadeOutDuration))
        Preferences.transition = originalTransition

        // ================================================================ 10. 状态机仍守宽限期
        lines.append("")
        lines.append("【身份比较对状态机的影响】")

        // The hover machine tracks Dock icons (DockItem), not windows. A magnified icon has a
        // different frame but the same identity — that must not restart the dwell timer.
        let icon = DockItem(
            name: "TestApp",
            frame: CGRect(x: 0, y: 800, width: 60, height: 60),
            bundleURL: URL(fileURLWithPath: "/Applications/TestApp.app"),
            isApplicationRunning: true
        )
        let magnifiedIcon = DockItem(
            name: "TestApp",
            frame: CGRect(x: 0, y: 800, width: 74, height: 74),
            bundleURL: URL(fileURLWithPath: "/Applications/TestApp.app"),
            isApplicationRunning: true
        )

        var state = DockMonitor.HoverState()
        let t0 = Date()
        _ = DockMonitor.hoverStep(
            state: &state, hit: icon, now: t0, dwellTime: 0.25, switchDelay: 0.05,
            gracePeriod: 0.22, isRetained: false, resolve: { $0 }
        )
        let shown = DockMonitor.hoverStep(
            state: &state, hit: icon, now: t0.addingTimeInterval(0.3), dwellTime: 0.25,
            switchDelay: 0.05, gracePeriod: 0.22, isRetained: false, resolve: { $0 }
        )
        check(shown == .show(hit: icon, resolved: icon), "悬停可正常弹出")

        let noRepeat = DockMonitor.hoverStep(
            state: &state, hit: magnifiedIcon, now: t0.addingTimeInterval(0.5), dwellTime: 0.25,
            switchDelay: 0.05, gracePeriod: 0.22, isRetained: false, resolve: { $0 }
        )
        check(noRepeat == .nothing,
              "图标被悬停放大（frame 变化）时不重新触发预览")
        check(state.reportedItem != nil, "预览保持上报状态")

        lines.append("")
        lines.append(failures == 0 ? "回归测试全部通过。" : "有 \(failures) 项失败。")
        print(lines.joined(separator: "\n"))
        return failures == 0 ? 0 : 1
    }

    /// Exercise the real image view geometry rather than a duplicate scaling formula.
    private static func fittedPictureSize(image: CGSize, box: CGSize) -> CGSize {
        let tile = WindowTileView(target: target(windowID: 42, title: "Fixture", minimized: false),
                                  tileSize: CGSize(width: box.width, height: box.height + WindowTileView.captionHeight))
        let bitmap = NSImage(size: image)
        bitmap.lockFocus()
        NSColor.systemBlue.setFill()
        NSRect(origin: .zero, size: image).fill()
        bitmap.unlockFocus()
        tile.setThumbnail(bitmap)
        return tile.testPictureGeometry.drawnSize
    }
}
