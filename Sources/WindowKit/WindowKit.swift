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

    public var permissionStatus: PermissionState {
        SystemPermissions.shared.currentState
    }

    public var ignoredPIDs: Set<pid_t> {
        get { tracker.repository.ignoredPIDs }
        set { tracker.repository.ignoredPIDs = newValue }
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

    private static let launchTimeoutSeconds: TimeInterval = 30

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
    private var isTrackingActive = false
    private let badgeStore = DockBadgeStore()
    private var cancellables = Set<AnyCancellable>()
    @ObservationIgnored private var appStates: [pid_t: AppWindowState] = [:]
    @ObservationIgnored private var badgeStates: [AppBadgeLookup: AppBadgeState] = [:]
    private var badgePollTimer: Timer?
    private let badgeQueue = DispatchQueue(label: "com.windowkit.badge", qos: .userInitiated)
    private var badgeRefreshInFlight = false
    private var badgeTrackingGeneration: UInt = 0
    private var shouldResumeBadgePollingAfterWake = false
    private var launchTimeoutWork: [pid_t: DispatchWorkItem] = [:]

    private init() {
        self.tracker = WindowTracker()
        self.frontmostApplication = tracker.frontmostApplication

        tracker.processEvents
            .sink { [weak self] event in
                guard let self else { return }
                switch event {
                case .applicationWillLaunch(let app):
                    let pid = app.processIdentifier
                    guard !self.launchingApplications.contains(where: { $0.processIdentifier == pid }) else { break }
                    self.launchingApplications.append(app)
                    self.scheduleLaunchTimeout(for: pid)

                case .applicationLaunched(let app):
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
                    self.refreshTrackedApplicationsFromRepository()
                    self.refreshWindowedApplicationPIDs()
                    self.invalidateAppState(forPID: window.ownerPID)
                case .windowDisappeared(let id):
                    self.refreshTrackedApplicationsFromRepository()
                    self.refreshWindowedApplicationPIDs()
                    self.invalidateAppState(forWindowID: id)
                case .windowChanged(let window):
                    self.invalidateAppState(forPID: window.ownerPID)
                case .previewCaptured(let id, _):
                    self.invalidateAppState(forWindowID: id)
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

    private func refreshTrackedApplicationsFromRepository() {
        let applications = tracker.repository.trackedApplications()
            .map { (app: $0, pid: $0.processIdentifier) }
            .sorted { $0.pid < $1.pid }

        let pids = applications.map(\.pid)
        let currentPIDs = trackedApplications.map(\.processIdentifier)
        guard pids != currentPIDs else { return }

        trackedApplications = applications.map(\.app)
    }

    private func removeTrackedApplication(pid: pid_t) {
        guard trackedApplications.contains(where: { $0.processIdentifier == pid }) else { return }
        trackedApplications.removeAll { $0.processIdentifier == pid }
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
    }

    public func endTracking() {
        isTrackingActive = false
        stopBadgePolling()
        orphanedWindowTracker.stop()
        dockHandoffTracker.stop()
        appSwitcherObserver.stop()
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
        let pids = trackedApplications.map(\.processIdentifier)
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
        windowState(for: application.processIdentifier)
    }

    public func badgeState(forBundleIdentifier bundleIdentifier: String) -> AppBadgeState {
        let lookup = AppBadgeLookup.bundleIdentifier(bundleIdentifier)
        if let existing = badgeStates[lookup] { return existing }
        let state = AppBadgeState(bundleIdentifier: bundleIdentifier, badgeStore: badgeStore)
        badgeStates[lookup] = state
        refreshBadge(forBundleIdentifier: bundleIdentifier)
        return state
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
        let app = NSRunningApplication(processIdentifier: pid)
        let bundleIdentifier = app?.bundleIdentifier
        let bundlePath = app?.bundleURL?.standardizedFileURL.path
        badgeQueue.async { [badgeStore, weak self] in
            let changed = badgeStore.refresh(forPID: pid)
            if changed {
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

        var allPIDs = trackedApplications.map(\.processIdentifier)
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
