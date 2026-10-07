import AppKit

// MARK: - Layout constants

/// Every number the three pages lay themselves out with, in one place.
///
/// `pageWidth` is the width of one page's *content*.
private enum Metrics {
    /// Width of a page's content area.
    static let pageWidth: CGFloat = 460
    static let padding: CGFloat = 20
    static let labelWidth: CGFloat = 150
    static let fieldWidth: CGFloat = 72
    static let fieldHeight: CGFloat = 22
    static let popupWidth: CGFloat = 150
    static let popupHeight: CGFloat = 26
    static let recorderWidth: CGFloat = 150
    /// Width of a same-row accessory control (e.g. 快捷键 的恢复默认按钮).
    ///
    /// 110 is the largest that still fits beside the 150pt recorder row (170 + 150 + 8 + 110 = 438,
    /// inside the 444pt content edge). It also has to be wide enough for the glass bezel plus its
    /// padding: a cramped frame makes AppKit skip the bezel and draw only the title, which is what
    /// the button looked like before.
    static let accessoryWidth: CGFloat = 110
    static let accessoryGap: CGFloat = 8
    static let rowHeight: CGFloat = 30
    static let checkRowHeight: CGFloat = 24
    static let hintIndent: CGFloat = 18
    static let hintGap: CGFloat = 4
    static let headerHeight: CGFloat = 22
    static let sectionGap: CGFloat = 16
    static let buttonHeight: CGFloat = 28

    /// Width available to text inside a page.
    static let contentWidth: CGFloat = pageWidth - padding * 2
    /// Where a row's control starts (label column + gutter).
    static let controlX: CGFloat = padding + labelWidth
    /// Breathing room between the window edges and the tab strip / page content.
    ///
    /// Without it the tab bar sits flush under the title bar and against both window sides, which
    /// reads as the tabs colliding with the page background.
    static let windowInset: CGFloat = 16
}

/// Minimal modal target: records the choice and ends the modal session.
@MainActor
private final class ModalChoiceTarget: NSObject {
    private let onChoose: () -> Void
    init(_ onChoose: @escaping () -> Void) { self.onChoose = onChoose }
    @objc func choose(_ sender: Any?) { onChoose() }
}

/// Bezel style for every button in this window.
///
/// `.push`, not `.glass`. `NSBezelStyleGlass` was tried first on the assumption that it is the
/// macOS 26 appearance, but rendering the candidates side by side (`--test-buttons`) showed it draws
/// **no bezel at all** on this system: the control came out as plain text, which is exactly the
/// "it looks like clickable text, not a button" report. `.push` draws the standard bordered button
/// and is what the comparison image shows as correct.
private var buttonBezelStyle: NSButton.BezelStyle { .push }

/// Top-down container: `NSView` is bottom-left origin by default, which made a hand-written
/// top-down layout stack upwards and push the footer out of the window.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(nil) }
}

private final class SettingsBackgroundView: NSView {
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(nil) }
}

private final class ReleaseNotesTextView: NSTextView {
    override func writeSelection(to pasteboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        if super.writeSelection(to: pasteboard, type: type) { return true }
        guard type == .string || type.rawValue == "NSStringPboardType" else { return false }
        let source = string as NSString
        let ranges = selectedRanges.map(\.rangeValue).filter { $0.length > 0 && NSMaxRange($0) <= source.length }
        guard !ranges.isEmpty else { return false }
        return pasteboard.setString(ranges.map { source.substring(with: $0) }.joined(separator: "\n"), forType: type)
    }
}

// MARK: - Shortcut recorder

/// A button-like control that shows the current key combination and records a new one when clicked.
///
/// Recording uses a local event monitor, so it sees the very next key press no matter which view in
/// the window would otherwise handle it. A bare modifier press is ignored (that is a `.flagsChanged`
/// event, and modifier key codes are filtered out of `.keyDown`), and `Esc` cancels.
@MainActor
private final class ShortcutRecorderView: NSView {

    /// Shown while waiting for the next combination.
    static var recordingTitle: String { L10n.text("按下新的组合键…") }

    var shortcut: Preferences.Shortcut = .default {
        didSet {
            needsDisplay = true
            setAccessibilityValue(shortcut.displayName)
        }
    }

    /// Called with the newly recorded combination (never called for a cancel).
    var onCapture: ((Preferences.Shortcut) -> Void)?

    private(set) var isRecording = false
    private var monitor: Any?
    private var resignObserver: NSObjectProtocol?

    /// Modifier keys, which only ever produce `flagsChanged`; listed defensively so a stray key code
    /// can never be stored as a "combination".
    private static let modifierKeyCodes: Set<UInt16> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]
    private static let escapeKeyCode: UInt16 = 53

    /// The few facts the monitor needs, copied out of the `NSEvent` up front so the hop onto the
    /// main actor carries only plain values.
    private struct MonitoredEvent {
        let isKeyDown: Bool
        let isFlagsChanged: Bool
        let isMouseDown: Bool
        let keyCode: UInt16
        let flags: NSEvent.ModifierFlags
        let windowNumber: Int
        let location: NSPoint

        init(_ event: NSEvent) {
            isKeyDown = event.type == .keyDown
            isFlagsChanged = event.type == .flagsChanged
            isMouseDown = event.type == .leftMouseDown
            keyCode = event.keyCode
            flags = event.modifierFlags
            windowNumber = event.windowNumber
            location = event.locationInWindow
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityRole(.button)
        setAccessibilityLabel("窗口切换快捷键")
        setAccessibilityHelp("点击后按下新的组合键；按 Esc 取消")
        setAccessibilityValue(shortcut.displayName)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stopRecording() }
    }

    override func mouseDown(with event: NSEvent) {
        if isRecording { stopRecording() } else { startRecording() }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6)
        if isRecording {
            NSColor.controlAccentColor.withAlphaComponent(0.15).setFill()
        } else {
            NSColor.controlBackgroundColor.setFill()
        }
        outline.fill()
        (isRecording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        outline.lineWidth = isRecording ? 2 : 1
        outline.stroke()

        let text = isRecording ? Self.recordingTitle : shortcut.displayName
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: isRecording ? NSColor.controlAccentColor : NSColor.labelColor
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        let origin = NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2)
        (text as NSString).draw(at: origin, withAttributes: attributes)
    }

    // MARK: Recording

    private func startRecording() {
        guard !isRecording else { return }
        isRecording = true
        needsDisplay = true
        window?.makeFirstResponder(self)

        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged, .leftMouseDown]) { [weak self] event in
            guard let self else { return event }
            let monitored = MonitoredEvent(event)
            let swallow = MainActor.assumeIsolated { self.process(monitored) }
            return swallow ? nil : event
        }

        if let window {
            resignObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { _ = self?.stopRecording() }
            }
        }
    }

    private func stopRecording() {
        guard isRecording || monitor != nil || resignObserver != nil else { return }
        isRecording = false
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
            self.resignObserver = nil
        }
        needsDisplay = true
    }

    /// Returns `true` when the event must be swallowed, `false` when it should carry on.
    private func process(_ monitored: MonitoredEvent) -> Bool {
        guard isRecording else { return false }

        // An event belonging to another window means focus moved away: end recording.
        if let window, monitored.windowNumber != window.windowNumber {
            stopRecording()
            return false
        }

        if monitored.isFlagsChanged {
            // A modifier pressed on its own is not a combination; keep waiting.
            return true
        }

        if monitored.isMouseDown {
            let inside = window.map { _ in bounds.contains(convert(monitored.location, from: nil)) } ?? false
            stopRecording()
            return inside
        }

        guard monitored.isKeyDown else { return false }

        if monitored.keyCode == Self.escapeKeyCode {
            // Escape cancels: the stored combination is left exactly as it was.
            stopRecording()
            return true
        }
        guard !Self.modifierKeyCodes.contains(monitored.keyCode) else { return true }

        let flags = monitored.flags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.option) || flags.contains(.control) || flags.contains(.command) else {
            // Shift alone (or no modifier at all) is not a usable combination.
            NSSound.beep()
            return true
        }

        let combination = Preferences.Shortcut(
            option: flags.contains(.option),
            shift: flags.contains(.shift),
            control: flags.contains(.control),
            command: flags.contains(.command),
            keyCode: monitored.keyCode
        )
        shortcut = combination
        stopRecording()
        onCapture?(combination)
        return true
    }
}

// MARK: - Page builder

/// Lays one page out top-down and reports the height it needs.
///
/// The cursor only ever moves downwards, so a row can never be placed on top of the previous one,
/// and `requiredHeight` is exactly what the page occupies — the window is sized from the tallest.
@MainActor
private final class SettingsForm {

    /// Marks the checkboxes this form builds, so the layout report can print their state.
    static let checkboxIdentifier = NSUserInterfaceItemIdentifier("DockPeekCheckbox")

    let container: FlippedView

    private var cursor: CGFloat = Metrics.padding
    private var hasSection = false

