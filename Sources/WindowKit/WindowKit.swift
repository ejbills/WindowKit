import Cocoa
import Combine
import Observation

@Observable
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

    public var headless: Bool = false {
        didSet { tracker.headless = headless }
    }

    public var previewCacheDuration: TimeInterval {
        get { tracker.repository.previewCacheDuration }
        set { tracker.repository.previewCacheDuration = newValue }
    }

    public var events: AnyPublisher<WindowEvent, Never> { tracker.events }

    public var processEvents: AnyPublisher<ProcessEvent, Never> { tracker.processEvents }

    public private(set) var frontmostApplication: NSRunningApplication?
    public private(set) var trackedApplications: [NSRunningApplication] = []
    public private(set) var launchingApplications: [NSRunningApplication] = []

    public var permissionStatus: PermissionState {
        SystemPermissions.shared.currentState
    }

    private let tracker: WindowTracker
    private var cancellables = Set<AnyCancellable>()

    private init() {
        self.tracker = WindowTracker()
        self.frontmostApplication = tracker.frontmostApplication

        tracker.processEvents
            .sink { [weak self] event in
                guard let self else { return }
                switch event {
                case .applicationWillLaunch(let app):
                    self.launchingApplications.append(app)

                case .applicationLaunched:
                    break

                case .applicationTerminated(let pid):
                    self.launchingApplications.removeAll { $0.processIdentifier == pid }
                    self.trackedApplications = self.tracker.repository.trackedApplications()

                case .applicationActivated:
                    self.frontmostApplication = self.tracker.frontmostApplication

                case .spaceChanged:
                    break
                }
            }
            .store(in: &cancellables)

        tracker.events
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                guard let self else { return }
                switch event {
                case .windowAppeared(let window):
                    self.launchingApplications.removeAll { $0.processIdentifier == window.ownerPID }
                    self.trackedApplications = self.tracker.repository.trackedApplications()
                case .windowDisappeared:
                    self.trackedApplications = self.tracker.repository.trackedApplications()
                default:
                    break
                }
            }
            .store(in: &cancellables)
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
