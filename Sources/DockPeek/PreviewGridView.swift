import AppKit

/// Manual-flow grid of thumbnail tiles inside the preview panel.
///
/// The grid sizes itself from the windows being shown rather than assuming a fixed box, so the
/// panel can hug its content exactly. Tiles within one preview share a size (rows stay tidy), but
/// each thumbnail keeps its own window's aspect ratio inside its tile.
@MainActor
final class PreviewGridView: NSView {

    /// Everything the grid needs to lay one preview out.
    ///
    /// Kept free of actor isolation so it can be computed (and unit-tested) from anywhere.
    struct Layout {
        var tileSize: CGSize
        var columns: Int
        var spacing: CGFloat
        var margin: CGFloat
        /// Set in title-only mode where the panel height is not simply rows × tile height.
        var contentHeightOverride: CGFloat?
        /// False when the user switched thumbnails off; tiles then render as title rows.
        var showsPictures: Bool

        static let spacing: CGFloat = 6
        static let margin: CGFloat = 6
        static let minTileWidth: CGFloat = 130
        static let absoluteMaxColumns = 4
        /// Keep the whole panel well inside the display.
        static let maxScreenWidthFraction: CGFloat = 0.70
        static let maxScreenHeightFraction: CGFloat = 0.58

        /// Computes a layout that hugs the windows being previewed.
        ///
        /// Sizing is driven by the windows themselves: each is fitted into the available box at its
        /// own aspect ratio, and the resulting content size becomes the panel size. The cap comes
        /// from the user's size preference and must stay in step with `ThumbnailProvider` — a tile
        /// allowed to be larger than the capture shows the shortfall as empty glass around the picture.
        ///
        /// When thumbnails are switched off the tiles collapse to title-only rows: the window list
        /// stays usable for choosing a window even with no pictures.
        static func make(
            for targets: [WindowTarget],
            size: Preferences.PanelSize = Preferences.panelSize,
            titleSize: Preferences.TitleSize = Preferences.titleSize,
            screen: NSRect? = nil,
            /// Hard ceiling on the whole panel, in points. Defaults to a fraction of the screen, but
            /// callers that already know the real available area (the panel does) should pass it so
            /// the panel can never be larger than the space it has to appear in.
            maxContentSize: CGSize? = nil
        ) -> Layout {
            let count = max(targets.count, 1)
            let visible = screen ?? NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            let widthLimit = max(32, min(visible.width * maxScreenWidthFraction, maxContentSize?.width ?? .greatestFiniteMagnitude))
            let heightLimit = max(32, min(visible.height * maxScreenHeightFraction, maxContentSize?.height ?? .greatestFiniteMagnitude))
            let caption = !size.showsThumbnails && !titleSize.showsTitle
                ? Preferences.TitleSize.medium.captionHeight : titleSize.captionHeight
            guard let cap = size.maxTileSize else {
                return Layout(tileSize: CGSize(width: min(360, widthLimit - margin * 2), height: max(caption + 8, 25)),
                              columns: 1, spacing: spacing, margin: margin,
                              contentHeightOverride: heightLimit, showsPictures: false)
            }
            let columns = max(1, min(count, absoluteMaxColumns,
                                    Int((widthLimit - margin * 2 + spacing) / (minTileWidth + spacing))))
            let biggest = targets.max { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }
            let window = biggest?.bounds.size ?? CGSize(width: 16, height: 10)
            let aspect = min(max(window.height / max(window.width, 1), 0.25), 1.6)
            let maxWidth = min(cap.width, (widthLimit - margin * 2 - CGFloat(columns - 1) * spacing) / CGFloat(columns))
            let imageHeight = min(maxWidth * aspect, cap.height)
            let imageWidth = imageHeight / aspect
            return Layout(tileSize: CGSize(width: floor(imageWidth), height: floor(imageHeight) + caption),
                          columns: columns, spacing: spacing, margin: margin,
                          contentHeightOverride: heightLimit, showsPictures: true)
        }
    }

