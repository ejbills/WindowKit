import Cocoa
import Combine
import os

public final class WindowTracker {
    static let eventDebounceInterval: TimeInterval = 0.3

    public let repository: WindowRepository

    public var events: AnyPublisher<WindowEvent, Never> {
        eventSubject.eraseToAnyPublisher()
    }

    private let eventSubject = PassthroughSubject<WindowEvent, Never>()
    var headless: Bool = false {
        didSet { discovery.screenshotService.headless = headless }
    }

    var previewCaptureQuality: WindowCaptureQuality = .nominal {
        didSet { discovery.screenshotService.captureQuality = previewCaptureQuality }
    }

    var previewResolutionScale: Int = 1 {
        didSet { discovery.screenshotService.downsampleFactor = previewResolutionScale }
    }

    var discovery: WindowDiscovery
    private let enumerator = WindowEnumerator()

    private let processWatcher = ProcessWatcher()
    private var watcherManager: AccessibilityWatcherManager?
    private var subscriptions = Set<AnyCancellable>()

    public var processEvents: AnyPublisher<ProcessEvent, Never> { processWatcher.events }
    public var frontmostApplication: NSRunningApplication? { processWatcher.frontmostApplication }

    private let debouncedTasks = OSAllocatedUnfairLock(initialState: [String: (task: Task<Void, Never>, generation: UInt64)]())
    private let debounceGeneration = OSAllocatedUnfairLock(initialState: UInt64(0))
    private let coalescedTasks = OSAllocatedUnfairLock(initialState: [String: Task<Void, Never>]())
    private let coalescedFollowUps = OSAllocatedUnfairLock(initialState: Set<String>())
    private let pendingOperations = OSAllocatedUnfairLock(initialState: [String: [() async -> Void]]())
    private let inFlightTracks = OSAllocatedUnfairLock(initialState: [pid_t: Task<[CapturedWindow], Never>]())
    private let destroyBurstState = OSAllocatedUnfairLock(initialState: [pid_t: DestroyBurstState]())
    private let axQueue = DispatchQueue(label: "com.windowkit.ax", qos: .userInitiated)
    private var notificationCenterWatcher: AccessibilityWatcher?
    private var isTracking = false
    private var wakeObserver: NSObjectProtocol?
    private var wakeCooldownUntil: ContinuousClock.Instant?
    private var wakeRecoveryTask: Task<Void, Never>?
    private var previewPurgeTask: Task<Void, Never>?

    // Wake recovery backoff parameters
    private static let wakeInitialDelay: Duration = .seconds(1)
    private static let wakeMaxDelay: Duration = .seconds(15)
    private static let wakeBackoffMultiplier: Double = 2.0

    // AX watcher retry backoff (1s, 2s, 4s, 8s, 16s)
    private static let watchRetryInitialDelay: TimeInterval = 1.0
    private static let watchRetryMaxAttempts = 5
    private let watchRetryAttempts = OSAllocatedUnfairLock(initialState: [pid_t: Int]())

    // Rediscovery for late first windows: apps like Bambu Studio spawn a .regular
    // process whose first window can take 10+ seconds to materialize, long after
    // the single post-launch discovery ran.
    private static let lateWindowRescanDelays: [TimeInterval] = [3.0, 8.0]

    private static let spaceScanMinInterval: TimeInterval = 120
    private let spaceScanState = OSAllocatedUnfairLock(initialState: (lastScan: TimeInterval(0), trailingScheduled: false))

    // Destroy burst tapering — escalating debounce per PID
    private static let destroyMinInterval: Duration = .milliseconds(50)
    private static let destroyMaxInterval: Duration = .milliseconds(800)
    private static let destroyEscalationFactor: Double = 2.0
    private static let destroyResetThreshold: Duration = .milliseconds(1500)

    public init() {
        let repository = WindowRepository()
        self.repository = repository
        self.discovery = WindowDiscovery(
            repository: repository,
            screenshotService: ScreenshotService(),
            enumerator: WindowEnumerator()
        )
    }

    /// AX messaging timeout — lower than the 6s default to fail fast on hung apps.
    public static let axMessagingTimeout: Float = 2.0

    /// Expired previews are otherwise only released by the store-path sweep, which
    /// starves at steady state (no store calls → every expired CGImage stays resident).
    private func startPreviewPurgeLoop() {
        previewPurgeTask?.cancel()
        previewPurgeTask = Task { [weak self] in
            while !Task.isCancelled {
                let interval = max(self?.repository.previewCacheDuration
                    ?? WindowRepository.defaultPreviewCacheDuration, 30)
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled, let self else { return }
                self.repository.purgeExpiredPreviews()
            }
        }
    }

    public func startTracking() {
        guard !isTracking else { return }
        isTracking = true
        Logger.info("Starting window tracking")

        AXUIElement.systemWide().setMessagingTimeout(seconds: Self.axMessagingTimeout)

        processWatcher.events
            .sink { [weak self] event in
                Task { [weak self] in
                    await self?.handleProcessEvent(event)
                }
            }
            .store(in: &subscriptions)

        let manager = AccessibilityWatcherManager()
        watcherManager = manager

        manager.events
            .sink { [weak self] (pid, event) in
                self?.axQueue.async { [weak self] in
                    self?.handleAccessibilityEvent(event, forPID: pid)
                }
            }
            .store(in: &subscriptions)

        let apps = processWatcher.runningApplications()
        Logger.debug("Found running applications", details: "count=\(apps.count)")
        for app in apps {
            repository.registerPID(app.processIdentifier)
            manager.watch(pid: app.processIdentifier)
        }

        startNotificationCenterWatcher()
        startWakeObserver()
        startPreviewPurgeLoop()

        Task { [weak self] in
            await self?.performFullScan()
        }
    }

