import AppKit
import CoreGraphics
import Foundation

/// A minimal bounded LRU of decoded thumbnails.
///
/// The previous implementation used `NSCache` and was purged every time the preview closed, which
/// is exactly why every hover had to re-capture: nothing survived. This keeps images around for the
/// life of the process while still enforcing a hard ceiling, so the memory budget cannot creep.
@MainActor
final class ThumbnailCache {

    private var storage: [String: NSImage] = [:]
    /// Most-recently-used last.
    private var order: [String] = []
    /// When each entry was captured, used to expire pictures that no longer reflect the window.
    private var storedAt: [String: Date] = [:]
    private let capacity: Int

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    var count: Int { storage.count }

    /// Approximate decoded size, for the memory readout in the menu.
    var approximateBytes: Int {
        storage.values.reduce(0) { total, image in
            total + Self.decodedBytes(image)
        }
    }

    static func decodedBytes(_ image: NSImage) -> Int {
        if let bitmap = image.representations.compactMap({ $0 as? NSBitmapImageRep }).first {
            return bitmap.bytesPerRow * bitmap.pixelsHigh
        }
        if let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            return cg.bytesPerRow * cg.height
        }
        return Int(image.size.width * image.size.height * 4)
    }

    func trim(toBytes limit: Int) {
        while approximateBytes > limit, storage.count > 1, let oldest = order.first {
            removeImage(forKey: oldest)
        }
    }

    func image(forKey key: String) -> NSImage? {
        guard let image = storage[key] else { return nil }
        touch(key)
        return image
    }

    /// In-memory store; entries never outlive the process, so a shutdown or relaunch always starts
    /// from a clean slate. There is deliberately no on-disk persistence.
    func store(_ image: NSImage, forKey key: String) {
        storage[key] = image
        storedAt[key] = Date()
        touch(key)
        while storage.count > capacity, let oldest = order.first {
            order.removeFirst()
            storage.removeValue(forKey: oldest)
            storedAt.removeValue(forKey: oldest)
        }
    }

    /// The moment an entry was captured, so callers can judge how stale it is.
    func captureTime(forKey key: String) -> Date? { storedAt[key] }

    /// Drops entries older than `age`; used to refresh windows whose contents changed while their
    /// size (and therefore their cache key) stayed the same.
    @discardableResult
    func expire(olderThan age: TimeInterval) -> Int {
        guard age > 0 else { return 0 }
        let cutoff = Date().addingTimeInterval(-age)
        let stale = storedAt.filter { $0.value < cutoff }.map(\.key)
        for key in stale {
            storage.removeValue(forKey: key)
            storedAt.removeValue(forKey: key)
            if let index = order.firstIndex(of: key) { order.remove(at: index) }
        }
        return stale.count
    }

    func removeAll() {
        storage.removeAll()
        order.removeAll()
        storedAt.removeAll()
    }

    /// Keys matching a predicate, for bulk invalidation.
    func keys(where predicate: (String) -> Bool) -> [String] {
        storage.keys.filter(predicate)
    }

    func removeImage(forKey key: String) {
        storage.removeValue(forKey: key)
        storedAt.removeValue(forKey: key)
        if let index = order.firstIndex(of: key) { order.remove(at: index) }
    }

    /// Keeps the newest `keep` entries; used as a safety valve when the process grows too large.
    func trim(keeping keep: Int) {
        guard storage.count > keep else { return }
        let survivors = Array(order.suffix(keep))
        storage = storage.filter { survivors.contains($0.key) }
        storedAt = storedAt.filter { survivors.contains($0.key) }
        order = survivors
    }

    private func touch(_ key: String) {
        if let index = order.firstIndex(of: key) { order.remove(at: index) }
        order.append(key)
    }
}

/// Memory-only cache: keep the last good frame until a replacement succeeds or the app quits.
@MainActor
final class ThumbnailProvider {
    static let shared = ThumbnailProvider()
    private let cache = ThumbnailCache(capacity: 120)
    private let now: () -> Date
    private let captureOverride: ((WindowTarget, CGSize) async -> NSImage?)?
    private var capturedAt: [String: Date] = [:]
    private var configurations: [String: String] = [:]
    private struct Pending {
        let token: UUID
        let task: Task<NSImage?, Never>
    }
    private var inFlight: [String: Pending] = [:]
    private var epoch = 0
    private var appEpoch: [pid_t: Int] = [:]

