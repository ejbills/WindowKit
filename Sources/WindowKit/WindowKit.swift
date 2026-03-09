import Cocoa
import Combine
import Observation
import SwiftUI

@Observable
@MainActor
public final class AppWindowState {
    public let pid: pid_t
    private let repository: WindowRepository
    private let badgeStore: DockBadgeStore

    // Only tracked stored property — bumped to trigger re-evaluation
    private var version: UInt = 0

    // -- Window access (read-through to repository) --

    public var windows: [CapturedWindow] {
        _ = version
        return repository.readCache(forPID: pid).sorted {
            $0.lastInteractionTime > $1.lastInteractionTime
        }
    }

    public var count: Int {
        _ = version
        return repository.readCache(forPID: pid).count
    }

    public var hasWindows: Bool {
        _ = version
        return !repository.readCache(forPID: pid).isEmpty
    }

    // -- Convenience state --

    public var allMinimized: Bool {
        _ = version
        let cached = repository.readCache(forPID: pid)
        return !cached.isEmpty && cached.allSatisfy(\.isMinimized)
    }

    public var allHidden: Bool {
        _ = version
        let cached = repository.readCache(forPID: pid)
        return !cached.isEmpty && cached.allSatisfy(\.isOwnerHidden)
    }

    public var isMinimized: Bool { allMinimized }
    public var isHidden: Bool { allHidden }

    public var visibleCount: Int {
        _ = version
        return repository.readCache(forPID: pid).filter {
            !$0.isMinimized && !$0.isOwnerHidden
        }.count
    }

    // -- Dock badge --

    public var badgeLabel: String? {
        _ = version
        return badgeStore.badge(forPID: pid)
    }

    public var hasBadge: Bool {
        _ = version
        return badgeStore.badge(forPID: pid) != nil
    }

    /// Animation applied when state changes. Set to `nil` to disable.
    @ObservationIgnored public var animation: Animation? = .default

    init(pid: pid_t, repository: WindowRepository, badgeStore: DockBadgeStore) {
        self.pid = pid
        self.repository = repository
        self.badgeStore = badgeStore
    }

    func invalidate() {
        if let animation {
            withAnimation(animation) { version &+= 1 }
        } else {
            version &+= 1
        }
    }
}

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
        didSet {
            SystemPermissions.headless = headless
            tracker.headless = headless
        }
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

    public var ignoredPIDs: Set<pid_t> {
        get { tracker.repository.ignoredPIDs }
        set { tracker.repository.ignoredPIDs = newValue }
    }

    private let tracker: WindowTracker
    private let badgeStore = DockBadgeStore()
    private var cancellables = Set<AnyCancellable>()
    @ObservationIgnored private var appStates: [pid_t: AppWindowState] = [:]

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
                    self.trackedApplications = self.tracker.repository.trackedApplications()

                case .applicationTerminated(let pid):
                    self.launchingApplications.removeAll { $0.processIdentifier == pid }
                    self.trackedApplications.removeAll { $0.processIdentifier == pid }
                    self.badgeStore.removeBadge(forPID: pid)
                    self.appStates[pid]?.invalidate()

                case .applicationActivated:
                    self.frontmostApplication = self.tracker.frontmostApplication
                    if let pid = self.frontmostApplication?.processIdentifier {
                        self.refreshBadge(forPID: pid)
                    }

                case .applicationDeactivated(let app):
                    let pid = app.processIdentifier
                    self.refreshBadge(forPID: pid)
                    self.appStates[pid]?.invalidate()

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
                    self.invalidateAppState(forPID: window.ownerPID)
                case .windowDisappeared(let id):
                    self.trackedApplications = self.tracker.repository.trackedApplications()
                    self.invalidateAppState(forWindowID: id)
                case .windowChanged(let window):
                    self.invalidateAppState(forPID: window.ownerPID)
                case .previewCaptured(let id, _):
                    self.invalidateAppState(forWindowID: id)
                case .notificationBannerChanged:
                    self.refreshAllBadges()
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

    // MARK: - Per-App Observable State

    public func windowState(for pid: pid_t) -> AppWindowState {
        if let existing = appStates[pid] { return existing }
        let state = AppWindowState(pid: pid, repository: tracker.repository, badgeStore: badgeStore)
        appStates[pid] = state
        return state
    }

    public func windowState(for application: NSRunningApplication) -> AppWindowState {
        windowState(for: application.processIdentifier)
    }

    private func invalidateAppState(forPID pid: pid_t) {
        refreshBadge(forPID: pid)
        appStates[pid]?.invalidate()
    }

    private func invalidateAppState(forWindowID id: CGWindowID) {
        if let window = tracker.repository.readCache(windowID: id) {
            invalidateAppState(forPID: window.ownerPID)
        } else {
            for state in appStates.values {
                state.invalidate()
            }
        }
    }

    private func refreshBadge(forPID pid: pid_t) {
        badgeStore.refresh(forPID: pid)
    }

    private func refreshAllBadges() {
        var refreshed = Set<pid_t>()

        for app in trackedApplications {
            let pid = app.processIdentifier
            badgeStore.refresh(forPID: pid)
            appStates[pid]?.invalidate()
            refreshed.insert(pid)
        }

        for (pid, state) in appStates where !refreshed.contains(pid) {
            badgeStore.refresh(forPID: pid)
            state.invalidate()
        }
    }
}