    public func stopTracking() {
        guard isTracking else { return }
        isTracking = false
        Logger.info("Stopping window tracking")

        wakeRecoveryTask?.cancel()
        wakeRecoveryTask = nil
        wakeCooldownUntil = nil
        previewPurgeTask?.cancel()
        previewPurgeTask = nil

        subscriptions.removeAll()
        watcherManager?.unwatchAll()
        watcherManager = nil
        notificationCenterWatcher?.stopWatching()
        notificationCenterWatcher = nil
        stopWakeObserver()

        let tasks = debouncedTasks.withLockUnchecked { tasks -> [String: (task: Task<Void, Never>, generation: UInt64)] in
            let snapshot = tasks
            tasks.removeAll()
            return snapshot
        }

        for (_, entry) in tasks {
            entry.task.cancel()
        }
        cancelCoalescedTasks()

        pendingOperations.withLockUnchecked { $0.removeAll() }
        destroyBurstState.withLockUnchecked { $0.removeAll() }
        watchRetryAttempts.withLockUnchecked { $0.removeAll() }
    }

    @discardableResult
    public func trackApplication(_ app: NSRunningApplication) async -> [CapturedWindow] {
        let pid = app.processIdentifier
        if repository.ignoredPIDs.contains(pid) { return [] }
        let appName = app.localizedName ?? "Unknown"

        let policy = app.activationPolicy
        guard policy == .regular else {
            let cached = repository.readCache(forPID: pid)
            if !cached.isEmpty {
                Logger.debug("App no longer .regular, purging", details: "pid=\(pid), name=\(appName), policy=\(policy.rawValue)")
                repository.removeAll(forPID: pid)
                for window in cached {
                    eventSubject.send(.windowDisappeared(window.id))
                }
            }
            return []
        }

        // Cancel any in-flight discovery for this PID
        repository.registerPID(pid)
        ensureWatching(pid: pid, reason: "trackApplication")
        inFlightTracks.withLockUnchecked { $0[pid]?.cancel() }

        let task = Task<[CapturedWindow], Never> {
            Logger.debug("Tracking application", details: "pid=\(pid), name=\(appName), policy=\(policy.rawValue)")

            let discoveryResult = await discovery.discoverAllWithVisibility(for: app)
            guard !Task.isCancelled else { return [] }
            let discoveredWindows = discoveryResult.windows

            let changes = repository.store(forPID: pid, windows: Set(discoveredWindows))
            emitChanges(changes)

            let beforeIDs = Set(repository.readCache(forPID: pid).map(\.id))
            repository.purify(
                forPID: pid,
                preservingWindowIDs: discoveryResult.externallyVisibleWindowIDs,
                validator: { enumerator.isValidElement($0) }
            )
            let afterIDs = Set(repository.readCache(forPID: pid).map(\.id))
            for staleID in beforeIDs.subtracting(afterIDs) {
                eventSubject.send(.windowDisappeared(staleID))
            }

            Logger.info("Application tracked", details: "pid=\(pid), name=\(appName), windows=\(afterIDs.count)")
            return discoveredWindows
        }

        inFlightTracks.withLockUnchecked { $0[pid] = task }
        let result = await task.value
        inFlightTracks.withLockUnchecked { tracks in
            // Only remove if this is still our task (not replaced by a newer one)
            if tracks[pid] == task { tracks.removeValue(forKey: pid) }
        }
        return result
    }

    public func performFullScan() async {
        Logger.info("Performing full window scan")
        let startTime = CFAbsoluteTimeGetCurrent()

        let apps = processWatcher.runningApplications()
        for app in apps {
            _ = await trackApplication(app)
        }

        let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        Logger.info("Full scan complete", details: "duration=\(String(format: "%.1f", elapsed))ms, apps=\(apps.count)")
    }

    /// Returns cached windows immediately — no discovery, no IPC.
    /// Cache is kept current by AX event handlers and focus-change discovery.
    public func cachedWindows(for pid: pid_t) -> [CapturedWindow] {
        Array(repository.readCache(forPID: pid))
    }

    /// Returns cached windows and refreshes stale previews in the background.
    /// Use this for hover/preview paths instead of full discovery.
    public func cachedWindowsRefreshingPreviews(for pid: pid_t) async -> [CapturedWindow] {
        let windows = repository.readCache(forPID: pid)
        let freshIDs = repository.windowIDsWithFreshPreviews(forPID: pid)
        let stale = windows.filter { !freshIDs.contains($0.id) }
        for window in stale {
            _ = await capturePreview(for: window.id)
        }
        return Array(repository.readCache(forPID: pid))
    }

