import Foundation

/// Version and build identity, so any copy of the app can be told apart from another.
///
/// The build script stamps `DockPeekBuildStamp` into `Info.plist` at bundle time. When running the
/// bare binary (self tests, benchmarks) that key is absent, so the value degrades gracefully.
enum Version {

    static var shortVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    /// Build stamp written by `Scripts/make-app.sh`, e.g. `2026-10-07 09:58`.
    static var buildStamp: String {
        Bundle.main.object(forInfoDictionaryKey: "DockPeekBuildStamp") as? String ?? "未打包（脚本/调试运行）"
    }

    /// Where this copy is running from — the quickest way to tell two installs apart.
    static var executablePath: String {
        Bundle.main.executablePath ?? CommandLine.arguments.first ?? "未知"
    }

    static var isBundled: Bool {
        Bundle.main.bundlePath.hasSuffix(".app")
    }

    /// One-line summary for the About panel and `--diagnose`.
    static var summary: String {
        "版本 \(shortVersion)（构建于 \(buildStamp)）"
    }

    /// Multi-line detail for the About panel.
    static var detail: String {
        """
        \(summary)
        包标识：\(Bundle.main.bundleIdentifier ?? "无")
        位置：\(isBundled ? Bundle.main.bundlePath : executablePath)
        """
    }
}
