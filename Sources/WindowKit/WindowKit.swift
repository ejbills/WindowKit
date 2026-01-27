import Cocoa
import Combine

@MainActor
public final class WindowKit {
    public static let shared = WindowKit()

    public var logging: Bool {
        get { Logger.enabled }
        set { Logger.enabled = newValue }
    }

    /// Custom log handler. When set, logs are forwarded here instead of default output.
    /// Parameters: (level: String, message: String, details: String?)
    public var logHandler: ((String, String, String?) -> Void)? {
        get { nil }
        set {
            if let handler = newValue {
                Logger.logHandler = { level, message, details in
                    handler(level.rawValue, message, details)
                }
            } else {
                Logger.logHandler = nil
            }
        }
    }

    public var events: AnyPublisher<WindowEvent, Never> { tracker.events }

    public var permissionStatus: PermissionState {
        SystemPermissions.shared.currentState
    }

    private let tracker: WindowTracker

    private init() {
        self.tracker = WindowTracker()
    }

    public func allWindows() async -> [CapturedWindow] {
        tracker.repository.readAllCache()
    }

    public func windows(bundleID: String) async -> [CapturedWindow] {
        tracker.repository.readCache(bundleID: bundleID).sorted {
            $0.lastInteractionTime > $1.lastInteractionTime
        }
    }

    public func windows(application: NSRunningApplication) async -> [CapturedWindow] {
        await windows(pid: application.processIdentifier)
    }

    public func windows(pid: pid_t) async -> [CapturedWindow] {
        tracker.repository.readCache(forPID: pid).sorted {
            $0.lastInteractionTime > $1.lastInteractionTime
        }
    }

    public func window(withID id: CGWindowID) async -> CapturedWindow? {
        tracker.repository.readCache(windowID: id)
    }

    public func refresh(application: NSRunningApplication) async {
        await tracker.refreshApplication(application)
    }

    public func refreshAll() async {
        await tracker.performFullScan()
    }

    public func beginTracking() {
        tracker.startTracking()
    }

    public func endTracking() {
        tracker.stopTracking()
    }
}
