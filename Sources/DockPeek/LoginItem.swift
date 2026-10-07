import AppKit
import ServiceManagement

/// "Launch at login" via the modern SMAppService API. Requires the app to live in a real
/// `.app` bundle; running the bare binary simply reports `false`.
enum LoginItem {

    static var isEnabled: Bool {
        guard Bundle.main.bundleIdentifier != nil, Bundle.main.bundlePath.hasSuffix(".app") else {
            return false
        }
        return SMAppService.mainApp.status == .enabled
    }

    @MainActor
    static func setEnabled(_ enabled: Bool) {
        guard Bundle.main.bundlePath.hasSuffix(".app") else {
            Log.error("login item needs a bundled .app; run make-app.sh first")
            return
        }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            Log.info("login item set to \(enabled)")
        } catch {
            Log.error("login item update failed: \(error.localizedDescription)")
            let alert = NSAlert()
            alert.messageText = L10n.text("登录时启动设置未生效")
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: L10n.text("好"))
            alert.runModal()
        }
    }
}
