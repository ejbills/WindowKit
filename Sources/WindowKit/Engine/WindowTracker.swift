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

    private var discovery: WindowDiscovery
    private let enumerator = WindowEnumerator()

    private let processWatcher = ProcessWatcher()
    private var watcherManager: AccessibilityWatcherManager?
    private var subscriptions = Set<AnyCancellable>()

    public var processEvents: AnyPublisher<ProcessEvent, Never> { processWatcher.events }
    public var frontmostApplication: NSRunningApplication? { processWatcher.frontmostApplication }

    private let debouncedTasks = OSAllocatedUnfairLock(initialState: [String: Task<Void, Never>]())
    private let pendingDestroyPIDs = OSAllocatedUnfairLock(initialState: Set<pid_t>())
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
                Task { [weak self] in
                    await self?.handleAccessibilityEvent(event, forPID: pid)
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

        Logger.debug("Tracking application", details: "pid=\(pid), name=\(appName), policy=\(policy.rawValue)")

        let discoveredWindows = await discovery.discoverAll(for: app)

        let changes = repository.store(forPID: pid, windows: Set(discoveredWindows))
        emitChanges(changes)

        Logger.info("Application tracked", details: "pid=\(pid), name=\(appName), windows=\(discoveredWindows.count)")
        return discoveredWindows
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
            _ = repository.purify(forPID: pid, validator: enumerator.isValidElement)
        }

        let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        Logger.info("Full scan complete", details: "duration=\(String(format: "%.1f", elapsed))ms, apps=\(apps.count)")
    }

    public func refreshApplication(_ app: NSRunningApplication) async {
        _ = await trackApplication(app)
    }

    /// Closes the window and suppresses it from future discovery.
    public func closeWindow(_ window: CapturedWindow) throws {
        try window.close()
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
            watcherManager?.watch(pid: app.processIdentifier)
            debounce(key: "refresh-\(app.processIdentifier)") { [weak self] in
                await self?.refreshApplication(app)
            }

        case .applicationTerminated(let pid):
            watcherManager?.unwatch(pid: pid)
            let windows = repository.readCache(forPID: pid)
            repository.removeAll(forPID: pid)
            for window in windows {
                eventSubject.send(.windowDisappeared(window.id))
            }

        case .applicationActivated(let app):
            debounce(key: "refresh-\(app.processIdentifier)") { [weak self] in
                await self?.refreshApplication(app)
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

    private func handleAccessibilityEvent(_ event: AccessibilityEvent, forPID pid: pid_t) async {
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
                await self?.refreshApplication(app)
            }

        case .windowDestroyed:
            pendingDestroyPIDs.withLockUnchecked { _ = $0.insert(pid) }
            debounce(key: "window-destroyed") { [weak self] in
                guard let self else { return }
                let pids = pendingDestroyPIDs.withLockUnchecked { pids -> Set<pid_t> in
                    let snapshot = pids
                    pids.removeAll()
                    return snapshot
                }
                for pid in pids {
                    guard let app = NSRunningApplication(processIdentifier: pid) else { continue }
                    Logger.debug("Window destroyed debounced handler", details: "pid=\(pid), policy=\(app.activationPolicy.rawValue), terminated=\(app.isTerminated), hidden=\(app.isHidden)")

                    if app.isHidden {
                        Logger.debug("Skipping destroy — app is hidden", details: "pid=\(pid)")
                        continue
                    }

                    let cached = repository.readCache(forPID: pid)
                    if !cached.isEmpty, cached.allSatisfy(\.isMinimized) {
                        Logger.debug("Skipping destroy — all windows minimized", details: "pid=\(pid), count=\(cached.count)")
                        continue
                    }

                    if app.isTerminated || app.activationPolicy != .regular {
                        Logger.debug("App terminated or no longer .regular during destroy, purging all", details: "pid=\(pid)")
                        let windows = repository.readCache(forPID: pid)
                        repository.removeAll(forPID: pid)
                        for window in windows {
                            eventSubject.send(.windowDisappeared(window.id))
                        }
                    } else {
                        // Filter cached windows in-place using isValidElement, matching
                        // DockDoor's approach: no expensive purify/re-discovery cycle.
                        let changes = repository.modify(forPID: pid) { windows in
                            let before = windows
                            windows = windows.filter { self.enumerator.isValidElement($0.axElement) }
                            let removedCount = before.count - windows.count
                            if removedCount > 0 {
                                Logger.debug("Filtered invalid windows", details: "pid=\(pid), removed=\(removedCount)")
                            }
                        }
                        emitChanges(changes)
                    }
                }
            }

        case .windowMinimized(let element):
            debounce(key: "window-minimized-\(pid)") { [weak self] in
                guard let self else { return }
                updateWindowState(element: element, pid: pid) { window in
                    CapturedWindow(
                        id: window.id,
                        title: window.title,
                        ownerBundleID: window.ownerBundleID,
                        ownerPID: window.ownerPID,
                        bounds: window.bounds,
                        isMinimized: true,
                        isFullscreen: window.isFullscreen,
                        isOwnerHidden: window.isOwnerHidden,
                        isVisible: window.isVisible,
                        owningDisplayID: window.owningDisplayID,
                        desktopSpace: window.desktopSpace,
                        lastInteractionTime: window.lastInteractionTime,
                        creationTime: window.creationTime,
                        axElement: window.axElement,
                        appAxElement: window.appAxElement
                    )
                }
            }

        case .windowRestored(let element):
            debounce(key: "window-restored-\(pid)") { [weak self] in
                guard let self else { return }
                updateWindowState(element: element, pid: pid) { window in
                    CapturedWindow(
                        id: window.id,
                        title: window.title,
                        ownerBundleID: window.ownerBundleID,
                        ownerPID: window.ownerPID,
                        bounds: window.bounds,
                        isMinimized: false,
                        isFullscreen: window.isFullscreen,
                        isOwnerHidden: window.isOwnerHidden,
                        isVisible: window.isVisible,
                        owningDisplayID: window.owningDisplayID,
                        desktopSpace: window.desktopSpace,
                        lastInteractionTime: window.lastInteractionTime,
                        creationTime: window.creationTime,
                        axElement: window.axElement,
                        appAxElement: window.appAxElement
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
                            appAxElement: window.appAxElement
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
                            appAxElement: window.appAxElement
                        )
                        updated.cachedPreview = window.cachedPreview
                        updated.previewTimestamp = window.previewTimestamp
                        return updated
                    })
                }
                emitChanges(changes)
            }

        case .windowFocused(let element), .mainWindowChanged(let element):
            updateWindowTimestamp(element: element, pid: pid)

        case .titleChanged(let element):
            axQueue.async { [weak self] in
                guard let role = try? element.role(), role == kAXWindowRole as String,
                      let newTitle = try? element.title() else { return }
                self?.updateWindowState(element: element, pid: pid) { window in
                    CapturedWindow(
                        id: window.id,
                        title: newTitle,
                        ownerBundleID: window.ownerBundleID,
                        ownerPID: window.ownerPID,
                        bounds: window.bounds,
                        isMinimized: window.isMinimized,
                        isFullscreen: window.isFullscreen,
                        isOwnerHidden: window.isOwnerHidden,
                        isVisible: window.isVisible,
                        owningDisplayID: window.owningDisplayID,
                        desktopSpace: window.desktopSpace,
                        lastInteractionTime: window.lastInteractionTime,
                        creationTime: window.creationTime,
                        axElement: window.axElement,
                        appAxElement: window.appAxElement
                    )
                }
            }

        case .windowResized, .windowMoved:
            debounce(key: "refresh-\(pid)") { [weak self] in
                await self?.refreshApplication(app)
            }
        }
    }

    private func updateWindowState(element: AXUIElement, pid: pid_t, update: (CapturedWindow) -> CapturedWindow) {
        let changes = repository.modify(forPID: pid) { windows in
            if let windowID = try? element.windowID(),
               let existing = windows.first(where: { $0.id == windowID }) {
                windows.remove(existing)
                var updated = update(existing)
                updated.cachedPreview = existing.cachedPreview
                updated.previewTimestamp = existing.previewTimestamp
                windows.insert(updated)
            } else if let existing = windows.first(where: { $0.axElement == element }) {
                windows.remove(existing)
                var updated = update(existing)
                updated.cachedPreview = existing.cachedPreview
                updated.previewTimestamp = existing.previewTimestamp
                windows.insert(updated)
            }
        }
        emitChanges(changes)
    }

    private func updateWindowTimestamp(element: AXUIElement, pid: pid_t) {
        axQueue.async { [weak self] in
            let windowID = try? element.windowID()
            guard let self, let windowID else { return }
            self.repository.modify(forPID: pid) { windows in
                if let existing = windows.first(where: { $0.id == windowID }) {
                    windows.remove(existing)
                    var updated = CapturedWindow(
                        id: existing.id,
                        title: existing.title,
                        ownerBundleID: existing.ownerBundleID,
                        ownerPID: existing.ownerPID,
                        bounds: existing.bounds,
                        isMinimized: existing.isMinimized,
                        isFullscreen: existing.isFullscreen,
                        isOwnerHidden: existing.isOwnerHidden,
                        isVisible: existing.isVisible,
                        owningDisplayID: existing.owningDisplayID,
                        desktopSpace: existing.desktopSpace,
                        lastInteractionTime: Date(),
                        creationTime: existing.creationTime,
                        axElement: existing.axElement,
                        appAxElement: existing.appAxElement
                    )
                    updated.cachedPreview = existing.cachedPreview
                    updated.previewTimestamp = existing.previewTimestamp
                    windows.insert(updated)
                }
            }
        }
    }

    private func debounce(key: String, operation: @escaping () async -> Void) {
        debouncedTasks.withLockUnchecked { tasks in
            tasks[key]?.cancel()
            tasks[key] = Task {
                do {
                    try await Task.sleep(nanoseconds: UInt64(Self.eventDebounceInterval * 1_000_000_000))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                await operation()
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