    /// Re-reads `AXMinimized` for each cached window of `pid` and updates the
    /// repository where the live value disagrees, returning the reconciled
    /// windows. Some system configurations (notably Stage Manager) do not
    /// reliably deliver miniaturize/deminiaturize AX notifications, so the
    /// event-driven minimized state can go stale; call this before decisions
    /// that depend on the current minimized state.
    public func reconcileMinimizedState(for pid: pid_t) async -> [CapturedWindow] {
        let cached = repository.readCache(forPID: pid)
        guard !cached.isEmpty else { return cached }

        let liveByID: [CGWindowID: Bool] = await withCheckedContinuation { continuation in
            axQueue.async {
                var live = [CGWindowID: Bool]()
                for window in cached {
                    if let isMinimized = try? window.axElement.isMinimized() {
                        live[window.id] = isMinimized
                    }
                }
                continuation.resume(returning: live)
            }
        }

        let staleCount = cached.count { window in
            liveByID[window.id].map { $0 != window.isMinimized } ?? false
        }
        guard staleCount > 0 else { return cached }

        let changes = repository.modify(forPID: pid) { windows in
            windows = Set(windows.map { window in
                guard let liveValue = liveByID[window.id], liveValue != window.isMinimized else { return window }
                var updated = CapturedWindow(
                    id: window.id, title: window.title, ownerBundleID: window.ownerBundleID,
                    ownerPID: window.ownerPID, bounds: window.bounds,
                    isMinimized: liveValue, isFullscreen: window.isFullscreen,
                    isOwnerHidden: window.isOwnerHidden, isVisible: window.isVisible,
                    owningDisplayID: window.owningDisplayID, desktopSpace: window.desktopSpace,
                    lastInteractionTime: window.lastInteractionTime, creationTime: window.creationTime,
                    axElement: window.axElement, appAxElement: window.appAxElement,
                    closeButton: window.closeButton, subrole: window.subrole
                )
                updated.cachedPreview = window.cachedPreview
                updated.previewTimestamp = window.previewTimestamp
                return updated
            })
        }
        emitChanges(changes)
        Logger.debug("Reconciled minimized state", details: "pid=\(pid), corrected=\(staleCount)")
        return repository.readCache(forPID: pid)
    }

    /// Explicit refresh: rediscover and validate windows, then capture stale previews.
    public func refreshApplication(_ app: NSRunningApplication) async {
        _ = await trackApplication(app)
        _ = await cachedWindowsRefreshingPreviews(for: app.processIdentifier)
    }

    /// Closes the window and suppresses it from future discovery.
    public func closeWindow(_ window: CapturedWindow) async throws {
        try await window.close()
        repository.suppress(windowID: window.id, forPID: window.ownerPID)
        eventSubject.send(.windowDisappeared(window.id))
    }

    public func touchWindow(id: CGWindowID, pid: pid_t) {
        guard let updated = repository.touch(windowID: id, pid: pid) else { return }
        eventSubject.send(.windowChanged(updated))
    }

    /// Minimizes the window and immediately reflects the state in the cache
    /// (miniaturize notifications are not reliably delivered, e.g. under Stage Manager).
    public func minimizeWindow(_ window: CapturedWindow) async throws {
        var target = window
        try await target.minimize()
        applyCachedWindowState(windowID: window.id, pid: window.ownerPID) { $0.isMinimized = true }
    }

    /// Restores the window and immediately reflects the unminimize (and the
    /// bring-to-front's unhide side effect) in the cache.
    public func restoreWindow(_ window: CapturedWindow) async throws {
        var target = window
        try await target.restore()
        applyCachedWindowState(windowID: window.id, pid: window.ownerPID) { $0.isMinimized = false }
        applyCachedOwnerHidden(pid: window.ownerPID, hidden: false)
    }

    /// Toggles the window's minimized state and immediately reflects it in the cache.
    @discardableResult
    public func toggleMinimizeWindow(_ window: CapturedWindow) async throws -> Bool {
        var target = window
        let minimized = try await target.toggleMinimize()
        applyCachedWindowState(windowID: window.id, pid: window.ownerPID) { $0.isMinimized = minimized }
        if !minimized {
            applyCachedOwnerHidden(pid: window.ownerPID, hidden: false)
        }
        return minimized
    }

    /// Brings the window to front and immediately reflects the unminimize/unhide
    /// side effects in the cache.
    public func focusWindow(_ window: CapturedWindow) async throws {
        var target = window
        try await target.bringToFront()
        applyCachedWindowState(windowID: window.id, pid: window.ownerPID) { $0.isMinimized = false }
        applyCachedOwnerHidden(pid: window.ownerPID, hidden: false)
    }

    /// Hides the window's owner application and immediately marks all of its
    /// cached windows hidden.
    public func hideWindowOwner(_ window: CapturedWindow) async throws {
        var target = window
        try await target.hide()
        applyCachedOwnerHidden(pid: window.ownerPID, hidden: true)
    }

    /// Unhides the window's owner application and immediately marks all of its
    /// cached windows visible.
    public func unhideWindowOwner(_ window: CapturedWindow) async throws {
        var target = window
        try await target.unhide()
        applyCachedOwnerHidden(pid: window.ownerPID, hidden: false)
    }

    /// Toggles the owner application's hidden state and immediately reflects it
    /// across all of its cached windows.
    @discardableResult
    public func toggleWindowOwnerHidden(_ window: CapturedWindow) async throws -> Bool {
        var target = window
        let hidden = try await target.toggleHidden()
        applyCachedOwnerHidden(pid: window.ownerPID, hidden: hidden)
        return hidden
    }

