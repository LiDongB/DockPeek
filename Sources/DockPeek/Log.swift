import Foundation
import os

/// Unified-logging wrapper. View output with:
///     log stream --predicate 'subsystem == "com.dockpeek.app"' --level info
enum Log {
    private static let logger = Logger(subsystem: "com.dockpeek.app", category: "main")

    static func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
    }

    static func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
    }

    static func debug(_ message: String) {
        logger.debug("\(message, privacy: .public)")
    }
}
