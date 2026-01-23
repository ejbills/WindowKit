import Cocoa
import Combine
import ScreenCaptureKit

@MainActor
public final class WindowTracker {
    static let minimumWindowSize = CGSize(width: 100, height: 100)
    static let eventDebounceInterval: TimeInterval = 0.3

    public let repository: WindowRepository

    public var events: AnyPublisher<WindowEvent, Never> {
        eventSubject.eraseToAnyPublisher()
    }

    private let eventSubject = PassthroughSubject<WindowEvent, Never>()
    private let screenshotService = ScreenshotService()
    private let enumerator = WindowEnumerator()

    private var processWatcher: ProcessWatcher?
    private var watcherManager: AccessibilityWatcherManager?
    private var subscriptions = Set<AnyCancellable>()

    private var debouncedTasks: [String: Task<Void, Never>] = [:]
    private var isTracking = false

    public init() {
        self.repository = WindowRepository()
    }

    public func startTracking() {
        guard !isTracking else { return }
        isTracking = true
        Logger.info("Starting window tracking")

        let watcher = ProcessWatcher()
        processWatcher = watcher

        watcher.events
            .sink { [weak self] event in
                Task { @MainActor in
                    await self?.handleProcessEvent(event)
                }
            }
            .store(in: &subscriptions)

        let manager = AccessibilityWatcherManager()
        watcherManager = manager

        manager.events
            .sink { [weak self] (pid, event) in
                Task { @MainActor in
                    await self?.handleAccessibilityEvent(event, forPID: pid)
                }
            }
            .store(in: &subscriptions)

        let apps = watcher.runningApplications()
        Logger.debug("Found running applications", details: "count=\(apps.count)")
        for app in apps {
            manager.watch(pid: app.processIdentifier)
        }

        Task {
            await performFullScan()
        }
    }

    public func stopTracking() {
        guard isTracking else { return }
        isTracking = false
        Logger.info("Stopping window tracking")

        subscriptions.removeAll()
        processWatcher?.stopWatching()
        processWatcher = nil
        watcherManager?.unwatchAll()
        watcherManager = nil

        for (_, task) in debouncedTasks {
            task.cancel()
        }
        debouncedTasks.removeAll()
    }

    @discardableResult
    public func trackApplication(_ app: NSRunningApplication) async -> [CapturedWindow] {
        let pid = app.processIdentifier
        let appName = app.localizedName ?? "Unknown"
        Logger.debug("Tracking application", details: "pid=\(pid), name=\(appName)")

        var discoveredWindows: [CapturedWindow] = []

        if #available(macOS 12.3, *), SystemPermissions.hasScreenRecording() {
            if let sckWindows = await discoverViaSCK(for: app) {
                Logger.debug("SCK discovery complete", details: "pid=\(pid), found=\(sckWindows.count)")
                discoveredWindows.append(contentsOf: sckWindows)
            }
        }

        let sckWindowIDs = Set(discoveredWindows.map(\.id))
        let axWindows = await discoverViaAccessibility(for: app, excludeIDs: sckWindowIDs)
        Logger.debug("AX discovery complete", details: "pid=\(pid), found=\(axWindows.count)")
        discoveredWindows.append(contentsOf: axWindows)

        let changes = await repository.store(forPID: pid, windows: Set(discoveredWindows))
        emitChanges(changes)

