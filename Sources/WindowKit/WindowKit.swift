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
        return DockAppKey.parsedBadgeCount(from: label)
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

private enum AppBadgeLookup: Hashable, Sendable {
    case bundleIdentifier(String)
    case bundlePath(String)

    var bundleIdentifier: String? {
        switch self {
        case .bundleIdentifier(let bundleIdentifier):
            return bundleIdentifier
        case .bundlePath:
            return nil
        }
    }

    var bundleURL: URL? {
        switch self {
        case .bundleIdentifier:
            return nil
        case .bundlePath(let bundlePath):
            return URL(fileURLWithPath: bundlePath)
        }
    }

    var logDetails: String {
        switch self {
        case .bundleIdentifier(let bundleIdentifier):
            return "bundleIdentifier=\(bundleIdentifier)"
        case .bundlePath(let bundlePath):
            return "bundlePath=\(bundlePath)"
        }
    }
}

@Observable
@MainActor
public final class AppBadgeState {
    public let bundleIdentifier: String?
    public let bundleURL: URL?
    private let lookup: AppBadgeLookup
    private let badgeStore: DockBadgeStore

    private var badgeVersion: UInt = 0

    public var badgeLabel: String? {
        _ = badgeVersion
        switch lookup {
        case .bundleIdentifier(let bundleIdentifier):
            return badgeStore.badge(forBundleIdentifier: bundleIdentifier)
        case .bundlePath(let bundlePath):
            return badgeStore.badge(forBundleURL: URL(fileURLWithPath: bundlePath))
        }
    }

    public var hasBadge: Bool {
        _ = badgeVersion
        return badgeLabel != nil
    }

    public var badgeCount: Int? {
        _ = badgeVersion
        guard let label = badgeLabel else { return nil }
        return DockAppKey.parsedBadgeCount(from: label)
    }

    init(bundleIdentifier: String, badgeStore: DockBadgeStore) {
        self.lookup = .bundleIdentifier(bundleIdentifier)
        self.bundleIdentifier = bundleIdentifier
        self.bundleURL = nil
        self.badgeStore = badgeStore
    }

    init(bundleURL: URL, badgeStore: DockBadgeStore) {
        let standardizedURL = bundleURL.standardizedFileURL
        self.lookup = .bundlePath(standardizedURL.path)
        self.bundleIdentifier = Bundle(url: standardizedURL)?.bundleIdentifier
        self.bundleURL = standardizedURL
        self.badgeStore = badgeStore
    }

