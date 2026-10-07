import AppKit

/// Regression checks use the real panel, settings controls, and an injected capture pipeline.
@MainActor
enum FixVerificationTests {
    private static func window(_ id: Int, title: String = "Same title", minimized: Bool = false) -> WindowTarget {
        WindowTarget(pid: 4242, windowID: UInt32(id), ownerName: "Test", title: title,
                     bounds: CGRect(x: 100, y: 100, width: 960, height: 600), isMain: id == 1,
                     isMinimized: minimized, identity: "4242|ax:fixture-\(id)")
    }
    static func image() -> NSImage {
        let image = NSImage(size: CGSize(width: 240, height: 150))
        image.lockFocus()
        for (rect, color) in [
            (NSRect(x: 0, y: 0, width: 120, height: 75), NSColor.systemRed),
            (NSRect(x: 120, y: 0, width: 120, height: 75), NSColor.systemBlue),
            (NSRect(x: 0, y: 75, width: 120, height: 75), NSColor.systemGreen),
            (NSRect(x: 120, y: 75, width: 120, height: 75), NSColor.systemYellow)
        ] { color.setFill(); rect.fill() }
        image.unlockFocus()
        return image
    }
    static func run(output: URL) async -> Int32 {
        var failures = 0
        var lines: [String] = []
        func check(_ condition: Bool, _ text: String) {
            lines.append("\(condition ? "PASS" : "FAIL") \(text)")
            if !condition { failures += 1 }
        }
        let keys = ["previewEnabled", "panelSize", "thumbnailClarity", "transition", "titleSize", "backdrop",
                    "interfaceLanguage", "switcherEnabled", "switcherShortcut", "dwellTime", "selectionTrigger"]
        let saved = Dictionary(uniqueKeysWithValues: keys.compactMap { key in UserDefaults.standard.object(forKey: key).map { (key, $0) } })
        defer { for key in keys { if let value = saved[key] { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) } } }
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        L10n.language = .chinese
        Preferences.panelSize = .medium
        Preferences.titleSize = .medium
        Preferences.transition = .none
        Preferences.thumbnailClarity = .standard
        let first = window(1)
        let second = window(2)
        check(first.cacheKey != second.cacheKey, "同名窗口缓存互不覆盖")
        check(WindowTarget.makeIdentity(pid: 1, ownerName: "A", title: "Old", slot: 10)
              == WindowTarget.makeIdentity(pid: 1, ownerName: "A", title: "New", slot: 10), "窗口标题变化不改变后备身份")
        check(Preferences.Shortcut(dictionary: ["keyCode": -1]) == nil
              && Preferences.Shortcut(dictionary: ["keyCode": 999999]) == nil, "损坏的快捷键数据不会导致崩溃")
        UserDefaults.standard.set(Double.nan, forKey: "dwellTime")
        check(Preferences.dwellTime.isFinite, "非有限延迟值回退到默认设置")

        var clock = Date()
        var shouldFail = false
        let provider = ThumbnailProvider(now: { clock }, capture: { _, _ in shouldFail ? nil : image() })
        _ = await provider.thumbnail(for: first)
        clock = clock.addingTimeInterval(3600)
        shouldFail = true
        _ = await provider.thumbnail(for: second)
        let retained = await provider.thumbnail(for: window(1, minimized: true))
        check(retained != nil, "一小时后、其他窗口刷新失败时最小化窗口仍保留画面")
        check(await provider.thumbnail(for: first) != nil, "旧画面不会因重新截取失败而丢失")
        provider.invalidateApp(pid: 4242)
        check(provider.cachedCount == 0, "应用退出时清理全部缓存")
        var captureStarted = false
        let delayed = ThumbnailProvider(capture: { _, _ in
            captureStarted = true
            // Deliberately ignore cancellation, like a framework callback already in flight.
            try? await Task.sleep(for: .milliseconds(50))
            return image()
        })
        let work = Task { await delayed.thumbnail(for: first) }
        while !captureStarted { await Task.yield() }
        delayed.invalidateApp(pid: 4242)
        _ = await work.value
        check(delayed.cachedCount == 0, "退出后的迟到截取不能重新写入缓存")

