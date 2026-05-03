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

    var discovery: WindowDiscovery
    private let enumerator = WindowEnumerator()

    private let processWatcher = ProcessWatcher()
    private var watcherManager: AccessibilityWatcherManager?
    private var subscriptions = Set<AnyCancellable>()

    public var processEvents: AnyPublisher<ProcessEvent, Never> { processWatcher.events }
    public var frontmostApplication: NSRunningApplication? { processWatcher.frontmostApplication }

    private let debouncedTasks = OSAllocatedUnfairLock(initialState: [String: Task<Void, Never>]())
    private let pendingOperations = OSAllocatedUnfairLock(initialState: [String: [() async -> Void]]())
    private let inFlightTracks = OSAllocatedUnfairLock(initialState: [pid_t: Task<[CapturedWindow], Never>]())
    private let destroyBurstState = OSAllocatedUnfairLock(initialState: [pid_t: DestroyBurstState]())
    private let axQueue = DispatchQueue(label: "com.windowkit.ax", qos: .userInitiated)
    private var notificationCenterWatcher: AccessibilityWatcher?
    private var isTracking = false
    private var wakeObserver: NSObjectProtocol?
    private var wakeCooldownUntil: ContinuousClock.Instant?
    private var wakeRecoveryTask: Task<Void, Never>?

    // Wake recovery backoff parameters
    private static let wakeInitialDelay: Duration = .seconds(1)
    private static let wakeMaxDelay: Duration = .seconds(15)
    private static let wakeBackoffMultiplier: Double = 2.0

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

        subscriptions.removeAll()
        watcherManager?.unwatchAll()
        watcherManager = nil
        notificationCenterWatcher?.stopWatching()
        notificationCenterWatcher = nil
        stopWakeObserver()

        let tasks = debouncedTasks.withLockUnchecked { tasks -> [String: Task<Void, Never>] in
            let snapshot = tasks
            tasks.removeAll()
            return snapshot
        }

        for (_, task) in tasks {
            task.cancel()
        }

        pendingOperations.withLockUnchecked { $0.removeAll() }
        destroyBurstState.withLockUnchecked { $0.removeAll() }
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

            let discoveredWindows = await discovery.discoverAll(for: app)
            guard !Task.isCancelled else { return [] }

            let changes = repository.store(forPID: pid, windows: Set(discoveredWindows))
            emitChanges(changes)

            let beforeIDs = Set(repository.readCache(forPID: pid).map(\.id))
            repository.purify(forPID: pid, validator: { enumerator.isValidElement($0) })
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

        var processedPIDs = Set<pid_t>()

        let apps = processWatcher.runningApplications()
        for app in apps {
            _ = await trackApplication(app)
            processedPIDs.insert(app.processIdentifier)
        }

        for pid in processedPIDs {
            _ = repository.purify(forPID: pid, validator: { enumerator.isValidElement($0) })
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
                _ = await self?.trackApplication(app)
            }

        case .applicationTerminated(let pid):
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
            debounce(key: "refresh-\(app.processIdentifier)") { [weak self] in
                _ = await self?.trackApplication(app)
            }

        case .applicationDeactivated:
            break

        case .spaceChanged:
            debounce(key: "space-change") { [weak self] in
                await self?.performFullScan()
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
            return
        }

        if !watcherManager.watch(pid: pid) {
            Logger.debug("AX watcher setup deferred", details: "pid=\(pid), reason=\(reason)")
        }
    }

    private func handleAccessibilityEvent(_ event: AccessibilityEvent, forPID pid: pid_t) {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return }

        // Post-cooldown full scan covers these; suppress to avoid redundant refreshes.
        if isInWakeCooldown {
            switch event {
            case .windowCreated, .windowResized, .windowMoved, .applicationRevealed:
                Logger.debug("Suppressing AX event during wake cooldown", details: "pid=\(pid), event=\(event)")
                return
            default:
                break
            }
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
            let windowID = try? element.windowID()
            let role = try? element.role()
            let newTitle = try? element.title()
            guard role == kAXWindowRole as String, let newTitle else { break }
            debounce(key: "title-\(pid)") { [weak self] in
                self?.updateWindowState(windowID: windowID, element: element, pid: pid) { window in
                    CapturedWindow(
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

    private func updateWindowState(
        windowID: CGWindowID?,
        element: AXUIElement,
        pid: pid_t,
        update: (CapturedWindow) -> CapturedWindow
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
            guard let existing else { return }
            windows.remove(existing)
            var updated = update(existing)
            updated.cachedPreview = existing.cachedPreview
            updated.previewTimestamp = existing.previewTimestamp
            windows.insert(updated)
        }
        emitChanges(changes)
    }

    private func updateWindowTimestamp(windowID: CGWindowID?, pid: pid_t) {
        guard let windowID else { return }
        var focused: CapturedWindow?
        repository.modify(forPID: pid) { windows in
            if let existing = windows.first(where: { $0.id == windowID }) {
                windows.remove(existing)
                var updated = CapturedWindow(
                    id: existing.id, title: existing.title, ownerBundleID: existing.ownerBundleID,
                    ownerPID: existing.ownerPID, bounds: existing.bounds,
                    isMinimized: existing.isMinimized, isFullscreen: existing.isFullscreen,
                    isOwnerHidden: existing.isOwnerHidden, isVisible: existing.isVisible,
                    owningDisplayID: existing.owningDisplayID, desktopSpace: existing.desktopSpace,
                    lastInteractionTime: Date(), creationTime: existing.creationTime,
                    axElement: existing.axElement, appAxElement: existing.appAxElement,
                    closeButton: existing.closeButton, subrole: existing.subrole
                )
                updated.cachedPreview = existing.cachedPreview
                updated.previewTimestamp = existing.previewTimestamp
                windows.insert(updated)
                focused = updated
            }
        }
        if let focused {
            eventSubject.send(.windowChanged(focused))
        }
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

    private func debounce(key: String, interval: Duration = .milliseconds(Int(eventDebounceInterval * 1000)), operation: @escaping () async -> Void) {
        pendingOperations.withLockUnchecked { $0[key, default: []].append(operation) }
        debouncedTasks.withLockUnchecked { tasks in
            tasks[key]?.cancel()
            tasks[key] = Task { [pendingOperations] in
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
        }
    }

    // MARK: - System Wake Recovery

    private func startWakeObserver() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, self.isTracking else { return }
            Logger.info("System wake detected, starting canary-gated recovery")

            self.wakeRecoveryTask?.cancel()
            self.wakeCooldownUntil = ContinuousClock.now + Self.wakeMaxDelay

            self.debouncedTasks.withLockUnchecked { tasks in
                for (_, task) in tasks { task.cancel() }
                tasks.removeAll()
            }

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
                self.wakeCooldownUntil = nil
                await self.performFullScan()

                self.watcherManager?.resetAll()
                self.notificationCenterWatcher?.reset()
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
