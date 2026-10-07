import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

/// Single-window capture via ScreenCaptureKit (macOS 14+), with asynchronous capture and retries after transient failures.
actor CaptureService {

    static let shared = CaptureService()

    /// `SCWindow` lookups are cached: `SCShareableContent` is by far the most expensive part of a capture.
    private var windowCache: [CGWindowID: SCWindow] = [:]

    private let timeout: Duration = .seconds(4)

    // MARK: - ScreenCaptureKit


    /// Captures one window and downscales it, or throws so the caller can fall back.
    func captureWithScreenCaptureKit(
        windowID: CGWindowID,
        bounds: CGRect,
        maxSize: CGSize,
        scale: CGFloat
    ) async throws -> NSImage {
        guard Permissions.hasScreenRecording else { throw CaptureError.permissionMissing }

        let target = WindowCapture.fittedSize(for: bounds.size, maxSize: maxSize)

        do {
            let image = try await withTimeout(timeout) { [self] in
                let window = try await self.window(for: windowID)
                let filter = SCContentFilter(desktopIndependentWindow: window)

                let configuration = SCStreamConfiguration()
                configuration.width = max(2, Int(target.width * scale))
                configuration.height = max(2, Int(target.height * scale))
                configuration.showsCursor = false
                configuration.capturesAudio = false
                configuration.ignoreShadowsSingleWindow = true
                configuration.ignoreGlobalClipSingleWindow = true
                // Sheets and popovers belong to the window; include them in its thumbnail.
                // (`includeChildWindows` only exists from macOS 14.2.)
                if #available(macOS 14.2, *) {
                    configuration.includeChildWindows = true
                }

                return try await SCScreenshotManager.captureImage(
                    contentFilter: filter,
                    configuration: configuration
                )
            }
            windowCache[windowID] = nil // window lists change often; keep the cache tiny
            return NSImage(cgImage: image, size: target)
        } catch {
            windowCache[windowID] = nil
            Log.debug("ScreenCaptureKit capture failed for window \(windowID): \(error)")
            if error is CaptureError { throw error }
            throw CaptureError.captureFailed
        }
    }

    private func window(for windowID: CGWindowID) async throws -> SCWindow {
        if let cached = windowCache[windowID] { return cached }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let match = content.windows.first(where: { $0.windowID == windowID }) else {
            throw CaptureError.windowNotFound
        }
        windowCache = [windowID: match]
        return match
    }

    struct DiscoveredWindow: Sendable {
        let id: CGWindowID
        let title: String
        let bounds: CGRect
        let onScreen: Bool
    }
    func discoverWindows(pid: pid_t) async throws -> [DiscoveredWindow] {
        let content = try await withTimeout(timeout) {
            try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        }
        return content.windows.filter { $0.owningApplication?.processID == pid }.map {
            DiscoveredWindow(id: $0.windowID, title: $0.title ?? "", bounds: $0.frame, onScreen: $0.isOnScreen)
        }
    }

    // MARK: - Timeout helper

    private func withTimeout<T: Sendable>(
        _ duration: Duration,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: duration)
                throw CaptureError.timedOut
            }
            guard let result = try await group.next() else { throw CaptureError.timedOut }
            group.cancelAll()
            return result
        }
    }
}

enum CaptureError: Error, CustomStringConvertible {
    case permissionMissing
    case windowNotFound
    case timedOut
    case captureFailed

    var description: String {
        switch self {
        case .permissionMissing: return "screen recording permission missing"
        case .windowNotFound: return "window not found in shareable content"
        case .timedOut: return "capture timed out"
        case .captureFailed: return "capture failed"
        }
    }
}
