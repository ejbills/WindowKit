import Cocoa

extension CapturedWindow {
    /// Sets the window frame in AppKit screen coordinates.
    public func setFrame(_ frame: CGRect) async throws {
        let screen = WindowLayoutScreenResolver.screen(containing: frame) ??
            (try? WindowLayoutScreenResolver.currentScreen(for: axElement)) ??
            NSScreen.main

        guard let screen else {
            throw WindowManipulationError.screenNotFound
        }

        try await applyWindowFrame(frame, on: screen)
    }

    /// Resizes and positions the window inside the visible frame of `screen`.
    /// If no screen is supplied, WindowKit uses the screen containing the current
    /// AX window frame.
    public func fill(_ area: WindowFillArea, on screen: NSScreen? = nil) async throws {
        let targetScreen = try screen ?? WindowLayoutScreenResolver.currentScreen(for: axElement)
        let targetFrame = area.frame(in: targetScreen.visibleFrame)
        try await applyWindowFrame(targetFrame, on: targetScreen)
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

    private func applyWindowFrame(_ targetFrame: CGRect, on screen: NSScreen) async throws {
        let primaryScreenMaxY = NSScreen.screens.first?.frame.maxY ?? screen.frame.maxY
        let position = CGPoint(x: targetFrame.minX, y: primaryScreenMaxY - targetFrame.maxY)
        let size = targetFrame.size
        guard let positionValue = AXValue.from(point: position),
              let sizeValue = AXValue.from(size: size) else {
            throw WindowManipulationError.invalidValue
        }

        let axEl = axElement
        try await Self.offMain {
            try axEl.setAttribute(kAXPositionAttribute, value: positionValue)
            try axEl.setAttribute(kAXSizeAttribute, value: sizeValue)
        }
    }
}

private enum WindowLayoutScreenResolver {
    static func currentScreen(for element: AXUIElement) throws -> NSScreen {
        guard let windowFrame = currentWindowFrame(for: element) else {
            throw WindowManipulationError.screenNotFound
        }

        guard let screen = screen(containing: windowFrame) ?? NSScreen.main else {
            throw WindowManipulationError.screenNotFound
        }

        return screen
    }

    static func currentWindowFrame(for element: AXUIElement) -> CGRect? {
        guard let position = try? element.position(),
              let size = try? element.size() else {
            return nil
        }

        let primaryScreenMaxY = NSScreen.screens.first?.frame.maxY ?? NSScreen.main?.frame.maxY ?? 0
        return CGRect(
            x: position.x,
            y: primaryScreenMaxY - position.y - size.height,
            width: size.width,
            height: size.height
        )
    }

    static func screen(containing frame: CGRect) -> NSScreen? {
        let screen = NSScreen.screens.max {
            $0.frame.intersection(frame).area < $1.frame.intersection(frame).area
        }

        guard let screen, screen.frame.intersects(frame) else {
            return nil
        }

        return screen
    }
}

private extension CGRect {
    var area: CGFloat { max(width, 0) * max(height, 0) }
}
