import AppKit

/// App language is independent of the macOS language. Window titles always belong to their apps.
enum L10n {
    enum Language: String { case chinese = "zh-Hans", english = "en" }
    static var language: Language {
        get { Language(rawValue: UserDefaults.standard.string(forKey: "interfaceLanguage") ?? "") ?? .english }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "interfaceLanguage") }
    }
    static func text(_ source: String) -> String {
        guard language == .english else { return source }
        if let value = english[source] { return value }
        if source.contains("\n") { return source.components(separatedBy: "\n").map(text).joined(separator: "\n") }
        if source.hasPrefix("·  ") { return "·  " + text(String(source.dropFirst(3))) }
        if source.hasPrefix("版本 ") {
            return source.replacingOccurrences(of: "版本 ", with: "Version ")
                .replacingOccurrences(of: "未打包（脚本/调试运行）", with: "unbundled debug build")
                .replacingOccurrences(of: "（大型更新）", with: " — Major update")
                .replacingOccurrences(of: "（稳定性与原生界面更新）", with: " — Stability & native design")
                .replacingOccurrences(of: "（窗口交互与设置优化）", with: " — Window interaction & settings")
                .replacingOccurrences(of: "（构建于 ", with: " (built ").replacingOccurrences(of: "）", with: ")")
        }
        if source.hasPrefix("内存占用：") { return source.replacingOccurrences(of: "内存占用：", with: "Memory: ") }
        return source
    }
    @MainActor static func localize(_ view: NSView) {
        if let popup = view as? NSPopUpButton { popup.itemArray.forEach { $0.title = text($0.title) } }
        else if let button = view as? NSButton { button.title = text(button.title) }
        else if let field = view as? NSTextField, !field.isEditable { field.stringValue = text(field.stringValue) }
        if let label = view.accessibilityLabel() { view.setAccessibilityLabel(text(label)) }
        view.subviews.forEach(localize)
    }
    private static let english: [String: String] = [
        "版本更新记录": "Release notes",
        "时长输入框增加加减按钮，每次调整 0.05 秒；点击空白结束编辑": "Added duration adjustment controls in 0.05-second steps; clicking the background ends editing.",
        "更新记录改用原生文本视图，支持稳定的跨段落选择与复制": "Release notes now use a native text view for stable selection and copying across paragraphs.",
        "关于页新增 AI 鸣谢": "Added AI credits to About.",
        "邮件入口、邮箱地址与 GitHub 链接固定在滚动区外的底部": "Email, the email address, and GitHub links stay in a fixed footer outside the scroll area.",
        "新安装默认使用英语，保留已有语言选择": "New installations default to English; existing language choices are preserved.",
        "未打包（脚本/调试运行）": "unbundled debug build",
        "缩略图切换时机": "Activate a thumbnail on",
        "按下鼠标时切换": "Mouse down", "松开鼠标时切换": "Mouse release",
        "按下后移开，再松开即可取消切换": "Press, move away, and release to cancel.",
        "关闭此应用的所有窗口": "Close all windows of this app",
        "部分窗口未能关闭": "Some windows could not be closed",
        "应用可能需要处理未保存的内容；请查看应用中的提示。": "The app may need to handle unsaved changes. Check its dialogs.",
        "特别鸣谢": "Special thanks",
        "特别鸣谢 ChatGPT 和 DeepSeek。": "Special thanks to ChatGPT and DeepSeek.",
        "本程序的全部代码均由 AI 编写。": "All code in this app was written by AI.",
        "人类负责提供想法、参与测试，以及偶尔追问：“这次真的修好了吗？”": "Humans provided ideas, testing, and the occasional: “Does it work this time?”",
        "欢迎提出意见和反馈。": "Ideas and feedback are always welcome.",
        "发送邮件": "Send email",
        "减少时长": "Decrease duration", "增加时长": "Increase duration",
        "新增按下或松开鼠标切换窗口，默认松开；移开后松开可取消": "Added mouse-down or mouse-release activation; release is the default and allows cancellation.",
        "恢复设置标题，顶部切换栏改为适度圆角的长方形，增加内容边框": "Restored the Settings title, rectangular page navigation at the top, and a content border.",
        "设置顶部使用原生页面切换栏，启用/关闭项统一为系统开关": "Adopted native page navigation and system switches.",
        "更新记录按 0.3.0 至 0.4.0 顺序展示；调整界面文案，清理重复缓存逻辑": "Ordered release notes from 0.3.0 to 0.4.0 and simplified wording and cache logic.",
        "增加其他桌面窗口发现，访问其他桌面优先于最小化": "Added discovery of windows on other Spaces; visiting a window takes priority over minimizing it.",
        "窗口交互与设置优化": "Window interaction and settings improvements",
        "切换主题和材质时只重新采样当前桌面可见、未最小化的窗口": "Theme and material changes recapture only visible, unminimized windows on the current desktop.",
        "时长输入框增加加减按钮，点击空白结束编辑": "Added duration adjustment buttons and click-away editing.",
        "动画时长设置展开与收起时同步调整窗口高度": "Animated the layout and window height when fade controls appear or disappear.",
        "优化弹出动画收起，连续加速并在末端同步隐藏整个面板": "Refined Pop dismissal with continuous acceleration and synchronized panel hiding.",
        "关于内容可选择复制，新增鸣谢与邮件反馈，默认语言改为英语": "Made About text selectable, added credits and email feedback, and changed the default language to English.",
        "关闭所有窗口会向目标应用一次提交全部关闭请求，并保留未保存提示": "Close All submits window-close requests together and preserves unsaved-change dialogs.",
        "预览尺寸选项：更小、小、中、大、关闭": "Preview sizes: Extra small, Small, Medium, Large, and Off.",
        "缩略图清晰度选项：原图、标准、流畅": "Image quality: Original, Standard, and Smooth.",
        "窗口标题字号选项：小、中、大、关闭": "Title sizes: Small, Medium, Large, and Off.",
        "语言 / Language": "Language", "功能": "Features", "外观与动效": "Appearance", "关于": "About", "设置": "Settings", "设置…": "Settings…",
        "基本": "General", "实验性": "Experimental", "启用悬停预览": "Enable hover previews",
        "登录时启动": "Launch at login", "显示菜单栏图标": "Show menu bar icon", "隐藏菜单栏图标": "Hide menu bar icon",
        "显示菜单栏快捷操作": "Show quick actions", "显示内存占用": "Show memory usage",
        "控制菜单里的启用预览、设置、登录时启动、检查权限、关于、退出等操作项": "Show additional actions in the menu bar menu.",
        "在菜单中显示内存占用读数；与上一项互不影响": "Show the app’s memory usage in the menu.",
        "启用窗口切换快捷键": "Enable window switching shortcut", "快捷键": "Shortcut",
        "窗口切换快捷键": "Window switching shortcut", "按下新的组合键…": "Press a shortcut…",
        "点击后按下新的组合键；按 Esc 取消": "Click and press a shortcut; Esc cancels.",
        "恢复默认": "Reset", "默认 ⌥Tab 切换窗口；加按 ⇧ 反向切换": "⌥Tab switches windows; add ⇧ to go backward.",
        "点击当前应用的 Dock 图标以最小化窗口": "Click active app’s Dock icon to minimize",
        "点击当前前台应用的 Dock 图标时最小化其活动窗口，行为类似 Windows 任务栏": "Minimize the focused window when its app is already active.",
        "悬停响应": "Hover response", "弹出延迟": "Show delay", "切换延迟": "Switch delay",
        "鼠标停在图标上多久弹出预览": "Time to hover before showing a preview.",
        "预览已弹出时，移到另一个图标后多快切换": "Time to switch an open preview to another app.",
        "过渡动画": "Transitions", "淡入时长": "Fade-in duration", "淡出时长": "Fade-out duration",
        "主题": "Theme", "外观模式": "Appearance", "背景材质": "Material",
        "窗口缩略图": "Window thumbnails", "预览尺寸": "Preview size", "缩略图清晰度": "Image quality",
        "关闭缩略图时不可用": "Requires images", "窗口标题": "Window titles", "窗口标题字号": "Title size",
        "只调整标题文字大小，不影响缩略图尺寸": "Changes title text only.", "恢复本页默认设置": "Reset appearance",
        "设置页面": "Settings pages", "关闭动画": "None", "淡入淡出": "Fade", "弹出动画": "Pop",
        "更小": "Extra small", "小": "Small", "中": "Medium", "大": "Large", "关闭": "Off",
        "原图": "Original", "标准": "Standard", "流畅": "Smooth", "液态玻璃": "Liquid Glass", "磨砂玻璃": "Frosted glass",
        "跟随系统": "System", "始终深色": "Dark", "始终浅色": "Light",
        "确认": "Reset", "取消": "Cancel", "好": "OK", "复制版本信息": "Copy version information",
        "恢复默认后将覆盖编辑内容 且不可撤销": "Your custom settings will be replaced by the defaults.",
        "要把快捷键恢复为默认状态吗？": "Reset the shortcut to its default?",
        "要把「外观与动效」恢复为默认设置吗？": "Reset appearance settings to their defaults?",
        "检查权限…": "Check permissions…", "关于 DockPeek": "About DockPeek", "退出 DockPeek": "Quit DockPeek",
        "DockPeek — 悬停程序坞预览窗口": "DockPeek — Hover over Dock icons to preview windows",
        "DockPeek 需要两项系统权限": "DockPeek needs two permissions",
        "两项权限都已授权": "Both permissions are granted",
        "如果悬停仍无反应，请退出并重新打开 DockPeek。": "If previews still do not appear, quit and reopen DockPeek.",
        "录屏与系统录音": "Screen & System Audio Recording", "屏幕录制": "Screen Recording",
        "设备控制和数据访问": "Device Control & Data Access", "辅助功能": "Accessibility",
        "1. 屏幕录制 —— 用于截取窗口画面生成缩略图。": "1. Screen Recording — captures window thumbnails.",
        "2. 设备控制和数据访问 —— 用于读取程序坞图标位置、枚举并切换其他应用的窗口。": "2. Device Control & Data Access — reads Dock icons and controls windows.",
        "在「系统设置 → 隐私与安全性」里分别勾选 DockPeek。授权后请退出并重新打开 DockPeek。": "Enable DockPeek in System Settings → Privacy & Security, then quit and reopen the app.",
        "登录时启动设置未生效": "Launch at login could not be enabled",
        "请在系统设置的登录项中允许 DockPeek，然后重试。": "Allow DockPeek in System Settings → Login Items, then try again.",
        "快捷键不可用": "Shortcut unavailable", "这个快捷键已被系统或其他应用占用，请选择另一个。": "This shortcut is in use. Please choose another.",
        "窗口操作需要权限": "Window control needs permission", "请先允许 DockPeek 读取和控制其他应用。": "Allow DockPeek to read and control other apps first.",
        "设置界面重组为三页：功能 / 外观与动效 / 关于": "Reorganized settings into Features, Appearance, and About.",
        "外观与动效页新增：预览尺寸五档（更小、小、中、大、关闭）、缩略图清晰度（原图、标准、流畅）、窗口标题字号四档": "Added preview sizes, image quality levels, and title sizes.",
        "过渡动画三选项：关闭动画 / 淡入淡出 / 弹出动画": "Added None, Fade, and Pop transitions.",
        "新增窗口切换快捷键设置项": "Added a window shortcut setting.",
        "新增实验性功能：再次点击 Dock 图标时最小化窗口": "Added an experimental Dock click setting.",
        "主题支持跟随系统 / 始终深色 / 始终浅色": "Added System, Dark, and Light appearance options.",
        "菜单栏新增「隐藏菜单栏图标」；三个开关互相独立：图标显示、菜单栏快捷操作、内存占用": "Added independent menu icon, quick action, and memory display settings.",
        "权限修正：第二项权限为「设备控制和数据访问」，此前误标为「辅助功能」": "Updated the permission label to Device Control & Data Access.",
        "权限弹窗统一为只有一个「好」按钮，不跳转、不请求授权": "Unified permission notices with a single OK button.",
        "删除菜单中的诊断信息项，删除用户文案编辑功能": "Removed diagnostics from the menu and removed user-editable app messages.",
        "修复缩略图四角异常：白色块状区域与三角形": "Addressed thumbnail corner artifacts.",
        "删除当前窗口右下角的对勾标记": "Removed the current-window checkmark.",
        "修复最小化后缩略图消失": "Addressed missing minimized-window thumbnails.",
        "改用 macOS 26 / 27 的新界面接口：按钮使用 NSBezelStyleGlass，预览面板使用 NSGlassEffectView": "Introduced newer macOS appearance APIs and NSGlassEffectView.",
        "修复「关闭动画」选项无效的问题": "Fixed the None transition option.",
        "缩略图缓存不再依赖鼠标悬停：新增后台预热，应用运行期间主动发现新窗口并提前采集": "Added background thumbnail warming for newly opened windows.",
        "修复预览位置与内容被裁切：面板尺寸不再超过屏幕可用区，网格不再大于面板": "Adjusted preview placement and size limits.",
        "修复 Dock 方向判定：改用屏幕完整区域判断，左侧程序坞不再被误判为顶部": "Adjusted Dock edge detection.",
        "快捷键行右侧新增「恢复默认」按钮": "Added a shortcut reset button.",
        "「外观与动效」页底部新增「恢复本页默认设置」": "Added an appearance reset button.",
        "关于页移除「恢复全部默认值」，保持干净": "Removed the global reset action from About.",
        "关于页新增版本更新记录（本页）": "Added release notes to About.",
        "构建日期改为只显示到日，不再显示时分": "Simplified the build date display.",
        "关于页的版本更新记录改为滚动区域：窗口高度不再随记录条数增长，版本号固定显示在滚动区上方": "Made release notes scroll while keeping the version visible.",
        "修复「恢复默认」按钮画不出来的问题。此前用的是 NSBezelStyleGlass，实测该档位不绘制背板，只显示文字；改用 NSBezelStylePush": "Corrected the reset button appearance.",
        "恢复默认的确认提示改为自建面板：去掉程序图标，只保留标题、内容与选项，按钮更名为「确认」与「取消」": "Redesigned the reset confirmation dialog.",
        "确认文案用词调整：把「组合」改为「状态」": "Refined reset confirmation wording.",
        "修正本页的版本更新记录：去掉未经证实的界面效果描述，版本号更正为 0.3.x": "Corrected release notes and version numbers.",
        "「功能」与「外观与动效」页的「恢复默认」按钮改为正常绘制，此前只显示文字、没有按钮外观": "Adjusted reset buttons in Features and Appearance.",
        "恢复默认前新增确认提示，避免误操作覆盖已编辑内容": "Added confirmation before resetting settings.",
        "新增「预览面板材质」设置：可在液态玻璃与磨砂玻璃之间切换": "Added Liquid Glass and frosted material options.",
        "修复预览被裁切：网格此前被放进系统管理的容器，尺寸会被系统改掉，导致面板按一种宽度布局、内容按另一种宽度排列": "Adjusted the preview container layout.",
        "修复预览裁切、大片空白和低清晰度图片显示过小；窗口较多时支持滚动": "Fixed clipping, blank space, and undersized low-resolution images; added scrolling for large window lists.",
        "修复切换到无窗口应用时仍显示上一个应用预览的问题": "Fixed the previous app’s preview remaining visible when hovering an app with no windows.",
        "接入 macOS 26 原生液态玻璃及 macOS 27 交互效果，材质切换立即生效": "Integrated native Liquid Glass and macOS 27 interactions; material changes apply immediately.",
        "修正构建兼容信息，启用 macOS 27 原生控件样式，同时保留旧系统兼容路径": "Corrected SDK metadata to adopt macOS 27 controls while retaining compatibility with older systems.",
        "设置顶部改用原生工具栏导航，启用/关闭项统一为系统开关": "Adopted native toolbar navigation and system switches.",
        "功能页新增登录时启动、菜单栏图标显示和中英文切换": "Added launch at login, menu icon control, and Chinese/English language switching.",
        "实现点击当前应用的 Dock 图标最小化活动窗口；实现可编辑的窗口切换快捷键": "Implemented Dock click minimization and customizable window switching shortcuts.",
        "窗口身份不再依赖标题，修复同名窗口混淆及最小化缓存丢失": "Separated window identities from titles; fixed same-title collisions and minimized thumbnail loss.",
        "缩略图刷新失败时保留上一次有效画面，后台预热会重试并限制并发": "Kept the last good frame after failed captures and bounded background retries.",
        "修复菜单开关不即时生效、材质选项不回显、异常设置可能崩溃的问题": "Fixed delayed menu updates, material selection display, and invalid preference crashes.",
        "更新记录按 0.3.0 至 0.4 顺序展示；调整界面文案，清理重复缓存逻辑": "Ordered release notes from 0.3.0 to 0.4, refined wording, and simplified caching."
    ]
}