    func invalidate() {
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

    /// Resolution window-preview captures are taken at. `.nominal` (the default)
    /// captures at 1x point resolution — half the linear pixels of a Retina backing,
    /// so cached previews cost a quarter of the memory. `.best` captures at the
    /// window's full backing resolution.
    public var previewCaptureQuality: WindowCaptureQuality = .nominal {
        didSet {
            tracker.previewCaptureQuality = previewCaptureQuality
            orphanedWindowTracker.previewCaptureQuality = previewCaptureQuality
        }
    }

    /// Integer divisor applied to preview capture dimensions before caching
    /// (1 = keep capture resolution). Downscaled captures — and deep-color captures —
    /// are flattened to 8-bit before being cached.
    public var previewResolutionScale: Int = 1 {
        didSet {
            tracker.previewResolutionScale = previewResolutionScale
            orphanedWindowTracker.previewResolutionScale = previewResolutionScale
        }
    }

    /// Releases every cached preview whose TTL has lapsed. The repository also purges
    /// opportunistically during window churn, and the tracker sweeps on a timer while
    /// tracking is active; call this for an immediate release (e.g. on memory pressure).
    public func purgeExpiredPreviews() {
        tracker.repository.purgeExpiredPreviews()
    }

    public var events: AnyPublisher<WindowEvent, Never> { tracker.events }

    public var processEvents: AnyPublisher<ProcessEvent, Never> { tracker.processEvents }

    /// Windows about to be focused through `focusWindow`, sent before any
    /// AX work so a Space commit it starts can be prepared for.
    let focusRequests = PassthroughSubject<CGWindowID, Never>()

    public private(set) var frontmostApplication: NSRunningApplication?
    public private(set) var trackedApplications: [NSRunningApplication] = []
    public private(set) var launchingApplications: [NSRunningApplication] = []

    /// PIDs of tracked apps that currently have at least one cached window.
    /// Companion to `trackedApplications` for consumers whose membership logic
    /// depends on window presence: identity diffing alone misses an app that was
    /// tracked before its first window appeared (multi-process apps open project
    /// windows seconds after their process registers). Mutated only when the set
    /// actually changes, so observation fires exactly on presence flips.
    public private(set) var windowedApplicationPIDs: Set<pid_t> = []

    /// Every minimized window the native macOS Dock parks near Trash, sourced by
    /// observing the Dock's accessibility tree (correct even when the native Dock is
    /// hidden). Each entry carries its owner pid and a window-preview thumbnail, so
    /// consumers can filter (e.g. drop windows whose app already has a dock icon).
    /// Continuously maintained while tracking is active and
    /// `tracksOrphanedMinimizedWindows` is enabled. Observable for SwiftUI.
    public private(set) var orphanedMinimizedWindows: [DockMinimizedWindow] = []

    /// Opt-in toggle for the minimized-dock-window subsystem (default `true`).
    /// Cheap when idle — a single Dock accessibility poll on a background queue.
    public var tracksOrphanedMinimizedWindows: Bool = true {
        didSet {
            guard oldValue != tracksOrphanedMinimizedWindows, isTrackingActive else { return }
            if tracksOrphanedMinimizedWindows {
                orphanedWindowTracker.start()
            } else {
                orphanedWindowTracker.stop()
            }
        }
    }

    /// Handoff activities the native macOS Dock advertises (`AXHandoffDockItem`),
    /// sourced from the same Dock accessibility observer as the minimized-window
    /// set. Each entry carries the advertising app's name and the source device's
    /// status label. Observable for SwiftUI.
    public private(set) var handoffItems: [DockHandoffItem] = []

    /// Opt-in toggle for the Handoff subsystem (default `true`).
    public var tracksHandoff: Bool = true {
        didSet {
            guard oldValue != tracksHandoff, isTrackingActive else { return }
            if tracksHandoff {
                dockHandoffTracker.start()
            } else {
                dockHandoffTracker.stop()
            }
        }
    }

    /// The item currently highlighted in the macOS system Cmd+Tab switcher, or `nil` when
    /// the switcher is closed. Pure observation of the Dock's accessibility tree — WindowKit
    /// does not intercept the keypress. Observable for SwiftUI. See also `processSwitcherEvents`.
    public private(set) var processSwitcherSelection: AppSwitcherSelection?

    /// Stream of Cmd+Tab switcher lifecycle events (appeared / selection changed / dismissed).
    public var processSwitcherEvents: AnyPublisher<AppSwitcherEvent, Never> {
        appSwitcherObserver.eventPublisher
    }

    /// Nudges the Cmd+Tab observer to look for the switcher now. Call when the host app
    /// detects a ⌘-Tab keydown: some systems' Dock never delivers the app-level AX
    /// creation notifications that normally trigger discovery (seen on macOS 26.5), so
    /// without this nudge the switcher is never found there. Briefly rescans until the
    /// switcher list appears, then its element-level notifications take over. No-op when
    /// switcher tracking is disabled or inactive.
    public func probeProcessSwitcher() {
        guard tracksProcessSwitcher else { return }
        appSwitcherObserver.probe()
    }

    public func isLaunching(_ app: NSRunningApplication) -> Bool {
        let pid = app.processIdentifier
        return launchingApplications.contains { $0.processIdentifier == pid }
    }

    /// Ends a running switcher discovery probe early; call on ⌘ release.
    public func cancelProcessSwitcherProbe() {
        guard tracksProcessSwitcher else { return }
        appSwitcherObserver.cancelProbe()
    }

    /// Opt-in toggle for Cmd+Tab switcher observation (default `true`).
    public var tracksProcessSwitcher: Bool = true {
        didSet {
            guard oldValue != tracksProcessSwitcher, isTrackingActive else { return }
            if tracksProcessSwitcher {
                appSwitcherObserver.start()
            } else {
                appSwitcherObserver.stop()
            }
        }
    }

    /// Windows that just started minimizing on their own (yellow button, Cmd+M, a title-bar
    /// double-click), published on the main thread as the native Dock begins the animation,
    /// ~0.5s before the owner app reports the minimize. Minimizes WindowKit performs itself
    /// go to `transitionDelegate` instead. Requires `tracksMinimizeTransitions`.
    public var minimizeStarts: AnyPublisher<CapturedWindow, Never> {
        minimizeStartSubject.eraseToAnyPublisher()
    }

    /// Opt-in toggle for `minimizeStarts` (default `false`).
    public var tracksMinimizeTransitions: Bool = false {
        didSet {
            guard oldValue != tracksMinimizeTransitions, isTrackingActive else { return }
            if tracksMinimizeTransitions {
                minimizeTransitionTracker.start()
            } else {
                minimizeTransitionTracker.stop()
            }
        }
    }

    /// Told about the minimizes and restores WindowKit performs, before and after each,
    /// so a host can animate them.
    @ObservationIgnored public weak var transitionDelegate: (any WindowTransitionDelegate)?

    public var permissionStatus: PermissionState {
        SystemPermissions.shared.currentState
    }

    public var ignoredPIDs: Set<pid_t> {
        get { tracker.repository.ignoredPIDs }
        set { tracker.repository.ignoredPIDs = newValue }
    }

    /// Bundle identifiers of apps that must never be touched through the
    /// accessibility API: no AX observers are registered, no window discovery
    /// runs, and no AX attributes are read for them. An excluded app still
    /// appears in `trackedApplications` while running, but always with zero
    /// windows. Changing the set takes effect immediately: newly excluded
    /// running apps have their watchers detached and cached windows purged;
    /// newly un-excluded apps are rewatched and rediscovered.
    public var excludedBundleIDs: Set<String> {
        get { tracker.excludedBundleIDs }
        set { tracker.setExcludedBundleIDs(newValue) }
    }

    /// Enables WindowKit's dock-badge refresh work, including event-driven refreshes and polling.
    public var badgeTrackingEnabled: Bool = true {
        didSet {
            guard oldValue != badgeTrackingEnabled else { return }
            badgeTrackingGeneration &+= 1
            if badgeTrackingEnabled {
                refreshAllBadges()
            } else {
                stopBadgePolling()
                clearBadgesAfterPendingRefreshes(generation: badgeTrackingGeneration)
            }
        }
    }

    nonisolated private static let launchTimeoutSeconds: TimeInterval = 30

    /// Grace window after `isFinishedLaunching` flips for a first window to appear
    /// before a windowless app (agents, menu-bar helpers, terminal tools) stops
    /// being reported as launching.
    private static let postLaunchWindowGraceSeconds: TimeInterval = 3

    /// How often dock badge state is polled while badge polling is active.
    /// Clamped to at least 1 second; changing it reschedules a running poll.
    public var badgePollInterval: TimeInterval = 5 {
        didSet {
            guard badgePollInterval != oldValue, badgePollTimer != nil else { return }
            startBadgePolling()
        }
    }

    private let tracker: WindowTracker
    private let orphanedWindowTracker = OrphanedWindowTracker()
    private let dockHandoffTracker = DockHandoffTracker()
    private let appSwitcherObserver = AppSwitcherObserver()
    private let minimizeTransitionTracker = MinimizeTransitionTracker()
    @ObservationIgnored private let minimizeStartSubject = PassthroughSubject<CapturedWindow, Never>()
    /// Windows WindowKit is minimizing itself, with when the minimize was requested. Their
    /// Dock item is expected and is not republished on `minimizeStarts`.
    @ObservationIgnored private var ownMinimizes: [CGWindowID: Date] = [:]
    /// Windows recently matched to a Dock item, so a burst of same-titled items (Minimize
    /// All) maps to distinct windows.
    @ObservationIgnored private var matchedMinimizeStarts: [CGWindowID: Date] = [:]
    private var isTrackingActive = false
    private nonisolated static let sharedBadgeStore = DockBadgeStore()
    private let badgeStore = WindowKit.sharedBadgeStore
    private var cancellables = Set<AnyCancellable>()
    @ObservationIgnored private var appStates: [pid_t: AppWindowState] = [:]
    /// PIDs parallel to `trackedApplications`; reading `processIdentifier` on an exiting app is a synchronous LaunchServices fetch.
    @ObservationIgnored private var trackedApplicationPIDs: [pid_t] = []
    @ObservationIgnored private var trackedPIDsByInstance: [ObjectIdentifier: pid_t] = [:]
    @ObservationIgnored private var pendingResolutionPIDs: [pid_t]?
    @ObservationIgnored private var resolutionGeneration: UInt64 = 0
    private let resolutionQueue = DispatchQueue(label: "com.windowkit.tracked-app-resolution", qos: .userInitiated)
    @ObservationIgnored private var badgeStates: [AppBadgeLookup: AppBadgeState] = [:]
    private var badgePollTimer: Timer?
    private let badgeQueue = DispatchQueue(label: "com.windowkit.badge", qos: .userInitiated)
    private var badgeRefreshInFlight = false
    private var badgeTrackingGeneration: UInt = 0
    private var shouldResumeBadgePollingAfterWake = false
    private var launchTimeoutWork: [pid_t: DispatchWorkItem] = [:]
    private var lastTrackedRepositoryPIDs: [pid_t] = []

    private var pendingTrackedRefresh = false
    private var pendingPIDInvalidations: Set<pid_t> = []
    private var pendingWindowInvalidations: Set<CGWindowID> = []
    private var bookkeepingFlushScheduled = false

    private init() {
        self.tracker = WindowTracker()
        self.frontmostApplication = tracker.frontmostApplication
        orphanedWindowTracker.isExcluded = { [repository = tracker.repository] pid in
            repository.isExcludedOrIgnored(pid)
        }

        tracker.processEvents
            .sink { [weak self] event in
                guard let self else { return }
                switch event {
                case .applicationWillLaunch(let app):
                    let pid = app.processIdentifier
                    guard !self.launchingApplications.contains(where: { $0.processIdentifier == pid }) else { break }
                    self.launchingApplications.append(app)
                    self.scheduleLaunchTimeout(for: pid)
                    self.tracker.repository.registerPID(pid)
                    self.refreshTrackedApplicationsFromRepository()

                case .applicationLaunched(let app):
                    let launchedPID = app.processIdentifier
                    if self.launchingApplications.contains(where: { $0.processIdentifier == launchedPID }) {
                        self.scheduleLaunchTimeout(for: launchedPID, after: Self.postLaunchWindowGraceSeconds)
                    }
                    self.tracker.repository.registerPID(app.processIdentifier)
                    self.refreshTrackedApplicationsFromRepository()
                    self.badgeStore.invalidateCache()
                    self.refreshBadge(forPID: app.processIdentifier)

                case .applicationTerminated(let pid):
                    self.cancelLaunchTimeout(for: pid)
                    self.launchingApplications.removeAll { $0.processIdentifier == pid }
                    self.removeTrackedApplication(pid: pid)
                    self.refreshWindowedApplicationPIDs()
                    self.badgeStore.removeBadge(forPID: pid)
                    self.badgeStore.invalidateCache()
                    self.appStates[pid]?.invalidateBadge()
                    self.appStates[pid]?.invalidate()
                    self.appStates.removeValue(forKey: pid)
                    self.refreshAllBadges()

                case .applicationActivated:
                    self.frontmostApplication = self.tracker.frontmostApplication
                    if let pid = self.frontmostApplication.flatMap(self.processIdentifier(of:)) {
                        self.refreshBadge(forPID: pid)
                    }

                case .applicationDeactivated(let app):
                    guard let pid = self.processIdentifier(of: app) else { break }
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
                    if self.launchingApplications.contains(where: { $0.processIdentifier == window.ownerPID }) {
                        self.launchingApplications.removeAll { $0.processIdentifier == window.ownerPID }
                    }
                    self.pendingTrackedRefresh = true
                    self.pendingPIDInvalidations.insert(window.ownerPID)
                    self.scheduleBookkeepingFlush()
                case .windowDisappeared(let id):
                    self.pendingTrackedRefresh = true
                    self.pendingWindowInvalidations.insert(id)
                    self.scheduleBookkeepingFlush()
                case .windowChanged(let window):
                    self.pendingTrackedRefresh = true
                    self.pendingPIDInvalidations.insert(window.ownerPID)
                    self.scheduleBookkeepingFlush()
                case .windowActivityDetected:
                    break
                case .previewCaptured(let id, _):
                    self.pendingWindowInvalidations.insert(id)
                    self.scheduleBookkeepingFlush()
                case .notificationBannerChanged:
                    self.refreshAllBadges()
                case .systemWoke:
                    self.pauseBadgePollingForWake()
                case .wakeRecoveryCompleted:
                    self.resumeBadgePollingAfterWake()
                }
            }
            .store(in: &cancellables)

        orphanedWindowTracker.windowsPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] windows in
                self?.orphanedMinimizedWindows = windows
            }
            .store(in: &cancellables)

