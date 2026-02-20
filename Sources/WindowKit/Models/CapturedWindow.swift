@preconcurrency import ApplicationServices
import Cocoa
import ScreenCaptureKit

public struct CapturedWindow: Identifiable, Hashable, @unchecked Sendable {
    public let id: CGWindowID
    public let title: String?
    public let ownerBundleID: String?
    public let ownerPID: pid_t
    public let bounds: CGRect
    public private(set) var isMinimized: Bool
    public private(set) var isFullscreen: Bool
    public private(set) var isOwnerHidden: Bool
    public let isVisible: Bool
    public let desktopSpace: Int?
    public let lastInteractionTime: Date
    public let creationTime: Date

    internal var cachedPreview: CGImage?
    internal var previewTimestamp: Date?

    public let axElement: AXUIElement
    public let appAxElement: AXUIElement
    public let closeButton: AXUIElement?

    public var preview: CGImage? { cachedPreview }
    public var ownerApplication: NSRunningApplication? {
        NSRunningApplication(processIdentifier: ownerPID)
    }

    public init(
        id: CGWindowID,
        title: String?,
        ownerBundleID: String?,
        ownerPID: pid_t,
        bounds: CGRect,
        isMinimized: Bool,
        isFullscreen: Bool,
        isOwnerHidden: Bool,
        isVisible: Bool,
        desktopSpace: Int?,
        lastInteractionTime: Date,
        creationTime: Date,
        axElement: AXUIElement,
        appAxElement: AXUIElement,
        closeButton: AXUIElement? = nil
    ) {
        self.id = id
        self.title = title
        self.ownerBundleID = ownerBundleID
        self.ownerPID = ownerPID
        self.bounds = bounds
        self.isMinimized = isMinimized
        self.isFullscreen = isFullscreen
        self.isOwnerHidden = isOwnerHidden
        self.isVisible = isVisible
        self.desktopSpace = desktopSpace
        self.lastInteractionTime = lastInteractionTime
        self.creationTime = creationTime
        self.axElement = axElement
        self.appAxElement = appAxElement
        self.closeButton = closeButton
        self.cachedPreview = nil
        self.previewTimestamp = nil
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    public static func == (lhs: CapturedWindow, rhs: CapturedWindow) -> Bool {
        lhs.id == rhs.id && lhs.ownerPID == rhs.ownerPID && lhs.axElement == rhs.axElement
    }
}

extension CapturedWindow {
    public mutating func bringToFront() throws {
        guard let app = ownerApplication else {
            throw WindowManipulationError.applicationNotFound
        }

        // Unhide the app if it's hidden
        if app.isHidden {
            app.unhide()
            isOwnerHidden = false
        }

        // Unminimize the window if it's minimized
        if (try? axElement.isMinimized()) == true {
            try axElement.setAttribute(kAXMinimizedAttribute, value: false)
            isMinimized = false
        }

        var psn = ProcessSerialNumber()
        _ = GetProcessForPID(ownerPID, &psn)
        _ = _SLPSSetFrontProcessWithOptions(&psn, id, SLPSMode.userGenerated.rawValue)

        makeKeyWindow(&psn)

        try axElement.performAction(kAXRaiseAction)
        try axElement.setAttribute(kAXMainAttribute, value: true)

        app.activate()
    }

    private func makeKeyWindow(_ psn: UnsafeMutablePointer<ProcessSerialNumber>) {
        var bytes = [UInt8](repeating: 0, count: 0xF8)
        bytes[0x04] = 0xF8
        bytes[0x3A] = 0x10
        var wid = UInt32(id)
        memcpy(&bytes[0x3C], &wid, MemoryLayout<UInt32>.size)
        memset(&bytes[0x20], 0xFF, 0x10)
        bytes[0x08] = 0x01
        _ = SLPSPostEventRecordTo(psn, &bytes)
        bytes[0x08] = 0x02
        _ = SLPSPostEventRecordTo(psn, &bytes)
    }

    @discardableResult
    public mutating func toggleMinimize() throws -> Bool {
        if isMinimized {
            if let app = ownerApplication, app.isHidden {
                app.unhide()
            }
            try axElement.setAttribute(kAXMinimizedAttribute, value: false)
            ownerApplication?.activate()
            try bringToFront()
            isMinimized = false
            return false
        } else {
            try axElement.setAttribute(kAXMinimizedAttribute, value: true)
            isMinimized = true
            return true
        }
    }

