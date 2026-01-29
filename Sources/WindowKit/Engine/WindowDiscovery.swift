import Cocoa
import ScreenCaptureKit

/// Performs window discovery work off the main thread.
/// All methods here run on the cooperative thread pool, not the main actor.
struct WindowDiscovery {
    static let minimumWindowSize = CGSize(width: 100, height: 100)

    let repository: WindowRepository
    let screenshotService: ScreenshotService
    let enumerator: WindowEnumerator

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
    private func discoverViaSCK(for app: NSRunningApplication) async -> [CapturedWindow]? {
        let pid = app.processIdentifier

        let contentResult: SCShareableContent? = await ConcurrencyHelpers.withTimeoutOptional {
            try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        }

        guard let content = contentResult else {
            return nil
        }

        let appWindows = content.windows.filter { $0.owningApplication?.processID == pid }
        let freshIDs = repository.windowIDsWithFreshPreviews(forPID: pid)

        let results: [CapturedWindow] = await ConcurrencyHelpers.mapConcurrent(appWindows, maxConcurrent: 4, timeout: 10) { scWindow -> CapturedWindow? in
            guard self.isValidSCKWindow(scWindow) else { return nil }
            return self.captureFromSCKWindow(scWindow, app: app, freshIDs: freshIDs)
        }

        return results
    }

    @available(macOS 12.3, *)
    private func isValidSCKWindow(_ window: SCWindow) -> Bool {
        guard window.isOnScreen,
              window.windowLayer == 0,
              window.frame.size.width >= Self.minimumWindowSize.width,
              window.frame.size.height >= Self.minimumWindowSize.height else {
            return false
        }
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
        guard closeButton != nil || minimizeButton != nil else {
            return nil
        }

        let isMinimized = (try? axWindow.isMinimized()) ?? false
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
            isOwnerHidden: isHidden,
            isVisible: scWindow.isOnScreen,
            desktopSpace: spaceID,
            lastInteractionTime: Date(),
            creationTime: creationTime,
            axElement: axWindow,
            appAxElement: appElement,
            closeButton: closeButton
        )

        if !freshIDs.contains(scWindow.windowID) {
            if let image = try? screenshotService.captureWindow(id: scWindow.windowID) {
                window.cachedPreview = image
                window.previewTimestamp = Date()
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

    func discoverViaAccessibility(for app: NSRunningApplication, excludeIDs: Set<CGWindowID>) async -> [CapturedWindow] {
        let pid = app.processIdentifier
        let appElement = AXUIElement.application(pid: pid)
        let axWindows = enumerator.enumerateWindows(forPID: pid)

        guard !axWindows.isEmpty else { return [] }

        let cgCandidates = enumerator.cgDescriptors(forPID: pid)
        let activeSpaces = activeSpaceIDs()
        let freshIDs = repository.windowIDsWithFreshPreviews(forPID: pid)

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

        let results = await ConcurrencyHelpers.mapConcurrent(candidateWindows, maxConcurrent: 4, timeout: 10) { candidate in
            self.captureAXWindow(
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
    ) -> CapturedWindow? {
        let title = (try? axWindow.title()) ?? windowID.title()
        let isMinimized = (try? axWindow.isMinimized()) ?? false
        let isHidden = app.isHidden
        let spaceID = windowID.spaces().first
        let closeButton = try? axWindow.closeButton()
        let existingWindow = repository.readCache(windowID: windowID)
        let creationTime = existingWindow?.creationTime ?? Date()

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
            creationTime: creationTime,
            axElement: axWindow,
            appAxElement: appElement,
            closeButton: closeButton
        )

        if !freshIDs.contains(windowID) {
            if let image = try? screenshotService.captureWindow(id: windowID) {
                window.cachedPreview = image
                window.previewTimestamp = Date()
            }
        }

        return window
    }
}
