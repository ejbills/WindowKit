import ApplicationServices
import Cocoa

public struct WindowEnumerator {
    static let minimumWindowSize = CGSize(width: 100, height: 100)

    public init() {}

    public func enumerateWindows(forPID pid: pid_t) -> [AXUIElement] {
        AXUIElement.allWindows(forPID: pid)
    }

    public func cgDescriptors(forPID pid: pid_t) -> [CGWindowDescriptor] {
        cgWindowDescriptors(forPID: pid)
    }

    public func resolveWindowID(
        _ element: AXUIElement,
        candidates: [CGWindowDescriptor],
        excludedIDs: Set<CGWindowID> = []
    ) -> CGWindowID? {
        if let windowID = axElementWindowID(element), windowID != 0 {
            return windowID
        }

        return matchByHeuristics(element: element, candidates: candidates, excludedIDs: excludedIDs)
    }

    private func matchByHeuristics(
        element: AXUIElement,
        candidates: [CGWindowDescriptor],
        excludedIDs: Set<CGWindowID>
    ) -> CGWindowID? {
        let axTitle = (try? element.title())?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let axPosition = try? element.position()
        let axSize = try? element.size()

        let availableCandidates = candidates.filter { !excludedIDs.contains($0.windowID) }

        // Tier 1: Exact title match
        if !axTitle.isEmpty {
            if let match = availableCandidates.first(where: { candidate in
                let candidateTitle = candidate.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return candidateTitle == axTitle
            }) {
                return match.windowID
            }
        }

        // Tier 2: Geometry match (within tolerance)
        if let position = axPosition, let size = axSize, size != .zero {
            let tolerance: CGFloat = 2.0
            if let match = availableCandidates.first(where: { candidate in
                let bounds = candidate.bounds
                let positionMatch = abs(bounds.origin.x - position.x) <= tolerance &&
                                    abs(bounds.origin.y - position.y) <= tolerance
                let sizeMatch = abs(bounds.size.width - size.width) <= tolerance &&
                                abs(bounds.size.height - size.height) <= tolerance
                return positionMatch && sizeMatch
            }) {
                return match.windowID
            }
        }

        // Tier 3: Fuzzy title match
        if !axTitle.isEmpty {
            let lowercasedAXTitle = axTitle.lowercased()
            if let match = availableCandidates.first(where: { candidate in
                guard let candidateTitle = candidate.title?.lowercased() else { return false }
                return candidateTitle.contains(lowercasedAXTitle)
            }) {
                return match.windowID
            }
        }

        return nil
    }

    public func meetsDiscoveryCriteria(_ element: AXUIElement) -> Bool {
        guard let role = try? element.role(), role == kAXWindowRole as String else {
            return false
        }

        if let subrole = try? element.subrole() {
            let validSubroles = [kAXStandardWindowSubrole as String, kAXDialogSubrole as String]
            if !validSubroles.contains(subrole) {
                return false
            }
        }

        if let size = try? element.size() {
            if size.width < Self.minimumWindowSize.width || size.height < Self.minimumWindowSize.height {
                return false
            }
        }

        if let position = try? element.position() {
            if !position.x.isFinite || !position.y.isFinite {
                return false
            }
        }

        return true
    }

    public func meetsDiscoveryCriteria(windowID: CGWindowID, descriptor: CGWindowDescriptor) -> Bool {
        if descriptor.bounds.size.width < Self.minimumWindowSize.width ||
           descriptor.bounds.size.height < Self.minimumWindowSize.height {
            return false
        }

        if descriptor.alpha <= 0.01 {
            return false
        }

        if !windowID.isAtNormalLevelOrAbove() {
            return false
        }

        return true
    }

    public func shouldAcceptWindow(
        element: AXUIElement,
        windowID: CGWindowID,
        descriptor: CGWindowDescriptor,
        app: NSRunningApplication,
        activeSpaces: Set<Int>,
        isScreenCaptureKitBacked: Bool
    ) -> Bool {
        let isOnScreen = descriptor.isOnScreen
        let isFullscreen = (try? element.isFullscreen()) ?? false
        let isMinimized = (try? element.isMinimized()) ?? false
        let windowSpaces = Set(windowID.spaces())

        let isOnActiveSpace = !windowSpaces.isEmpty && !windowSpaces.isDisjoint(with: activeSpaces)

        // Ghost window detection
        let isGhostWindow = !isOnScreen && isOnActiveSpace && !isMinimized && !isFullscreen && !app.isHidden
        if isGhostWindow {
            Logger.debug("Rejecting ghost window", details: "id=\(windowID), app=\(app.localizedName ?? "?")")
            return false
        }

        if isOnScreen || isScreenCaptureKitBacked {
            return true
        }

        if app.isHidden || isFullscreen || isMinimized {
            return true
        }

        if !windowSpaces.isEmpty && windowSpaces.isDisjoint(with: activeSpaces) {
            return true
        }

        if (try? element.isMainWindow()) == true {
            return true
        }

        Logger.debug("Window rejected by acceptance criteria", details: "id=\(windowID), onScreen=\(isOnScreen), spaces=\(windowSpaces)")
        return false
    }

    public func isValidElement(_ element: AXUIElement) -> Bool {
        do {
            if let _ = try element.position(), let _ = try element.size() {
                return true
            }
        } catch AccessibilityError.operationFailed {
            return false
        } catch {
            // Geometry check failed, try slow path
        }

        do {
            if let pid = try element.processID() {
                let appElement = AXUIElement.application(pid: pid)
                if let windows = try? appElement.windows() {
                    if let elementWindowID = try? element.windowID() {
                        for window in windows {
                            if let windowID = try? window.windowID(), windowID == elementWindowID {
                                return true
                            }
                        }
                    }

                    for window in windows {
                        if CFEqual(element, window) {
                            return true
                        }
                    }
                }
            }
        } catch {
            Logger.debug("isValidElement validation failed", details: "\(error)")
        }

        return false
    }
}

extension WindowEnumerator {
    public static func isFuzzyTitleMatch(_ title1: String, _ title2: String) -> Bool {
        let words1 = Set(title1.lowercased().split(separator: " "))
        let words2 = Set(title2.lowercased().split(separator: " "))

        let matchingWords = words1.intersection(words2)
        let matchPercentage = Double(matchingWords.count) / Double(max(words1.count, words2.count))

        return matchPercentage >= 0.9 ||
               title1.lowercased().contains(title2.lowercased()) ||
               title2.lowercased().contains(title1.lowercased())
    }
}