    init(now: @escaping () -> Date = Date.init,
         capture: ((WindowTarget, CGSize) async -> NSImage?)? = nil) {
        self.now = now
        captureOverride = capture
    }

    var cachedCount: Int { cache.count }
    var cachedBytes: Int { cache.approximateBytes }
    private var configuration: String { "\(Preferences.panelSize.rawValue):\(Preferences.thumbnailClarity.rawValue)" }

    func cached(for target: WindowTarget) -> NSImage? { cache.image(forKey: target.cacheKey) }

    func needsRefresh(_ target: WindowTarget) -> Bool {
        guard target.windowID != 0, Preferences.panelSize.showsThumbnails else { return false }
        if target.isMinimized { return cached(for: target) == nil }
        return cached(for: target) == nil || configurations[target.identity] != configuration
            || now().timeIntervalSince(capturedAt[target.identity] ?? .distantPast) > 20
    }

    func thumbnail(for target: WindowTarget) async -> NSImage? {
        guard Preferences.panelSize.showsThumbnails else { return nil }
        guard needsRefresh(target) else { return cached(for: target) }
        if let pending = inFlight[target.identity] { return await pending.task.value ?? cached(for: target) }
        guard let base = Preferences.panelSize.captureSize else { return nil }
        let maxSize = Preferences.thumbnailClarity == .original ? target.bounds.size
            : CGSize(width: base.width * Preferences.thumbnailClarity.captureScale,
                     height: base.height * Preferences.thumbnailClarity.captureScale)
        let token = UUID()
        let generation = epoch
        let pidGeneration = appEpoch[target.pid, default: 0]
        let setting = configuration
        let task = Task<NSImage?, Never> { [captureOverride] in
            if let captureOverride { return await captureOverride(target, maxSize) }
            return await Self.capture(target: target, maxSize: maxSize)
        }
        inFlight[target.identity] = Pending(token: token, task: task)
        let image = await task.value
        guard generation == epoch, pidGeneration == appEpoch[target.pid, default: 0],
              inFlight[target.identity]?.token == token else { return nil }
        inFlight[target.identity] = nil
        if let image, !task.isCancelled, configuration == setting {
            cache.store(image, forKey: target.cacheKey)
            capturedAt[target.identity] = now()
            configurations[target.identity] = setting
            cache.trim(toBytes: 96 * 1024 * 1024)
            let liveKeys = Set(cache.keys(where: { _ in true }))
            capturedAt = capturedAt.filter { liveKeys.contains("win-" + $0.key) }
            configurations = configurations.filter { liveKeys.contains("win-" + $0.key) }
        }
        // A failed refresh must never erase the last useful screenshot.
        return image ?? cached(for: target)
    }

    /// Force a fresh capture while retaining the old frame if capture fails.
    func requestRefresh(_ target: WindowTarget) {
        inFlight.removeValue(forKey: target.identity)?.task.cancel()
        capturedAt[target.identity] = nil
        configurations[target.identity] = nil
    }

    func invalidateImmediately(identity: String) {
        inFlight.removeValue(forKey: identity)?.task.cancel()
        cache.removeImage(forKey: "win-\(identity)")
        capturedAt[identity] = nil
        configurations[identity] = nil
    }

    func invalidateApp(pid: pid_t) {
        appEpoch[pid, default: 0] += 1
        let prefix = "\(pid)|"
        let identities = Set(capturedAt.keys.filter { $0.hasPrefix(prefix) })
            .union(inFlight.keys.filter { $0.hasPrefix(prefix) })
        identities.forEach { invalidateImmediately(identity: $0) }
        for key in cache.keys(where: { $0.hasPrefix("win-" + prefix) }) { cache.removeImage(forKey: key) }
        WindowActions.forget(pid: pid)
    }