    private(set) var tiles: [WindowTileView] = []
    private var currentLayout: Layout?
    /// Size of the content this grid was told to display. Set by `setTiles`, never recomputed during
    /// layout — see `layout()` for why that matters.
    private(set) var intrinsicSize: CGSize = .zero

    override var isFlipped: Bool { true }

    /// Trace of every `setTiles` call, so the self test can prove who cleared the grid.
    private(set) var setTilesTrace: [String] = []

    func setTiles(_ newTiles: [WindowTileView], layout: Layout) {
        setTilesTrace.append("setTiles(\(newTiles.count))")
        if setTilesTrace.count > 20 { setTilesTrace.removeFirst() }

        tiles.forEach { $0.removeFromSuperview() }
        tiles = newTiles
        currentLayout = layout
        tiles.forEach { addSubview($0) }
        intrinsicSize = layout.contentSize(tileCount: newTiles.count)
        needsLayout = true
        invalidateIntrinsicContentSize()
    }

    override func layout() {
        super.layout()
        // Deliberately does NOT resize the grid.
        //
        // An earlier version recomputed its own size here and pushed it back to the superview.
        // Changing a view's frame invalidates its superview's layout, so the grid and its container
        // re-triggered each other and the frame oscillated between two sizes: the panel was laid out
        // at one width while the rows were arranged for another, and content spilled outside the
        // panel to be clipped. The panel owns the size; the grid only places its tiles.
        arrangeTiles()
    }

    /// The size the panel assigned to this grid. The grid never proposes a different one.
    override var intrinsicContentSize: NSSize {
        intrinsicSize == .zero
            ? NSSize(width: 220, height: 120)
            : NSSize(width: intrinsicSize.width, height: intrinsicSize.height)
    }

    @discardableResult
    private func arrangeTiles() -> CGSize {
        guard !tiles.isEmpty, let currentLayout else { return .zero }

        let count = tiles.count
        let columns = max(1, min(currentLayout.columns, count))
        let rows = Int(ceil(Double(count) / Double(columns)))
        let tile = currentLayout.tileSize
        let contentWidth = CGFloat(columns) * tile.width + CGFloat(columns - 1) * currentLayout.spacing

        for (index, tileView) in tiles.enumerated() {
            let row = index / columns
            let column = index % columns
            // Centre a partially filled final row.
            let itemsInRow = (row == rows - 1) ? count - row * columns : columns
            let rowWidth = CGFloat(itemsInRow) * tile.width + CGFloat(itemsInRow - 1) * currentLayout.spacing
            let rowOffset = (contentWidth - rowWidth) / 2

            tileView.frame = NSRect(
                x: currentLayout.margin + rowOffset + CGFloat(column) * (tile.width + currentLayout.spacing),
                y: currentLayout.margin + CGFloat(row) * (tile.height + currentLayout.spacing),
                width: tile.width,
                height: tile.height
            )
        }

        return intrinsicSize
    }
}

extension PreviewGridView.Layout {
    func viewportSize(tileCount: Int) -> CGSize {
        let natural = contentSize(tileCount: tileCount)
        return CGSize(width: natural.width, height: min(natural.height, contentHeightOverride ?? natural.height))
    }

    /// The document size this layout needs for a given number of tiles.
    ///
    /// Computed once from the layout parameters and then frozen. Recomputing it during layout is what
    /// let the grid and its container fight over the size.
    func contentSize(tileCount: Int) -> CGSize {
        guard tileCount > 0 else { return .zero }
        let columns = max(1, min(self.columns, tileCount))
        let rows = Int(ceil(Double(tileCount) / Double(columns)))
        let tile = tileSize
        let contentWidth = CGFloat(columns) * tile.width + CGFloat(columns - 1) * spacing
        let naturalHeight = CGFloat(rows) * tile.height + CGFloat(rows - 1) * spacing
        return CGSize(
            width: contentWidth + margin * 2,
            height: naturalHeight + margin * 2
        )
    }
}
