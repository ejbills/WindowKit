import Cocoa
import Combine

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

    private var debouncedTasks: [String: Task<Void, Never>] = [:]
    private let debounceLock = NSLock()
    private var isTracking = false

    public init() {
        let repository = WindowRepository()
        self.repository = repository
        self.discovery = WindowDiscovery(
            repository: repository,
            screenshotService: ScreenshotService(),
            enumerator: WindowEnumerator()
        )
    }

    public func startTracking() {
        guard !isTracking else { return }
        isTracking = true
        Logger.info("Starting window tracking")

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
            manager.watch(pid: app.processIdentifier)
        }

        Task { [weak self] in
            await self?.performFullScan()
        }
    }

    public func stopTracking() {
        guard isTracking else { return }
        isTracking = false
        Logger.info("Stopping window tracking")

        subscriptions.removeAll()
        watcherManager?.unwatchAll()
        watcherManager = nil

        debounceLock.lock()
        let tasks = debouncedTasks
        debouncedTasks.removeAll()
        debounceLock.unlock()

        for (_, task) in tasks {
            task.cancel()
        }
    }

    @discardableResult
    public func trackApplication(_ app: NSRunningApplication) async -> [CapturedWindow] {
        let pid = app.processIdentifier
        if repository.ignoredPIDs.contains(pid) { return [] }
        let appName = app.localizedName ?? "Unknown"
        Logger.debug("Tracking application", details: "pid=\(pid), name=\(appName)")

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

        case .spaceChanged:
            debounce(key: "space-change") { [weak self] in
                await self?.performFullScan()
            }
        }
    }

    private func handleAccessibilityEvent(_ event: AccessibilityEvent, forPID pid: pid_t) async {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return }

        switch event {
        case .windowCreated:
            debounce(key: "refresh-\(pid)") { [weak self] in
                await self?.refreshApplication(app)
            }

        case .windowDestroyed:
            debounce(key: "window-destroyed-\(pid)") { [weak self] in
                guard let self else { return }
                Logger.debug("Window destroyed notification, validating all windows", details: "pid=\(pid)")
                if app.isTerminated {
                    Logger.debug("Application terminated during window destroy, purging all", details: "pid=\(pid)")
                    let windows = repository.readCache(forPID: pid)
                    repository.removeAll(forPID: pid)
                    for window in windows {
                        eventSubject.send(.windowDisappeared(window.id))
                    }
                } else {
                    let before = Set(repository.readCache(forPID: pid).map(\.id))
                    let remaining = Set(repository.purify(forPID: pid, validator: enumerator.isValidElement).map(\.id))
                    for removedID in before.subtracting(remaining) {
                        eventSubject.send(.windowDisappeared(removedID))
                    }
                }
            }

        case .windowMinimized(let element):
            debounce(key: "window-minimized-\(pid)") { [weak self] in
                guard let self else { return }
                _ = repository.purify(forPID: pid, validator: enumerator.isValidElement)
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
                _ = repository.purify(forPID: pid, validator: enumerator.isValidElement)
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
                _ = repository.purify(forPID: pid, validator: enumerator.isValidElement)
                repository.modify(forPID: pid) { windows in
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
            }

        case .applicationRevealed:
            debounce(key: "app-revealed-\(pid)") { [weak self] in
                guard let self else { return }
                _ = repository.purify(forPID: pid, validator: enumerator.isValidElement)
                repository.modify(forPID: pid) { windows in
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
            }

        case .windowFocused(let element), .mainWindowChanged(let element):
            updateWindowTimestamp(element: element, pid: pid)

        case .titleChanged(let element):
            if let role = try? element.role(), role == kAXWindowRole as String {
                if let newTitle = try? element.title() {
                    updateWindowState(element: element, pid: pid) { window in
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
        repository.modify(forPID: pid) { windows in
            if let windowID = try? element.windowID(),
               let existing = windows.first(where: { $0.id == windowID }) {
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

    private func debounce(key: String, operation: @escaping () async -> Void) {
        debounceLock.lock()
        debouncedTasks[key]?.cancel()
        debouncedTasks[key] = Task {
            do {
                try await Task.sleep(nanoseconds: UInt64(Self.eventDebounceInterval * 1_000_000_000))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await operation()
        }
        debounceLock.unlock()
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