    /// Set when `beginScroll` has been called: everything added from then on goes into this inner
    /// view instead of the page, and is scrolled inside `scrollView`.
    private var scrollView: NSScrollView?
    private var innerContainer: FlippedView?
    /// Cursor measured inside the inner container.
    private var innerCursor: CGFloat = 0
    private var isWritingInScroll = false
    private var scrollingText: NSTextView?
    /// Height the scroll region occupies on the page.
    private var scrollHeight: CGFloat = 0
    /// Cursor value where the scroll region starts.
    private var scrollOrigin: CGFloat = 0

    init() {
        container = FlippedView(frame: NSRect(x: 0, y: 0, width: Metrics.pageWidth, height: Metrics.padding * 2))
    }

    /// Height this page needs, including the trailing padding.
    ///
    /// With a scroll region the page is `scrollOrigin + scrollHeight`, not the full content height:
    /// the whole point of scrolling is that the page does not grow with the content inside it.
    var requiredHeight: CGFloat {
        guard let scrollView else { return cursor + Metrics.padding }
        if let text = scrollingText, let layout = text.layoutManager, let textContainer = text.textContainer {
            layout.ensureLayout(for: textContainer)
            text.frame.size.height = max(scrollHeight, ceil(layout.usedRect(for: textContainer).height + text.textContainerInset.height * 2))
        } else {
            innerContainer?.frame.size.height = innerCursor + Metrics.padding
            scrollView.documentView?.frame.size.height = innerCursor + Metrics.padding
        }
        return cursor + Metrics.padding
    }

    /// Freezes the built height (the tab view resizes the view to the window afterwards).
    func seal() {
        _ = requiredHeight
        container.frame.size.height = requiredHeight
        scrollView?.frame.size.height = scrollHeight
    }

    /// Ends the fixed part of the page and puts everything after it in a scrolling region.
    ///
    /// `height` is how much vertical space the region occupies on the page; the content inside can be
    /// any size and scrolls. Used by 关于 so a long changelog does not make the window taller.
    func beginScroll(height: CGFloat) {
        let width = Metrics.pageWidth
        scrollOrigin = cursor
        scrollHeight = height

        let scroll = NSScrollView(frame: NSRect(x: 0, y: activeCursor, width: width, height: height))
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.autoresizingMask = [.width]
        // Start at the top: with a flipped document view, `scroll(to:)` uses the same coordinates.
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)

        let inner = FlippedView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        scroll.documentView = inner
        container.addSubview(scroll)

        scrollView = scroll
        innerContainer = inner
        innerCursor = 0
        isWritingInScroll = true
        // The scroll region itself occupies a fixed slot on the page.
        cursor += height
        hasSection = false
    }

    /// The view new content is currently added to. Named to avoid colliding with the `target:`
    /// parameter that button factories take.
    func endScroll() {
        innerContainer?.frame.size.height = innerCursor + Metrics.padding
        isWritingInScroll = false
        hasSection = false
    }

    /// One native text document supports selection across headings and paragraphs without field editors.
    func makeScrollTextSelectable() {
        guard let scrollView, let innerContainer else { return }
        let content = NSMutableAttributedString(string: "")
        for field in innerContainer.subviews.compactMap({ $0 as? NSTextField }) {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 2
            paragraph.paragraphSpacing = 10
            content.append(NSAttributedString(string: field.stringValue + "\n", attributes: [
                .font: field.font ?? NSFont.systemFont(ofSize: 12),
                .foregroundColor: field.textColor ?? NSColor.labelColor,
                .paragraphStyle: paragraph
            ]))
        }
        let text = ReleaseNotesTextView(frame: NSRect(x: 0, y: 0, width: Metrics.pageWidth, height: scrollHeight))
        text.isEditable = false
        text.isSelectable = true
        text.isRichText = true
        text.drawsBackground = false
        text.isHorizontallyResizable = false
        text.isVerticallyResizable = true
        text.autoresizingMask = [.width]
        text.minSize = NSSize(width: 0, height: scrollHeight)
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.textContainerInset = NSSize(width: Metrics.padding, height: 4)
        text.textContainer?.widthTracksTextView = true
        text.textContainer?.containerSize = NSSize(width: Metrics.pageWidth - Metrics.padding * 2, height: CGFloat.greatestFiniteMagnitude)
        text.textStorage?.setAttributedString(content)
        text.setAccessibilityLabel(L10n.text("版本更新记录"))
        scrollView.documentView = text
        scrollingText = text
        _ = requiredHeight
        scrollView.contentView.scroll(to: .zero)
    }

    private var writeTarget: NSView { isWritingInScroll ? (innerContainer ?? container) : container }

    /// Moves the cursor in whichever region is active.
    private func advance(_ delta: CGFloat) {
        if isWritingInScroll { innerCursor += delta } else { cursor += delta }
    }

    /// Current vertical position in the active target.
    private var activeCursor: CGFloat { isWritingInScroll ? innerCursor : cursor }

    // MARK: Rows

    func addHeader(_ title: String) {
        beginSection()
        let label = headerLabel(title)
        label.frame = NSRect(x: Metrics.padding, y: activeCursor + 4, width: Metrics.contentWidth, height: 16)
        writeTarget.addSubview(label)
        advance(Metrics.headerHeight)
    }

    /// A section header that carries its control on the same line.
    @discardableResult
    func addHeaderRow<T: NSView>(_ title: String, controlSize: CGSize, make: () -> T) -> T {
        beginSection()
        let label = headerLabel(title)
        label.frame = NSRect(x: Metrics.padding, y: activeCursor + 7, width: Metrics.labelWidth, height: 16)
        writeTarget.addSubview(label)

        let control = make()
        control.frame = NSRect(
            x: Metrics.controlX,
            y: activeCursor + (Metrics.rowHeight - controlSize.height) / 2,
            width: controlSize.width,
            height: controlSize.height
        )
        writeTarget.addSubview(control)
        advance(Metrics.rowHeight)
        return control
    }

    @discardableResult
    func addSwitch(_ title: String, target: AnyObject?, action: Selector?) -> NSSwitch {
        let label = NSTextField(labelWithString: L10n.text(title))
        label.font = .systemFont(ofSize: 12)
        label.frame = NSRect(x: Metrics.padding, y: activeCursor + 5, width: Metrics.contentWidth - 60, height: 20)
        let control = NSSwitch(frame: NSRect(x: Metrics.pageWidth - Metrics.padding - 38, y: activeCursor, width: 38, height: 28))
        control.target = target
        control.action = action
        control.identifier = NSUserInterfaceItemIdentifier(title)
        control.setAccessibilityLabel(L10n.text(title))
        writeTarget.addSubview(label)
        writeTarget.addSubview(control)
        advance(32)
        return control
    }

    @discardableResult
    func addRow<T: NSView>(
        _ title: String,
        indented: Bool = false,
        controlSize: CGSize,
        accessory: (() -> NSView)? = nil,
        accessoryWidth: CGFloat = Metrics.accessoryWidth,
        make: () -> T
    ) -> (label: NSTextField, control: T, accessory: NSView?) {
        let labelX = indented ? Metrics.padding + Metrics.hintIndent : Metrics.padding
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12)
        label.lineBreakMode = .byTruncatingTail
        label.frame = NSRect(
            x: labelX,
            y: activeCursor + 5,
            width: Metrics.labelWidth - (labelX - Metrics.padding),
            height: 17
        )
        writeTarget.addSubview(label)

        let control = make()
        control.frame = NSRect(
            x: Metrics.controlX,
            y: activeCursor + (Metrics.rowHeight - controlSize.height) / 2,
            width: controlSize.width,
            height: controlSize.height
        )
        writeTarget.addSubview(control)

        // Optional second control on the same row, laid out to the right of the main one. Used by
        // 快捷键 for its per-row 恢复默认 button.
        var accessoryView: NSView?
        if let accessory {
            let view = accessory()
            let height = max(controlSize.height, view.frame.height)
            view.frame = NSRect(
                x: Metrics.controlX + controlSize.width + Metrics.accessoryGap,
                y: activeCursor + (Metrics.rowHeight - height) / 2,
                width: accessoryWidth,
                height: height
            )
            view.autoresizingMask = []
            writeTarget.addSubview(view)
            accessoryView = view
        }

        advance(Metrics.rowHeight)
        return (label, control, accessoryView)
    }

    @discardableResult
    func addHint(_ text: String, indented: Bool = true) -> NSTextField {
        let text = L10n.text(text)
        let font = NSFont.systemFont(ofSize: 11)
        let x = indented ? Metrics.padding + Metrics.hintIndent : Metrics.padding
        let width = Metrics.pageWidth - Metrics.padding - x
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = font
        label.textColor = .secondaryLabelColor
        label.frame = NSRect(x: x, y: activeCursor + 1, width: width, height: textHeight(text, width: width, font: font))
        writeTarget.addSubview(label)
        advance(label.frame.height + Metrics.hintGap)
        return label
    }

    /// A grey note sitting to the right of `control`, on the same line.
    @discardableResult
    func addTrailingHint(_ text: String, after control: NSView) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        let x = control.frame.maxX + 8
        label.frame = NSRect(
            x: x,
            y: control.frame.minY + 5,
            width: max(0, Metrics.pageWidth - Metrics.padding - x),
            height: 16
        )
        writeTarget.addSubview(label)
        return label
    }

    /// Vertical breathing room before a trailing action.
    func addSpacer(_ height: CGFloat) {
        advance(height)
    }

    /// A multi-line block of body text. Height is measured from the wrapped layout, so long
    /// changelog entries are never clipped (unlike `addText`, which is a fixed single line).
    @discardableResult
    func addMultiline(_ text: String, font: NSFont = .systemFont(ofSize: 12), color: NSColor = .secondaryLabelColor) -> NSTextField {
        let text = L10n.text(text)
        let width = Metrics.contentWidth
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = font
        label.textColor = color
        label.isSelectable = false
        label.frame = NSRect(
            x: Metrics.padding,
            y: activeCursor,
            width: width,
            height: textHeight(text, width: width, font: font)
        )
        writeTarget.addSubview(label)
        advance(label.frame.height + 8)
        return label
    }

    /// A small section heading inside a page.
    @discardableResult
    func addSubheading(_ text: String) -> NSTextField {
        let text = L10n.text(text)
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.frame = NSRect(x: Metrics.padding, y: activeCursor, width: Metrics.contentWidth, height: 20)
        writeTarget.addSubview(label)
        advance(24)
        return label
    }

    func addHeading(_ text: String) {
        let text = L10n.text(text)
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 22, weight: .semibold)
        label.frame = NSRect(x: Metrics.padding, y: activeCursor, width: Metrics.contentWidth, height: 30)
        writeTarget.addSubview(label)
        advance(36)
    }

    func addText(_ text: String) {
        let text = L10n.text(text)
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.frame = NSRect(x: Metrics.padding, y: activeCursor, width: Metrics.contentWidth, height: 18)
        writeTarget.addSubview(label)
        advance(26)
    }

    @discardableResult
    func addButton(_ title: String, target: AnyObject?, action: Selector, beside: NSButton? = nil) -> NSButton {
        let button = NSButton(title: L10n.text(title), target: target, action: action)
        button.bezelStyle = buttonBezelStyle
        button.sizeToFit()
        button.frame = NSRect(
            x: beside.map { $0.frame.maxX + 12 } ?? Metrics.padding,
            y: beside?.frame.minY ?? activeCursor,
            width: max(140, button.frame.width),
            height: Metrics.buttonHeight
        )
        writeTarget.addSubview(button)
        if beside == nil { advance(Metrics.buttonHeight) }
        return button
    }

    // MARK: Helpers

    private func beginSection() {
        if hasSection { advance(Metrics.sectionGap) }
        hasSection = true
    }

    private func headerLabel(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        return label
    }

    /// Height a wrapped hint really needs, so a two-line hint cannot run into the row below it.
}

