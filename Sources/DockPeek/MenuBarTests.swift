import AppKit
import Foundation

/// Behavioural tests for the menu bar.
///
/// The three switches in 功能 → 基本 sound similar but must stay independent: whether the icon is
/// shown at all, whether the quick actions are listed, and whether the memory readout is listed.
/// Treating any two of them as the same switch is an easy mistake to make and an annoying one to
/// live with, so each combination is asserted here.
@MainActor
enum MenuBarTests {

    static func run() -> Int32 {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)

        var lines: [String] = ["DockPeek 菜单栏行为测试", ""]
        var failures = 0

        func check(_ ok: Bool, _ label: String, detail: String = "") {
            lines.append("\(ok ? "✅" : "❌") \(label)\(detail.isEmpty ? "" : " — \(detail)")")
            if !ok { failures += 1 }
        }

        // Save and restore the user's real settings.
        let saved = (
            icon: Preferences.showMenuBarIcon,
            quick: Preferences.showMenuBarQuickActions,
            memory: Preferences.showMemoryUsage
        )
        defer {
            Preferences.showMenuBarIcon = saved.icon
            Preferences.showMenuBarQuickActions = saved.quick
            Preferences.showMemoryUsage = saved.memory
        }

        let delegate = AppDelegate()
        delegate.applicationDidFinishLaunching(
            Notification(name: NSApplication.didFinishLaunchingNotification)
        )

        // ================================================================ 图标显示开关
        lines.append("【菜单栏图标】")

        Preferences.showMenuBarIcon = true
        delegate.reapplyMenuBarIcon()
        delegate.rebuildMenuBar()
        check(delegate.hasMenuBarIcon, "开启时菜单栏图标存在")

        let titlesWithQuickActions = delegate.currentMenuTitles
        check(titlesWithQuickActions.contains("设置…"), "菜单位于图标之下且可访问",
              detail: titlesWithQuickActions.joined(separator: " / "))

        Preferences.showMenuBarIcon = false
        delegate.reapplyMenuBarIcon()
        check(!delegate.hasMenuBarIcon, "关闭时菜单栏图标被移除")

        // Hiding the icon must not disturb the preview switch.
        let previewBefore = Preferences.previewEnabled
        Preferences.showMenuBarIcon = true
        delegate.reapplyMenuBarIcon()
        delegate.rebuildMenuBar()
        check(Preferences.previewEnabled == previewBefore,
              "隐藏/显示图标不影响悬停预览开关")

        // ================================================================ 快捷操作开关
        lines.append("")
        lines.append("【菜单栏快捷操作】")

        Preferences.showMenuBarIcon = true
        Preferences.showMenuBarQuickActions = true
        Preferences.showMemoryUsage = true
        delegate.rebuildMenuBar()
        let full = delegate.currentMenuTitles
        for expected in ["启用悬停预览", "设置…", "登录时启动", "隐藏菜单栏图标", "检查权限…", "关于 DockPeek", "退出 DockPeek"] {
            check(full.contains(expected), "快捷操作开启时包含「\(expected)」")
        }
        check(!full.contains("复制诊断信息"), "诊断信息项已从菜单移除")

        Preferences.showMenuBarQuickActions = false
        delegate.rebuildMenuBar()
        let minimal = delegate.currentMenuTitles
        check(!minimal.contains("启用悬停预览"), "快捷操作关闭时不列出「启用悬停预览」")
        check(!minimal.contains("关于 DockPeek"), "快捷操作关闭时不列出「关于 DockPeek」")
        check(minimal.contains("设置…"), "快捷操作关闭时仍保留进入设置的入口",
              detail: minimal.joined(separator: " / "))
        check(minimal.contains("退出 DockPeek"), "快捷操作关闭时仍可退出")

        // ================================================================ 内存占用开关（独立）
        lines.append("")
        lines.append("【内存占用显示】")

        Preferences.showMenuBarQuickActions = true
        Preferences.showMemoryUsage = true
        delegate.rebuildMenuBar()
        let base = delegate.currentMenuTitles
        check(base.contains("内存占用：—") || base.contains { $0.hasPrefix("内存占用：") },
              "开启时菜单中出现内存占用读数")

        Preferences.showMemoryUsage = false
        delegate.rebuildMenuBar()
        let noMemory = delegate.currentMenuTitles
        check(!noMemory.contains { $0.hasPrefix("内存占用：") }, "关闭时不再显示内存占用")
        check(noMemory.contains("启用悬停预览"),
              "关闭内存占用不影响快捷操作（两者独立）")

        // And the reverse: quick actions off while memory stays on.
        Preferences.showMenuBarQuickActions = false
        Preferences.showMemoryUsage = true
        delegate.rebuildMenuBar()
        let memoryOnly = delegate.currentMenuTitles
        check(memoryOnly.contains { $0.hasPrefix("内存占用：") },
              "快捷操作关闭时内存占用仍可单独显示（证明两者不联动）",
              detail: memoryOnly.joined(separator: " / "))

        // ================================================================ 权限名称
        lines.append("")
        lines.append("【权限名称】")

        let screenName = Permissions.PrivacyPane.screenRecording.displayName
        let deviceName = Permissions.PrivacyPane.deviceAccess.displayName
        check(deviceName == "设备控制和数据访问", "第二项权限名称为「设备控制和数据访问」",
              detail: deviceName)
        check(!deviceName.contains("辅助功能"), "不再把该权限称为「辅助功能」")
        check(screenName.contains("录屏") || screenName.contains("屏幕录制"),
              "第一项权限名称正确", detail: screenName)

        lines.append("")
        lines.append(failures == 0 ? "菜单栏行为测试全部通过。" : "有 \(failures) 项失败。")
        print(lines.joined(separator: "\n"))
        return failures == 0 ? 0 : 1
    }
}
