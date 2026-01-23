import Foundation
import os.log

public enum Logger {
    public static var enabled: Bool = false

    private static let osLog = OSLog(subsystem: "com.windowkit", category: "WindowKit")

    public enum Level: String {
        case debug = "DEBUG"
        case info = "INFO"
        case warning = "WARN"
        case error = "ERROR"
    }

    public static func log(_ level: Level, _ message: String, details: String? = nil) {
        guard enabled else { return }

        let timestamp = ISO8601DateFormatter().string(from: Date())
        var output = "[\(timestamp)] [\(level.rawValue)] \(message)"
        if let details = details {
            output += " | \(details)"
        }

        switch level {
        case .debug:
            os_log(.debug, log: osLog, "%{public}@", output)
        case .info:
            os_log(.info, log: osLog, "%{public}@", output)
        case .warning:
            os_log(.default, log: osLog, "%{public}@", output)
        case .error:
            os_log(.error, log: osLog, "%{public}@", output)
        }

        print("[WindowKit] \(output)")
    }

    public static func debug(_ message: String, details: String? = nil) {
        log(.debug, message, details: details)
    }

    public static func info(_ message: String, details: String? = nil) {
        log(.info, message, details: details)
    }

    public static func warning(_ message: String, details: String? = nil) {
        log(.warning, message, details: details)
    }

    public static func error(_ message: String, details: String? = nil) {
        log(.error, message, details: details)
    }

    /// Logs a warning if block execution exceeds threshold
    @discardableResult
    public static func measureSlow<T>(
        _ operation: String,
        thresholdMs: Double = 50,
        details: String? = nil,
        block: () -> T
    ) -> T {
        guard enabled else { return block() }

        let start = CFAbsoluteTimeGetCurrent()
        let result = block()
        let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000

        if elapsed > thresholdMs {
            warning("\(operation) took \(String(format: "%.1f", elapsed))ms", details: details)
        }

        return result
    }

    @discardableResult
    public static func measureSlowAsync<T>(
        _ operation: String,
        thresholdMs: Double = 50,
        details: String? = nil,
        block: () async -> T
    ) async -> T {
        guard enabled else { return await block() }

        let start = CFAbsoluteTimeGetCurrent()
        let result = await block()
        let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000

        if elapsed > thresholdMs {
            warning("\(operation) took \(String(format: "%.1f", elapsed))ms", details: details)
        }

        return result
    }
}