/// Height needed to draw `text` wrapped to `width`. Shared by the form and the confirmation panel,
/// both of which lay text out by hand.
func textHeight(_ text: String, width: CGFloat, font: NSFont) -> CGFloat {
    let measured = (text as NSString).boundingRect(
        with: NSSize(width: width, height: .greatestFiniteMagnitude),
        options: [.usesLineFragmentOrigin, .usesFontLeading],
        attributes: [.font: font]
    )
    return max(15, ceil(measured.height))
}

// MARK: - Window controller

/// The preferences window: three top tabs (功能 / 外观与动效 / 关于), sized to the tallest page and
/// deliberately not resizable.
///
/// Every control writes its preference immediately and reports through `onChange`, so an open
/// preview adopts the new value without a restart.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate, NSTextFieldDelegate {

    /// Called when any value changes, so an open preview adopts new settings immediately.
    var onChange: (() -> Void)?

    /// A number typed into one of the timing fields.
    private struct NumericSpec {
        let key: String
        let range: ClosedRange<Double>
        let fallback: Double
    }

    private static let dwellSpec = NumericSpec(
        key: Preferences.Key.dwellTime,
        range: Preferences.dwellRange,
        fallback: Preferences.defaultDwellTime
    )
    private static let switchSpec = NumericSpec(
        key: Preferences.Key.switchDelay,
        range: Preferences.switchRange,
        fallback: Preferences.defaultSwitchDelay
    )
    private static let fadeInSpec = NumericSpec(
        key: Preferences.Key.fadeInDuration,
        range: Preferences.fadeRange,
        fallback: Preferences.defaultFadeIn
    )
    private static let fadeOutSpec = NumericSpec(
        key: Preferences.Key.fadeOutDuration,
        range: Preferences.fadeRange,
        fallback: Preferences.defaultFadeOut
    )

    private static let fieldSize = NSSize(width: 138, height: Metrics.fieldHeight)
    private static let popupSize = NSSize(width: Metrics.popupWidth, height: Metrics.popupHeight)
    private static let recorderSize = NSSize(width: Metrics.recorderWidth, height: Metrics.fieldHeight + 4)

    private var window: NSWindow?
    private var tabView: NSTabView?
    /// One per tab, in tab order, so the height budget can be reported per page.
    private var forms: [SettingsForm] = []

    private var numericFields: [String: NSTextField] = [:]
    private var numericSpecs: [String: NumericSpec] = [:]
    /// The 淡入/淡出 row labels and fields: shown only while the transition is 淡入淡出.
    private var fadeRowViews: [NSView] = []
    private var appearanceFrames: [ObjectIdentifier: CGRect] = [:]

    private var loginSwitch: NSSwitch?
    private var menuIconSwitch: NSSwitch?
    private var languagePopup: NSPopUpButton?
    private var triggerPopup: NSPopUpButton?
    private var pagePicker: NSSegmentedControl?
    private var backdropPopup: NSPopUpButton?
    private var previewCheckbox: NSSwitch?
    private var quickActionsCheckbox: NSSwitch?
    private var memoryCheckbox: NSSwitch?
    private var switcherCheckbox: NSSwitch?
    private var dockMinimizeCheckbox: NSSwitch?
    private var shortcutRecorder: ShortcutRecorderView?

    private var transitionPopup: NSPopUpButton?
    private var themePopup: NSPopUpButton?
    private var panelSizePopup: NSPopUpButton?
    private var clarityPopup: NSPopUpButton?
    private var titleSizePopup: NSPopUpButton?

    // MARK: - Presentation

    func show() {
        if window == nil { buildWindow() }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        reloadValues()
    }

    var isVisible: Bool { window?.isVisible ?? false }

    // MARK: - Building

    private func buildWindow() {
        let pages: [(title: String, form: SettingsForm)] = [
            ("功能", buildFunctionPage()),
            ("外观与动效", buildAppearancePage()),
            ("关于", buildAboutPage())
        ]
        pages.forEach { L10n.localize($0.form.container); $0.form.seal() }
        forms = pages.map(\.form)

        // The tab view draws a bezel and a tab strip around the page content. Measuring a probe
        // frame says exactly how much room that chrome takes, so the window can be sized to the
        // tallest page without clipping either axis.
        let tabView = NSTabView(frame: NSRect(x: 0, y: 0, width: Metrics.pageWidth + 40, height: 400))
        // `.topTabsBezelBorder` draws the legacy bezel backdrop — the grey slab that made the tab bar
        // look glued to the page content. Plain top tabs match the current system look and let the
        // window background show through.
        tabView.tabViewType = .noTabsNoBorder
        tabView.drawsBackground = false
        for page in pages {
            let item = NSTabViewItem(identifier: page.title)
            item.label = L10n.text(page.title)
            item.view = page.form.container
            tabView.addTabViewItem(item)
        }

        let chromeX = tabView.frame.width - tabView.contentRect.width
        let chromeY = tabView.frame.height - tabView.contentRect.height
        let tallest = pages.map { $0.form.requiredHeight }.max() ?? 240
        let inset = Metrics.windowInset
        let contentSize = NSSize(
            width: (Metrics.pageWidth + chromeX + inset * 2).rounded(.up),
            // Slack above the tallest page: the chrome measurement is rounded up, and a page that
            // fills its area exactly would clip on any fractional difference.
            height: (tallest + chromeY + inset * 2).rounded(.up) + 2
        )

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = L10n.text("设置")
        window.titleVisibility = .visible
        window.standardWindowButton(.miniaturizeButton)?.isEnabled = false
        window.standardWindowButton(.zoomButton)?.isEnabled = false
        window.isReleasedWhenClosed = false
        window.delegate = self
        // A plain container insets the tab view so the tab strip is not flush against the title bar
        // and the window sides.
        let root = SettingsBackgroundView(frame: NSRect(origin: .zero, size: contentSize))
        root.autoresizingMask = [.width, .height]
        tabView.frame = NSRect(
            x: inset,
            y: inset,
            width: contentSize.width - inset * 2,
            height: contentSize.height - inset * 2
        )
        tabView.autoresizingMask = [.width, .height]
        root.addSubview(tabView)
        tabView.wantsLayer = true
        tabView.layer?.cornerRadius = 8
        tabView.layer?.borderWidth = 0.5
        tabView.layer?.borderColor = NSColor.separatorColor.cgColor
        tabView.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.035).cgColor
        let picker = NSSegmentedControl(labels: ["功能", "外观与动效", "关于"].map(L10n.text),
                                        trackingMode: .selectOne, target: self, action: #selector(pageChanged(_:)))
        picker.segmentStyle = .smallSquare
        picker.selectedSegment = 0
        picker.setAccessibilityLabel(L10n.text("设置页面"))
        picker.frame = NSRect(x: 42, y: contentSize.height - 42, width: contentSize.width - 84, height: 30)
        picker.autoresizingMask = [.width, .minYMargin]
        root.addSubview(picker)
        pagePicker = picker
        window.contentView = root
        tabView.autoresizingMask = [.width, .height]
        window.setContentSize(contentSize)
        // Not resizable: the size comes from the tallest page.
        window.center()

        // Hand every page the real content area, so the layout check measures what users see.
        let area = tabView.contentRect
        for item in tabView.tabViewItems {
            item.view?.frame = NSRect(origin: area.origin, size: area.size)
        }

        self.window = window
        self.tabView = tabView
        L10n.localize(root)
        syncFadeRows()
        resizeForSelectedPage(animated: false)
    }

    // MARK: - Page 1：功能

    private func buildFunctionPage() -> SettingsForm {
        let form = SettingsForm()

        form.addHeader("基本")

        previewCheckbox = form.addSwitch(
            "启用悬停预览", target: self, action: #selector(togglePreviewEnabled(_:))
        )

        loginSwitch = form.addSwitch("登录时启动", target: self, action: #selector(toggleLogin(_:)))
        menuIconSwitch = form.addSwitch("显示菜单栏图标", target: self, action: #selector(toggleMenuIcon(_:)))
        quickActionsCheckbox = form.addSwitch(
            "显示菜单栏快捷操作", target: self, action: #selector(toggleQuickActions(_:))
        )
        form.addHint("控制菜单里的启用预览、设置、登录时启动、检查权限、关于、退出等操作项")

        memoryCheckbox = form.addSwitch(
            "显示内存占用", target: self, action: #selector(toggleMemoryUsage(_:))
        )
        form.addHint("在菜单中显示内存占用读数；与上一项互不影响")

        switcherCheckbox = form.addSwitch(
            "启用窗口切换快捷键", target: self, action: #selector(toggleSwitcher(_:))
        )

        let recorder = ShortcutRecorderView(frame: NSRect(origin: .zero, size: Self.recorderSize))
        recorder.onCapture = { [weak self] shortcut in
            Preferences.switcherShortcut = shortcut
            self?.onChange?()
        }
        shortcutRecorder = recorder
        form.addRow(
            "快捷键",
            indented: true,
            controlSize: Self.recorderSize,
            accessory: { [weak self] in
                self?.makeRestoreButton(title: "恢复默认", action: #selector(self?.restoreDefaultShortcut(_:))) ?? NSView()
            },
            accessoryWidth: Metrics.accessoryWidth
        ) { recorder }
        form.addHint("默认 ⌥Tab 切换窗口；加按 ⇧ 反向切换")

        languagePopup = form.addRow("语言 / Language", controlSize: Self.popupSize) {
            self.makePopup(["简体中文", "English"], action: #selector(self.languageChanged(_:)))
        }.control

        triggerPopup = form.addRow("缩略图切换时机", controlSize: Self.popupSize) {
            self.makePopup(Preferences.SelectionTrigger.allCases.map(\.displayName), action: #selector(self.triggerChanged(_:)))
        }.control
        form.addHint("按下后移开，再松开即可取消切换")

        form.addHeader("实验性")
        dockMinimizeCheckbox = form.addSwitch(
            "点击当前应用的 Dock 图标以最小化窗口", target: self, action: #selector(toggleDockMinimize(_:))
        )
        form.addHint("点击当前前台应用的 Dock 图标时最小化其活动窗口，行为类似 Windows 任务栏")

        return form
    }

    // MARK: - Page 2：外观与动效

    private func buildAppearancePage() -> SettingsForm {
        let form = SettingsForm()

        // ---------------------------------------------------------------- 悬停响应
        form.addHeader("悬停响应")
        form.addRow("弹出延迟", controlSize: Self.fieldSize) { self.makeNumericField(Self.dwellSpec) }
        form.addHint("鼠标停在图标上多久弹出预览", indented: false)
        form.addRow("切换延迟", controlSize: Self.fieldSize) { self.makeNumericField(Self.switchSpec) }
        form.addHint("预览已弹出时，移到另一个图标后多快切换", indented: false)

        // ---------------------------------------------------------------- 过渡动画
        transitionPopup = form.addHeaderRow("过渡动画", controlSize: Self.popupSize) {
            self.makePopup(Preferences.Transition.allCases.map(\.displayName), action: #selector(self.transitionChanged(_:)))
        }

        let fadeIn = form.addRow("淡入时长", controlSize: Self.fieldSize) {
            self.makeNumericField(Self.fadeInSpec)
        }
        fadeRowViews.append(contentsOf: [fadeIn.label, fadeIn.control])

        let fadeOut = form.addRow("淡出时长", controlSize: Self.fieldSize) {
            self.makeNumericField(Self.fadeOutSpec)
        }
        fadeRowViews.append(contentsOf: [fadeOut.label, fadeOut.control])

        // ---------------------------------------------------------------- 主题
        form.addHeader("主题")
        themePopup = form.addRow("外观模式", controlSize: Self.popupSize) {
            self.makePopup(Preferences.ThemeMode.allCases.map(\.displayName), action: #selector(self.themeChanged(_:)))
        }.control

        if #available(macOS 26.0, *) {
            backdropPopup = form.addRow("背景材质", controlSize: Self.popupSize) {
                self.makePopup(Preferences.Backdrop.allCases.map(\.displayName), action: #selector(self.backdropChanged(_:)))
            }.control
            backdropPopup?.identifier = NSUserInterfaceItemIdentifier("backdrop")
        }

        // ---------------------------------------------------------------- 窗口缩略图
        form.addHeader("窗口缩略图")
        panelSizePopup = form.addRow("预览尺寸", controlSize: Self.popupSize) {
            self.makePopup(Preferences.PanelSize.allCases.map(\.displayName), action: #selector(self.panelSizeChanged(_:)))
        }.control

        let clarity = form.addRow("缩略图清晰度", controlSize: Self.popupSize) {
            self.makePopup(Preferences.ThumbnailClarity.allCases.map(\.displayName), action: #selector(self.clarityChanged(_:)))
        }.control
        clarityPopup = clarity
        form.addTrailingHint("关闭缩略图时不可用", after: clarity)

        // ---------------------------------------------------------------- 窗口标题
        form.addHeader("窗口标题")
        titleSizePopup = form.addRow("窗口标题字号", controlSize: Self.popupSize) {
            self.makePopup(Preferences.TitleSize.allCases.map(\.displayName), action: #selector(self.titleSizeChanged(_:)))
        }.control
        form.addHint("只调整标题文字大小，不影响缩略图尺寸", indented: false)

        // Page-level recovery, placed at the visual end of the page it belongs to.
        form.addSpacer(8)
        form.addButton("恢复本页默认设置", target: self, action: #selector(restoreAppearanceDefaults))
        appearanceFrames = Dictionary(uniqueKeysWithValues: form.container.subviews.map { (ObjectIdentifier($0), $0.frame) })
        return form
    }

    // MARK: - Page 3：关于

    /// Visible height of the changelog region on 关于.
    ///
    /// The page height is this value, not the height of the changelog inside it, so the window no
    /// longer grows as entries are added — the extra content simply scrolls.
    static let changelogHeight: CGFloat = 340

    private func buildAboutPage() -> SettingsForm {
        let form = SettingsForm()
        form.addHeading("DockPeek V\(Version.shortVersion)")
        // Version number moved here from the window header. `Version.summary` also carries the build
        // date, which is what makes two installed copies distinguishable.
        form.addText(L10n.language == .english ? "Built \(L10n.text(Version.buildStamp))" : "构建于 \(Version.buildStamp)")

        // Everything from here down scrolls, so a long changelog no longer makes the window taller.
        // The heading and version above stay fixed and always visible.
        form.beginScroll(height: Self.changelogHeight)
        form.addSpacer(4)

        // Changelog. 0.3.0 is the large update; the later entries are follow-ups.
        struct Release {
            let version: String
            let headline: String
            let bullets: [String]
        }

        let releases: [Release] = [
            Release(
                version: "0.3.0",
                headline: "大型更新",
                bullets: [
                    "设置界面重组为三页：功能 / 外观与动效 / 关于",
                    "预览尺寸选项：更小、小、中、大、关闭",
                    "缩略图清晰度选项：原图、标准、流畅",
                    "窗口标题字号选项：小、中、大、关闭",
                    "过渡动画三选项：关闭动画 / 淡入淡出 / 弹出动画",
                    "新增窗口切换快捷键设置项",
                    "新增实验性功能：再次点击 Dock 图标时最小化窗口",
                    "主题支持跟随系统 / 始终深色 / 始终浅色",
                    "菜单栏新增「隐藏菜单栏图标」；三个开关互相独立：图标显示、菜单栏快捷操作、内存占用",
                    "权限修正：第二项权限为「设备控制和数据访问」，此前误标为「辅助功能」",
                    "权限弹窗统一为只有一个「好」按钮，不跳转、不请求授权",
                    "删除菜单中的诊断信息项，删除用户文案编辑功能",
                    "修复缩略图四角异常：白色块状区域与三角形",
                    "删除当前窗口右下角的对勾标记",
                    "修复最小化后缩略图消失",
                    "改用 macOS 26 / 27 的新界面接口：按钮使用 NSBezelStyleGlass，预览面板使用 NSGlassEffectView",
                    "修复「关闭动画」选项无效的问题"
                ]
            ),
            Release(
                version: "0.3.1",
                headline: "",
                bullets: [
                    "缩略图缓存不再依赖鼠标悬停：新增后台预热，应用运行期间主动发现新窗口并提前采集",
                    "修复预览位置与内容被裁切：面板尺寸不再超过屏幕可用区，网格不再大于面板",
                    "修复 Dock 方向判定：改用屏幕完整区域判断，左侧程序坞不再被误判为顶部",
                    "快捷键行右侧新增「恢复默认」按钮",
                    "「外观与动效」页底部新增「恢复本页默认设置」",
                    "关于页移除「恢复全部默认值」，保持干净"
                ]
            ),
            Release(
                version: "0.3.2",
                headline: "",
                bullets: [
                    "关于页新增版本更新记录（本页）",
                    "构建日期改为只显示到日，不再显示时分"
                ]
            ),
            Release(
                version: "0.3.4",
                headline: "",
                bullets: [
                    "关于页的版本更新记录改为滚动区域：窗口高度不再随记录条数增长，版本号固定显示在滚动区上方",
                    "修复「恢复默认」按钮画不出来的问题。此前用的是 NSBezelStyleGlass，实测该档位不绘制背板，只显示文字；改用 NSBezelStylePush",
                    "恢复默认的确认提示改为自建面板：去掉程序图标，只保留标题、内容与选项，按钮更名为「确认」与「取消」",
                    "确认文案用词调整：把「组合」改为「状态」"
                ]
            ),
            Release(
                version: "0.3.3",
                headline: "",
                bullets: [
                    "修正本页的版本更新记录：去掉未经证实的界面效果描述，版本号更正为 0.3.x",
                    "「功能」与「外观与动效」页的「恢复默认」按钮改为正常绘制，此前只显示文字、没有按钮外观",
                    "恢复默认前新增确认提示，避免误操作覆盖已编辑内容",
                    "新增「预览面板材质」设置：可在液态玻璃与磨砂玻璃之间切换",
                    "修复预览被裁切：网格此前被放进系统管理的容器，尺寸会被系统改掉，导致面板按一种宽度布局、内容按另一种宽度排列"
                ]
            )
        ]

        let ordered = releases.sorted {
            $0.version.compare($1.version, options: .numeric) == .orderedAscending
        } + [Release(version: "0.4.0", headline: "稳定性与原生界面更新", bullets: [
            "修复预览裁切、大片空白和低清晰度图片显示过小；窗口较多时支持滚动",
            "修复切换到无窗口应用时仍显示上一个应用预览的问题",
            "接入 macOS 26 原生液态玻璃及 macOS 27 交互效果，材质切换立即生效",
            "修正构建兼容信息，启用 macOS 27 原生控件样式，同时保留旧系统兼容路径",
            "设置顶部使用原生页面切换栏，启用/关闭项统一为系统开关",
            "功能页新增登录时启动、菜单栏图标显示和中英文切换",
            "实现点击当前应用的 Dock 图标最小化活动窗口；实现可编辑的窗口切换快捷键",
            "窗口身份不再依赖标题，修复同名窗口混淆及最小化缓存丢失",
            "缩略图刷新失败时保留上一次有效画面，后台预热会重试并限制并发",
            "修复菜单开关不即时生效、材质选项不回显、异常设置可能崩溃的问题",
            "更新记录按 0.3.0 至 0.4.0 顺序展示；调整界面文案，清理重复缓存逻辑",
        ]), Release(version: "0.4.1", headline: "窗口交互与设置优化", bullets: [
            "增加其他桌面窗口发现，访问其他桌面优先于最小化",
            "恢复设置标题，顶部切换栏改为适度圆角的长方形，增加内容边框",
            "新增按下或松开鼠标切换窗口，默认松开；移开后松开可取消",
            "时长输入框增加加减按钮，每次调整 0.05 秒；点击空白结束编辑",
            "动画时长设置展开与收起时同步调整窗口高度",
            "优化弹出动画收起，连续加速并在末端同步隐藏整个面板",
            "更新记录改用原生文本视图，支持稳定的跨段落选择与复制",
            "关于页新增 AI 鸣谢",
            "邮件入口、邮箱地址与 GitHub 链接固定在滚动区外的底部",
            "新安装默认使用英语，保留已有语言选择",
            "切换主题和材质时只重新采样当前桌面可见、未最小化的窗口",
            "关闭所有窗口会向目标应用一次提交全部关闭请求，并保留未保存提示"
        ])]
        for release in ordered {
            let title = release.headline.isEmpty
                ? "版本 \(release.version)"
                : "版本 \(release.version)（\(release.headline)）"
            form.addSubheading(title)
            form.addMultiline(release.bullets.map { "·  " + $0 }.joined(separator: "\n"))
        }

        form.addSubheading("特别鸣谢")
        form.addMultiline("特别鸣谢 ChatGPT 和 DeepSeek。\n本程序的全部代码均由 AI 编写。\n人类负责提供想法、参与测试，以及偶尔追问：“这次真的修好了吗？”")
        form.endScroll()
        form.makeScrollTextSelectable()
        form.addSpacer(12)
        form.addMultiline("欢迎提出意见和反馈。")
        form.addText("lidonggemail@gmail.com")
        form.addText("github.com/LiDongB/none-test")
        let email = form.addButton("发送邮件", target: self, action: #selector(sendEmail))
        email.image = NSImage(systemSymbolName: "envelope", accessibilityDescription: nil)
        email.imagePosition = .imageLeading
        let github = form.addButton("GitHub", target: self, action: #selector(openGitHub), beside: email)
        github.image = NSImage(systemSymbolName: "link", accessibilityDescription: nil)
        github.imagePosition = .imageLeading
        for link in [email, github] {
            link.isBordered = false
            link.contentTintColor = .linkColor
            link.font = .systemFont(ofSize: 12)
            link.alignment = .left
            link.sizeToFit()
            link.frame.size.height = Metrics.buttonHeight
        }
        github.frame.origin.x = email.frame.maxX + 12
        func selectable(_ view: NSView) {
            if let field = view as? NSTextField, !field.isEditable { field.isSelectable = true }
            view.subviews.forEach(selectable)
        }
        selectable(form.container)
        return form
    }

    // MARK: - Control factories

    private func makeNumericField(_ spec: NumericSpec) -> NSView {
        let container = NSView(frame: NSRect(origin: .zero, size: Self.fieldSize))
        let field = NSTextField(frame: NSRect(x: 32, y: 0, width: Metrics.fieldWidth, height: Metrics.fieldHeight))
        field.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        field.alignment = .right
        field.target = self
        field.action = #selector(numericFieldCommitted(_:))
        field.delegate = self
        field.identifier = NSUserInterfaceItemIdentifier(spec.key)
        numericFields[spec.key] = field
        numericSpecs[spec.key] = spec
        container.addSubview(field)
        for (tag, title, x) in [(-1, "−", CGFloat(0)), (1, "+", CGFloat(110))] {
            let button = NSButton(title: title, target: self, action: #selector(adjustDuration(_:)))
            button.bezelStyle = .smallSquare
            button.frame = NSRect(x: x, y: 0, width: 28, height: Metrics.fieldHeight)
            button.tag = tag
            button.identifier = NSUserInterfaceItemIdentifier(spec.key)
            button.setAccessibilityLabel(L10n.text(tag == -1 ? "减少时长" : "增加时长"))
            container.addSubview(button)
        }
        return container
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        if let field = obj.object as? NSTextField { numericFieldCommitted(field) }
    }
    @objc private func adjustDuration(_ sender: NSButton) {
        window?.makeFirstResponder(nil)
        guard let key = sender.identifier?.rawValue, let spec = numericSpecs[key] else { return }
        let value = Preferences.set(key, to: (Self.currentValue(spec) * 100).rounded() / 100 + Double(sender.tag) * 0.05, in: spec.range)
        numericFields[key]?.stringValue = Self.format(value)
        onChange?()
    }
    @objc private func triggerChanged(_ sender: NSPopUpButton) {
        Preferences.selectionTrigger = selected(Preferences.SelectionTrigger.allCases, sender)
        onChange?()
    }
    @objc private func sendEmail() {
        if let url = URL(string: "mailto:lidonggemail@gmail.com") { NSWorkspace.shared.open(url) }
    }
    @objc private func openGitHub() {
        if let url = URL(string: "https://github.com/LiDongB/none-test") { NSWorkspace.shared.open(url) }
    }

    private func makePopup(_ titles: [String], action: Selector) -> NSPopUpButton {
        let popup = NSPopUpButton(frame: NSRect(origin: .zero, size: Self.popupSize), pullsDown: false)
        popup.addItems(withTitles: titles)
        popup.target = self
        popup.action = action
        return popup
    }

    // MARK: - Values

    /// Reflects every stored preference in the UI. Called from `show()` and after a reset.
    private func reloadValues() {
        loginSwitch?.state = LoginItem.isEnabled ? .on : .off
        menuIconSwitch?.state = Preferences.showMenuBarIcon ? .on : .off
        languagePopup?.selectItem(at: L10n.language == .english ? 1 : 0)
        select(triggerPopup, Preferences.SelectionTrigger.allCases, Preferences.selectionTrigger)
        select(backdropPopup, Preferences.Backdrop.allCases, Preferences.backdrop)
        previewCheckbox?.state = Preferences.previewEnabled ? .on : .off
        quickActionsCheckbox?.state = Preferences.showMenuBarQuickActions ? .on : .off
        memoryCheckbox?.state = Preferences.showMemoryUsage ? .on : .off
        switcherCheckbox?.state = Preferences.switcherEnabled ? .on : .off
        dockMinimizeCheckbox?.state = Preferences.clickDockToMinimize ? .on : .off

        shortcutRecorder?.shortcut = Preferences.switcherShortcut

        for (key, field) in numericFields {
            guard let spec = numericSpecs[key] else { continue }
            field.stringValue = Self.format(Self.currentValue(spec))
        }

        select(transitionPopup, Preferences.Transition.allCases, Preferences.transition)
        select(themePopup, Preferences.ThemeMode.allCases, Preferences.themeMode)
        select(panelSizePopup, Preferences.PanelSize.allCases, Preferences.panelSize)
        select(clarityPopup, Preferences.ThumbnailClarity.allCases, Preferences.thumbnailClarity)
        select(titleSizePopup, Preferences.TitleSize.allCases, Preferences.titleSize)

        syncFadeRows()
        syncClarityRow()
        // The recorder remains visible so a disabled shortcut can still be edited.
        forms.forEach { L10n.localize($0.container) }
        if let content = window?.contentView { L10n.localize(content) }
    }

    private func select<T: Equatable>(_ popup: NSPopUpButton?, _ cases: [T], _ current: T) {
        guard let popup, let index = cases.firstIndex(of: current) else { return }
        popup.selectItem(at: index)
    }

    /// 淡入/淡出 rows are only meaningful for the 淡入淡出 transition: elsewhere they are hidden and
    /// disabled. The fields are re-read from storage and never written here, so changing the
    /// transition cannot alter the stored fade durations.
    private func syncFadeRows(animated: Bool = false) {
        let isFade = Preferences.transition == .fade
        if !isFade { window?.makeFirstResponder(nil) }
        let cutoff = fadeRowViews.compactMap { appearanceFrames[ObjectIdentifier($0)]?.maxY }.max() ?? .greatestFiniteMagnitude
        func changes() {
            if self.forms.count > 1 {
                for view in self.forms[1].container.subviews {
                    guard var frame = self.appearanceFrames[ObjectIdentifier(view)] else { continue }
                    if !isFade && frame.minY >= cutoff { frame.origin.y -= Metrics.rowHeight * 2 }
                    if animated { view.animator().frame = frame } else { view.frame = frame }
                }
            }
            for view in self.fadeRowViews {
                if isFade { view.isHidden = false }
                if animated { view.animator().alphaValue = isFade ? 1 : 0 }
                else { view.alphaValue = isFade ? 1 : 0; view.isHidden = !isFade }
                (view as? NSControl)?.isEnabled = isFade
            }
            for spec in [Self.fadeInSpec, Self.fadeOutSpec] { self.numericFields[spec.key]?.isEnabled = isFade }
            self.resizeForSelectedPage(animated: animated)
        }
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.20
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                changes()
            } completionHandler: { [weak self] in
                Task { @MainActor in
                    guard let self, Preferences.transition != .fade else { return }
                    self.fadeRowViews.forEach { $0.isHidden = true }
                }
            }
        } else { changes() }
    }

    private func resizeForSelectedPage(animated: Bool) {
        guard let window, let tabView, let selected = tabView.selectedTabViewItem else { return }
        let index = tabView.indexOfTabViewItem(selected)
        guard forms.indices.contains(index) else { return }
        let collapse: CGFloat = index == 1 && Preferences.transition != .fade ? Metrics.rowHeight * 2 : 0
        let height = forms[index].requiredHeight - collapse
        let size = NSSize(width: Metrics.pageWidth + Metrics.windowInset * 2, height: height + 58 + Metrics.windowInset)
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        if animated { window.animator().setFrame(frame, display: true) }
        else { window.setFrame(frame, display: true) }
        let tabFrame = NSRect(x: Metrics.windowInset, y: Metrics.windowInset, width: Metrics.pageWidth, height: height)
        if animated { tabView.animator().frame = tabFrame } else { tabView.frame = tabFrame }
        for item in tabView.tabViewItems { item.view?.frame = NSRect(origin: .zero, size: tabFrame.size) }
    }

    /// 缩略图清晰度 has no effect while thumbnails are switched off.
    private func syncClarityRow() {
        clarityPopup?.isEnabled = Preferences.panelSize != .off
    }

    // MARK: - Verification surface

    /// Whether the 淡入时长 / 淡出时长 rows are currently shown.
    /// Exposed so the conditional-visibility rule can be asserted rather than eyeballed.
    var fadeRowsAreVisible: Bool {
        guard let first = fadeRowViews.first else { return false }
        return !first.isHidden && (first as? NSControl)?.isEnabled == true
    }

    /// Whether the 缩略图清晰度 control accepts input.
    var clarityRowIsEnabled: Bool { clarityPopup?.isEnabled ?? false }

    /// Re-applies the conditional rules; used after the test mutates a preference directly.
    func refreshConditionalRows() {
        syncFadeRows()
        syncClarityRow()
    }

    // MARK: - Actions

    @objc private func toggleLogin(_ sender: NSSwitch) {
        LoginItem.setEnabled(sender.state == .on)
        sender.state = LoginItem.isEnabled ? .on : .off
        onChange?()
    }
    @objc private func toggleMenuIcon(_ sender: NSSwitch) {
        Preferences.showMenuBarIcon = sender.state == .on
        onChange?()
    }
    @objc private func languageChanged(_ sender: NSPopUpButton) {
        L10n.language = sender.indexOfSelectedItem == 1 ? .english : .chinese
        let selected = tabView?.indexOfTabViewItem(tabView!.selectedTabViewItem!) ?? 0
        window?.close()
        window = nil
        forms.removeAll()
        numericFields.removeAll()
        numericSpecs.removeAll()
        fadeRowViews.removeAll()
        buildWindow()
        show()
        selectPage(selected)
        onChange?()
    }
    func refreshValues() { reloadValues() }

    @objc private func pageChanged(_ sender: NSSegmentedControl) {
        window?.makeFirstResponder(nil)
        selectPage(sender.selectedSegment)
    }

    @objc private func togglePreviewEnabled(_ sender: NSSwitch) {
        Preferences.previewEnabled = (sender.state == .on)
        onChange?()
    }

    @objc private func toggleQuickActions(_ sender: NSSwitch) {
        Preferences.showMenuBarQuickActions = (sender.state == .on)
        onChange?()
    }

    @objc private func toggleMemoryUsage(_ sender: NSSwitch) {
        Preferences.showMemoryUsage = (sender.state == .on)
        onChange?()
    }

    @objc private func toggleSwitcher(_ sender: NSSwitch) {
        Preferences.switcherEnabled = (sender.state == .on)
        onChange?()
    }

    @objc private func toggleDockMinimize(_ sender: NSSwitch) {
        Preferences.clickDockToMinimize = (sender.state == .on)
        onChange?()
    }

    @objc private func transitionChanged(_ sender: NSPopUpButton) {
        Preferences.transition = selected(Preferences.Transition.allCases, sender)
        // Only the visibility of the fade rows changes; their stored values stay untouched.
        syncFadeRows(animated: true)
        onChange?()
    }

    @objc private func themeChanged(_ sender: NSPopUpButton) {
        Preferences.themeMode = selected(Preferences.ThemeMode.allCases, sender)
        onChange?()
    }

    @objc private func panelSizeChanged(_ sender: NSPopUpButton) {
        Preferences.panelSize = selected(Preferences.PanelSize.allCases, sender)
        syncClarityRow()
        onChange?()
    }

    @objc private func clarityChanged(_ sender: NSPopUpButton) {
        Preferences.thumbnailClarity = selected(Preferences.ThumbnailClarity.allCases, sender)
        onChange?()
    }

    @objc private func titleSizeChanged(_ sender: NSPopUpButton) {
        Preferences.titleSize = selected(Preferences.TitleSize.allCases, sender)
        onChange?()
    }

    @objc private func numericFieldCommitted(_ sender: NSTextField) {
        guard let key = sender.identifier?.rawValue, let spec = numericSpecs[key] else { return }
        let text = sender.stringValue.trimmingCharacters(in: .whitespaces)

        // Empty means "back to the default": drop the stored value and show what applies now.
        guard !text.isEmpty else {
            UserDefaults.standard.removeObject(forKey: key)
            sender.stringValue = Self.format(Self.currentValue(spec))
            onChange?()
            return
        }

        guard let parsed = Double(text.replacingOccurrences(of: ",", with: ".")), parsed.isFinite else {
            NSSound.beep()
            sender.stringValue = Self.format(Self.currentValue(spec))
            return
        }

        let applied = Preferences.set(key, to: parsed, in: spec.range)
        sender.stringValue = Self.format(applied)
        onChange?()
    }

    /// A small 恢复默认 button, styled with the system glass bezel.
    private func makeRestoreButton(title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = buttonBezelStyle
        // `.regular`, not `.small`: with the small control size inside a narrow frame the glass bezel
        // has no room to draw and the button renders as bare text, which is exactly how it looked.
        button.controlSize = .regular
        button.font = .systemFont(ofSize: 12)
        button.sizeToFit()
        return button
    }

    /// Asks before a destructive reset. Returns `true` when the user confirmed.
    ///
    /// Every reset entry point goes through this: the action discards edits and there is no undo.
    ///
    /// Built as a plain panel rather than an `NSAlert` because the design is title + body + options
    /// only. `NSAlert` always shows the application icon: setting its `icon` to nil *restores* the
    /// app icon rather than removing it, so there is no way to get an icon-less alert.
    private func confirmReset(_ message: String) -> Bool {
        let built = buildConfirmPanel(message + "\n\n" + "恢复默认后将覆盖编辑内容 且不可撤销")
        let panel = built.panel
        panel.center()
        NSApp.activate(ignoringOtherApps: true)

        var confirmed = false
        let confirmTarget = ModalChoiceTarget { confirmed = true; NSApp.stopModal() }
        let cancelTarget = ModalChoiceTarget { confirmed = false; NSApp.stopModal() }
        built.confirm.target = confirmTarget
        built.confirm.action = #selector(ModalChoiceTarget.choose(_:))
        built.cancel.target = cancelTarget
        built.cancel.action = #selector(ModalChoiceTarget.choose(_:))
        // Keep both targets alive for the duration of the modal session.
        modalTargets = [confirmTarget, cancelTarget]

        NSApp.runModal(for: panel)
        panel.orderOut(nil)
        modalTargets = []
        return confirmed
    }

    /// The confirmation panel and its two buttons, without running it.
    ///
    /// Split out so `--capture-confirm` can screenshot the exact panel the user sees.
    func buildConfirmPanel(_ text: String) -> (panel: NSPanel, confirm: NSButton, cancel: NSButton) {
        let width: CGFloat = 360
        let inset: CGFloat = 20

        let (titleText, bodyText) = Self.splitConfirmText(text)

        let title = NSTextField(wrappingLabelWithString: titleText)
        title.font = .systemFont(ofSize: 13, weight: .semibold)

        let body = NSTextField(wrappingLabelWithString: bodyText)
        body.font = .systemFont(ofSize: 12)
        body.textColor = .secondaryLabelColor

        // "确认" rather than repeating the action name: the panel already states what will happen.
        let confirm = NSButton(title: "确认", target: nil, action: nil)
        confirm.bezelStyle = buttonBezelStyle
        confirm.keyEquivalent = "\r"

        let cancel = NSButton(title: "取消", target: nil, action: nil)
        cancel.bezelStyle = buttonBezelStyle
        cancel.keyEquivalent = "\u{1b}"

        let textWidth = width - inset * 2
        let titleHeight = textHeight(titleText, width: textWidth, font: title.font!)
        let bodyHeight = textHeight(bodyText, width: textWidth, font: body.font!)

        let buttonsHeight: CGFloat = 32
        let height = inset + titleHeight + 8 + bodyHeight + 18 + buttonsHeight + inset

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        // Title only, no application icon: the design is title + body + options.
        panel.title = "DockPeek"

        let content = FlippedView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        title.frame = NSRect(x: inset, y: inset, width: textWidth, height: titleHeight)
        body.frame = NSRect(x: inset, y: title.frame.maxY + 8, width: textWidth, height: bodyHeight)
        content.addSubview(title)
        content.addSubview(body)

        let buttonWidth: CGFloat = 80
        cancel.frame = NSRect(
            x: width - inset - buttonWidth,
            y: height - inset - buttonsHeight + 4,
            width: buttonWidth,
            height: 26
        )
        confirm.frame = NSRect(
            x: cancel.frame.minX - 10 - buttonWidth,
            y: cancel.frame.minY,
            width: buttonWidth,
            height: 26
        )
        content.addSubview(cancel)
        content.addSubview(confirm)
        panel.contentView = content
        panel.defaultButtonCell = confirm.cell as? NSButtonCell

        if let content = panel.contentView { L10n.localize(content) }
        return (panel, confirm, cancel)
    }

    /// Splits the combined text into a one-line title and the rest as body copy.
    static func splitConfirmText(_ text: String) -> (title: String, body: String) {
        guard let range = text.range(of: "\n\n") else { return (text, "") }
        return (String(text[text.startIndex..<range.lowerBound]),
                String(text[range.upperBound...]))
    }

    /// Retains the small action targets used by the confirmation panel.
    private var modalTargets: [AnyObject] = []

    /// 恢复快捷键为默认状态（只影响快捷键）。
    @objc private func restoreDefaultShortcut(_ sender: Any?) {
        guard confirmReset("要把快捷键恢复为默认状态吗？") else { return }
        Preferences.switcherShortcut = .default
        reloadValues()
        onChange?()
    }

    @objc private func backdropChanged(_ sender: NSPopUpButton) {
        Preferences.backdrop = selected(Preferences.Backdrop.allCases, sender)
        onChange?()
    }

    /// 恢复「外观与动效」页的全部设置为默认值。
    ///
    /// Scoped to this page on purpose: the button sits on this page, so it should not silently
    /// change settings the user configured elsewhere.
    @objc private func restoreAppearanceDefaults(_ sender: Any?) {
        guard confirmReset("要把「外观与动效」恢复为默认设置吗？") else { return }
        [
            Preferences.Key.dwellTime,
            Preferences.Key.switchDelay,
            Preferences.Key.transition,
            Preferences.Key.fadeInDuration,
            Preferences.Key.fadeOutDuration,
            Preferences.Key.themeMode,
            Preferences.Key.panelSize,
            Preferences.Key.thumbnailClarity,
            Preferences.Key.titleSize,
            Preferences.Key.backdrop
        ].forEach { UserDefaults.standard.removeObject(forKey: $0) }

        reloadValues()
        onChange?()
    }

    @objc private func resetDefaults() {
        Preferences.resetToDefaults()
        reloadValues()
        onChange?()
    }

    private func selected<T>(_ cases: [T], _ popup: NSPopUpButton) -> T {
        let index = max(0, min(popup.indexOfSelectedItem, cases.count - 1))
        return cases[index]
    }

    // MARK: - Small helpers

    private static func stored(_ key: String) -> Double? {
        UserDefaults.standard.object(forKey: key) as? Double
    }

    /// The value the app would actually use: stored (clamped into range) or the default.
    private static func currentValue(_ spec: NumericSpec) -> Double {
        guard let stored = stored(spec.key) else { return spec.fallback }
        return stored.isFinite ? min(max(stored, spec.range.lowerBound), spec.range.upperBound) : spec.fallback
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    // MARK: - Layout verification

    /// Dumps the real geometry involved in placing the tab bar and the pages.
    ///
    /// Used to diagnose a reported overlap between the tab bar and the page content: these numbers
    /// can only be read from a live, laid-out window.
    /// Selects a tab by index (test surface).
    func selectPage(_ index: Int) {
        if window == nil { buildWindow() }
        guard let tabView, index >= 0, index < tabView.numberOfTabViewItems else { return }
        tabView.selectTabViewItem(at: index)
        pagePicker?.selectedSegment = index
        resizeForSelectedPage(animated: false)
    }

    /// The settings window (test surface).
    var windowForTesting: NSWindow? { window }

    func geometryReport() -> [String] {
        if window == nil { buildWindow() }
        guard let window, let content = window.contentView else { return ["窗口未构建"] }

        window.layoutIfNeeded()
        content.layoutSubtreeIfNeeded()

        func rect(_ r: NSRect) -> String {
            String(format: "(%.0f, %.0f) %.0f×%.0f", r.minX, r.minY, r.width, r.height)
        }

        var lines: [String] = ["窗口几何"]
        lines.append("  contentView.frame       = \(rect(content.frame))")
        lines.append("  window.frame            = \(rect(window.frame))")

        func findTabView(_ view: NSView) -> NSTabView? {
            if let tab = view as? NSTabView { return tab }
            for sub in view.subviews {
                if let found = findTabView(sub) { return found }
            }
            return nil
        }

        guard let tabView = findTabView(content) else {
            lines.append("  ❌ 没找到 NSTabView")
            lines.append("  content 子视图树：")
            func dump(_ view: NSView, _ depth: Int) {
                let pad = String(repeating: "  ", count: depth)
                lines.append("  \(pad)\(type(of: view)) \(rect(view.frame))")
                if depth < 3 { view.subviews.forEach { dump($0, depth + 1) } }
            }
            content.subviews.forEach { dump($0, 1) }
            return lines
        }

        lines.append("  tabView.frame           = \(rect(tabView.frame))")
        lines.append("  tabView.contentRect     = \(rect(tabView.contentRect))")
        lines.append("  tabView.tabPosition     = \(tabView.tabPosition.rawValue)")
        lines.append("  tabView.borderType      = \(tabView.tabViewBorderType.rawValue)")
        lines.append("  tabView.drawsBackground = \(tabView.drawsBackground)")

        for (index, item) in tabView.tabViewItems.enumerated() {
            guard let page = item.view else { continue }
            lines.append("  page[\(index)] \(item.label) frame = \(rect(page.frame))")
        }

        tabView.selectTabViewItem(at: 0)
        content.layoutSubtreeIfNeeded()
        if let page = tabView.selectedTabViewItem?.view {
            let inside = tabView.contentRect.contains(page.frame)
            lines.append("  选中页落在 contentRect 内：\(inside ? "是" : "否 ← 重叠")")
        }
        return lines
    }

    /// Verifies the layout numerically: every control must sit inside its page and no two controls
    /// may overlap. All three tab items are walked — a screenshot only ever shows one page, and the
    /// clipped footer this check exists for was on the last one.
    func layoutReport() -> (lines: [String], ok: Bool) {
        if window == nil { buildWindow() }
        guard let window, let tabView else { return (["窗口未构建"], false) }

        // Check the window as the user would see it: same selections, same hidden rows.
        reloadValues()

        var lines: [String] = []
        var ok = true

        tabView.layoutSubtreeIfNeeded()
        let resizable = window.styleMask.contains(.resizable)

        lines.append("DockPeek 设置窗口布局校验")
        lines.append("窗口内容尺寸：\(Self.points(window.contentView?.frame.width ?? 0)) x \(Self.points(window.contentView?.frame.height ?? 0))")
        lines.append("标签页内容区：\(Self.points(tabView.contentRect.width)) x \(Self.points(tabView.contentRect.height))")
        lines.append("标签页数量：\(tabView.numberOfTabViewItems)")
        lines.append("可缩放：\(resizable ? "是 ❌" : "否 ✅")")
        if resizable { ok = false }
        lines.append("")

        for (index, item) in tabView.tabViewItems.enumerated() {
            selectPage(index)
            let area = tabView.contentRect
            lines.append("第 \(index + 1) 页「\(item.label)」")

            guard let container = item.view else {
                lines.append("  ❌ 该页没有内容视图")
                ok = false
                continue
            }

            // Give the page exactly the room the window provides, then measure against that.
            container.frame = NSRect(origin: area.origin, size: area.size)
            container.layoutSubtreeIfNeeded()

            let required = index < forms.count ? forms[index].requiredHeight - (index == 1 && Preferences.transition != .fade ? Metrics.rowHeight * 2 : 0) : container.frame.height
            lines.append("  容器 \(Self.points(container.frame.width)) x \(Self.points(container.frame.height))，内容需要高度 \(Self.points(required))")
            if required > container.frame.height + 0.5 {
                lines.append("  ❌ 内容高于标签页可视区域，底部会被裁掉")
                ok = false
            }

            var pageOK = true
            let controls = interactiveControls(in: container)
            lines.append("  可交互控件（\(controls.count) 个）：")

            for control in controls {
                let validationContainer = control.enclosingScrollView?.documentView ?? container
                let frame = validationContainer.convert(control.bounds, from: control)
                let hidden = control.isHiddenOrHasHiddenAncestor
                lines.append("    " + describe(control) + (hidden ? "  [隐藏]" : ""))
                if frame.minX < validationContainer.bounds.minX - 0.5 || frame.maxX > validationContainer.bounds.maxX + 0.5 {
                    lines.append("      ❌ 水平方向超出内容区域")
                    pageOK = false
                }
                if frame.minY < validationContainer.bounds.minY - 0.5 || frame.maxY > validationContainer.bounds.maxY + 0.5 {
                    lines.append("      ❌ 垂直方向超出内容区域（会被窗口裁掉）")
                    pageOK = false
                }
            }

            // Rows deliberately overlap their hidden alternatives after collapsing the page.
            // Verify visible controls; the suite checks each transition mode separately.
            var overlaps = 0
            if controls.count > 1 {
                for i in 0..<controls.count {
                    for j in (i + 1)..<controls.count {
                        guard !controls[i].isHiddenOrHasHiddenAncestor, !controls[j].isHiddenOrHasHiddenAncestor else { continue }
                        let shared = container.convert(controls[i].bounds, from: controls[i]).intersection(container.convert(controls[j].bounds, from: controls[j]))
                        if shared.width > 2, shared.height > 2 {
                            overlaps += 1
                            lines.append("      ❌ 重叠：\(describe(controls[i])) × \(describe(controls[j]))")
                        }
                    }
                }
            }
            if overlaps > 0 { pageOK = false }

            lines.append(pageOK ? "  ✅ 控件都在页面内，互不重叠" : "  ❌ 本页布局有问题，见上面标注")
            if !pageOK { ok = false }
            lines.append("")
        }

        // Text labels are not interactive, so they are excluded from the overlap test, but they must
        // still fit inside their page: a long changelog block that runs past the bottom would be
        // silently clipped, which is exactly the kind of thing a controls-only check misses.
        lines.append("文本边界检查：")
        var textOverflow = 0
        for (index, item) in tabView.tabViewItems.enumerated() {
            guard let page = item.view else { continue }
            selectPage(index)
            page.layoutSubtreeIfNeeded()
            var lowest: CGFloat = 0
            var widest: CGFloat = 0
            for sub in page.subviews {
                lowest = max(lowest, sub.frame.maxY)
                widest = max(widest, sub.frame.maxX)
            }
            let fits = lowest <= page.bounds.height + 0.5 && widest <= page.bounds.width + 0.5
            if !fits { textOverflow += 1 }
            lines.append(String(format: "  第 %d 页「%@」最低内容 y=%.0f / 容器高 %.0f，最宽 x=%.0f / 容器宽 %.0f  %@",
                                index + 1, item.label, lowest, page.bounds.height,
                                widest, page.bounds.width, fits ? "✅" : "❌ 会被裁切"))
        }
        if textOverflow > 0 { ok = false }
        lines.append(textOverflow == 0 ? "  ✅ 没有文本被裁切" : "  ❌ 有文本会被裁切")
        lines.append("")

        selectPage(0)
        lines.append(ok
            ? "✅ 布局正常：三个页面的控件都在窗口内、互不重叠，且无文本被裁切。"
            : "❌ 布局有问题，见上面标注。")
        return (lines, ok)
    }

    /// Interactive controls anywhere below `view` (labels are deliberately excluded — a hint
    /// legitimately shares a band with the row it explains).
    private func interactiveControls(in view: NSView) -> [NSView] {
        var found: [NSView] = []
        for subview in view.subviews {
            if isInteractive(subview) { found.append(subview) }
            found.append(contentsOf: interactiveControls(in: subview))
        }
        return found
    }

    private func isInteractive(_ view: NSView) -> Bool {
        if view is ShortcutRecorderView { return true }
        if view is NSSwitch || view is NSPopUpButton || view is NSButton || view is NSColorWell { return true }
        if let field = view as? NSTextField { return field.isEditable }
        return false
    }

    private func describe(_ view: NSView) -> String {
        let kind: String
        var text: String
        switch view {
        case let popup as NSPopUpButton:
            kind = "NSPopUpButton"
            text = popup.titleOfSelectedItem ?? ""
        case let control as NSSwitch:
            kind = "NSSwitch"
            text = (control.accessibilityLabel() ?? "") + (control.state == .on ? "（开启）" : "（关闭）")
        case let button as NSButton:
            kind = "NSButton"
            text = button.title
            if button.identifier == SettingsForm.checkboxIdentifier {
                text += button.state == .on ? "（已勾选）" : "（未勾选）"
            }
        case let recorder as ShortcutRecorderView:
            kind = "ShortcutRecorderView"
            text = recorder.isRecording ? ShortcutRecorderView.recordingTitle : recorder.shortcut.displayName
        case let field as NSTextField:
            kind = "NSTextField"
            text = field.stringValue
        default:
            kind = String(describing: type(of: view))
            text = ""
        }
        let name = text.isEmpty ? kind : "\(kind)「\(text.prefix(24))」"
        let disabled = (view as? NSControl)?.isEnabled == false ? "（已停用）" : ""
        let frame = view.frame
        return "\(name)\(disabled) x=\(Self.points(frame.minX)) y=\(Self.points(frame.minY)) w=\(Self.points(frame.width)) h=\(Self.points(frame.height))"
    }

    private static func points(_ value: CGFloat) -> String {
        String(Int(value.rounded()))
    }
}