        Logger.info("Application tracked", details: "pid=\(pid), name=\(appName), windows=\(discoveredWindows.count)")
        return discoveredWindows
    }

    public func performFullScan() async {
        Logger.info("Performing full window scan")
        let startTime = CFAbsoluteTimeGetCurrent()

        var processedPIDs = Set<pid_t>()

        guard let watcher = processWatcher else {
            let apps = NSWorkspace.shared.runningApplications.filter {
                $0.activationPolicy == .regular
            }
            Logger.debug("No process watcher, scanning workspace apps", details: "count=\(apps.count)")

            for app in apps {
                _ = await trackApplication(app)
                processedPIDs.insert(app.processIdentifier)
            }

            for pid in processedPIDs {
                _ = await repository.purify(forPID: pid)
            }

            let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            Logger.info("Full scan complete", details: "duration=\(String(format: "%.1f", elapsed))ms")
            return
        }

        let apps = watcher.runningApplications()
        for app in apps {
            _ = await trackApplication(app)
            processedPIDs.insert(app.processIdentifier)
        }

        for pid in processedPIDs {
            _ = await repository.purify(forPID: pid)
        }

        let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        Logger.info("Full scan complete", details: "duration=\(String(format: "%.1f", elapsed))ms, apps=\(apps.count)")
    }

    public func refreshApplication(_ app: NSRunningApplication) async {
        _ = await trackApplication(app)
    }

    public func capturePreview(for windowID: CGWindowID) async -> CGImage? {
        do {
            let image = try screenshotService.captureWindow(id: windowID)
            await repository.storePreview(image, forWindowID: windowID)
            eventSubject.send(.previewCaptured(windowID, image))
            return image
        } catch {
            return nil
        }
    }

    public func refreshPreviews(for pid: pid_t) async {
        let windows = await repository.fetch(forPID: pid)
        let freshIDs = await repository.windowIDsWithFreshPreviews()

        let needsCapture = windows.filter { !freshIDs.contains($0.id) }

        for window in needsCapture {
            _ = await capturePreview(for: window.id)
        }
    }

    @available(macOS 12.3, *)
    private func discoverViaSCK(for app: NSRunningApplication) async -> [CapturedWindow]? {
        let pid = app.processIdentifier

        // Fetch SCShareableContent with timeout protection
        let contentResult: SCShareableContent? = await ConcurrencyHelpers.withTimeoutOptional {
            try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        }

        guard let content = contentResult else {
            return nil
        }

        let appWindows = content.windows.filter { $0.owningApplication?.processID == pid }
        let freshIDs = await repository.windowIDsWithFreshPreviews()

        // Process windows concurrently with limited concurrency
        let results: [CapturedWindow] = await ConcurrencyHelpers.mapConcurrent(appWindows, maxConcurrent: 4) { [self] scWindow -> CapturedWindow? in
            guard await isValidSCKWindow(scWindow) else { return nil }
            return await captureFromSCKWindow(scWindow, app: app, skipPreview: freshIDs.contains(scWindow.windowID))
        }

        return results
    }

    @available(macOS 12.3, *)
    private func isValidSCKWindow(_ window: SCWindow) async -> Bool {
        guard window.isOnScreen,
              window.windowLayer == 0,
              window.frame.size.width >= Self.minimumWindowSize.width,
              window.frame.size.height >= Self.minimumWindowSize.height else {
            return false
        }
        return true
    }

    @available(macOS 12.3, *)
    private func captureFromSCKWindow(_ scWindow: SCWindow, app: NSRunningApplication, skipPreview: Bool) async -> CapturedWindow? {
        let pid = app.processIdentifier
        let appElement = AXUIElement.application(pid: pid)

        guard let axWindows = try? appElement.windows(),
              let axWindow = findMatchingAXWindow(for: scWindow, in: axWindows) else {
            return nil
        }

        let closeButton = try? axWindow.closeButton()
        let minimizeButton = try? axWindow.minimizeButton()
        guard closeButton != nil || minimizeButton != nil else {
            return nil
        }

        let isMinimized = (try? axWindow.isMinimized()) ?? false
        let isHidden = app.isHidden
        let spaceID = scWindow.windowID.spaces().first

        var window = CapturedWindow(
            id: scWindow.windowID,
            title: scWindow.title,
            ownerBundleID: app.bundleIdentifier,
            ownerPID: pid,
            bounds: scWindow.frame,
            isMinimized: isMinimized,
            isOwnerHidden: isHidden,
            isVisible: scWindow.isOnScreen,
            desktopSpace: spaceID,
            lastInteractionTime: Date(),
            creationTime: Date(),
            axElement: axWindow,
            appAxElement: appElement,
            closeButton: closeButton
        )

        if !skipPreview {
            if let image = try? screenshotService.captureWindow(id: scWindow.windowID) {
                window.cachedPreview = image
                window.previewTimestamp = Date()
                await repository.storePreview(image, forWindowID: scWindow.windowID)
            }
        }

        return window
    }

    @available(macOS 12.3, *)
    private func findMatchingAXWindow(for scWindow: SCWindow, in axWindows: [AXUIElement]) -> AXUIElement? {
        for axWindow in axWindows {
            if let axWindowID = try? axWindow.windowID(), axWindowID == scWindow.windowID {
                return axWindow
            }
        }

        for axWindow in axWindows {
            if let scTitle = scWindow.title,
               let axTitle = try? axWindow.title(),
               WindowEnumerator.isFuzzyTitleMatch(scTitle, axTitle) {
                return axWindow
            }

            if let axPosition = try? axWindow.position(),
               let axSize = try? axWindow.size() {
                let tolerance: CGFloat = 10
                let positionMatch = abs(axPosition.x - scWindow.frame.origin.x) <= tolerance &&
                                    abs(axPosition.y - scWindow.frame.origin.y) <= tolerance
                let sizeMatch = abs(axSize.width - scWindow.frame.size.width) <= tolerance &&
                                abs(axSize.height - scWindow.frame.size.height) <= tolerance

                if positionMatch && sizeMatch {
                    return axWindow
                }
            }
        }

        return nil
    }

    private func discoverViaAccessibility(for app: NSRunningApplication, excludeIDs: Set<CGWindowID>) async -> [CapturedWindow] {
        let pid = app.processIdentifier
        let appElement = AXUIElement.application(pid: pid)
        let axWindows = enumerator.enumerateWindows(forPID: pid)

        guard !axWindows.isEmpty else { return [] }

        let cgCandidates = enumerator.cgDescriptors(forPID: pid)
        let activeSpaces = activeSpaceIDs()
        let freshIDs = await repository.windowIDsWithFreshPreviews()

        // Pre-filter windows and resolve IDs synchronously to avoid race conditions
        var candidateWindows: [(axWindow: AXUIElement, windowID: CGWindowID, descriptor: CGWindowDescriptor)] = []
        var usedIDs = excludeIDs

        for axWindow in axWindows {
            guard enumerator.meetsDiscoveryCriteria(axWindow) else { continue }

            guard let windowID = enumerator.resolveWindowID(axWindow, candidates: cgCandidates, excludedIDs: usedIDs) else {
                continue
            }

            guard !excludeIDs.contains(windowID) else { continue }

            guard let descriptor = cgCandidates.first(where: { $0.windowID == windowID }),
                  enumerator.meetsDiscoveryCriteria(windowID: windowID, descriptor: descriptor) else {
                continue
            }

            guard enumerator.shouldAcceptWindow(
                element: axWindow,
                windowID: windowID,
                descriptor: descriptor,
                app: app,
                activeSpaces: activeSpaces,
                isScreenCaptureKitBacked: false
            ) else {
                continue
            }

            usedIDs.insert(windowID)
            candidateWindows.append((axWindow, windowID, descriptor))
        }

        // Process candidate windows concurrently
        let results = await ConcurrencyHelpers.mapConcurrent(candidateWindows, maxConcurrent: 4) { [self] candidate in
            await captureAXWindow(
                candidate.axWindow,
                windowID: candidate.windowID,
                descriptor: candidate.descriptor,
                app: app,
                appElement: appElement,
                freshIDs: freshIDs
            )
        }

        return results
    }

    private func captureAXWindow(
        _ axWindow: AXUIElement,
        windowID: CGWindowID,
        descriptor: CGWindowDescriptor,
        app: NSRunningApplication,
        appElement: AXUIElement,
        freshIDs: Set<CGWindowID>
    ) async -> CapturedWindow? {
        let title = (try? axWindow.title()) ?? windowID.title()
        let isMinimized = (try? axWindow.isMinimized()) ?? false
        let isHidden = app.isHidden
        let spaceID = windowID.spaces().first
        let closeButton = try? axWindow.closeButton()

        var window = CapturedWindow(
            id: windowID,
            title: title,
            ownerBundleID: app.bundleIdentifier,
            ownerPID: app.processIdentifier,
            bounds: descriptor.bounds,
            isMinimized: isMinimized,
            isOwnerHidden: isHidden,
            isVisible: descriptor.isOnScreen,
            desktopSpace: spaceID,
            lastInteractionTime: Date(),
            creationTime: Date(),
            axElement: axWindow,
            appAxElement: appElement,
            closeButton: closeButton
        )

        if !freshIDs.contains(windowID) {
            if let image = try? screenshotService.captureWindow(id: windowID) {
                window.cachedPreview = image
                window.previewTimestamp = Date()
                await repository.storePreview(image, forWindowID: windowID)
            }
        }

        return window
    }

    private func handleProcessEvent(_ event: ProcessEvent) async {
        switch event {
        case .applicationLaunched(let app):
            watcherManager?.watch(pid: app.processIdentifier)
            debounce(key: "launch-\(app.processIdentifier)") { [weak self] in
                await self?.refreshApplication(app)
            }

        case .applicationTerminated(let pid):
            watcherManager?.unwatch(pid: pid)
            let windows = await repository.fetch(forPID: pid)
            await repository.removeAll(forPID: pid)
            for window in windows {
                eventSubject.send(.windowDisappeared(window.id))
            }

        case .applicationActivated(let app):
            debounce(key: "activate-\(app.processIdentifier)") { [weak self] in
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
            debounce(key: "window-created-\(pid)") { [weak self] in
                await self?.refreshApplication(app)
            }

        case .windowDestroyed:
            debounce(key: "window-destroyed-\(pid)") { [weak self] in
                Logger.debug("Window destroyed notification, validating all windows", details: "pid=\(pid)")
                _ = await self?.repository.purify(forPID: pid)
            }

        case .windowMinimized(let element):
            debounce(key: "window-minimized-\(pid)") { [weak self] in
                guard let self else { return }
                _ = await repository.purify(forPID: pid)
                await updateWindowState(element: element, pid: pid) { window in
                    CapturedWindow(
                        id: window.id,
                        title: window.title,
                        ownerBundleID: window.ownerBundleID,
                        ownerPID: window.ownerPID,
                        bounds: window.bounds,
                        isMinimized: true,
                        isOwnerHidden: window.isOwnerHidden,
                        isVisible: window.isVisible,
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
                _ = await repository.purify(forPID: pid)
                await updateWindowState(element: element, pid: pid) { window in
                    CapturedWindow(
                        id: window.id,
                        title: window.title,
                        ownerBundleID: window.ownerBundleID,
                        ownerPID: window.ownerPID,
                        bounds: window.bounds,
                        isMinimized: false,
                        isOwnerHidden: window.isOwnerHidden,
                        isVisible: window.isVisible,
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
                _ = await repository.purify(forPID: pid)
                await repository.modify(forPID: pid) { windows in
                    windows = Set(windows.map { window in
                        CapturedWindow(
                            id: window.id,
                            title: window.title,
                            ownerBundleID: window.ownerBundleID,
                            ownerPID: window.ownerPID,
                            bounds: window.bounds,
                            isMinimized: window.isMinimized,
                            isOwnerHidden: true,
                            isVisible: window.isVisible,
                            desktopSpace: window.desktopSpace,
                            lastInteractionTime: window.lastInteractionTime,
                            creationTime: window.creationTime,
                            axElement: window.axElement,
                            appAxElement: window.appAxElement
                        )
                    })
                }
            }

        case .applicationRevealed:
            debounce(key: "app-revealed-\(pid)") { [weak self] in
                guard let self else { return }
                _ = await repository.purify(forPID: pid)
                await repository.modify(forPID: pid) { windows in
                    windows = Set(windows.map { window in
                        CapturedWindow(
                            id: window.id,
                            title: window.title,
                            ownerBundleID: window.ownerBundleID,
                            ownerPID: window.ownerPID,
                            bounds: window.bounds,
                            isMinimized: window.isMinimized,
                            isOwnerHidden: false,
                            isVisible: window.isVisible,
                            desktopSpace: window.desktopSpace,
                            lastInteractionTime: window.lastInteractionTime,
                            creationTime: window.creationTime,
                            axElement: window.axElement,
                            appAxElement: window.appAxElement
                        )
                    })
                }
            }

        case .windowFocused(let element), .mainWindowChanged(let element):
            await updateWindowTimestamp(element: element, pid: pid)

        case .titleChanged(let element):
            if let role = try? element.role(), role == kAXWindowRole as String {
                if let newTitle = try? element.title() {
                    await updateWindowState(element: element, pid: pid) { window in
                        CapturedWindow(
                            id: window.id,
                            title: newTitle,
                            ownerBundleID: window.ownerBundleID,
                            ownerPID: window.ownerPID,
                            bounds: window.bounds,
                            isMinimized: window.isMinimized,
                            isOwnerHidden: window.isOwnerHidden,
                            isVisible: window.isVisible,
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
            debounce(key: "geometry-\(pid)") { [weak self] in
                await self?.refreshApplication(app)
            }
        }
    }

    private func updateWindowState(element: AXUIElement, pid: pid_t, update: (CapturedWindow) -> CapturedWindow) async {
        let changes = await repository.modify(forPID: pid) { windows in
            if let windowID = try? element.windowID(),
               let existing = windows.first(where: { $0.id == windowID }) {
                windows.remove(existing)
                windows.insert(update(existing))
            } else if let existing = windows.first(where: { $0.axElement == element }) {
                windows.remove(existing)
                windows.insert(update(existing))
            }
        }
        emitChanges(changes)
    }

    private func updateWindowTimestamp(element: AXUIElement, pid: pid_t) async {
        await repository.modify(forPID: pid) { windows in
            if let windowID = try? element.windowID(),
               let existing = windows.first(where: { $0.id == windowID }) {
                windows.remove(existing)
                let updated = CapturedWindow(
                    id: existing.id,
                    title: existing.title,
                    ownerBundleID: existing.ownerBundleID,
                    ownerPID: existing.ownerPID,
                    bounds: existing.bounds,
                    isMinimized: existing.isMinimized,
                    isOwnerHidden: existing.isOwnerHidden,
                    isVisible: existing.isVisible,
                    desktopSpace: existing.desktopSpace,
                    lastInteractionTime: Date(),
                    creationTime: existing.creationTime,
                    axElement: existing.axElement,
                    appAxElement: existing.appAxElement
                )
                windows.insert(updated)
            }
        }
    }

    private func debounce(key: String, operation: @escaping () async -> Void) {
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
