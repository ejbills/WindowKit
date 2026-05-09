import Cocoa

extension CapturedWindow {
    public func setFrame(_ frame: CGRect) async throws {
        try await setPositionAndSize(position: frame.origin, size: frame.size)
    }

    /// Resizes and positions the window inside the visible frame of `screen`.
    /// If no screen is supplied, WindowKit uses the window's owning display when
    /// available, then the screen containing the largest part of the window.
    public func fill(_ area: WindowFillArea, on screen: NSScreen? = nil) async throws {
        try await setFrame(targetFrame(for: area, on: screen))
    }

    public func maximize(on screen: NSScreen? = nil) async throws {
        try await fill(.full, on: screen)
    }

    public func fillLeftHalf(on screen: NSScreen? = nil) async throws {
        try await fill(.leftHalf, on: screen)
    }

    public func fillRightHalf(on screen: NSScreen? = nil) async throws {
        try await fill(.rightHalf, on: screen)
    }

    public func fillTopHalf(on screen: NSScreen? = nil) async throws {
        try await fill(.topHalf, on: screen)
    }

    public func fillBottomHalf(on screen: NSScreen? = nil) async throws {
        try await fill(.bottomHalf, on: screen)
    }

    public func fillTopLeftQuarter(on screen: NSScreen? = nil) async throws {
        try await fill(.topLeftQuarter, on: screen)
    }

    public func fillTopRightQuarter(on screen: NSScreen? = nil) async throws {
        try await fill(.topRightQuarter, on: screen)
    }

    public func fillBottomLeftQuarter(on screen: NSScreen? = nil) async throws {
        try await fill(.bottomLeftQuarter, on: screen)
    }

    public func fillBottomRightQuarter(on screen: NSScreen? = nil) async throws {
        try await fill(.bottomRightQuarter, on: screen)
    }

    private func targetFrame(for area: WindowFillArea, on screen: NSScreen?) throws -> CGRect {
        guard let targetScreen = WindowLayoutScreenResolver.screen(for: self, preferred: screen) else {
            throw WindowManipulationError.screenNotFound
        }

        return area.frame(in: WindowLayoutScreenResolver.accessibilityVisibleFrame(for: targetScreen))
    }
}

private enum WindowLayoutScreenResolver {
    static func screen(for window: CapturedWindow, preferred screen: NSScreen?) -> NSScreen? {
        if let screen { return screen }

        if let owningDisplayID = window.owningDisplayID,
           let displayScreen = NSScreen.screens.first(where: { $0.directDisplayID == owningDisplayID }) {
            return displayScreen
        }

        if let intersectingScreen = screenContainingMost(of: window.bounds) {
            return intersectingScreen
        }

        return NSScreen.main ?? NSScreen.screens.first
    }

    static func accessibilityVisibleFrame(for screen: NSScreen) -> CGRect {
        let visibleFrame = screen.visibleFrame
        let screenFrame = screen.frame

        guard let displayID = screen.directDisplayID else {
            return CGRect(
                x: visibleFrame.minX,
                y: screenFrame.maxY - visibleFrame.maxY,
                width: visibleFrame.width,
                height: visibleFrame.height
            )
        }

        let displayBounds = CGDisplayBounds(displayID)
        return CGRect(
            x: displayBounds.minX + (visibleFrame.minX - screenFrame.minX),
            y: displayBounds.minY + (screenFrame.maxY - visibleFrame.maxY),
            width: visibleFrame.width,
            height: visibleFrame.height
        )
    }

    private static func screenContainingMost(of windowBounds: CGRect) -> NSScreen? {
        let screen = NSScreen.screens.max {
            accessibilityVisibleFrame(for: $0).intersection(windowBounds).area <
                accessibilityVisibleFrame(for: $1).intersection(windowBounds).area
        }

        guard let screen,
              accessibilityVisibleFrame(for: screen).intersects(windowBounds) else {
            return nil
        }

        return screen
    }
}

private extension CGRect {
    var area: CGFloat { max(width, 0) * max(height, 0) }
}

private extension NSScreen {
    var directDisplayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
            .map { CGDirectDisplayID($0.uint32Value) }
    }
}
