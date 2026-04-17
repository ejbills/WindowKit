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

    private var windowVersion: UInt = 0
    private var badgeVersion: UInt = 0

    public var windows: [CapturedWindow] {
        _ = windowVersion
        return repository.readCache(forPID: pid).sorted {
            $0.lastInteractionTime > $1.lastInteractionTime
        }
    }

    public var count: Int {
        _ = windowVersion
        return repository.readCache(forPID: pid).count
    }

    public var hasWindows: Bool {
        _ = windowVersion
        return !repository.readCache(forPID: pid).isEmpty
    }

    public var allMinimized: Bool {
        _ = windowVersion
        let cached = repository.readCache(forPID: pid)
        return !cached.isEmpty && cached.allSatisfy(\.isMinimized)
    }

    public var allHidden: Bool {
        _ = windowVersion
        let cached = repository.readCache(forPID: pid)
        return !cached.isEmpty && cached.allSatisfy(\.isOwnerHidden)
    }

    public var isMinimized: Bool { allMinimized }
    public var isHidden: Bool { allHidden }

    public var visibleCount: Int {
        _ = windowVersion
        return repository.readCache(forPID: pid).filter {
            !$0.isMinimized && !$0.isOwnerHidden
        }.count
    }

    public var badgeLabel: String? {
        _ = badgeVersion
        return badgeStore.badge(forPID: pid)
    }

    public var hasBadge: Bool {
        _ = badgeVersion
        return badgeStore.badge(forPID: pid) != nil
    }

    public var badgeCount: Int? {
        _ = badgeVersion
        guard let label = badgeStore.badge(forPID: pid) else { return nil }
        return Int(label)
    }

    /// Set to `nil` to disable state-change animation.
    @ObservationIgnored public var animation: Animation? = .default

    init(pid: pid_t, repository: WindowRepository, badgeStore: DockBadgeStore) {
        self.pid = pid
        self.repository = repository
        self.badgeStore = badgeStore
    }

    func invalidate() {
        if let animation {
            withAnimation(animation) { windowVersion &+= 1 }
        } else {
            windowVersion &+= 1
        }
    }

    func invalidateBadge() {
        badgeVersion &+= 1
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

    /// Custom log handler — replaces default output. Parameters: (level, message, details).
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

    private static let launchTimeoutSeconds: TimeInterval = 30

    private let tracker: WindowTracker
    private let badgeStore = DockBadgeStore()
    private var cancellables = Set<AnyCancellable>()
    @ObservationIgnored private var appStates: [pid_t: AppWindowState] = [:]
    private var badgePollTimer: Timer?
    private let badgeQueue = DispatchQueue(label: "com.windowkit.badge", qos: .userInitiated)
    private var badgeRefreshInFlight = false
    private var wakeCooldownWork: DispatchWorkItem?
    private var launchTimeoutWork: [pid_t: DispatchWorkItem] = [:]

    private init() {
        self.tracker = WindowTracker()
        self.frontmostApplication = tracker.frontmostApplication

        tracker.processEvents
            .sink { [weak self] event in
                guard let self else { return }
                switch event {
                case .applicationWillLaunch(let app):
                    self.launchingApplications.append(app)
                    self.scheduleLaunchTimeout(for: app.processIdentifier)

                case .applicationLaunched:
                    self.trackedApplications = self.tracker.repository.trackedApplications()
                    self.badgeStore.invalidateCache()

                case .applicationTerminated(let pid):
                    self.cancelLaunchTimeout(for: pid)
                    self.launchingApplications.removeAll { $0.processIdentifier == pid }
                    self.trackedApplications.removeAll { $0.processIdentifier == pid }
                    self.badgeStore.removeBadge(forPID: pid)
                    self.badgeStore.invalidateCache()
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
                    self.cancelLaunchTimeout(for: window.ownerPID)
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
                    self.refreshAllBadgesAndInvalidate()
                }
            }
            .store(in: &cancellables)

        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .sink { [weak self] _ in
                self?.handleWake()
            }
            .store(in: &cancellables)
    }

    private func scheduleLaunchTimeout(for pid: pid_t) {
        launchTimeoutWork[pid]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.launchTimeoutWork[pid] = nil
            self.launchingApplications.removeAll { $0.processIdentifier == pid }
        }
        launchTimeoutWork[pid] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.launchTimeoutSeconds, execute: work)
    }

    private func cancelLaunchTimeout(for pid: pid_t) {
        launchTimeoutWork[pid]?.cancel()
        launchTimeoutWork[pid] = nil
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

    public func closeWindow(_ window: CapturedWindow) async throws {
        try await tracker.closeWindow(window)
    }

    /// Quits the application owning `window`, then polls until the process is
    /// confirmed dead before purging state. If the app ignores the quit after
    /// `timeout`, state is left intact.
    public func quitApplication(owning window: CapturedWindow, force: Bool = false, timeout: TimeInterval = 5) {
        let pid = window.ownerPID
        guard let app = window.ownerApplication else { return }

        if force {
            app.forceTerminate()
        } else {
            app.terminate()
        }

        Task { [weak self] in
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                try? await Task.sleep(nanoseconds: 200_000_000)
                if app.isTerminated {
                    await MainActor.run { [weak self] in
                        self?.purgeTerminatedApp(pid: pid)
                    }
                    return
                }
            }
            // App didn't quit — leave state intact
            Logger.debug("App ignored quit request", details: "pid=\(pid)")
        }
    }

    /// Removes all state for a PID that is confirmed dead.
    private func purgeTerminatedApp(pid: pid_t) {
        cancelLaunchTimeout(for: pid)
        launchingApplications.removeAll { $0.processIdentifier == pid }
        trackedApplications.removeAll { $0.processIdentifier == pid }
        badgeStore.removeBadge(forPID: pid)
        badgeStore.invalidateCache()
        appStates[pid]?.invalidate()
        appStates.removeValue(forKey: pid)

        let windows = tracker.repository.readCache(forPID: pid)
        tracker.repository.removeAll(forPID: pid)
        for window in windows {
            invalidateAppState(forWindowID: window.id)
        }
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
        stopBadgePolling()
        tracker.stopTracking()
    }

    /// Starts a 1-second polling timer for dock badge state.
    public func startBadgePolling() {
        stopBadgePolling()
        Logger.debug("Badge polling started")
        badgePollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshAllBadges()
            }
        }
    }

    public func stopBadgePolling() {
        let wasActive = badgePollTimer != nil
        wakeCooldownWork?.cancel()
        wakeCooldownWork = nil
        badgePollTimer?.invalidate()
        badgePollTimer = nil
        if wasActive {
            Logger.debug("Badge polling stopped")
        }
    }

    private func handleWake() {
        guard badgePollTimer != nil else { return }
        stopBadgePolling()
        badgeStore.invalidateCache()

        // Wait for AX canary to pass before resuming badge polling.
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            Task.detached(priority: .utility) {
                var delay: TimeInterval = 1.0
                var totalWaited: TimeInterval = 0
                let maxWait: TimeInterval = 15.0

                while totalWaited < maxWait {
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    totalWaited += delay

                    if isAccessibilityReady() {
                        Logger.info("Badge polling: AX canary passed after \(String(format: "%.1f", totalWaited))s")
                        break
                    }

                    delay = min(delay * 2, maxWait - totalWaited)
                }

                // Rebuild cache before resuming so first poll doesn't report spurious changes
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    let pids = self.trackedApplications.map(\.processIdentifier)
                    self.badgeQueue.async { [badgeStore = self.badgeStore] in
                        badgeStore.invalidateCache()
                        _ = badgeStore.refreshAll(pids: pids)
                        Task { @MainActor [weak self] in
                            self?.startBadgePolling()
                        }
                    }
                }
            }
        }
        wakeCooldownWork = work
        DispatchQueue.main.async(execute: work)
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
        badgeQueue.async { [badgeStore, weak self] in
            let changed = badgeStore.refresh(forPID: pid)
            if changed {
                Logger.debug("Badge changed", details: "pid=\(pid)")
                Task { @MainActor [weak self] in
                    self?.appStates[pid]?.invalidate()
                }
            }
        }
    }

    private func refreshAllBadges() {
        guard !badgeRefreshInFlight else {
            Logger.debug("Badge poll skipped, refresh in flight")
            return
        }
        badgeRefreshInFlight = true

        var allPIDs = trackedApplications.map(\.processIdentifier)
        for pid in appStates.keys where !allPIDs.contains(pid) {
            allPIDs.append(pid)
        }

        let pids = allPIDs
        badgeQueue.async { [badgeStore, weak self] in
            let changed = badgeStore.refreshAll(pids: pids)
            if !changed.isEmpty {
                Logger.debug("Badge poll found changes", details: "pids=\(changed)")
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.badgeRefreshInFlight = false
                for pid in changed {
                    self.appStates[pid]?.invalidate()
                }
            }
        }
    }

    /// Refreshes all badges and invalidates all states unconditionally.
    private func refreshAllBadgesAndInvalidate() {
        let trackedPIDs = trackedApplications.map(\.processIdentifier)
        let statePIDs = Array(appStates.keys)

        Logger.debug("Badge full refresh triggered", details: "tracked=\(trackedPIDs.count), states=\(statePIDs.count)")
        badgeQueue.async { [badgeStore, weak self] in
            var allPIDs = Set(trackedPIDs)
            for pid in statePIDs {
                allPIDs.insert(pid)
            }

            for pid in allPIDs {
                badgeStore.refresh(forPID: pid)
            }

            Task { @MainActor [weak self] in
                guard let self else { return }
                for pid in allPIDs {
                    self.appStates[pid]?.invalidate()
                }
            }
        }
    }

}
