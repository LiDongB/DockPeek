import AppKit
import CoreGraphics

/// One thumbnail cell: the window's picture on top, its title underneath, hover highlight and
/// click-to-focus.
///
/// The image deliberately keeps the *window's own* aspect ratio and is centred in the cell, so a
/// tall dialog and a wide document window can sit side by side without either being stretched or
/// padded with an opaque box. Whatever space is left over stays translucent, which is what makes
/// the window look like it is floating on glass.
@MainActor
final class WindowTileView: NSView, NSMenuDelegate {

    let windowID: CGWindowID
    var onSelect: ((NSView) -> Void)?
    var onCloseAll: (() -> Void)?
    var onMenuTracking: ((Bool) -> Void)?
    private var pressedForRelease = false

    private let imageView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let placeholderSymbol = NSImageView()
    private var trackingAreaRef: NSTrackingArea?
    private var isHovered = false
    private var isActiveWindow = false

    // Keep a readable list if both pictures and titles are switched off.
    static var captionHeight: CGFloat {
        !Preferences.panelSize.showsThumbnails && !Preferences.titleSize.showsTitle
            ? Preferences.TitleSize.medium.captionHeight : Preferences.titleSize.captionHeight
    }

    /// Corner radius shared by the cell outline and the picture, so they curve identically.
    static let tileCornerRadius: CGFloat = 8

    /// Picture frame inside the cell (excludes the caption strip).
    private var imageFrame: CGRect = .zero

    /// Same orientation as `PreviewGridView`, so tile-local coordinates grow downwards.
    override var isFlipped: Bool { true }

    // MARK: - Init

    init(target: WindowTarget, tileSize: CGSize) {
        self.windowID = target.windowID
        super.init(frame: NSRect(origin: .zero, size: tileSize))
        translatesAutoresizingMaskIntoConstraints = true
        wantsLayer = true
        setup(target: target, tileSize: tileSize)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    private func setup(target: WindowTarget, tileSize: CGSize) {
        layer?.cornerRadius = Self.tileCornerRadius
        // Barely-there cell background: enough to read as a card, translucent enough to keep the
        // glass effect visible behind the thumbnail.
        layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.06).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor(white: 1.0, alpha: 0.10).cgColor
        // The cell itself does not clip. Clipping happens on the picture so the border ring stays
        // continuous, and so nothing gets sliced into a triangle at the corners.
        layer?.masksToBounds = false

        let showsThumbnails = Preferences.panelSize.showsThumbnails
        let captionHeight = Self.captionHeight

        imageFrame = NSRect(
            x: 0,
            y: 0,
            width: tileSize.width,
            height: max(1, tileSize.height - captionHeight)
        )

        // The picture container carries the rounding and the clipping. Its corner radius matches the
        // cell's, so the outline and the picture curve identically.
        imageView.frame = imageFrame
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = Self.tileCornerRadius
        imageView.layer?.masksToBounds = true
        imageView.layer?.backgroundColor = NSColor(white: 0.35, alpha: 0.16).cgColor
        imageView.isHidden = !showsThumbnails
        addSubview(imageView)

        // Shown until the capture lands so the cell never reads as "broken".
        placeholderSymbol.image = NSImage(systemSymbolName: "macwindow", accessibilityDescription: nil)
        placeholderSymbol.contentTintColor = NSColor(white: 1.0, alpha: 0.30)
        placeholderSymbol.imageScaling = .scaleProportionallyUpOrDown
        placeholderSymbol.frame = NSRect(
            x: imageFrame.midX - imageFrame.width * 0.14,
            y: imageFrame.midY - imageFrame.height * 0.14,
            width: imageFrame.width * 0.28,
            height: imageFrame.height * 0.28
        )
        placeholderSymbol.isHidden = !showsThumbnails
        addSubview(placeholderSymbol)

        titleLabel.frame = NSRect(
            x: 5,
            y: tileSize.height - captionHeight + 1,
            width: max(1, tileSize.width - 10),
            height: max(1, captionHeight - 3)
        )
        titleLabel.stringValue = displayTitle(for: target)
        titleLabel.font = .systemFont(ofSize: Preferences.titleSize.fontSize ?? 11, weight: .medium)
        titleLabel.textColor = captionColor(isActive: target.isMain)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.alignment = .center
        titleLabel.drawsBackground = false
        titleLabel.isHidden = Preferences.panelSize.showsThumbnails && !Preferences.titleSize.showsTitle
        addSubview(titleLabel)

        layoutPicture(fallback: imageFrame.size)

        // The "current window" badge was removed on request: it covered thumbnail content and
        // added no information. Current-window *identification* still exists (it feeds the title
        // text and the initial selection); only the overlay is gone.
        isActiveWindow = target.isMain
    }