        let iconCocoa = NSRect(x: NSScreen.main?.frame.midX ?? 700, y: 0, width: 48, height: 48)
        let item = DockItem(name: "Fixture", frame: CoordinateConversion.quartzRect(fromCocoa: iconCocoa), bundleURL: nil, isApplicationRunning: true)
        let panel = PreviewPanel()
        panel.shouldAcceptEmptyWindowList = { false }
        _ = panel.testBuildPreview(for: item, windows: [first])
        let emptyItem = DockItem(name: "No windows", frame: item.frame, bundleURL: nil, isApplicationRunning: true)
        check(!panel.testBuildPreview(for: emptyItem, windows: []), "没有窗口的另一个应用不显示旧预览")
        check(panel.testAcceptedWindowCount == 0 && !panel.testPanelIsOrderedIn, "切换至无窗口应用时立即清除旧面板")
        for size in Preferences.PanelSize.allCases {
            Preferences.panelSize = size
            for title in Preferences.TitleSize.allCases {
                Preferences.titleSize = title
                let targets = (1...24).map { window($0) }
                _ = panel.testBuildPreview(for: item, windows: targets)
                check(panel.testTiles.count == 24 && panel.testPlacementFacts?.panelFits == true,
                      "24窗口布局不越屏：\(size.displayName)/标题\(title.displayName)")
                if panel.testPlacementFacts?.panelFits != true { lines.append("Placement: \(String(describing: panel.testPlacementFacts))") }
                let scroll = panel.testScrollView!
                let document = scroll.documentView!
                check(panel.testTiles.allSatisfy { document.bounds.contains($0.frame) }, "全部窗口均在可滚动文档范围内")
                scroll.contentView.scroll(to: CGPoint(x: 0, y: document.bounds.height - scroll.contentView.bounds.height))
                check(panel.testTiles.last!.frame.intersects(scroll.contentView.bounds), "最后一个窗口能够滚动显示")
            }
        }
        Preferences.panelSize = .medium
        Preferences.titleSize = .medium
        _ = panel.testBuildPreview(for: item, windows: [first, second])
        for tile in panel.testTiles { tile.setThumbnail(image()) }
        let picture = panel.testTiles[0].testPictureGeometry
        check(abs(picture.drawnSize.width - picture.availableBox.width) < 2,
              "低清晰度图片填充相同比例的显示区域")
        for material in Preferences.Backdrop.allCases {
            Preferences.backdrop = material
            panel.refreshPreferences()
            for tile in panel.testTiles { tile.setThumbnail(image()) }
            let expected = material == .glass ? "NSGlassEffectView" : "NSVisualEffectView"
            check(panel.testMaterialName == expected, "材质切换立即创建正确原生组件：\(expected)")
            let screenshot = output.appendingPathComponent("preview-\(material.rawValue).png")
            check(panel.testScrollView?.window?.windowNumber == panel.testWindowNumber,
                  "切换材质后窗口内容仍属于预览面板")
            await capture(panel.testWindowNumber, to: screenshot)
            check(hasColoredThumbnail(screenshot), "实际截图中包含完整缩略图：\(material.rawValue)")
        }
        Preferences.transition = .pop
        _ = panel.testBuildPreview(for: item, windows: [first, second])
        for tile in panel.testTiles { tile.setThumbnail(image()) }
        try? await Task.sleep(for: .milliseconds(250))
        let layer = panel.testContentLayer!
        check(CATransform3DIsIdentity(layer.transform), "弹出动画完成后内容变换为恒等矩阵")
        check(layer.frame.origin == .zero, "弹出动画不移动根图层、不造成大片内容裁切")
        let popScreenshot = output.appendingPathComponent("preview-pop.png")
        await capture(panel.testWindowNumber, to: popScreenshot)
        check(hasColoredThumbnail(popScreenshot), "弹出动画后实际截图中缩略图仍可见")
        panel.hide()
        Preferences.transition = .none
        for language in [L10n.Language.chinese, .english] {
            L10n.language = language
            let settings = SettingsWindowController()
            settings.show()
            for mode in Preferences.Transition.allCases {
                Preferences.transition = mode
                let (_, fits) = settings.layoutReport()
                check(fits, "\(language.rawValue)/\(mode.rawValue)条件布局正常")
            }
            Preferences.transition = .none
            let (report, good) = settings.layoutReport()
            check(good, "\(language.rawValue)设置页无控件或文字越界")
            if !good { lines += report }
            let root = settings.windowForTesting!.contentView!
            func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
            let views = descendants(root)
            check(views.compactMap { $0 as? NSSwitch }.count == 7, "七项启用/关闭设置全部使用 NSSwitch")
            check(!views.contains { ($0 as? NSButton)?.identifier?.rawValue == "DockPeekCheckbox" }, "设置中不存在旧勾选框")
            let picker = views.compactMap { $0 as? NSSegmentedControl }.first
            check(picker != nil && picker!.frame.minY > settings.windowForTesting!.contentView!.bounds.height - 58,
                  "设置页使用顶部原生方正页面切换栏")
            check(settings.windowForTesting?.titleVisibility == .visible, "设置窗口标题可见")
            check(settings.windowForTesting?.standardWindowButton(.zoomButton)?.isEnabled != true, "设置绿色按钮禁用")
            settings.selectPage(2)
            let about = descendants(root).compactMap { $0 as? NSTextField }.filter { !$0.isEditable && ($0.stringValue.hasPrefix("DockPeek V") || $0.stringValue.hasPrefix("Version 0.") || $0.stringValue.hasPrefix("版本 0.")) }
            check(!about.isEmpty && about.allSatisfy(\.isSelectable), "关于标题与更新记录可选择复制")
            for page in 0...2 {
                settings.selectPage(page)
                settings.windowForTesting?.contentView?.layoutSubtreeIfNeeded()
                if language == .english {
                    let fields = descendants(root).compactMap { $0 as? NSTextField }.map(\.stringValue)
                    check(fields.allSatisfy { $0.range(of: "[\\u4e00-\\u9fff]", options: .regularExpression) == nil },
                          "英文页面 \(page) 无遗漏中文")
                }
                await capture(settings.windowForTesting?.windowNumber, to: output.appendingPathComponent("settings-\(language.rawValue)-\(page).png"))
            }
            settings.selectPage(2)
            let footerButtons = descendants(root).compactMap { $0 as? NSButton }
                .filter { ["GitHub", "发送邮件", "Send email"].contains($0.title) }
            check(footerButtons.count == 2 && footerButtons.allSatisfy { $0.enclosingScrollView == nil }
                  && abs(footerButtons[0].frame.minY - footerButtons[1].frame.minY) < 1,
                  "邮件与 GitHub 入口固定在滚动容器外且同一行")
            let emailAddress = descendants(root).compactMap { $0 as? NSTextField }.first { $0.stringValue == "lidonggemail@gmail.com" }
            check(emailAddress != nil && emailAddress!.enclosingScrollView == nil && emailAddress!.isSelectable,
                  "邮箱地址固定在滚动区外并支持复制")
            let document = descendants(root).compactMap { $0 as? NSTextView }.first { $0.enclosingScrollView != nil }!
            settings.windowForTesting?.makeFirstResponder(document)
            let selection = NSRange(location: 0, length: min(200, document.string.utf16.count))
            document.setSelectedRange(selection)
            document.scrollRangeToVisible(NSRange(location: document.string.utf16.count - 1, length: 1))
            document.layoutSubtreeIfNeeded()
            check(document.isSelectable && !document.isEditable && document.selectedRange() == selection,
                  "更新记录跨段落选区在滚动后保持稳定")
            let clipboard = NSPasteboard.withUniqueName()
            let copied = document.writeSelection(to: clipboard, types: [.string])
            let copiedText = clipboard.string(forType: .string)
            let expectedText = (document.string as NSString).substring(with: selection)
            check(copied && copiedText == expectedText,
                  "原生文本选择可复制完整的跨段落内容")
            if !copied || copiedText != expectedText {
                lines.append("Copy diagnostic: returned=\(copied), types=\(String(describing: clipboard.types)), actual=\(String(describing: copiedText)), expected=\(expectedText)")
            }
            clipboard.releaseGlobally()
            let notes = descendants(root).compactMap { $0 as? NSTextField }.map(\.stringValue)
                + document.string.components(separatedBy: "\n")
            let headings = notes.filter { $0.hasPrefix(language == .english ? "Version 0." : "版本 0.") }
            check(headings == headings.sorted { $0.compare($1, options: .numeric) == .orderedAscending }
                  && headings.count == 7, "关于页包含按升序排列的七个版本")
            if language == .english {
                lines += notes.filter { $0.range(of: "[\\u4e00-\\u9fff]", options: .regularExpression) != nil }.map { "Untranslated: " + $0 }
                check(notes.filter { $0.range(of: "[\\u4e00-\\u9fff]", options: .regularExpression) != nil }.isEmpty,
                      "英文设置页没有遗漏的中文正文")
            }
            settings.windowForTesting?.close()
        }
        let interaction = WindowInteractionController()
        Preferences.switcherEnabled = true
        Preferences.switcherShortcut = .default
        check(interaction.configure() && interaction.isShortcutRegistered, "默认全局窗口切换快捷键实际注册成功")
        Preferences.switcherEnabled = false
        _ = interaction.configure()
        check(!interaction.isShortcutRegistered, "关闭快捷键后撤销全局注册")
        interaction.stop()
        for (passed, label) in await FollowupVerificationTests.run() { check(passed, label) }
        // Public screenshots use synthetic documents, never windows belonging to the user.
        L10n.language = .english
        Preferences.transition = .none
        Preferences.panelSize = .small
        Preferences.backdrop = .glass
        _ = panel.testBuildPreview(for: item, windows: [window(1, title: "Weekend ideas"), window(2, title: "Launch checklist")])
        for (index, tile) in panel.testTiles.enumerated() { tile.setThumbnail(demoDocument(index)) }
        await capture(panel.testWindowNumber, to: output.appendingPathComponent("preview-demo.png"))
        panel.hide()
        lines.append("\n\(failures == 0 ? "全部通过" : "失败 \(failures) 项")")
        print(lines.joined(separator: "\n"))
        try? lines.joined(separator: "\n").write(to: output.appendingPathComponent("verification.txt"), atomically: true, encoding: .utf8)
        return failures == 0 ? 0 : 1
    }
    private static func demoDocument(_ index: Int) -> NSImage {
        let image = NSImage(size: NSSize(width: 960, height: 600))
        image.lockFocus()
        NSColor(calibratedWhite: 0.98, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 960, height: 600).fill()
        NSColor(calibratedWhite: 0.93, alpha: 1).setFill()
        NSRect(x: 0, y: 548, width: 960, height: 52).fill()
        for (x, color) in [(CGFloat(24), NSColor.systemRed), (CGFloat(50), NSColor.systemYellow), (CGFloat(76), NSColor.systemGreen)] {
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: x, y: 566, width: 14, height: 14)).fill()
        }
        let title = index == 0 ? "Weekend ideas" : "Launch checklist"
        (title as NSString).draw(at: NSPoint(x: 70, y: 450), withAttributes: [.font: NSFont.systemFont(ofSize: 42, weight: .bold), .foregroundColor: NSColor.black])
        let lines = index == 0 ? ["Walk somewhere new", "Sketch a tiny app idea", "Read a chapter", "Make time for a good cup of tea"]
            : ["Polish the window previews", "Test the small details", "Write clear documentation", "Share it with the world"]
        for (row, text) in lines.enumerated() {
            let y = CGFloat(360 - row * 66)
            NSColor.systemBlue.setFill()
            NSBezierPath(roundedRect: NSRect(x: 70, y: y + 3, width: 20, height: 20), xRadius: 5, yRadius: 5).fill()
            (text as NSString).draw(at: NSPoint(x: 110, y: y), withAttributes: [.font: NSFont.systemFont(ofSize: 28), .foregroundColor: NSColor.darkGray])
        }
        image.unlockFocus()
        return image
    }
    private static func hasColoredThumbnail(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url), let bitmap = NSBitmapImageRep(data: data) else { return false }
        for y in [0.2, 0.65] {
            guard let c = bitmap.colorAt(x: Int(Double(bitmap.pixelsWide) * 0.1),
                                         y: Int(Double(bitmap.pixelsHigh) * y))?.usingColorSpace(.sRGB) else { return false }
            let channels = [c.redComponent, c.greenComponent, c.blueComponent]
            if (channels.max()! - channels.min()!) < 0.2 { return false }
        }
        return true
    }
    private static func capture(_ number: Int?, to url: URL) async {
        try? await Task.sleep(for: .milliseconds(150))
        guard let number else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-l", String(number), url.path]
        try? process.run()
        process.waitUntilExit()
    }
}