    public mutating func minimize() throws {
        guard !isMinimized else { return }
        try axElement.setAttribute(kAXMinimizedAttribute, value: true)
        isMinimized = true
    }

    public mutating func restore() throws {
        guard isMinimized else { return }
        if let app = ownerApplication, app.isHidden {
            app.unhide()
        }
        try axElement.setAttribute(kAXMinimizedAttribute, value: false)
        ownerApplication?.activate()
        try bringToFront()
        isMinimized = false
    }

    @discardableResult
    public mutating func toggleHidden() throws -> Bool {
        let newHiddenState = !isOwnerHidden
        try appAxElement.setAttribute(kAXHiddenAttribute, value: newHiddenState)
        if !newHiddenState {
            ownerApplication?.activate()
            try bringToFront()
        }
        isOwnerHidden = newHiddenState
        return newHiddenState
    }

    public mutating func hide() throws {
        guard !isOwnerHidden else { return }
        try appAxElement.setAttribute(kAXHiddenAttribute, value: true)
        isOwnerHidden = true
    }

    public mutating func unhide() throws {
        guard isOwnerHidden else { return }
        try appAxElement.setAttribute(kAXHiddenAttribute, value: false)
        ownerApplication?.activate()
        try bringToFront()
        isOwnerHidden = false
    }

    public func toggleFullScreen() throws {
        let isCurrentlyFullscreen = (try? axElement.isFullscreen()) ?? false
        try axElement.setAttribute("AXFullScreen", value: !isCurrentlyFullscreen)
    }

    public func enterFullScreen() throws {
        try axElement.setAttribute("AXFullScreen", value: true)
    }

    public func exitFullScreen() throws {
        try axElement.setAttribute("AXFullScreen", value: false)
    }

    public func close() throws {
        guard let button = closeButton else {
            throw WindowManipulationError.closeButtonNotFound
        }
        try button.performAction(kAXPressAction)
    }

    public func quit(force: Bool = false) {
        guard let app = ownerApplication else { return }
        if force {
            app.forceTerminate()
        } else {
            app.terminate()
        }
    }

    public func setPosition(_ position: CGPoint) throws {
        guard let positionValue = AXValue.from(point: position) else {
            throw WindowManipulationError.invalidValue
        }
        try axElement.setAttribute(kAXPositionAttribute, value: positionValue)
    }

    public func setSize(_ size: CGSize) throws {
        guard let sizeValue = AXValue.from(size: size) else {
            throw WindowManipulationError.invalidValue
        }
        try axElement.setAttribute(kAXSizeAttribute, value: sizeValue)
    }

    public func setPositionAndSize(position: CGPoint, size: CGSize) throws {
        try setPosition(position)
        try setSize(size)
    }
}

public enum WindowManipulationError: Error, LocalizedError {
    case applicationNotFound
    case closeButtonNotFound
    case invalidValue

    public var errorDescription: String? {
        switch self {
        case .applicationNotFound:
            return "The owning application could not be found"
        case .closeButtonNotFound:
            return "The window's close button could not be found"
        case .invalidValue:
            return "Could not create AXValue for the given value"
        }
    }
}

protocol WindowPropertySource {
    var windowID: CGWindowID { get }
    var frame: CGRect { get }
    var title: String? { get }
    var owningBundleIdentifier: String? { get }
    var owningProcessID: pid_t? { get }
    var isOnScreen: Bool { get }
    var windowLayer: Int { get }
}

@available(macOS 12.3, *)
extension SCWindow: WindowPropertySource {
    var owningBundleIdentifier: String? { owningApplication?.bundleIdentifier }
    var owningProcessID: pid_t? { owningApplication?.processID }
}

struct FallbackWindowSource: WindowPropertySource {
    let windowID: CGWindowID
    var frame: CGRect { .zero }
    var title: String? { nil }
    var owningBundleIdentifier: String? { nil }
    var owningProcessID: pid_t? { nil }
    var isOnScreen: Bool { true }
    var windowLayer: Int { 0 }
}

public enum WindowEvent: Sendable {
    case windowAppeared(CapturedWindow)
    case windowDisappeared(CGWindowID)
    case windowChanged(CapturedWindow)
    case previewCaptured(CGWindowID, CGImage)
}