    /// Enters fullscreen and immediately reflects the state in the cache.
    public func enterFullScreen(_ window: CapturedWindow) async throws {
        try await window.enterFullScreen()
        applyCachedWindowState(windowID: window.id, pid: window.ownerPID) { $0.isFullscreen = true }
    }

    /// Exits fullscreen and immediately reflects the state in the cache.
    public func exitFullScreen(_ window: CapturedWindow) async throws {
        try await window.exitFullScreen()
        applyCachedWindowState(windowID: window.id, pid: window.ownerPID) { $0.isFullscreen = false }
    }

    /// Toggles fullscreen and optimistically flips the cached state; discovery
    /// corrects it if the transition failed.
    public func toggleFullScreen(_ window: CapturedWindow) async throws {
        try await window.toggleFullScreen()
        let flipped = !window.isFullscreen
        applyCachedWindowState(windowID: window.id, pid: window.ownerPID) { $0.isFullscreen = flipped }
    }

    private func applyCachedWindowState(windowID: CGWindowID, pid: pid_t, _ mutate: (inout CapturedWindow) -> Void) {
        let changes = repository.modify(forPID: pid) { windows in
            guard let existing = windows.first(where: { $0.id == windowID }) else { return }
            var updated = existing
            mutate(&updated)
            windows.remove(existing)
            windows.insert(updated)
        }
        emitChanges(changes)
    }

    private func applyCachedOwnerHidden(pid: pid_t, hidden: Bool) {
        let changes = repository.modify(forPID: pid) { windows in
            windows = Set(windows.map { window in
                var updated = window
                updated.isOwnerHidden = hidden
                return updated
            })
        }
        emitChanges(changes)
    }

    public func capturePreview(for windowID: CGWindowID) async -> CGImage? {
        let screenshotService = discovery.screenshotService
        do {
            let image = try screenshotService.captureWindow(id: windowID)
            repository.storePreview(image, forWindowID: windowID)
            eventSubject.send(.previewCaptured(windowID, image))
            return image
        } catch {
            return nil
        }
    }

    public func refreshPreviews(for pid: pid_t) async {
        let windows = repository.readCache(forPID: pid)
        let freshIDs = repository.windowIDsWithFreshPreviews(forPID: pid)

        let needsCapture = windows.filter { !freshIDs.contains($0.id) }

        for window in needsCapture {
            _ = await capturePreview(for: window.id)
        }
    }

    private func handleProcessEvent(_ event: ProcessEvent) async {
        switch event {
        case .applicationWillLaunch:
            break

        case .applicationLaunched(let app):
            repository.registerPID(app.processIdentifier)
            ensureWatching(pid: app.processIdentifier, reason: "applicationLaunched")
            debounce(key: "refresh-\(app.processIdentifier)") { [weak self] in
                guard let self else { return }
                let windows = await self.trackApplication(app)
                if windows.isEmpty {
                    self.scheduleLateWindowRescans(for: app)
                }
            }

        case .applicationTerminated(let pid):
            watchRetryAttempts.withLockUnchecked { _ = $0.removeValue(forKey: pid) }
            watcherManager?.unwatch(pid: pid)
            destroyBurstState.withLockUnchecked { _ = $0.removeValue(forKey: pid) }
            let windows = repository.readCache(forPID: pid)
            repository.removeAll(forPID: pid)
            for window in windows {
                eventSubject.send(.windowDisappeared(window.id))
            }

        case .applicationActivated(let app):
            repository.registerPID(app.processIdentifier)
            ensureWatching(pid: app.processIdentifier, reason: "applicationActivated")
            touchFocusedWindow(for: app)
            debounce(key: "refresh-\(app.processIdentifier)") { [weak self] in
                _ = await self?.trackApplication(app)
            }

        case .applicationDeactivated:
            break

        case .spaceChanged:
            debounce(key: "space-change") { [weak self] in
                await self?.performSpaceChangeScan()
            }
        }
    }

