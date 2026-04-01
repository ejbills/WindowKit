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
    public let owningDisplayID: CGDirectDisplayID?
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
        owningDisplayID: CGDirectDisplayID? = nil,
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
        self.owningDisplayID = owningDisplayID
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
    private static let axManipulationQueue = DispatchQueue(label: "com.windowkit.axManipulation", qos: .userInitiated)

    private static func offMain<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            axManipulationQueue.async {
                do {
                    continuation.resume(returning: try work())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public mutating func bringToFront() async throws {
        guard let app = ownerApplication else {
            throw WindowManipulationError.applicationNotFound
        }

        let axEl = axElement
        let wid = id
        let pid = ownerPID

        let (newHidden, newMinimized) = try await Self.offMain {
            var hidden = app.isHidden
            var minimized = false
            if hidden {
                app.unhide()
                hidden = false
            }
            if (try? axEl.isMinimized()) == true {
                try axEl.setAttribute(kAXMinimizedAttribute, value: false)
                minimized = false
            }

            var psn = ProcessSerialNumber()
            _ = GetProcessForPID(pid, &psn)
            _ = _SLPSSetFrontProcessWithOptions(&psn, wid, SLPSMode.userGenerated.rawValue)

            var bytes = [UInt8](repeating: 0, count: 0xF8)
            bytes[0x04] = 0xF8
            bytes[0x3A] = 0x10
            var widCopy = UInt32(wid)
            memcpy(&bytes[0x3C], &widCopy, MemoryLayout<UInt32>.size)
            memset(&bytes[0x20], 0xFF, 0x10)
            bytes[0x08] = 0x01
            _ = SLPSPostEventRecordTo(&psn, &bytes)
            bytes[0x08] = 0x02
            _ = SLPSPostEventRecordTo(&psn, &bytes)

            try axEl.performAction(kAXRaiseAction)
            try axEl.setAttribute(kAXMainAttribute, value: true)
            app.activate()
            return (hidden, minimized)
        }
        isOwnerHidden = newHidden
        if !newMinimized { isMinimized = false }
    }

    @discardableResult
    public mutating func toggleMinimize() async throws -> Bool {
        let axEl = axElement
        if isMinimized {
            if let app = ownerApplication, app.isHidden {
                app.unhide()
            }
            try await Self.offMain {
                try axEl.setAttribute(kAXMinimizedAttribute, value: false)
            }
            ownerApplication?.activate()
            try await bringToFront()
            isMinimized = false
            return false
        } else {
            try await Self.offMain {
                try axEl.setAttribute(kAXMinimizedAttribute, value: true)
            }
            isMinimized = true
            return true
        }
    }

    public mutating func minimize() async throws {
        guard !isMinimized else { return }
        let axEl = axElement
        try await Self.offMain {
            try axEl.setAttribute(kAXMinimizedAttribute, value: true)
        }
        isMinimized = true
    }

    public mutating func restore() async throws {
        guard isMinimized else { return }
        if let app = ownerApplication, app.isHidden {
            app.unhide()
        }
        let axEl = axElement
        try await Self.offMain {
            try axEl.setAttribute(kAXMinimizedAttribute, value: false)
        }
        ownerApplication?.activate()
        try await bringToFront()
        isMinimized = false
    }

    @discardableResult
    public mutating func toggleHidden() async throws -> Bool {
        let newHiddenState = !isOwnerHidden
        let appAx = appAxElement
        try await Self.offMain {
            try appAx.setAttribute(kAXHiddenAttribute, value: newHiddenState)
        }
        if !newHiddenState {
            ownerApplication?.activate()
            try await bringToFront()
        }
        isOwnerHidden = newHiddenState
        return newHiddenState
    }

    public mutating func hide() async throws {
        guard !isOwnerHidden else { return }
        let appAx = appAxElement
        try await Self.offMain {
            try appAx.setAttribute(kAXHiddenAttribute, value: true)
        }
        isOwnerHidden = true
    }

    public mutating func unhide() async throws {
        guard isOwnerHidden else { return }
        let appAx = appAxElement
        try await Self.offMain {
            try appAx.setAttribute(kAXHiddenAttribute, value: false)
        }
        ownerApplication?.activate()
        try await bringToFront()
        isOwnerHidden = false
    }

    public func toggleFullScreen() async throws {
        let axEl = axElement
        try await Self.offMain {
            let isCurrentlyFullscreen = (try? axEl.isFullscreen()) ?? false
            try axEl.setAttribute("AXFullScreen", value: !isCurrentlyFullscreen)
        }
    }

    public func enterFullScreen() async throws {
        let axEl = axElement
        try await Self.offMain {
            try axEl.setAttribute("AXFullScreen", value: true)
        }
    }

    public func exitFullScreen() async throws {
        let axEl = axElement
        try await Self.offMain {
            try axEl.setAttribute("AXFullScreen", value: false)
        }
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
    case notificationBannerChanged
}