    /// Caption colour follows the effective appearance, so a light panel does not get white text.
    private func captionColor(isActive: Bool) -> NSColor {
        let base = Preferences.captionColor(for: effectiveAppearance)
        return isActive ? base : base.withAlphaComponent(0.75)
    }

    /// Re-reads the caption colour; called when the appearance or the preference changes.
    func refreshCaptionColor() {
        titleLabel.textColor = captionColor(isActive: isActiveWindow)
    }

    private func displayTitle(for target: WindowTarget) -> String {
        if !target.title.isEmpty { return target.title }
        return target.isMain ? (L10n.language == .english ? "\(target.ownerName) (Current window)" : "\(target.ownerName)（当前窗口）") : target.ownerName
    }

    // MARK: - Thumbnail

    /// Attaches a capture. `animated` fades it in so a late-arriving thumbnail does not pop.
    func setThumbnail(_ image: NSImage?, animated: Bool = false) {
        guard let image else { return }

        let animatedFade = animated && Preferences.transition == .fade && Preferences.fadeInDuration > 0

        if animatedFade {
            imageView.alphaValue = 0
            imageView.image = image
            layoutPicture(fallback: imageFrame.size)
            placeholderSymbol.isHidden = true
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Preferences.fadeInDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                imageView.animator().alphaValue = 1
            }
        } else {
            imageView.image = image
            imageView.alphaValue = 1
            layoutPicture(fallback: imageFrame.size)
            placeholderSymbol.isHidden = true
        }
    }

    /// Whether a real capture is attached (used by the self test).
    var hasThumbnail: Bool { imageView.image != nil }

    /// The picture container's frame and the size the picture is actually drawn at.
    ///
    /// This is the invariant behind the corner fix: the container must be exactly as large as the
    /// drawn picture. When it was the larger available box instead, its rounded clip left the box's
    /// corners — and the translucent wash behind them — visible around a smaller rectangle, which
    /// is what produced the white wedges.
    var testPictureGeometry: (containerFrame: CGRect, drawnSize: CGSize, availableBox: CGRect) {
        let fallback = imageFrame.size
        guard let image = imageView.image, image.size.width > 1, image.size.height > 1 else {
            return (imageView.frame, fallback, imageFrame)
        }
        let scale = min(fallback.width / image.size.width, fallback.height / image.size.height)
        let drawn = CGSize(width: (image.size.width * scale).rounded(),
                           height: (image.size.height * scale).rounded())
        return (imageView.frame, drawn, imageFrame)
    }

    /// Sizes the picture container to the image that is actually drawn.
    ///
    /// This is what fixes the corner artefacts. The picture keeps its own aspect ratio, so with
    /// proportional fitting it can be smaller than the available box for another aspect ratio. Clipping the *box*
    /// then leaves the box's rounded corners — and its translucent background — visible around a
    /// smaller rectangle, which reads as white wedges at the corners. Clipping to the drawn size
    /// means the rounding always sits exactly on the picture's own edge.
    private func layoutPicture(fallback: CGSize) {
        guard let image = imageView.image, image.size.width > 1, image.size.height > 1 else {
            imageView.frame = CGRect(origin: .zero, size: fallback)
            return
        }
        let scale = min(fallback.width / image.size.width, fallback.height / image.size.height)
        let drawn = CGSize(width: (image.size.width * scale).rounded(),
                           height: (image.size.height * scale).rounded())
        imageView.frame = CGRect(
            x: (fallback.width - drawn.width) / 2,
            y: (fallback.height - drawn.height) / 2,
            width: drawn.width,
            height: drawn.height
        )
    }

    // MARK: - Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef { removeTrackingArea(trackingAreaRef) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        layer?.borderColor = NSColor.controlAccentColor.cgColor
        layer?.borderWidth = 2
        layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.14).cgColor
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        layer?.borderColor = NSColor(white: 1.0, alpha: 0.10).cgColor
        layer?.borderWidth = 1
        layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.06).cgColor
    }

    /// The preview panel is never the key window, so clicks must be accepted explicitly.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if Preferences.selectionTrigger == .mouseDown { onSelect?(self) }
        else { pressedForRelease = true }
    }

    override func mouseUp(with event: NSEvent) {
        let pressed = pressedForRelease
        pressedForRelease = false
        guard pressed, Preferences.selectionTrigger == .mouseUp,
              bounds.contains(convert(event.locationInWindow, from: nil)),
              window?.isVisible == true,
              !isHiddenOrHasHiddenAncestor else { return }
        onSelect?(self)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.delegate = self
        let item = NSMenuItem(title: L10n.text("关闭此应用的所有窗口"),
                              action: #selector(closeAllWindows), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return menu
    }

    @objc private func closeAllWindows() { onCloseAll?() }
    func menuWillOpen(_ menu: NSMenu) { onMenuTracking?(true) }
    func menuDidClose(_ menu: NSMenu) { onMenuTracking?(false) }

    var isPressPending: Bool { pressedForRelease }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}