        dockHandoffTracker.itemsPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] items in
                self?.handoffItems = items
            }
            .store(in: &cancellables)

        minimizeTransitionTracker.titlesPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] title in
                self?.minimizeStarted(title: title)
            }
            .store(in: &cancellables)

        appSwitcherObserver.selectionPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] selection in
                self?.processSwitcherSelection = selection
            }
            .store(in: &cancellables)
    }

    private func refreshWindowedApplicationPIDs() {
        let pids = tracker.repository.windowedPIDs()
        guard pids != windowedApplicationPIDs else { return }
        windowedApplicationPIDs = pids
    }

    /// Coalesces bursts of `tracker.events` (e.g. ~1000 window events on a Space
    /// switch) into a single pass of tracked-application resolution and app-state
    /// invalidation per runloop turn, instead of repeating that work per event.
    private func scheduleBookkeepingFlush() {
        guard !bookkeepingFlushScheduled else { return }
        bookkeepingFlushScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.flushEventBookkeeping()
        }
    }

    private func flushEventBookkeeping() {
        bookkeepingFlushScheduled = false

        if pendingTrackedRefresh {
            pendingTrackedRefresh = false
            refreshTrackedApplicationsFromRepository()
            refreshWindowedApplicationPIDs()
        }

        var pidsToInvalidate = pendingPIDInvalidations
        pendingPIDInvalidations.removeAll()

        let windowIDs = pendingWindowInvalidations
        pendingWindowInvalidations.removeAll()
        for id in windowIDs {
            if let window = tracker.repository.readCache(windowID: id) {
                pidsToInvalidate.insert(window.ownerPID)
            } else {
                for state in appStates.values {
                    state.invalidate()
                }
            }
        }

        for pid in pidsToInvalidate {
            invalidateAppState(forPID: pid)
        }
    }

    /// Publishes the repository's PIDs as `trackedApplications`, reusing
    /// already-published instances. The PID-list guard latches only when every
    /// live PID resolved to a `.regular` app; otherwise the next refresh retries.
    /// Resolution runs on `resolutionQueue` because every `NSRunningApplication`
    /// state read is a synchronous LaunchServices fetch that stalls while an app exits;
    /// a result superseded by a newer refresh or a removal is dropped. Published
    /// instances are only liveness-checked by pid: a background fetch holds the
    /// instance's lock, which main-thread readers of the same instance then wait on.
    private func refreshTrackedApplicationsFromRepository() {
        let currentRepositoryPIDs = tracker.repository.trackedPIDs()
        guard currentRepositoryPIDs != lastTrackedRepositoryPIDs,
              currentRepositoryPIDs != pendingResolutionPIDs else { return }
        pendingResolutionPIDs = currentRepositoryPIDs
        resolutionGeneration &+= 1
        let generation = resolutionGeneration

        var trackedByPID: [pid_t: NSRunningApplication] = [:]
        for (app, pid) in zip(trackedApplications, trackedApplicationPIDs) { trackedByPID[pid] = app }
        let launching = launchingApplications

        resolutionQueue.async { [weak self] in
            var retained = trackedByPID
            for app in launching where retained[app.processIdentifier] == nil {
                retained[app.processIdentifier] = app
            }

            var unresolvedLivePID = false
            let applications = currentRepositoryPIDs
                .compactMap { pid -> (app: NSRunningApplication, pid: pid_t)? in
                    if let published = trackedByPID[pid] {
                        guard kill(pid, 0) == 0 || errno != ESRCH else {
                            Logger.warning("Dropped exited app from tracked applications", details: "pid=\(pid)")
                            return nil
                        }
                        return (app: published, pid: pid)
                    }
                    guard let app = retained[pid] ?? RunningApplicationResolver.application(forProcessIdentifier: pid) else {
                        if kill(pid, 0) == 0 { unresolvedLivePID = true }
                        return nil
                    }
                    guard !app.isTerminated else {
                        Logger.warning("Dropped terminated app from tracked applications", details: "pid=\(pid), bundleID=\(app.bundleIdentifier ?? "-")")
                        return nil
                    }
                    guard app.activationPolicy == .regular else {
                        if !app.isTerminated, retained[pid] == nil { unresolvedLivePID = true }
                        return nil
                    }
                    return (app: app, pid: pid)
                }

            DispatchQueue.main.async {
                guard let self else { return }
                guard generation == self.resolutionGeneration else {
                    if self.pendingResolutionPIDs == nil { self.refreshTrackedApplicationsFromRepository() }
                    return
                }
                self.pendingResolutionPIDs = nil
                self.lastTrackedRepositoryPIDs = unresolvedLivePID ? [] : currentRepositoryPIDs

                let pids = applications.map(\.pid)
                guard pids != self.trackedApplicationPIDs else { return }
                self.trackedApplications = applications.map(\.app)
                self.trackedApplicationPIDs = pids
                self.trackedPIDsByInstance = Dictionary(
                    applications.map { (ObjectIdentifier($0.app), $0.pid) },
                    uniquingKeysWith: { first, _ in first }
                )
            }
        }
    }

    private func removeTrackedApplication(pid: pid_t) {
        lastTrackedRepositoryPIDs = []
        pendingResolutionPIDs = nil
        resolutionGeneration &+= 1
        guard let index = trackedApplicationPIDs.firstIndex(of: pid) else { return }
        trackedPIDsByInstance.removeValue(forKey: ObjectIdentifier(trackedApplications[index]))
        trackedApplications.remove(at: index)
        trackedApplicationPIDs.remove(at: index)
    }

    /// The pid WindowKit resolved for `app`, matched by instance: a tracked application or one
    /// delivered in a recent activation event; nil otherwise. Reading `processIdentifier` instead
    /// is a synchronous LaunchServices fetch that stalls while any app exits.
    public func processIdentifier(of app: NSRunningApplication) -> pid_t? {
        trackedPIDsByInstance[ObjectIdentifier(app)] ?? tracker.deliveredProcessIdentifier(of: app)
    }

    private func scheduleLaunchTimeout(for pid: pid_t, after seconds: TimeInterval = WindowKit.launchTimeoutSeconds) {
        launchTimeoutWork[pid]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.launchTimeoutWork[pid] = nil
            self.launchingApplications.removeAll { $0.processIdentifier == pid }
        }
        launchTimeoutWork[pid] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
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
        if let cached = tracker.repository.readCache(windowID: id) {
            return cached
        }
        return await tracker.discovery.captureWindow(withID: id)
    }

    public func managedDisplays() throws -> [ManagedDisplay] {
        try WindowSpaces.managedDisplays()
    }

    public func currentManagedSpaceID() throws -> CGSSpaceID {
        try WindowSpaces.currentManagedSpaceID()
    }

    public func managedSpaces(for window: CapturedWindow) -> [CGSSpaceID] {
        managedSpaces(forWindowID: window.id)
    }

    public func managedSpaces(forWindowID id: CGWindowID) -> [CGSSpaceID] {
        WindowSpaces.spaces(forWindowID: id)
    }

    public func moveWindow(_ window: CapturedWindow, toManagedSpace spaceID: CGSSpaceID) throws {
        try moveWindow(withID: window.id, ownerPID: window.ownerPID, toManagedSpace: spaceID)
    }

    public func moveWindow(withID id: CGWindowID, toManagedSpace spaceID: CGSSpaceID) throws {
        try moveWindow(withID: id, ownerPID: nil, toManagedSpace: spaceID)
    }

    public func moveWindowToCurrentManagedSpace(_ window: CapturedWindow) throws {
        try moveWindow(window, toManagedSpace: currentManagedSpaceID())
    }

    public func moveWindowToCurrentManagedSpace(withID id: CGWindowID) throws {
        try moveWindow(withID: id, toManagedSpace: currentManagedSpaceID())
    }

    public func touchWindow(id: CGWindowID, pid: pid_t) {
        tracker.touchWindow(id: id, pid: pid)
        invalidateAppState(forPID: pid)
    }

    public func closeWindow(_ window: CapturedWindow) async throws {
        try await tracker.closeWindow(window)
    }

    /// Minimizes the window, updating the cache immediately rather than waiting
    /// on AX notifications (unreliable under Stage Manager).
    public func minimizeWindow(_ window: CapturedWindow) async throws {
        let transition = await beginMinimizeTransition(window)
        defer { if let transition { transitionDelegate?.windowDidMinimize(transition) } }
        try await tracker.minimizeWindow(window)
    }

    /// Restores the window, updating the cache immediately.
    public func restoreWindow(_ window: CapturedWindow) async throws {
        let transition = await beginRestoreTransition(window)
        defer { if let transition { transitionDelegate?.windowDidRestore(transition) } }
        try await tracker.restoreWindow(window)
    }

    /// Toggles the window's minimized state, updating the cache immediately.
    @discardableResult
    public func toggleMinimizeWindow(_ window: CapturedWindow) async throws -> Bool {
        if cachedWindow(window).isMinimized {
            let transition = await beginRestoreTransition(window)
            defer { if let transition { transitionDelegate?.windowDidRestore(transition) } }
            return try await tracker.toggleMinimizeWindow(window)
        }
        let transition = await beginMinimizeTransition(window)
        defer { if let transition { transitionDelegate?.windowDidMinimize(transition) } }
        return try await tracker.toggleMinimizeWindow(window)
    }

    /// Brings the window to front, reflecting its unminimize/unhide side effects
    /// in the cache immediately.
    public func focusWindow(_ window: CapturedWindow) async throws {
        focusRequests.send(window.id)
        let transition = await beginRestoreTransition(window)
        defer { if let transition { transitionDelegate?.windowDidRestore(transition) } }
        try await tracker.focusWindow(window)
    }

    // MARK: Minimize transitions

    private static let minimizeStartMatchWindow: TimeInterval = 1.5

    private func cachedWindow(_ window: CapturedWindow) -> CapturedWindow {
        tracker.repository.readCache(windowID: window.id) ?? window
    }

    /// Tells the delegate WindowKit is about to minimize `window` and records the minimize as
    /// WindowKit's own. Returns the window the delegate was told about, nil when it wasn't.
    private func beginMinimizeTransition(_ window: CapturedWindow) async -> CapturedWindow? {
        let current = cachedWindow(window)
        guard let delegate = transitionDelegate, !current.isMinimized,
              !tracker.repository.isExcludedOrIgnored(current.ownerPID)
        else { return nil }
        await delegate.windowWillMinimize(current)
        ownMinimizes[current.id] = Date()
        return current
    }

    /// Tells the delegate WindowKit is about to restore the minimized `window`. Returns the
    /// window the delegate was told about, nil when it wasn't.
    private func beginRestoreTransition(_ window: CapturedWindow) async -> CapturedWindow? {
        let current = cachedWindow(window)
        guard let delegate = transitionDelegate, current.isMinimized,
              !tracker.repository.isExcludedOrIgnored(current.ownerPID)
        else { return nil }
        await delegate.windowWillRestore(current)
        return current
    }

    /// Resolves the title of a Dock item that just appeared to the window being minimized: an
    /// unminimized cached window with that title, the frontmost app's first, then the most
    /// recently used. Never asks the owner app, whose main thread is busy in the minimize.
    private func minimizeStarted(title: String) {
        let now = Date()
        ownMinimizes = ownMinimizes.filter { now.timeIntervalSince($0.value) < Self.minimizeStartMatchWindow }
        matchedMinimizeStarts = matchedMinimizeStarts.filter { now.timeIntervalSince($0.value) < Self.minimizeStartMatchWindow }
        let candidates = tracker.repository.readAllCache().filter {
            !$0.isMinimized && ($0.title ?? "") == title && matchedMinimizeStarts[$0.id] == nil
        }
        let frontPID = frontmostApplication.flatMap(processIdentifier(of:))
        let rank = { (window: CapturedWindow) in (window.ownerPID == frontPID ? 1 : 0, window.lastInteractionTime) }
        guard let window = candidates.first(where: { ownMinimizes[$0.id] != nil })
            ?? candidates.max(by: { rank($0) < rank($1) })
        else { return }
        matchedMinimizeStarts[window.id] = now
        guard ownMinimizes.removeValue(forKey: window.id) == nil else { return }
        minimizeStartSubject.send(window)
    }

    /// Hides the window's owner application, marking all its cached windows hidden.
    public func hideWindowOwner(_ window: CapturedWindow) async throws {
        try await tracker.hideWindowOwner(window)
    }

    /// Unhides the window's owner application, marking all its cached windows visible.
    public func unhideWindowOwner(_ window: CapturedWindow) async throws {
        try await tracker.unhideWindowOwner(window)
    }

    /// Toggles the owner application's hidden state, updating the cache immediately.
    @discardableResult
    public func toggleWindowOwnerHidden(_ window: CapturedWindow) async throws -> Bool {
        try await tracker.toggleWindowOwnerHidden(window)
    }

    /// Enters fullscreen, updating the cached state immediately.
    public func enterFullScreen(_ window: CapturedWindow) async throws {
        try await tracker.enterFullScreen(window)
    }

    /// Exits fullscreen, updating the cached state immediately.
    public func exitFullScreen(_ window: CapturedWindow) async throws {
        try await tracker.exitFullScreen(window)
    }

    /// Toggles fullscreen, optimistically flipping the cached state.
    public func toggleFullScreen(_ window: CapturedWindow) async throws {
        try await tracker.toggleFullScreen(window)
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
        removeTrackedApplication(pid: pid)
        badgeStore.removeBadge(forPID: pid)
        badgeStore.invalidateCache()
        appStates[pid]?.invalidateBadge()
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

    /// Live-probes `AXMinimized` for each of the app's tracked windows and
    /// heals cached state where it disagrees, returning the reconciled
    /// windows. Use before minimize/restore decisions: Stage Manager does not
    /// reliably deliver miniaturize AX notifications, so cached flags can lag
    /// reality.
    public func reconcileMinimizedState(for application: NSRunningApplication) async -> [CapturedWindow] {
        await tracker.reconcileMinimizedState(for: application.processIdentifier)
    }

    /// Refreshes stale previews for the app's cached windows without a full AX
    /// rediscovery. Cheap enough to call per sibling process of a multi-instance
    /// bundle (one process per document window), whose caches are already kept
    /// current by AX events.
    public func refreshPreviews(application: NSRunningApplication) async {
        _ = await tracker.cachedWindowsRefreshingPreviews(for: application.processIdentifier)
    }

    /// Captures one window's thumbnail now (regardless of cache freshness), stores it, and emits `.previewCaptured`.
    public func capturePreview(windowID: CGWindowID) async -> CGImage? {
        await tracker.capturePreview(for: windowID)
    }

    /// Captures the window's thumbnail only when the cached one is missing or older than `previewCacheDuration`.
    /// Returns the fresh or newly captured image.
    public func capturePreviewIfStale(windowID: CGWindowID) async -> CGImage? {
        if let cached = tracker.repository.freshPreview(forWindowID: windowID) { return cached }
        return await tracker.capturePreview(for: windowID)
    }

    /// Window IDs whose cached preview is within `previewCacheDuration`.
    public func windowIDsWithFreshPreviews() -> Set<CGWindowID> {
        tracker.repository.windowIDsWithFreshPreviews()
    }

    public func refreshAll() async {
        await tracker.performFullScan()
    }

    public func beginTracking() {
        isTrackingActive = true
        tracker.startTracking()
        if tracksOrphanedMinimizedWindows {
            orphanedWindowTracker.start()
        }
        if tracksHandoff {
            dockHandoffTracker.start()
        }
        if tracksProcessSwitcher {
            appSwitcherObserver.start()
        }
        if tracksMinimizeTransitions {
            minimizeTransitionTracker.start()
        }
    }

    public func endTracking() {
        isTrackingActive = false
        stopBadgePolling()
        orphanedWindowTracker.stop()
        dockHandoffTracker.stop()
        appSwitcherObserver.stop()
        minimizeTransitionTracker.stop()
        tracker.stopTracking()
    }

    /// Forces an immediate rebuild of the minimized-dock-window set, bypassing the
    /// poll's change short-circuit. No-op when the subsystem is not active.
    public func refreshOrphanedMinimizedWindows() async {
        orphanedWindowTracker.refreshNow()
    }

    /// Restores a minimized dock window by pressing its native Dock item
    /// (`AXPress`) — mirroring a click on the native Dock. `id` is a
    /// `DockMinimizedWindow.id`. No-op if the window is no longer minimized.
    public func restoreOrphanedMinimizedWindow(id: String) {
        orphanedWindowTracker.restore(id: id)
    }

    /// Forces an immediate rebuild of the Handoff set. No-op when the subsystem
    /// is not active.
    public func refreshHandoffItems() async {
        dockHandoffTracker.refreshNow()
    }

    /// Resumes a Handoff activity by pressing its native Dock item (`AXPress`).
    /// `id` is a `DockHandoffItem.id`. No-op if the activity is no longer offered.
    public func activateHandoff(id: String) {
        dockHandoffTracker.activate(id: id)
    }

    /// Starts a repeating polling timer for dock badge state at `badgePollInterval`.
    public func startBadgePolling() {
        guard badgeTrackingEnabled else { return }
        stopBadgePolling()
        Logger.debug("Badge polling started")
        badgePollTimer = Timer.scheduledTimer(withTimeInterval: max(1, badgePollInterval), repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshAllBadges()
            }
        }
        refreshAllBadges()
    }

    public func stopBadgePolling() {
        stopBadgePolling(clearWakeResume: true)
    }

    private func stopBadgePolling(clearWakeResume: Bool) {
        let wasActive = badgePollTimer != nil
        if clearWakeResume {
            shouldResumeBadgePollingAfterWake = false
        }
        badgePollTimer?.invalidate()
        badgePollTimer = nil
        if wasActive {
            Logger.debug("Badge polling stopped")
        }
    }

    private func pauseBadgePollingForWake() {
        guard badgePollTimer != nil else { return }
        shouldResumeBadgePollingAfterWake = true
        stopBadgePolling(clearWakeResume: false)
        badgeStore.invalidateCache()
    }

    private func resumeBadgePollingAfterWake() {
        guard shouldResumeBadgePollingAfterWake, badgeTrackingEnabled else { return }
        shouldResumeBadgePollingAfterWake = false

        // Rebuild cache before resuming so first poll doesn't report spurious changes.
        let pids = trackedApplicationPIDs
        let badgeLookups = Array(badgeStates.keys)
        let bundleIdentifiers = badgeLookups.compactMap(\.bundleIdentifier)
        let bundleURLs = badgeLookups.compactMap(\.bundleURL)
        badgeQueue.async { [badgeStore = self.badgeStore, weak self] in
            badgeStore.invalidateCache()
            let changed = badgeStore.refreshAll(
                pids: pids,
                bundleIdentifiers: bundleIdentifiers,
                bundleURLs: bundleURLs
            )
            Task { @MainActor in
                guard let self else { return }
                guard self.badgeTrackingEnabled else { return }
                for pid in changed.pids {
                    self.appStates[pid]?.invalidateBadge()
                }
                self.invalidateBadgeStates(
                    bundleIdentifiers: changed.bundleIdentifiers,
                    bundlePaths: changed.bundlePaths
                )
                self.startBadgePolling()
            }
        }
    }

    // MARK: - Per-App Observable State

    public func windowState(for pid: pid_t) -> AppWindowState {
        if let existing = appStates[pid] { return existing }
        let state = AppWindowState(pid: pid, repository: tracker.repository, badgeStore: badgeStore)
        appStates[pid] = state
        return state
    }

    public func windowState(for application: NSRunningApplication) -> AppWindowState {
        windowState(for: processIdentifier(of: application) ?? application.processIdentifier)
    }

    public func badgeState(forBundleIdentifier bundleIdentifier: String) -> AppBadgeState {
        let lookup = AppBadgeLookup.bundleIdentifier(bundleIdentifier)
        if let existing = badgeStates[lookup] { return existing }
        let state = AppBadgeState(bundleIdentifier: bundleIdentifier, badgeStore: badgeStore)
        badgeStates[lookup] = state
        refreshBadge(forBundleIdentifier: bundleIdentifier)
        return state
    }

    /// The Dock's application tiles for a bundle, in Dock order. Separate instances of one app have one tile each.
    /// Safe off the main thread.
    public nonisolated static func dockTiles(bundleIdentifier: String) -> [AXUIElement] {
        sharedBadgeStore.dockItemElements(bundleIdentifier: bundleIdentifier)
    }

    public func badgeState(forBundleURL bundleURL: URL) -> AppBadgeState {
        let standardizedURL = bundleURL.standardizedFileURL
        let lookup = AppBadgeLookup.bundlePath(standardizedURL.path)
        if let existing = badgeStates[lookup] { return existing }
        let state = AppBadgeState(bundleURL: standardizedURL, badgeStore: badgeStore)
        badgeStates[lookup] = state
        refreshBadge(forBundleURL: standardizedURL)
        return state
    }

    private func invalidateAppState(forPID pid: pid_t) {
        refreshBadge(forPID: pid)
        appStates[pid]?.invalidate()
    }

    private func moveWindow(withID id: CGWindowID, ownerPID: pid_t?, toManagedSpace spaceID: CGSSpaceID) throws {
        try WindowSpaces.move(windowID: id, toManagedSpace: spaceID)
        if let ownerPID {
            invalidateAppState(forPID: ownerPID)
        } else {
            invalidateAppState(forWindowID: id)
        }
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

    private func clearBadgesAfterPendingRefreshes(generation: UInt) {
        badgeQueue.async { [badgeStore, weak self] in
            Task { @MainActor [weak self] in
                guard let self,
                      self.badgeTrackingGeneration == generation,
                      !self.badgeTrackingEnabled else { return }
                self.badgeRefreshInFlight = false
                let removed = badgeStore.removeAllBadges()
                for pid in removed {
                    self.appStates[pid]?.invalidateBadge()
                }
                for state in self.badgeStates.values {
                    state.invalidate()
                }
            }
        }
    }

    private func refreshBadge(forPID pid: pid_t) {
        guard badgeTrackingEnabled else { return }
        badgeQueue.async { [badgeStore, weak self] in
            let changed = badgeStore.refresh(forPID: pid)
            if changed {
                let app = NSRunningApplication(processIdentifier: pid)
                let bundleIdentifier = app?.bundleIdentifier
                let bundlePath = app?.bundleURL?.standardizedFileURL.path
                Logger.debug("Badge changed", details: "pid=\(pid)")
                Task { @MainActor [weak self] in
                    guard let self, self.badgeTrackingEnabled else { return }
                    self.appStates[pid]?.invalidateBadge()
                    if let bundleIdentifier {
                        self.badgeStates[.bundleIdentifier(bundleIdentifier)]?.invalidate()
                    }
                    if let bundlePath {
                        self.badgeStates[.bundlePath(bundlePath)]?.invalidate()
                    }
                }
            }
        }
    }

    private func refreshBadge(forBundleIdentifier bundleIdentifier: String) {
        guard badgeTrackingEnabled else { return }
        badgeQueue.async { [badgeStore, weak self] in
            let changed = badgeStore.refresh(bundleIdentifier: bundleIdentifier)
            if changed {
                Logger.debug("Badge changed", details: "bundleIdentifier=\(bundleIdentifier)")
                Task { @MainActor [weak self] in
                    guard let self, self.badgeTrackingEnabled else { return }
                    self.badgeStates[.bundleIdentifier(bundleIdentifier)]?.invalidate()
                }
            }
        }
    }

    private func refreshBadge(forBundleURL bundleURL: URL) {
        guard badgeTrackingEnabled else { return }
        let standardizedURL = bundleURL.standardizedFileURL
        let lookup = AppBadgeLookup.bundlePath(standardizedURL.path)
        badgeQueue.async { [badgeStore, weak self] in
            let changed = badgeStore.refresh(bundleURL: standardizedURL)
            if changed {
                Logger.debug("Badge changed", details: lookup.logDetails)
                Task { @MainActor [weak self] in
                    guard let self, self.badgeTrackingEnabled else { return }
                    self.badgeStates[lookup]?.invalidate()
                }
            }
        }
    }

    private func refreshAllBadges() {
        guard badgeTrackingEnabled else { return }
        guard !badgeRefreshInFlight else {
            Logger.debug("Badge poll skipped, refresh in flight")
            return
        }
        badgeRefreshInFlight = true

        var allPIDs = trackedApplicationPIDs
        for pid in appStates.keys where !allPIDs.contains(pid) {
            allPIDs.append(pid)
        }

        let pids = allPIDs
        let badgeLookups = Array(badgeStates.keys)
        let bundleIdentifiers = badgeLookups.compactMap(\.bundleIdentifier)
        let bundleURLs = badgeLookups.compactMap(\.bundleURL)
        badgeQueue.async { [badgeStore, weak self] in
            let changed = badgeStore.refreshAll(
                pids: pids,
                bundleIdentifiers: bundleIdentifiers,
                bundleURLs: bundleURLs
            )
            if !changed.isEmpty {
                Logger.debug(
                    "Badge poll found changes",
                    details: """
                    pids=\(changed.pids) bundleIdentifiers=\(changed.bundleIdentifiers) \
                    bundlePaths=\(changed.bundlePaths)
                    """
                )
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.badgeTrackingEnabled else {
                    self.badgeRefreshInFlight = false
                    return
                }
                self.badgeRefreshInFlight = false
                for pid in changed.pids {
                    self.appStates[pid]?.invalidateBadge()
                }
                self.invalidateBadgeStates(
                    bundleIdentifiers: changed.bundleIdentifiers,
                    bundlePaths: changed.bundlePaths
                )
            }
        }
    }

    private func invalidateBadgeStates(bundleIdentifiers: Set<String>, bundlePaths: Set<String>) {
        for bundleIdentifier in bundleIdentifiers {
            badgeStates[.bundleIdentifier(bundleIdentifier)]?.invalidate()
        }
        for bundlePath in bundlePaths {
            badgeStates[.bundlePath(bundlePath)]?.invalidate()
        }
    }

}
