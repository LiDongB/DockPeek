import AppKit
import ApplicationServices
import Carbon

/// Owns global input only while the corresponding feature is enabled.
@MainActor
final class WindowInteractionController {
    var dockItemAtPoint: ((CGPoint) -> DockItem?)?
    var onMinimize: (() -> Void)?
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var swallowingMouseUp = false
    private var hotKeys: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    private var configuredShortcut: Preferences.Shortcut?
    private var cycle: [WindowTarget] = []
    private var selectedIdentity: String?
    private var lastSwitch = Date.distantPast

    func configure() -> Bool {
        let needsTap = Preferences.previewEnabled || Preferences.clickDockToMinimize || Preferences.switcherEnabled
        if !needsTap { removeTap() }
        else if tap == nil, Permissions.hasDeviceAccess { installTap() }
        if !Preferences.switcherEnabled {
            unregisterShortcut()
            return true
        }
        let shortcut = Preferences.switcherShortcut
        if configuredShortcut == shortcut { return true }
        unregisterShortcut()
        guard shortcut.option || shortcut.control || shortcut.command else { return false }
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let result = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                    nil, MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr else { return OSStatus(eventNotHandledErr) }
            MainActor.assumeIsolated {
                Unmanaged<WindowInteractionController>.fromOpaque(context).takeUnretainedValue().switchWindow(backward: id.id == 2)
            }
            return noErr
        }, 1, &event, pointer, &handler)
        guard result == noErr else { unregisterShortcut(); return false }
        let modifiers = Self.carbonModifiers(shortcut)
        for (id, flags) in [(UInt32(1), modifiers), (UInt32(2), modifiers ^ UInt32(shiftKey))] {
            var ref: EventHotKeyRef?
            let result = RegisterEventHotKey(UInt32(shortcut.keyCode), flags,
                                            EventHotKeyID(signature: 0x44504B34, id: id), GetApplicationEventTarget(), 0, &ref)
            guard result == noErr, let ref else { unregisterShortcut(); return false }
            hotKeys.append(ref)
        }
        configuredShortcut = shortcut
        return true
    }

    private static func carbonModifiers(_ shortcut: Preferences.Shortcut) -> UInt32 {
        var flags: UInt32 = 0
        if shortcut.option { flags |= UInt32(optionKey) }
        if shortcut.shift { flags |= UInt32(shiftKey) }
        if shortcut.command { flags |= UInt32(cmdKey) }
        if shortcut.control { flags |= UInt32(controlKey) }
        return flags
    }

    private func installTap() {
        let mask = (CGEventMask(1) << CGEventType.leftMouseDown.rawValue)
            | (CGEventMask(1) << CGEventType.leftMouseUp.rawValue)
            | (CGEventMask(1) << CGEventType.flagsChanged.rawValue)
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                         options: .defaultTap, eventsOfInterest: mask, callback: { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            return MainActor.assumeIsolated {
                let owner = Unmanaged<WindowInteractionController>.fromOpaque(context).takeUnretainedValue()
                return owner.handle(type: type, event: event) ? nil : Unmanaged.passUnretained(event)
            }
        }, userInfo: pointer) else { return }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        tapSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func handle(type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        }
        if type == .flagsChanged {
            let flags = NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue))
            let required = Preferences.switcherShortcut.modifierFlags.subtracting(.shift)
            if !flags.isSuperset(of: required) { cycle.removeAll(); selectedIdentity = nil }
        }
        if type == .leftMouseUp, swallowingMouseUp { swallowingMouseUp = false; return true }
        guard type == .leftMouseDown, Preferences.previewEnabled || Preferences.clickDockToMinimize,
              event.getIntegerValueField(.mouseEventClickState) == 1,
              event.flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift]).isEmpty,
              let item = dockItemAtPoint?(event.location), item.frame.contains(event.location),
              let app = NSWorkspace.shared.runningApplications.first(where: { Self.matches(item, app: $0) })
        else { return false }
        let windows = WindowEnumerator.windows(pid: app.processIdentifier, ownerName: item.name)
        // Visit another Space before considering minimize. Never perform both actions on one click.
        if !windows.isEmpty, !windows.contains(where: { !$0.isMinimized && WindowActions.isOnCurrentDesktop($0) }),
           let remote = windows.first(where: { !$0.isMinimized }), WindowActions.activate(remote) {
            swallowingMouseUp = true
            onMinimize?()
            return true
        }
        guard Preferences.clickDockToMinimize,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else { return false }
        // This runs before Dock handles the click. Consuming the successful click prevents
        // Dock from immediately restoring the window we just minimized.
        guard WindowActions.minimizeFocusedWindow(pid: app.processIdentifier) else { return false }
        swallowingMouseUp = true
        WindowEnumerator.invalidateCache()
        onMinimize?()
        return true
    }

    static func matches(_ item: DockItem, app: NSRunningApplication) -> Bool {
        if let url = item.bundleURL { return app.bundleURL == url }
        if let id = item.bundleID { return app.bundleIdentifier == id }
        return app.localizedName == item.name
    }

    private func switchWindow(backward: Bool) {
        guard Preferences.switcherEnabled, Permissions.hasDeviceAccess else { return }
        let live = WindowEnumerator.allCapturableWindows()
        let liveIDs = Set(live.map(\.identity))
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let focused = live.first { $0.pid == frontPID && $0.isMain }
        if cycle.isEmpty || Date().timeIntervalSince(lastSwitch) > 2
            || (focused != nil && focused?.identity != selectedIdentity) {
            cycle = live.sorted {
                if $0.identity == focused?.identity { return true }
                if $1.identity == focused?.identity { return false }
                if $0.ownerName != $1.ownerName { return $0.ownerName.localizedStandardCompare($1.ownerName) == .orderedAscending }
                return $0.identity < $1.identity
            }
            selectedIdentity = focused?.identity
        } else { cycle.removeAll { !liveIDs.contains($0.identity) } }
        guard !cycle.isEmpty else { return }
        let current = cycle.firstIndex { $0.identity == selectedIdentity } ?? (backward ? 0 : -1)
        let index = (current + (backward ? -1 : 1) + cycle.count) % cycle.count
        let target = cycle[index]
        if WindowActions.activate(target) { selectedIdentity = target.identity; lastSwitch = Date() }
    }

    private func unregisterShortcut() {
        hotKeys.forEach { UnregisterEventHotKey($0) }
        hotKeys.removeAll()
        if let handler { RemoveEventHandler(handler) }
        handler = nil
        configuredShortcut = nil
        cycle.removeAll()
        selectedIdentity = nil
    }
    private func removeTap() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source = tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        tapSource = nil
        swallowingMouseUp = false
    }
    func stop() { unregisterShortcut(); removeTap() }
    var isMinimizeHookInstalled: Bool { tap != nil }
    var isShortcutRegistered: Bool { hotKeys.count == 2 }
}