    func invalidate(identities: Set<String>) { identities.forEach { invalidateImmediately(identity: $0) } }
    func purge() {
        epoch += 1
        inFlight.values.forEach { $0.task.cancel() }
        inFlight.removeAll()
        cache.removeAll()
        capturedAt.removeAll()
        configurations.removeAll()
    }
    func testInsert(image: NSImage, key: String) { cache.store(image, forKey: key) }
    func testRemove(key: String) { cache.removeImage(forKey: key) }
    func testAge(forKey key: String) -> TimeInterval? { cache.captureTime(forKey: key).map { now().timeIntervalSince($0) } }

    private static func capture(target: WindowTarget, maxSize: CGSize) async -> NSImage? {
        guard Permissions.hasScreenRecording else { return nil }
        let center = CoordinateConversion.cocoaRect(fromQuartz: target.bounds).center
        let scale = NSScreen.screens.first(where: { $0.frame.contains(center) })?.backingScaleFactor ?? 2
        do {
            return try await CaptureService.shared.captureWithScreenCaptureKit(
                windowID: target.windowID, bounds: target.bounds, maxSize: maxSize, scale: scale)
        } catch {
            Log.debug("Capture failed for window \(target.windowID): \(error)")
            // Legacy capture is only needed by supported systems before macOS 15.
            if #available(macOS 15, *) { return nil }
            return await legacyCapture(target: target, maxSize: maxSize, scale: scale)
        }
    }

    private static func legacyCapture(target: WindowTarget, maxSize: CGSize, scale: CGFloat) async -> NSImage? {
        let id = target.windowID
        let bounds = target.bounds
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: WindowCapture.legacyCapture(windowID: id, bounds: bounds, maxSize: maxSize, scale: scale))
            }
        }
    }
}

/// Low-level capture primitives shared by both paths.
enum WindowCapture {

    /// Deprecated CoreGraphics single-window capture. Kept as the fallback path.
    ///
    /// `CGWindowListCreateImage` is `deprecated=14.0, obsoleted=15.0` in the SDK, so calling it
    /// directly becomes a hard compile error the moment the deployment target reaches macOS 15 —
    /// even though the symbol is still present and working at runtime. Resolving it through
    /// `dlsym` keeps the fallback available without pinning the whole package to an older target.
    static func legacyCapture(windowID: CGWindowID, bounds: CGRect, maxSize: CGSize, scale: CGFloat) -> NSImage? {
        typealias CreateImage = @convention(c) (CGRect, CGWindowListOption, CGWindowID, CGWindowImageOption) -> Unmanaged<CGImage>?

        guard let handle = dlopen(nil, RTLD_LAZY),
              let symbol = dlsym(handle, "CGWindowListCreateImage") else {
            Log.info("CGWindowListCreateImage not available at runtime; no fallback capture")
            return nil
        }

        let createImage = unsafeBitCast(symbol, to: CreateImage.self)
        guard let image = createImage(.null, .optionIncludingWindow, windowID, [.boundsIgnoreFraming, .bestResolution])?
            .takeRetainedValue() else {
            return nil
        }
        return downsample(image, windowSize: bounds.size, maxSize: maxSize, scale: scale)
    }

    /// Scales a capture down to fit `maxSize`, preserving the window's own aspect ratio.
    static func downsample(_ image: CGImage, windowSize: CGSize, maxSize: CGSize, scale: CGFloat) -> NSImage? {
        let target = fittedSize(for: windowSize, maxSize: maxSize)
        let pixelWidth = max(1, Int(target.width * scale))
        let pixelHeight = max(1, Int(target.height * scale))

        guard let context = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        guard let scaled = context.makeImage() else { return nil }
        return NSImage(cgImage: scaled, size: target)
    }

    /// Largest size with the window's aspect ratio that fits inside `maxSize`.
    static func fittedSize(for windowSize: CGSize, maxSize: CGSize) -> CGSize {
        guard windowSize.width > 1, windowSize.height > 1 else { return maxSize }
        let ratio = min(maxSize.width / windowSize.width, maxSize.height / windowSize.height, 1)
        return CGSize(
            width: max(1, (windowSize.width * ratio).rounded()),
            height: max(1, (windowSize.height * ratio).rounded())
        )
    }
}
