import Cocoa
import Combine

@MainActor
public final class WindowKit {
    public static let shared = WindowKit()

    public var logging: Bool {
        get { Logger.enabled }
        set { Logger.enabled = newValue }
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
        await tracker.repository.fetchAll()
    }

    public func windows(bundleID: String) async -> [CapturedWindow] {
        await tracker.repository.fetch(bundleID: bundleID)
    }

    public func windows(application: NSRunningApplication) async -> [CapturedWindow] {
        await windows(pid: application.processIdentifier)
    }

    public func windows(pid: pid_t) async -> [CapturedWindow] {
        await tracker.repository.fetch(forPID: pid).sorted {
            $0.lastInteractionTime > $1.lastInteractionTime
        }
    }

    public func window(withID id: CGWindowID) async -> CapturedWindow? {
        await tracker.repository.fetch(windowID: id)
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
