import AppKit

@MainActor
enum FollowupVerificationTests {
    static func run() async -> [(Bool, String)] {
        var checks: [(Bool, String)] = []
        func check(_ value: Bool, _ label: String) { checks.append((value, label)) }
        let oldTrigger = Preferences.selectionTrigger
        defer { Preferences.selectionTrigger = oldTrigger }
        let target = WindowTarget(pid: 4242, windowID: 1, ownerName: "Example", title: "Example window",
                                  bounds: CGRect(x: 0, y: 0, width: 400, height: 300), isMain: true,
                                  isMinimized: false, identity: "followup-test")
        let host = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 400, height: 200),
                            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        host.isReleasedWhenClosed = false
        let tile = WindowTileView(target: target, tileSize: CGSize(width: 180, height: 140))
        let other = WindowTileView(target: target, tileSize: CGSize(width: 180, height: 140))
        other.frame.origin.x = 200
        host.contentView?.addSubview(tile)
        host.contentView?.addSubview(other)
        host.orderFrontRegardless()
        defer { host.close() }
        var selected = 0
        tile.onSelect = { _ in selected += 1 }
        other.onSelect = { _ in selected += 100 }
        func event(_ type: NSEvent.EventType, _ point: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                               windowNumber: host.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        let inside = tile.convert(NSPoint(x: 50, y: 50), to: nil)
        let outside = tile.convert(NSPoint(x: 190, y: 50), to: nil)
        Preferences.selectionTrigger = .mouseUp
        tile.mouseDown(with: event(.leftMouseDown, inside))
        check(selected == 0 && tile.isPressPending, "松开模式按下时不会切换")
        tile.mouseUp(with: event(.leftMouseUp, outside))
        check(selected == 0 && !tile.isPressPending, "按下后移开再松开取消切换")
        other.mouseUp(with: event(.leftMouseUp, other.convert(NSPoint(x: 50, y: 50), to: nil)))
        check(selected == 0, "在另一个缩略图松开不会误切换")
        tile.mouseDown(with: event(.leftMouseDown, inside))
        tile.mouseUp(with: event(.leftMouseUp, inside))
        check(selected == 1, "同一缩略图按下并松开恰好切换一次")
        Preferences.selectionTrigger = .mouseDown
        tile.mouseDown(with: event(.leftMouseDown, inside))
        tile.mouseUp(with: event(.leftMouseUp, inside))
        check(selected == 2, "按下模式立即切换且松开不重复触发")
        Preferences.selectionTrigger = .mouseUp
        tile.mouseDown(with: event(.leftMouseDown, inside))
        host.orderOut(nil)
        tile.mouseUp(with: event(.leftMouseUp, inside))
        check(selected == 2, "面板已隐藏时松开不会激活旧窗口")
        var requested = false
        tile.onCloseAll = { requested = true }
        let menu = tile.menu(for: event(.rightMouseDown, inside))!
        menu.performActionForItem(at: 0)
        check(requested, "关闭所有窗口菜单接入独立操作")

        let preferences = UserDefaults.standard
        let storedLanguage = preferences.object(forKey: "interfaceLanguage")
        preferences.removeObject(forKey: "interfaceLanguage")
        check(L10n.language == .english, "首次使用默认英语")
        if let storedLanguage { preferences.set(storedLanguage, forKey: "interfaceLanguage") }

        let settings = SettingsWindowController()
        settings.show()
        settings.selectPage(1)
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let fields = descendants(settings.windowForTesting!.contentView!).compactMap { $0 as? NSTextField }
        let field = fields.first { $0.identifier?.rawValue == "dwellTime" }!
        let buttons = descendants(settings.windowForTesting!.contentView!).compactMap { $0 as? NSButton }
            .filter { $0.identifier?.rawValue == "dwellTime" }
        let savedDwell = preferences.object(forKey: "dwellTime")
        field.stringValue = "0.25"
        settings.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: field))
        let plus = buttons.first { $0.tag == 1 }!
        NSApp.sendAction(plus.action!, to: plus.target, from: plus)
        check(abs(Preferences.dwellTime - 0.30) < 0.0001, "时长增加按钮按0.05秒调整")
        let minus = buttons.first { $0.tag == -1 }!
        field.stringValue = "0"
        settings.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: field))
        NSApp.sendAction(minus.action!, to: minus.target, from: minus)
        check(Preferences.dwellTime == 0, "减少按钮不会产生负时长")
        if let savedDwell { preferences.set(savedDwell, forKey: "dwellTime") }
        settings.windowForTesting?.close()

        let closing = (0..<2).map { index -> NSWindow in
            let window = NSWindow(contentRect: CGRect(x: 100 + index * 50, y: 100, width: 220, height: 160),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Disposable close test \(index)"
            window.isReleasedWhenClosed = false
            window.orderFrontRegardless()
            return window
        }
        let failed: Int = await withCheckedContinuation { continuation in
            WindowActions.closeAll(pid: ProcessInfo.processInfo.processIdentifier) { continuation.resume(returning: $0) }
        }
        try? await Task.sleep(for: .milliseconds(200))
        check(failed == 0 && closing.allSatisfy { !$0.isVisible }, "一次关闭请求实际关闭两个自建测试窗口")
        closing.forEach { $0.close() }
        return checks
    }
}
