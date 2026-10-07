import AppKit
import Foundation

/// User-tunable behaviour, persisted in `UserDefaults`.
///
/// Changes take effect immediately: the Dock monitor reads timings on every poll, and the panel
/// reads size, clarity, theme and title settings each time it is shown, so nothing needs a restart.
enum Preferences {

    enum SelectionTrigger: String, CaseIterable {
        case mouseDown, mouseUp
        var displayName: String { self == .mouseDown ? "按下鼠标时切换" : "松开鼠标时切换" }
    }
    static var selectionTrigger: SelectionTrigger {
        get { SelectionTrigger(rawValue: UserDefaults.standard.string(forKey: "selectionTrigger") ?? "") ?? .mouseUp }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "selectionTrigger") }
    }

    enum Key {
        // 功能
        static let previewEnabled = "previewEnabled"
        static let showMenuBarIcon = "showMenuBarIcon"
        static let showMenuBarQuickActions = "showMenuBarQuickActions"
        static let showMemoryUsage = "showMemoryUsage"
        static let switcherEnabled = "switcherEnabled"
        static let switcherShortcut = "switcherShortcut"
        static let clickDockToMinimize = "clickDockToMinimize"

        // 外观与动效
        static let dwellTime = "dwellTime"
        static let switchDelay = "switchDelay"
        static let transition = "transition"
        static let fadeInDuration = "fadeInDuration"
        static let fadeOutDuration = "fadeOutDuration"
        static let themeMode = "themeMode"
        static let panelSize = "panelSize"
        static let thumbnailClarity = "thumbnailClarity"
        static let titleSize = "titleSize"
        static let captionColorDark = "captionColorDark"
        static let captionColorLight = "captionColorLight"
        static let backdrop = "backdrop"
    }

    // MARK: - 悬停时序

    static let defaultDwellTime: Double = 0.25
    static let defaultSwitchDelay: Double = 0.05
    static let defaultFadeIn: Double = 0.11
    static let defaultFadeOut: Double = 0.09

    static let dwellRange: ClosedRange<Double> = 0.0...3.0
    static let switchRange: ClosedRange<Double> = 0.0...1.0
    static let fadeRange: ClosedRange<Double> = 0.0...1.0

    /// 鼠标停在图标上多久才弹出预览。
    static var dwellTime: Double { double(Key.dwellTime, default: defaultDwellTime, in: dwellRange) }
    /// 预览已弹出时，移到另一个图标多快切换。
    static var switchDelay: Double { double(Key.switchDelay, default: defaultSwitchDelay, in: switchRange) }
    static var fadeInDuration: Double { double(Key.fadeInDuration, default: defaultFadeIn, in: fadeRange) }
    static var fadeOutDuration: Double { double(Key.fadeOutDuration, default: defaultFadeOut, in: fadeRange) }

    // MARK: - 功能开关

    static var previewEnabled: Bool {
        get { bool(Key.previewEnabled, default: true) }
        set { UserDefaults.standard.set(newValue, forKey: Key.previewEnabled) }
    }

    /// 菜单栏图标是否显示。与「悬停预览是否启用」完全独立：隐藏图标不会停止预览。
    static var showMenuBarIcon: Bool {
        get { bool(Key.showMenuBarIcon, default: true) }
        set { UserDefaults.standard.set(newValue, forKey: Key.showMenuBarIcon) }
    }

    /// 菜单栏中的快捷操作是否显示。
    ///
    /// 「快捷操作」指菜单里可直接执行的动作项（启用悬停预览 / 设置 / 登录时启动 /
    /// 检查权限 / 关于 / 退出）。它与「菜单栏图标是否显示」是两个独立开关。
    static var showMenuBarQuickActions: Bool {
        get { bool(Key.showMenuBarQuickActions, default: true) }
        set { UserDefaults.standard.set(newValue, forKey: Key.showMenuBarQuickActions) }
    }

    /// 菜单栏是否显示内存占用读数。与「显示菜单栏快捷操作」无依赖关系，可单独开关。
    static var showMemoryUsage: Bool {
        get { bool(Key.showMemoryUsage, default: true) }
        set { UserDefaults.standard.set(newValue, forKey: Key.showMemoryUsage) }
    }

    /// 实验性：再次点击 Dock 图标时最小化当前活动窗口。
    static var clickDockToMinimize: Bool {
        get { bool(Key.clickDockToMinimize, default: false) }
        set { UserDefaults.standard.set(newValue, forKey: Key.clickDockToMinimize) }
    }

    // MARK: - 窗口切换快捷键

    /// 修饰键组合。默认 ⌥ + Tab（候选值，尚待确认）。
    struct Shortcut: Equatable {
        var option: Bool
        var shift: Bool
        var control: Bool
        var command: Bool
        var keyCode: UInt16

        static let `default` = Shortcut(option: true, shift: false, control: false, command: false, keyCode: 48)

        /// 人类可读描述，例如「⌥⇥」。
        var displayName: String {
            var text = ""
            if control { text += "⌃" }
            if option { text += "⌥" }
            if shift { text += "⇧" }
            if command { text += "⌘" }
            text += Self.keyName(for: keyCode)
            return text
        }

        var modifierFlags: NSEvent.ModifierFlags {
            var flags: NSEvent.ModifierFlags = []
            if option { flags.insert(.option) }
            if shift { flags.insert(.shift) }
            if control { flags.insert(.control) }
            if command { flags.insert(.command) }
            return flags
        }

        static func keyName(for keyCode: UInt16) -> String {
            switch keyCode {
            case 48: return "⇥"
            case 49: return "Space"
            case 50: return "`"
            default: return "键\(keyCode)"
            }
        }

        var dictionary: [String: Any] {
            ["option": option, "shift": shift, "control": control, "command": command, "keyCode": Int(keyCode)]
        }

        init(option: Bool, shift: Bool, control: Bool, command: Bool, keyCode: UInt16) {
            self.option = option
            self.shift = shift
            self.control = control
            self.command = command
            self.keyCode = keyCode
        }

        init?(dictionary: [String: Any]) {
            guard let keyCode = dictionary["keyCode"] as? Int, (0...127).contains(keyCode) else { return nil }
            self.init(
                option: dictionary["option"] as? Bool ?? false,
                shift: dictionary["shift"] as? Bool ?? false,
                control: dictionary["control"] as? Bool ?? false,
                command: dictionary["command"] as? Bool ?? false,
                keyCode: UInt16(keyCode)
            )
        }
    }

    static var switcherEnabled: Bool {
        get { bool(Key.switcherEnabled, default: false) }
        set { UserDefaults.standard.set(newValue, forKey: Key.switcherEnabled) }
    }

    static var switcherShortcut: Shortcut {
        get {
            guard let stored = UserDefaults.standard.dictionary(forKey: Key.switcherShortcut),
                  let shortcut = Shortcut(dictionary: stored) else { return .default }
            return shortcut
        }
        set { UserDefaults.standard.set(newValue.dictionary, forKey: Key.switcherShortcut) }
    }

    // MARK: - 过渡动画

    enum Transition: String, CaseIterable {
        case none, fade, pop

        var displayName: String {
            switch self {
            case .none: return "关闭动画"
            case .fade: return "淡入淡出"
            case .pop: return "弹出动画"
            }
        }
    }

    static var transition: Transition {
        get { Transition(rawValue: UserDefaults.standard.string(forKey: Key.transition) ?? "") ?? .fade }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Key.transition) }
    }

    // MARK: - 面板尺寸

    enum PanelSize: String, CaseIterable {
        case tiny, small, medium, large, off

        var displayName: String {
            switch self {
            case .tiny: return "更小"
            case .small: return "小"
            case .medium: return "中"
            case .large: return "大"
            case .off: return "关闭"
            }
        }

        /// 缩略图最大显示尺寸。`off` 表示不显示缩略图（仍可保留窗口标题列表）。
        ///
        /// 原有的 small / medium / large 保持原值不变；tiny 为新增档位。
        var maxTileSize: CGSize? {
            switch self {
            case .tiny: return CGSize(width: 240, height: 180)
            case .small: return CGSize(width: 300, height: 230)
            case .medium: return CGSize(width: 400, height: 300)
            case .large: return CGSize(width: 520, height: 390)
            case .off: return nil
            }
        }

        /// 采集像素尺寸：略大于显示尺寸，避免看起来发虚。
        var captureSize: CGSize? {
            maxTileSize.map { CGSize(width: $0.width * 1.15, height: $0.height * 1.15) }
        }

        var showsThumbnails: Bool { maxTileSize != nil }
    }

    static var panelSize: PanelSize {
        get { PanelSize(rawValue: UserDefaults.standard.string(forKey: Key.panelSize) ?? "") ?? .medium }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Key.panelSize) }
    }

    // MARK: - 缩略图清晰度

    /// 决定采集分辨率与缓存像素上限，必须实际影响图像处理，而不只是改标签。
    enum ThumbnailClarity: String, CaseIterable {
        case original, standard, smooth

        var displayName: String {
            switch self {
            case .original: return "原图"
            case .standard: return "标准"
            case .smooth: return "流畅"
            }
        }

        /// 相对采集尺寸的缩放系数。
        ///
        /// - `original`：1.0，按窗口实际像素与 Retina 比例采集，不做额外缩小。
        /// - `standard`：0.75，画质与资源占用的折中。
        /// - `smooth`：0.5，明显降低解码、缓存载入与内存成本。
        var captureScale: CGFloat {
            switch self {
            case .original: return 1.0
            case .standard: return 0.75
            case .smooth: return 0.5
            }
        }

        /// 缓存像素上限：超过该像素数的位图不再保留，以控制内存。
        var cachePixelLimit: Int {
            switch self {
            case .original: return 1_600_000
            case .standard: return 700_000
            case .smooth: return 320_000
            }
        }
    }

    static var thumbnailClarity: ThumbnailClarity {
        get { ThumbnailClarity(rawValue: UserDefaults.standard.string(forKey: Key.thumbnailClarity) ?? "") ?? .standard }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Key.thumbnailClarity) }
    }

    // MARK: - 窗口标题字号

    enum TitleSize: String, CaseIterable {
        case small, medium, large, off

        var displayName: String {
            switch self {
            case .small: return "小"
            case .medium: return "中"
            case .large: return "大"
            case .off: return "关闭"
            }
        }

        /// 标题字号；`nil` 表示不显示标题。
        var fontSize: CGFloat? {
            switch self {
            case .small: return 9.5
            case .medium: return 11
            case .large: return 13
            case .off: return nil
            }
        }

        /// 标题条高度；不显示标题时为 0。
        var captionHeight: CGFloat {
            guard let fontSize else { return 0 }
            return (fontSize + 6).rounded()
        }

        var showsTitle: Bool { fontSize != nil }
    }

    static var titleSize: TitleSize {
        get { TitleSize(rawValue: UserDefaults.standard.string(forKey: Key.titleSize) ?? "") ?? .medium }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Key.titleSize) }
    }

    // MARK: - 预览面板背景

    /// Which material the preview panel is drawn with.
    ///
    /// Two options because the newer one is not universally better in practice: the Liquid Glass
    /// material renders through a path the app cannot inspect, and on some systems it comes out
    /// invisible. Falling back is the user's call rather than a guess baked into the code.
    enum Backdrop: String, CaseIterable {
        case glass, frosted

        var displayName: String {
            switch self {
            case .glass: return "液态玻璃"
            case .frosted: return "磨砂玻璃"
            }
        }

        /// Short note shown next to the picker.
        var note: String {
            switch self {
            case .glass: return "macOS 26 的新材质；若预览面板显示异常可切换到磨砂"
            case .frosted: return "沿用系统毛玻璃，兼容性更好"
            }
        }
    }

    static var backdrop: Backdrop {
        get { Backdrop(rawValue: UserDefaults.standard.string(forKey: Key.backdrop) ?? "") ?? .glass }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Key.backdrop) }
    }

    // MARK: - 主题

    enum ThemeMode: String, CaseIterable {
        case system, dark, light

        var displayName: String {
            switch self {
            case .system: return "跟随系统"
            case .dark: return "始终深色"
            case .light: return "始终浅色"
            }
        }

        var appearance: NSAppearance? {
            switch self {
            case .system: return nil
            case .dark: return NSAppearance(named: .darkAqua)
            case .light: return NSAppearance(named: .aqua)
            }
        }
    }

    static var themeMode: ThemeMode {
        get { ThemeMode(rawValue: UserDefaults.standard.string(forKey: Key.themeMode) ?? "") ?? .system }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Key.themeMode) }
    }

    // MARK: - 标题文字颜色（内部值，当前未暴露为用户设置）

    static let defaultCaptionColorDark = "#FFFFFF"
    static let defaultCaptionColorLight = "#1C1C1E"

    static var captionColorDark: String {
        get { UserDefaults.standard.string(forKey: Key.captionColorDark) ?? defaultCaptionColorDark }
        set { UserDefaults.standard.set(newValue, forKey: Key.captionColorDark) }
    }

    static var captionColorLight: String {
        get { UserDefaults.standard.string(forKey: Key.captionColorLight) ?? defaultCaptionColorLight }
        set { UserDefaults.standard.set(newValue, forKey: Key.captionColorLight) }
    }

    static func captionColor(for appearance: NSAppearance?) -> NSColor {
        let isDark = appearance?.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let hex = isDark ? captionColorDark : captionColorLight
        return NSColor(hexString: hex) ?? (isDark ? .white : .black)
    }

    // MARK: - 权限提示文案（开发期确定，应用内不提供编辑入口）

    /// 权限弹窗文案。由开发者在发布前确定。
    ///
    /// 待用户提供最终文字，见交付说明。
    enum PermissionNoticeText {
        static let title = "DockPeek 需要两项系统权限"
        static let body = """
        1. 屏幕录制 —— 用于截取窗口画面生成缩略图。
        2. 设备控制和数据访问 —— 用于读取程序坞图标位置、枚举并切换其他应用的窗口。

        在「系统设置 → 隐私与安全性」里分别勾选 DockPeek。授权后请退出并重新打开 DockPeek。
        """
    }

    // MARK: - Helpers

    private static func bool(_ key: String, default fallback: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? fallback
    }

    private static func double(_ key: String, default fallback: Double, in range: ClosedRange<Double>) -> Double {
        guard UserDefaults.standard.object(forKey: key) != nil else { return fallback }
        let value = UserDefaults.standard.double(forKey: key)
        return value.isFinite ? min(max(value, range.lowerBound), range.upperBound) : fallback
    }

    /// Clamps and stores a value, returning what was actually saved so the UI can echo it back.
    @discardableResult
    static func set(_ key: String, to value: Double, in range: ClosedRange<Double>) -> Double {
        let clamped = value.isFinite ? min(max(value, range.lowerBound), range.upperBound) : range.lowerBound
        UserDefaults.standard.set(clamped, forKey: key)
        return clamped
    }

    static func resetToDefaults() {
        [
            Key.previewEnabled, Key.showMenuBarIcon, Key.showMenuBarQuickActions, Key.showMemoryUsage,
            Key.switcherEnabled, Key.switcherShortcut, Key.clickDockToMinimize,
            Key.dwellTime, Key.switchDelay, Key.transition, Key.fadeInDuration, Key.fadeOutDuration,
            Key.themeMode, Key.panelSize, Key.thumbnailClarity, Key.titleSize,
            Key.captionColorDark, Key.captionColorLight, Key.backdrop
        ].forEach { UserDefaults.standard.removeObject(forKey: $0) }
    }
}

// MARK: - Hex colours

extension NSColor {

    /// Parses `#RRGGBB` / `RRGGBB` / `#RGB`. Returns `nil` for anything else so callers can fall
    /// back instead of silently painting black.
    convenience init?(hexString: String) {
        var text = hexString.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if text.hasPrefix("#") { text.removeFirst() }

        if text.count == 3 {
            text = text.map { "\($0)\($0)" }.joined()
        }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }

        self.init(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }

    var hexString: String {
        guard let rgb = usingColorSpace(.sRGB) else { return "#000000" }
        return String(
            format: "#%02X%02X%02X",
            Int((rgb.redComponent * 255).rounded()),
            Int((rgb.greenComponent * 255).rounded()),
            Int((rgb.blueComponent * 255).rounded())
        )
    }
}
