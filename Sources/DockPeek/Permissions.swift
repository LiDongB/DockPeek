import AppKit
import ApplicationServices
import Foundation

/// Permission handling.
///
/// ## What DockPeek actually needs
///
/// 1. **屏幕录制** — required. The window server refuses to hand over window pixels without it, so
///    this is the one permission the app cannot work around.
/// 2. **设备控制和数据访问** (`Privacy_DeviceAccess`) — this is the pane that governs one app
///    reading and controlling *other* applications' windows. Window enumeration through
///    `CGWindowListCopyWindowInfo` also needs it: without the grant that call returns only
///    DockPeek's own windows, which is why an app can look like it "has no windows".
///
/// An earlier version of this app labelled item 2 as "辅助功能" and sent the user to the
/// Accessibility pane. That was simply wrong: the Accessibility pane covers assistive control of
/// the machine, and on this OS it is not the grant that unlocks window enumeration.
enum Permissions {

    // MARK: - Screen recording

    static var hasScreenRecording: Bool {
        CGPreflightScreenCaptureAccess()
    }

    @discardableResult
    static func requestScreenRecording() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        return CGRequestScreenCaptureAccess()
    }

    // MARK: - Device control and data access

    /// Whether this process is trusted to inspect and control other applications.
    ///
    /// The grant lives in the same TCC service that governs assistive control, which is why the
    /// query is `AXIsProcessTrusted()` even though the pane the user must visit is
    /// 「设备控制和数据访问」.
    static var hasDeviceAccess: Bool {
        AXIsProcessTrusted()
    }

    @discardableResult
    static func requestDeviceAccess() -> Bool {
        if AXIsProcessTrusted() { return true }
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    // MARK: - Diagnostics

    static func logStatus() {
        Log.info("permissions: screenRecording=\(hasScreenRecording ? "granted" : "missing") deviceAccess=\(hasDeviceAccess ? "granted" : "missing")")
    }

    // MARK: - Guided setup

    struct MissingPermission {
        let pane: PrivacyPane
        let name: String
    }

    static var missingPermissions: [MissingPermission] {
        var missing: [MissingPermission] = []
        if !hasScreenRecording {
            missing.append(MissingPermission(pane: .screenRecording, name: PrivacyPane.screenRecording.displayName))
        }
        if !hasDeviceAccess {
            missing.append(MissingPermission(pane: .deviceAccess, name: PrivacyPane.deviceAccess.displayName))
        }
        return missing
    }

    /// Fires both system prompts, then — for anything macOS did not grant — shows an informational
    /// dialog.
    ///
    /// The dialog deliberately has a single "好" button: its job is to tell the user what is
    /// missing and nothing else. Navigation is offered separately from the menu bar
    /// (「打开权限设置…」), so the launch dialog never has to guess which pane the user wants.
    @MainActor
    static func requestAllAtLaunch() {
        if !hasScreenRecording { _ = requestScreenRecording() }
        if !hasDeviceAccess { _ = requestDeviceAccess() }

        // Give the system prompts a moment to appear before deciding what is still missing.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            let missing = missingPermissions
            guard !missing.isEmpty else {
                Log.info("both permissions granted at launch")
                return
            }
            presentNotice(for: missing)
        }
    }

    /// Informational only: one "好" button, no navigation.
    @MainActor
    static func presentNotice(for missing: [MissingPermission]) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = L10n.text(Preferences.PermissionNoticeText.title)
        alert.informativeText = L10n.text(Preferences.PermissionNoticeText.body)
        alert.addButton(withTitle: L10n.text("好"))
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
        Log.info("permission notice shown for \(missing.map(\.name).joined(separator: ", "))")
    }

    /// Menu-bar entry point.
    ///
    /// Uses exactly the same notice as the launch prompt: one "好" button that only dismisses.
    /// Navigation to System Settings is intentionally not offered by the dialog — the "好" button
    /// must never jump, request, or start an authorisation flow.
    @MainActor
    static func showPermissionMenuAction() {
        let missing = missingPermissions
        guard !missing.isEmpty else {
            let alert = NSAlert()
            alert.messageText = L10n.text("两项权限都已授权")
            alert.informativeText = L10n.text("如果悬停仍无反应，请退出并重新打开 DockPeek。")
            alert.addButton(withTitle: L10n.text("好"))
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            return
        }
        presentNotice(for: missing)
    }

    // MARK: - Opening the right System Settings pane

    enum PrivacyPane {
        /// 「屏幕录制」/「录屏与系统录音」 depending on OS version.
        case screenRecording
        /// 「设备控制和数据访问」 — the grant that unlocks window enumeration and control.
        case deviceAccess

        /// Name exactly as it appears in System Settings on this OS version.
        var displayName: String {
            switch self {
            case .screenRecording: return "录屏与系统录音"
            case .deviceAccess: return "设备控制和数据访问"
            }
        }

        /// Sidebar entries inside the Privacy & Security pane, best match first.
        var sidebarDescriptions: [String] {
            switch self {
            case .screenRecording:
                return ["录屏与系统录音", "屏幕录制", "Screen Recording"]
            case .deviceAccess:
                return ["设备控制和数据访问", "辅助功能", "Device Control", "Accessibility"]
            }
        }

        /// Top-level sidebar entries (used when the pane lives directly in the sidebar).
        var topLevelDescriptions: [String] {
            switch self {
            case .deviceAccess: return ["设备控制和数据访问", "辅助功能", "Accessibility"]
            case .screenRecording: return []
            }
        }
    }

    /// Opens System Settings directly on the pane that holds the requested permission.
    ///
    /// The `x-apple.systempreferences:` deep links are unreliable: on macOS 27 the old
    /// `?Privacy_Accessibility` anchor no longer resolves, and both links landed on the same page.
    /// So the URL is only used to reach Privacy & Security, and the actual entry is then clicked
    /// through the Accessibility API — which is verifiable (the Settings window title changes).
    static func openSettingsPane(for pane: PrivacyPane) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension")!)

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            if clickSettingsSidebarEntry(pane) {
                Log.info("navigated System Settings to \(pane)")
            } else {
                Log.error("could not navigate System Settings to \(pane); leaving it at Privacy & Security")
            }
        }
    }

    /// Finds and presses a System Settings sidebar button whose description matches.
    ///
    /// Two passes: first the top-level sidebar, then (after selecting Privacy & Security) the
    /// permission list inside it.
    private static func clickSettingsSidebarEntry(_ pane: PrivacyPane) -> Bool {
        guard hasDeviceAccess else {
            Log.info("device access not granted; cannot navigate Settings automatically")
            return false
        }
        guard let settings = NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.systempreferences").first
        else { return false }

        let root = AXUIElementCreateApplication(settings.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 2.0)

        // Pass 1 — the entry may be a top-level sidebar row.
        for description in pane.topLevelDescriptions {
            if let button = findButton(root, descriptions: [description]), press(button) { return true }
        }

        // Pass 2 — select Privacy & Security, then look again inside it.
        if let privacy = findButton(root, descriptions: ["隐私与安全", "Privacy & Security"]) {
            _ = press(privacy)
            Thread.sleep(forTimeInterval: 1.2)
        }
        for description in pane.sidebarDescriptions {
            if let button = findButton(root, descriptions: [description]), press(button) { return true }
        }
        return false
    }

    private static func press(_ element: AXUIElement) -> Bool {
        AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
    }

    /// Depth-first search for a button whose `AXDescription` starts with one of the candidates,
    /// ignoring the trailing count badge the Settings sidebar appends ("录屏与系统录音、6").
    private static func findButton(
        _ element: AXUIElement,
        descriptions: [String],
        depth: Int = 0
    ) -> AXUIElement? {
        guard depth < 14 else { return nil }

        var roleValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue) == .success,
           (roleValue as? String) == "AXButton" {
            var descriptionValue: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXDescriptionAttribute as CFString, &descriptionValue) == .success,
               let description = descriptionValue as? String {
                for wanted in descriptions where description.hasPrefix(wanted) {
                    return element
                }
            }
        }

        var childrenValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenValue) == .success,
              let children = childrenValue as? [AXUIElement] else { return nil }

        for child in children {
            if let hit = findButton(child, descriptions: descriptions, depth: depth + 1) { return hit }
        }
        return nil
    }
}