    private func performSpaceChangeScan() async {
        let now = ProcessInfo.processInfo.systemUptime
        let action: (runNow: Bool, scheduleTrailing: Bool) = spaceScanState.withLockUnchecked { state in
            if now - state.lastScan >= Self.spaceScanMinInterval {
                state.lastScan = now
                return (true, false)
            }
            if state.trailingScheduled {
                return (false, false)
            }
            state.trailingScheduled = true
            return (false, true)
        }

        if action.runNow {
            await performFullScan()
            return
        }
        Logger.debug("Space-change scan rate-limited", details: "trailing=\(action.scheduleTrailing)")
        guard action.scheduleTrailing else { return }
        let delay = Self.spaceScanMinInterval - (now - spaceScanState.withLockUnchecked { $0.lastScan })
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(1, delay)))
            guard let self, self.isTracking else { return }
            self.spaceScanState.withLockUnchecked { state in
                state.trailingScheduled = false
                state.lastScan = ProcessInfo.processInfo.systemUptime
            }
            await self.performFullScan()
        }
    }

    /// One post-launch discovery is not enough for apps whose first window shows
    /// up seconds later; retry a couple of times, stopping at the first success.
    private func scheduleLateWindowRescans(for app: NSRunningApplication, delayIndex: Int = 0) {
        guard delayIndex < Self.lateWindowRescanDelays.count else { return }
        let pid = app.processIdentifier
        axQueue.asyncAfter(deadline: .now() + Self.lateWindowRescanDelays[delayIndex]) { [weak self] in
            guard let self, self.isTracking, !app.isTerminated else { return }
            guard self.repository.readCache(forPID: pid).isEmpty else { return }
            Task { [weak self] in
                guard let self else { return }
                let windows = await self.trackApplication(app)
                if windows.isEmpty {
                    self.scheduleLateWindowRescans(for: app, delayIndex: delayIndex + 1)
                }
            }
        }
    }

    private var isInWakeCooldown: Bool {
        if let wakeCooldownUntil, ContinuousClock.now < wakeCooldownUntil {
            return true
        }
        return false
    }

    private func ensureWatching(pid: pid_t, reason: String) {
        guard let watcherManager else { return }
        if watcherManager.isWatching(pid: pid) {
            watchRetryAttempts.withLockUnchecked { _ = $0.removeValue(forKey: pid) }
            return
        }

        if watcherManager.watch(pid: pid) {
            watchRetryAttempts.withLockUnchecked { _ = $0.removeValue(forKey: pid) }
        } else {
            Logger.debug("AX watcher setup deferred", details: "pid=\(pid), reason=\(reason)")
            scheduleWatchRetry(pid: pid)
        }
    }

    /// Freshly spawned processes (e.g. per-window child instances Bambu Studio
    /// execs from its own bundle) are often not AX-ready when first seen, and a
    /// failed watch used to be permanent — no watcher meant no windowCreated
    /// events, so windows that appeared seconds later were never discovered.
    /// Retry with backoff and rediscover once the watcher finally attaches.
    private func scheduleWatchRetry(pid: pid_t) {
        let attempt = watchRetryAttempts.withLockUnchecked { attempts -> Int? in
            let next = (attempts[pid] ?? 0) + 1
            guard next <= Self.watchRetryMaxAttempts else { return nil }
            attempts[pid] = next
            return next
        }
        guard let attempt else {
            Logger.warning("AX watcher setup abandoned after \(Self.watchRetryMaxAttempts) attempts", details: "pid=\(pid)")
            return
        }

        let delay = Self.watchRetryInitialDelay * pow(2.0, Double(attempt - 1))
        axQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.isTracking, let watcherManager = self.watcherManager else { return }
            guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else {
                self.watchRetryAttempts.withLockUnchecked { _ = $0.removeValue(forKey: pid) }
                return
            }
            if watcherManager.isWatching(pid: pid) {
                self.watchRetryAttempts.withLockUnchecked { _ = $0.removeValue(forKey: pid) }
                return
            }
            if watcherManager.watch(pid: pid) {
                Logger.info("AX watcher attached on retry", details: "pid=\(pid), attempt=\(attempt)")
                self.watchRetryAttempts.withLockUnchecked { _ = $0.removeValue(forKey: pid) }
                self.debounce(key: "refresh-\(pid)") { [weak self] in
                    _ = await self?.trackApplication(app)
                }
            } else {
                self.scheduleWatchRetry(pid: pid)
            }
        }
    }

    private func handleAccessibilityEvent(_ event: AccessibilityEvent, forPID pid: pid_t) {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return }

        // Post-cooldown full scan covers these; suppress to avoid redundant refreshes.
        if isInWakeCooldown {
            switch event {
            case .windowCreated, .windowDestroyed, .windowResized, .windowMoved, .applicationRevealed:
                Logger.debug("Suppressing AX event during wake cooldown", details: "pid=\(pid), event=\(event)")
                return
            default:
                break
            }
        }

        switch event {
        case .windowCreated, .windowDestroyed, .windowFocused, .mainWindowChanged:
            eventSubject.send(.windowActivityDetected(pid))
        default:
            break
        }

        switch event {
        case .windowCreated:
            repository.clearSuppressions(forPID: pid)
            debounce(key: "refresh-\(pid)") { [weak self] in
                guard let self else { return }
                let newWindows = await discovery.discoverNew(for: app)
                guard !newWindows.isEmpty else { return }
                let changes = repository.store(forPID: pid, windows: Set(newWindows))
                emitChanges(changes)
                Logger.debug("New windows discovered", details: "pid=\(pid), count=\(newWindows.count)")
            }

        case .windowDestroyed:
            scheduleDestroyHandler(forPID: pid)

        case .windowMinimized(let element):
            let windowID = try? element.windowID()
            debounce(key: "window-minimized-\(pid)") { [weak self] in
                self?.updateWindowState(windowID: windowID, element: element, pid: pid) { window in
                    CapturedWindow(
                        id: window.id, title: window.title, ownerBundleID: window.ownerBundleID,
                        ownerPID: window.ownerPID, bounds: window.bounds,
                        isMinimized: true, isFullscreen: window.isFullscreen,
                        isOwnerHidden: window.isOwnerHidden, isVisible: window.isVisible,
                        owningDisplayID: window.owningDisplayID, desktopSpace: window.desktopSpace,
                        lastInteractionTime: window.lastInteractionTime, creationTime: window.creationTime,
                        axElement: window.axElement, appAxElement: window.appAxElement,
                        closeButton: window.closeButton, subrole: window.subrole
                    )
                }
            }

        case .windowRestored(let element):
            let windowID = try? element.windowID()
            debounce(key: "window-restored-\(pid)") { [weak self] in
                self?.updateWindowState(windowID: windowID, element: element, pid: pid) { window in
                    CapturedWindow(
                        id: window.id, title: window.title, ownerBundleID: window.ownerBundleID,
                        ownerPID: window.ownerPID, bounds: window.bounds,
                        isMinimized: false, isFullscreen: window.isFullscreen,
                        isOwnerHidden: window.isOwnerHidden, isVisible: window.isVisible,
                        owningDisplayID: window.owningDisplayID, desktopSpace: window.desktopSpace,
                        lastInteractionTime: window.lastInteractionTime, creationTime: window.creationTime,
                        axElement: window.axElement, appAxElement: window.appAxElement,
                        closeButton: window.closeButton, subrole: window.subrole
                    )
                }
            }

        case .applicationHidden:
            debounce(key: "app-hidden-\(pid)") { [weak self] in
                guard let self else { return }
                let changes = repository.modify(forPID: pid) { windows in
                    windows = Set(windows.map { window in
                        var updated = CapturedWindow(
                            id: window.id,
                            title: window.title,
                            ownerBundleID: window.ownerBundleID,
                            ownerPID: window.ownerPID,
                            bounds: window.bounds,
                            isMinimized: window.isMinimized,
                            isFullscreen: window.isFullscreen,
                            isOwnerHidden: true,
                            isVisible: window.isVisible,
                            owningDisplayID: window.owningDisplayID,
                            desktopSpace: window.desktopSpace,
                            lastInteractionTime: window.lastInteractionTime,
                            creationTime: window.creationTime,
                            axElement: window.axElement,
                            appAxElement: window.appAxElement,
                            closeButton: window.closeButton,
                            subrole: window.subrole
                        )
                        updated.cachedPreview = window.cachedPreview
                        updated.previewTimestamp = window.previewTimestamp
                        return updated
                    })
                }
                emitChanges(changes)
            }

        case .applicationRevealed:
            debounce(key: "app-revealed-\(pid)") { [weak self] in
                guard let self else { return }
                let changes = repository.modify(forPID: pid) { windows in
                    windows = Set(windows.map { window in
                        var updated = CapturedWindow(
                            id: window.id,
                            title: window.title,
                            ownerBundleID: window.ownerBundleID,
                            ownerPID: window.ownerPID,
                            bounds: window.bounds,
                            isMinimized: window.isMinimized,
                            isFullscreen: window.isFullscreen,
                            isOwnerHidden: false,
                            isVisible: window.isVisible,
                            owningDisplayID: window.owningDisplayID,
                            desktopSpace: window.desktopSpace,
                            lastInteractionTime: window.lastInteractionTime,
                            creationTime: window.creationTime,
                            axElement: window.axElement,
                            appAxElement: window.appAxElement,
                            closeButton: window.closeButton,
                            subrole: window.subrole
                        )
                        updated.cachedPreview = window.cachedPreview
                        updated.previewTimestamp = window.previewTimestamp
                        return updated
                    })
                }
                emitChanges(changes)
            }

        case .windowFocused(let element), .mainWindowChanged(let element):
            let windowID = try? element.windowID()
            updateWindowTimestamp(windowID: windowID, pid: pid)

        case .titleChanged(let element):
            // Coalesced: apps rewriting their title continuously would starve
            // a debounce, and the AX reads must not run per event.
            coalesce(key: "title-\(pid)") { [weak self] in
                guard let self else { return }
                let windowID = try? element.windowID()
                guard (try? element.role()) == kAXWindowRole as String,
                      let newTitle = try? element.title() else { return }
                updateWindowState(windowID: windowID, element: element, pid: pid) { window in
                    guard window.title != newTitle else { return nil }
                    return CapturedWindow(
                        id: window.id, title: newTitle, ownerBundleID: window.ownerBundleID,
                        ownerPID: window.ownerPID, bounds: window.bounds,
                        isMinimized: window.isMinimized, isFullscreen: window.isFullscreen,
                        isOwnerHidden: window.isOwnerHidden, isVisible: window.isVisible,
                        owningDisplayID: window.owningDisplayID, desktopSpace: window.desktopSpace,
                        lastInteractionTime: window.lastInteractionTime, creationTime: window.creationTime,
                        axElement: window.axElement, appAxElement: window.appAxElement,
                        closeButton: window.closeButton, subrole: window.subrole
                    )
                }
            }

        case .windowResized(let element), .windowMoved(let element):
            let windowID = try? element.windowID()
            let position = try? element.position()
            let size = try? element.size()
            let isFullscreen = try? element.isFullscreen()
            guard let position, let size else { break }
            let newBounds = CGRect(origin: position, size: size)
            debounce(key: "geometry-\(pid)") { [weak self] in
                self?.updateWindowState(windowID: windowID, element: element, pid: pid) { window in
                    CapturedWindow(
                        id: window.id, title: window.title, ownerBundleID: window.ownerBundleID,
                        ownerPID: window.ownerPID, bounds: newBounds,
                        isMinimized: window.isMinimized,
                        isFullscreen: isFullscreen ?? window.isFullscreen,
                        isOwnerHidden: window.isOwnerHidden, isVisible: window.isVisible,
                        owningDisplayID: WindowDiscovery.displayID(for: newBounds) ?? window.owningDisplayID,
                        desktopSpace: window.desktopSpace, lastInteractionTime: Date(),
                        creationTime: window.creationTime,
                        axElement: window.axElement, appAxElement: window.appAxElement,
                        closeButton: window.closeButton, subrole: window.subrole
                    )
                }
            }
        }
    }

    /// Applies `update` to the matched window; returning nil leaves the
    /// repository untouched and emits nothing.
    private func updateWindowState(
        windowID: CGWindowID?,
        element: AXUIElement,
        pid: pid_t,
        update: (CapturedWindow) -> CapturedWindow?
    ) {
        let changes = repository.modify(forPID: pid) { windows in
            let existing: CapturedWindow?
            if let windowID, let match = windows.first(where: { $0.id == windowID }) {
                existing = match
            } else if let match = windows.first(where: { $0.axElement == element }) {
                existing = match
            } else {
                existing = nil
            }
            guard let existing, var updated = update(existing) else { return }
            windows.remove(existing)
            updated.cachedPreview = existing.cachedPreview
            updated.previewTimestamp = existing.previewTimestamp
            windows.insert(updated)
        }
        emitChanges(changes)
    }

    private func updateWindowTimestamp(windowID: CGWindowID?, pid: pid_t) {
        guard let windowID else { return }
        if let touched = repository.touch(windowID: windowID, pid: pid) {
            eventSubject.send(.windowChanged(touched))
        }
    }

    private func touchFocusedWindow(for app: NSRunningApplication) {
        let pid = app.processIdentifier
        let appElement = AXUIElement.application(pid: pid)
        guard let focusedWindow = try? appElement.focusedWindow(),
              let windowID = try? focusedWindow.windowID()
        else {
            Logger.debug("Activated app has no focused window to touch", details: "pid=\(pid), name=\(app.localizedName ?? "?")")
            return
        }
        updateWindowTimestamp(windowID: windowID, pid: pid)
    }

    // MARK: - Destroy Burst Tapering

    private struct DestroyBurstState {
        var lastEventTime: ContinuousClock.Instant
        var currentInterval: Duration
        var eventCount: Int
    }

    private func scheduleDestroyHandler(forPID pid: pid_t) {
        let (interval, eventCount) = destroyBurstState.withLockUnchecked { states -> (Duration, Int) in
            let now = ContinuousClock.now
            var state = states[pid] ?? DestroyBurstState(
                lastEventTime: now, currentInterval: Self.destroyMinInterval, eventCount: 0
            )

            let elapsed = now - state.lastEventTime

            if elapsed > Self.destroyResetThreshold {
                // Quiet period — reset to minimum
                state.currentInterval = Self.destroyMinInterval
                state.eventCount = 1
            } else {
                state.eventCount += 1
                if state.eventCount > 1 {
                    let next = state.currentInterval * Self.destroyEscalationFactor
                    state.currentInterval = min(next, Self.destroyMaxInterval)
                }
            }

            state.lastEventTime = now
            states[pid] = state
            return (state.currentInterval, state.eventCount)
        }

        if eventCount > 2 {
            Logger.debug("Destroy burst tapering", details: "pid=\(pid), interval=\(interval), events=\(eventCount)")
        }

        debounce(key: "window-destroyed-\(pid)", interval: interval) { [weak self] in
            guard let self else { return }
            guard let app = NSRunningApplication(processIdentifier: pid) else { return }
            Logger.debug("Destroy handler fired", details: "pid=\(pid), policy=\(app.activationPolicy.rawValue), terminated=\(app.isTerminated), hidden=\(app.isHidden)")

            if app.isHidden {
                Logger.debug("Skipping destroy — app is hidden", details: "pid=\(pid)")
                return
            }

            let cached = repository.readCache(forPID: pid)
            if !cached.isEmpty, cached.allSatisfy(\.isMinimized) {
                Logger.debug("Skipping destroy — all windows minimized", details: "pid=\(pid), count=\(cached.count)")
                return
            }

            if app.isTerminated || app.activationPolicy != .regular {
                Logger.debug("App terminated or no longer .regular during destroy, purging all", details: "pid=\(pid)")
                let windows = repository.readCache(forPID: pid)
                repository.removeAll(forPID: pid)
                for window in windows {
                    eventSubject.send(.windowDisappeared(window.id))
                }
            } else {
                let changes = repository.modify(forPID: pid) { windows in
                    let before = windows
                    windows = windows.filter {
                        self.enumerator.isValidElement($0.axElement, isMinimized: $0.isMinimized, isHidden: $0.isOwnerHidden)
                    }
                    let removedCount = before.count - windows.count
                    if removedCount > 0 {
                        Logger.debug("Filtered invalid windows", details: "pid=\(pid), removed=\(removedCount)")
                    }
                }
                emitChanges(changes)
            }
        }
    }

    /// Throttle for high-rate event streams: the first event schedules
    /// `operation` after `interval`; events arriving before it fires are
    /// absorbed, and one absorbed mid-flight schedules a single follow-up so
    /// the stream's final state always applies.
    private func coalesce(key: String, interval: Duration = .milliseconds(Int(eventDebounceInterval * 1000)), operation: @escaping () async -> Void) {
        coalescedTasks.withLockUnchecked { tasks in
            guard tasks[key] == nil else {
                coalescedFollowUps.withLockUnchecked { _ = $0.insert(key) }
                return
            }
            tasks[key] = Task { [coalescedTasks, coalescedFollowUps] in
                var cancelled = false
                do {
                    try await Task.sleep(for: interval)
                } catch { cancelled = true }
                if !cancelled {
                    await withCheckedContinuation { continuation in
                        self.axQueue.async { continuation.resume() }
                    }
                    if !Task.isCancelled {
                        await operation()
                    }
                }
                let followUp = coalescedFollowUps.withLockUnchecked { $0.remove(key) != nil }
                coalescedTasks.withLockUnchecked { _ = $0.removeValue(forKey: key) }
                if followUp, !Task.isCancelled {
                    self.coalesce(key: key, interval: interval, operation: operation)
                }
            }
        }
    }

    private func cancelCoalescedTasks() {
        coalescedFollowUps.withLockUnchecked { $0.removeAll() }
        let tasks = coalescedTasks.withLockUnchecked { tasks -> [String: Task<Void, Never>] in
            let snapshot = tasks
            tasks.removeAll()
            return snapshot
        }
        for (_, task) in tasks {
            task.cancel()
        }
    }

    private func debounce(key: String, interval: Duration = .milliseconds(Int(eventDebounceInterval * 1000)), operation: @escaping () async -> Void) {
        pendingOperations.withLockUnchecked { $0[key, default: []].append(operation) }
        let generation = debounceGeneration.withLockUnchecked { gen -> UInt64 in
            gen += 1
            return gen
        }
        debouncedTasks.withLockUnchecked { tasks in
            tasks[key]?.task.cancel()
            let task = Task { [pendingOperations, debouncedTasks] in
                defer {
                    debouncedTasks.withLockUnchecked { tasks in
                        if tasks[key]?.generation == generation { tasks.removeValue(forKey: key) }
                    }
                }
                do {
                    try await Task.sleep(for: interval)
                } catch { return }
                guard !Task.isCancelled else { return }
                await withCheckedContinuation { continuation in
                    self.axQueue.async { continuation.resume() }
                }
                guard !Task.isCancelled else { return }
                let ops = pendingOperations.withLockUnchecked { $0.removeValue(forKey: key) ?? [] }
                for op in ops {
                    await op()
                }
            }
            tasks[key] = (task, generation)
        }
    }

    // MARK: - System Wake Recovery

    private func startWakeObserver() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, self.isTracking else { return }
            self.eventSubject.send(.systemWoke)
            Logger.info("System wake detected, starting canary-gated recovery")

            self.wakeRecoveryTask?.cancel()
            self.wakeCooldownUntil = ContinuousClock.now + Self.wakeMaxDelay

            self.debouncedTasks.withLockUnchecked { tasks in
                for (_, entry) in tasks { entry.task.cancel() }
                tasks.removeAll()
            }
            self.cancelCoalescedTasks()

            self.pendingOperations.withLockUnchecked { $0.removeAll() }
            self.destroyBurstState.withLockUnchecked { $0.removeAll() }

            self.watcherManager?.resetAll()
            self.notificationCenterWatcher?.reset()

            self.wakeRecoveryTask = Task { [weak self] in
                guard let self else { return }

                var delay = Self.wakeInitialDelay
                var totalWaited: Duration = .zero

                while !Task.isCancelled && self.isTracking {
                    try? await Task.sleep(for: delay)
                    guard !Task.isCancelled, self.isTracking else { return }

                    totalWaited += delay

                    if isAccessibilityReady() {
                        Logger.info("AX canary passed after \(totalWaited), performing full scan")
                        break
                    }

                    Logger.debug("AX canary failed after \(totalWaited), backing off", details: "nextDelay=\(delay * Self.wakeBackoffMultiplier)")

                    if totalWaited >= Self.wakeMaxDelay {
                        Logger.warning("AX canary never passed within \(Self.wakeMaxDelay), scanning anyway")
                        break
                    }

                    let nextDelay = delay * Self.wakeBackoffMultiplier
                    let remaining = Self.wakeMaxDelay - totalWaited
                    delay = min(nextDelay, remaining)
                }

                guard !Task.isCancelled, self.isTracking else { return }
                await self.performFullScan()

                self.watcherManager?.resetAll()
                self.notificationCenterWatcher?.reset()
                self.wakeCooldownUntil = nil
                await MainActor.run {
                    self.eventSubject.send(.wakeRecoveryCompleted)
                }
            }
        }
    }

    private func stopWakeObserver() {
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
        wakeObserver = nil
    }

    // MARK: - Notification Center Banner Watcher

    private func startNotificationCenterWatcher() {
        guard let ncApp = NSWorkspace.shared.runningApplications
            .first(where: { $0.bundleIdentifier == "com.apple.notificationcenterui" }),
              let watcher = AccessibilityWatcher(pid: ncApp.processIdentifier) else {
            Logger.debug("NotificationCenter UI not found or not watchable")
            return
        }

        notificationCenterWatcher = watcher
        Logger.debug("Watching NotificationCenter UI", details: "pid=\(ncApp.processIdentifier)")

        watcher.events
            .sink { [weak self] event in
                guard let self else { return }
                switch event {
                case .windowCreated, .windowDestroyed:
                    debounce(key: "notification-banner") {
                        self.eventSubject.send(.notificationBannerChanged)
                    }
                default:
                    break
                }
            }
            .store(in: &subscriptions)
    }

    private func emitChanges(_ changes: ChangeReport) {
        for window in changes.added {
            eventSubject.send(.windowAppeared(window))
        }
        for windowID in changes.removed {
            eventSubject.send(.windowDisappeared(windowID))
        }
        for window in changes.modified {
            eventSubject.send(.windowChanged(window))
        }
    }
}
