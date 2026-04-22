import Cocoa
import ScreenCaptureKit

struct WindowDiscovery {
    static let minimumWindowSize = CGSize(width: 100, height: 100)
    static let axWorkQueue = DispatchQueue(label: "com.windowkit.axDiscovery", qos: .userInitiated)

    let repository: WindowRepository
    var screenshotService: ScreenshotService
    let enumerator: WindowEnumerator

    /// Runs synchronous work on axWorkQueue, guaranteed off main thread.
    /// Returns nil if the parent task was cancelled before work began.
    private func onAXQueue<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T? {
        await withCheckedContinuation { continuation in
            Self.axWorkQueue.async {
                guard !Task.isCancelled else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: work())
            }
        }
    }

    /// Skips windows already in cache; only discovers genuinely new ones.
    func discoverNew(for app: NSRunningApplication) async -> [CapturedWindow] {
        let pid = app.processIdentifier
        let cachedIDs = Set(repository.readCache(forPID: pid).map(\.id))

        // Fast-path: CG window list is cheap — skip expensive SCK+AX if no uncached IDs exist
        let cgIDs = Set(enumerator.cgDescriptors(forPID: pid).map(\.windowID))
        if !cgIDs.isEmpty, cgIDs.subtracting(cachedIDs).isEmpty {
            Logger.debug("discoverNew fast-path: no uncached CG IDs", details: "pid=\(pid), cached=\(cachedIDs.count)")
            return []
        }

        var discoveredWindows: [CapturedWindow] = []

        if #available(macOS 12.3, *), SystemPermissions.hasScreenRecording() {
            if let sckWindows = await discoverViaSCK(for: app, skipIDs: cachedIDs) {
                Logger.debug("SCK new-window discovery complete", details: "pid=\(pid), found=\(sckWindows.count)")
                discoveredWindows.append(contentsOf: sckWindows)
            }
        }

        let sckWindowIDs = Set(discoveredWindows.map(\.id))
        let axWindows = await discoverViaAccessibility(for: app, excludeIDs: cachedIDs.union(sckWindowIDs))
        Logger.debug("AX new-window discovery complete", details: "pid=\(pid), found=\(axWindows.count)")
        discoveredWindows.append(contentsOf: axWindows)

        return discoveredWindows
    }

    func discoverAll(for app: NSRunningApplication) async -> [CapturedWindow] {
        let pid = app.processIdentifier
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

        return discoveredWindows
    }

    @available(macOS 12.3, *)
    private func discoverViaSCK(for app: NSRunningApplication, skipIDs: Set<CGWindowID> = []) async -> [CapturedWindow]? {
        let pid = app.processIdentifier

        let contentResult: SCShareableContent? = await ConcurrencyHelpers.withTimeoutOptional {
            try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        }

        guard let content = contentResult else {
            return nil
        }

        let appWindows = content.windows.filter {
            $0.owningApplication?.processID == pid && !skipIDs.contains($0.windowID)
        }
        let freshIDs = repository.windowIDsWithFreshPreviews(forPID: pid)

        let results: [CapturedWindow] = await ConcurrencyHelpers.mapConcurrent(appWindows, maxConcurrent: 4, timeout: 10) { scWindow -> CapturedWindow? in
            guard self.isValidSCKWindow(scWindow) else { return nil }
            return await self.onAXQueue {
                self.captureFromSCKWindow(scWindow, app: app, freshIDs: freshIDs)
            } ?? nil
        }

        return results
    }

    @available(macOS 12.3, *)
    private func isValidSCKWindow(_ window: SCWindow) -> Bool {
        let onScreen = window.isOnScreen
        let layer = window.windowLayer
        let frame = window.frame
        let title = window.title
        let appName = window.owningApplication?.applicationName
        let pid = window.owningApplication?.processID

        guard onScreen,
              layer == 0,
              frame.size.width >= Self.minimumWindowSize.width,
              frame.size.height >= Self.minimumWindowSize.height else {
            Logger.debug("SCK window rejected", details: "id=\(window.windowID), app=\(appName ?? "?"), pid=\(pid.map(String.init) ?? "?"), title=\(title ?? "nil"), onScreen=\(onScreen), layer=\(layer), frame=\(frame)")
            return false
        }

        Logger.debug("SCK window accepted", details: "id=\(window.windowID), app=\(appName ?? "?"), pid=\(pid.map(String.init) ?? "?"), title=\(title ?? "nil"), onScreen=\(onScreen), layer=\(layer), frame=\(frame)")
        return true
    }

    @available(macOS 12.3, *)
    private func captureFromSCKWindow(_ scWindow: SCWindow, app: NSRunningApplication, freshIDs: Set<CGWindowID>) -> CapturedWindow? {
        let pid = app.processIdentifier
        let appElement = AXUIElement.application(pid: pid)

        guard let axWindows = try? appElement.windows(),
              let axWindow = findMatchingAXWindow(for: scWindow, in: axWindows) else {
            return nil
        }

        let closeButton = try? axWindow.closeButton()
        let minimizeButton = try? axWindow.minimizeButton()
        let role = try? axWindow.role()
        let subrole = try? axWindow.subrole()
        Logger.debug("SCK→AX match details", details: "id=\(scWindow.windowID), role=\(role ?? "nil"), subrole=\(subrole ?? "nil"), closeBtn=\(closeButton != nil), minBtn=\(minimizeButton != nil)")
        guard closeButton != nil || minimizeButton != nil else {
            return nil
        }

        let isMinimized = (try? axWindow.isMinimized()) ?? false
        let isFullscreen = (try? axWindow.isFullscreen()) ?? false
        let isHidden = app.isHidden
        let spaceID = scWindow.windowID.spaces().first
        let existingWindow = repository.readCache(windowID: scWindow.windowID)
        let creationTime = existingWindow?.creationTime ?? Date()

        var window = CapturedWindow(
            id: scWindow.windowID,
            title: scWindow.title,
            ownerBundleID: app.bundleIdentifier,
            ownerPID: pid,
            bounds: scWindow.frame,
            isMinimized: isMinimized,
            isFullscreen: isFullscreen,
            isOwnerHidden: isHidden,
            isVisible: scWindow.isOnScreen,
            owningDisplayID: Self.displayID(for: scWindow.frame),
            desktopSpace: spaceID,
            lastInteractionTime: existingWindow?.lastInteractionTime ?? Date(),
            creationTime: creationTime,
            axElement: axWindow,
            appAxElement: appElement,
            closeButton: closeButton,
            subrole: subrole
        )

        if freshIDs.contains(scWindow.windowID) {
            window.cachedPreview = existingWindow?.cachedPreview
            window.previewTimestamp = existingWindow?.previewTimestamp
        } else if let image = try? screenshotService.captureWindow(id: scWindow.windowID) {
            window.cachedPreview = image
            window.previewTimestamp = Date()
        } else {
            window.cachedPreview = existingWindow?.cachedPreview
            window.previewTimestamp = existingWindow?.previewTimestamp
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

    func discoverViaAccessibility(for app: NSRunningApplication, excludeIDs: Set<CGWindowID>) async -> [CapturedWindow] {
        let pid = app.processIdentifier
        let freshIDs = repository.windowIDsWithFreshPreviews(forPID: pid)

        typealias AXCandidate = (axWindow: AXUIElement, windowID: CGWindowID, descriptor: CGWindowDescriptor)
        let candidateWindows: [AXCandidate]? = await onAXQueue({ () -> [AXCandidate] in
            let appElement = AXUIElement.application(pid: pid)
            _ = appElement // used later in capture
            let axWindows = self.enumerator.enumerateWindows(forPID: pid)
            guard !axWindows.isEmpty else { return [] }

            let cgCandidates = self.enumerator.cgDescriptors(forPID: pid)
            let activeSpaces = activeSpaceIDs()

            var candidates: [AXCandidate] = []
            var usedIDs = excludeIDs

            for axWindow in axWindows {
                guard self.enumerator.meetsDiscoveryCriteria(axWindow) else { continue }

                guard let windowID = self.enumerator.resolveWindowID(axWindow, candidates: cgCandidates, excludedIDs: usedIDs) else {
                    continue
                }

                guard !excludeIDs.contains(windowID) else { continue }

                guard let descriptor = cgCandidates.first(where: { $0.windowID == windowID }),
                      self.enumerator.meetsDiscoveryCriteria(windowID: windowID, descriptor: descriptor) else {
                    continue
                }

                guard self.enumerator.shouldAcceptWindow(
                    element: axWindow,
                    windowID: windowID,
                    descriptor: descriptor,
                    app: app,
                    activeSpaces: activeSpaces,
                    isScreenCaptureKitBacked: false
                ) else {
                    continue
                }

                Logger.debug("AX window accepted", details: "pid=\(pid), id=\(windowID), bounds=\(descriptor.bounds)")
                usedIDs.insert(windowID)
                candidates.append((axWindow, windowID, descriptor))
            }
            return candidates
        })

        guard let candidateWindows, !candidateWindows.isEmpty else { return [] }

        let appElement = AXUIElement.application(pid: pid)
        let results = await ConcurrencyHelpers.mapConcurrent(candidateWindows, maxConcurrent: 4, timeout: 10) { candidate -> CapturedWindow? in
            await self.onAXQueue {
                self.captureAXWindow(
                    candidate.axWindow,
                    windowID: candidate.windowID,
                    descriptor: candidate.descriptor,
                    app: app,
                    appElement: appElement,
                    freshIDs: freshIDs
                )
            } ?? nil
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
    ) -> CapturedWindow? {
        let title = (try? axWindow.title()) ?? windowID.title()
        let isMinimized = (try? axWindow.isMinimized()) ?? false
        let isFullscreen = (try? axWindow.isFullscreen()) ?? false
        let isHidden = app.isHidden
        let spaceID = windowID.spaces().first
        let closeButton = try? axWindow.closeButton()
        let subrole = try? axWindow.subrole()
        let existingWindow = repository.readCache(windowID: windowID)
        let creationTime = existingWindow?.creationTime ?? Date()

        var window = CapturedWindow(
            id: windowID,
            title: title,
            ownerBundleID: app.bundleIdentifier,
            ownerPID: app.processIdentifier,
            bounds: descriptor.bounds,
            isMinimized: isMinimized,
            isFullscreen: isFullscreen,
            isOwnerHidden: isHidden,
            isVisible: descriptor.isOnScreen,
            owningDisplayID: Self.displayID(for: descriptor.bounds),
            desktopSpace: spaceID,
            lastInteractionTime: existingWindow?.lastInteractionTime ?? Date(),
            creationTime: creationTime,
            axElement: axWindow,
            appAxElement: appElement,
            closeButton: closeButton,
            subrole: subrole
        )

        if freshIDs.contains(windowID) {
            window.cachedPreview = existingWindow?.cachedPreview
            window.previewTimestamp = existingWindow?.previewTimestamp
        } else if let image = try? screenshotService.captureWindow(id: windowID) {
            window.cachedPreview = image
            window.previewTimestamp = Date()
        } else {
            window.cachedPreview = existingWindow?.cachedPreview
            window.previewTimestamp = existingWindow?.previewTimestamp
        }

        return window
    }

    static func displayID(for bounds: CGRect) -> CGDirectDisplayID? {
        var displayID: CGDirectDisplayID = 0
        var count: UInt32 = 0
        let result = CGGetDisplaysWithRect(bounds, 1, &displayID, &count)
        guard result == .success, count > 0 else { return nil }
        return displayID
    }
}
