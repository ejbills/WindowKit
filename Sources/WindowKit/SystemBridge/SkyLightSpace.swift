import Cocoa
import ObjectiveC.runtime

public struct ManagedDisplay: Identifiable, Hashable, Sendable {
    public var id: String { displayIdentifier }

    public let displayIdentifier: String
    public let currentSpaceID: CGSSpaceID
    public let spaces: [ManagedSpace]

    /// The NSScreen backing this managed display, matched by either the
    /// CGDirectDisplayID string or the display UUID that SkyLight reports
    /// as the display identifier.
    public var screen: NSScreen? {
        NSScreen.screens.first { screen in
            if let directDisplayID = screen.directDisplayID, String(directDisplayID) == displayIdentifier {
                return true
            }
            return screen.displayUUIDString == displayIdentifier
        }
    }
}

public struct ManagedSpace: Identifiable, Hashable, Sendable {
    public let id: CGSSpaceID
    public let displayIdentifier: String
    public let uuid: String?
    public let type: Int
    public let isCurrent: Bool

    /// A user Desktop space (CGS type 0) — the kind listed in Mission Control
    /// and targetable by `WindowSpaces.move`.
    public var isUserDesktop: Bool { type == 0 }

    /// A space created for a fullscreen app (CGS type 4).
    public var isFullscreen: Bool { type == 4 }
}

public enum WindowSpaceError: Error, LocalizedError, Sendable {
    case operationUnavailable(String)
    case currentSpaceUnavailable
    case invalidSpace(CGSSpaceID)

    public var errorDescription: String? {
        switch self {
        case .operationUnavailable(let name):
            return "The SkyLight operation \(name) is unavailable"
        case .currentSpaceUnavailable:
            return "The current managed Desktop space could not be resolved"
        case .invalidSpace(let spaceID):
            return "Managed Desktop space \(spaceID) does not exist"
        }
    }
}

public enum WindowSpaces {
    public static func managedDisplays() throws -> [ManagedDisplay] {
        guard let rawDisplays = slsCopyManagedDisplaySpaces(CGSMainConnectionID()) as? [[String: Any]] else {
            throw WindowSpaceError.operationUnavailable("SLSCopyManagedDisplaySpaces")
        }

        return rawDisplays.compactMap { rawDisplay in
            guard let displayIdentifier = rawDisplay["Display Identifier"] as? String,
                  let currentSpaceDictionary = rawDisplay["Current Space"] as? [String: Any],
                  let currentSpaceID = managedSpaceID(from: currentSpaceDictionary) else {
                return nil
            }

            let spaces = (rawDisplay["Spaces"] as? [[String: Any]] ?? []).compactMap { rawSpace -> ManagedSpace? in
                guard let id = managedSpaceID(from: rawSpace) else { return nil }
                return ManagedSpace(
                    id: id,
                    displayIdentifier: displayIdentifier,
                    uuid: rawSpace["uuid"] as? String,
                    type: (rawSpace["type"] as? NSNumber)?.intValue ?? 0,
                    isCurrent: id == currentSpaceID
                )
            }

            return ManagedDisplay(
                displayIdentifier: displayIdentifier,
                currentSpaceID: currentSpaceID,
                spaces: spaces
            )
        }
    }

    public static func currentManagedSpaceID() throws -> CGSSpaceID {
        let displays = try managedDisplays()

        if let mouseDisplayIdentifiers = displayIdentifiersContainingMouse(),
           let display = displays.first(where: { mouseDisplayIdentifiers.contains($0.displayIdentifier) }) {
            return display.currentSpaceID
        }

        guard let spaceID = displays.first?.currentSpaceID else {
            throw WindowSpaceError.currentSpaceUnavailable
        }
        return spaceID
    }

    public static func spaces(forWindowID windowID: CGWindowID) -> [CGSSpaceID] {
        cgsWindowSpaces(CGSMainConnectionID(), windowID).map(CGSSpaceID.init)
    }

    public static func move(windowID: CGWindowID, toManagedSpace spaceID: CGSSpaceID) throws {
        try move(windowIDs: [windowID], toManagedSpace: spaceID)
    }

    public static func move(windowIDs: [CGWindowID], toManagedSpace spaceID: CGSSpaceID) throws {
        let windowIDs = Array(Set(windowIDs))
        guard !windowIDs.isEmpty else { return }

        guard try managedDisplays().flatMap(\.spaces).contains(where: { $0.id == spaceID }) else {
            throw WindowSpaceError.invalidSpace(spaceID)
        }

        let windowsToMove = windowIDs.filter { windowID in
            !spaces(forWindowID: windowID).contains(spaceID)
        }
        guard !windowsToMove.isEmpty else { return }

        let operationName = "SLSBridgedMoveWindowsToManagedSpaceOperation"
        let initSelector = NSSelectorFromString("initWithWindows:spaceID:")
        let performSelector = NSSelectorFromString("performWithWMBridgeDelegate")

        guard let operationClass = NSClassFromString(operationName) as? NSObject.Type,
              let initMethod = class_getInstanceMethod(operationClass, initSelector),
              let performMethod = class_getInstanceMethod(operationClass, performSelector),
              let allocatedOperation = class_createInstance(operationClass, 0) as AnyObject? else {
            throw WindowSpaceError.operationUnavailable(operationName)
        }

        typealias InitFunction = @convention(c) (AnyObject, Selector, AnyObject, UInt64) -> AnyObject
        typealias PerformFunction = @convention(c) (AnyObject, Selector) -> Void

        let windows = windowsToMove.map { NSNumber(value: UInt32($0)) } as NSArray
        let operation = unsafeBitCast(method_getImplementation(initMethod), to: InitFunction.self)(
            allocatedOperation,
            initSelector,
            windows,
            spaceID
        )

        unsafeBitCast(method_getImplementation(performMethod), to: PerformFunction.self)(
            operation,
            performSelector
        )
    }

    public static func moveToCurrentManagedSpace(windowID: CGWindowID) throws {
        try move(windowID: windowID, toManagedSpace: currentManagedSpaceID())
    }

    public static func moveToCurrentManagedSpace(windowIDs: [CGWindowID]) throws {
        try move(windowIDs: windowIDs, toManagedSpace: currentManagedSpaceID())
    }

    private static func managedSpaceID(from dictionary: [String: Any]) -> CGSSpaceID? {
        if let id = (dictionary["ManagedSpaceID"] as? NSNumber)?.uint64Value {
            return id
        }
        return (dictionary["id64"] as? NSNumber)?.uint64Value
    }

    private static func displayIdentifiersContainingMouse() -> Set<String>? {
        let mouseLocation = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }),
              let displayID = screen.directDisplayID else {
            return nil
        }

        return Set([String(displayID), screen.displayUUIDString].compactMap { $0 })
    }
}

extension NSScreen {
    var directDisplayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
            .map { CGDirectDisplayID($0.uint32Value) }
    }

    var displayUUIDString: String? {
        guard let directDisplayID,
              let uuid = CGDisplayCreateUUIDFromDisplayID(directDisplayID)?.takeRetainedValue() else {
            return nil
        }
        return CFUUIDCreateString(nil, uuid) as String
    }
}

extension CapturedWindow {
    public var managedSpaces: [CGSSpaceID] {
        WindowSpaces.spaces(forWindowID: id)
    }

    public func moveToManagedSpace(_ spaceID: CGSSpaceID) throws {
        try WindowSpaces.move(windowID: id, toManagedSpace: spaceID)
    }

    public func moveToCurrentManagedSpace() throws {
        try WindowSpaces.moveToCurrentManagedSpace(windowID: id)
    }

    /// Moves the window to the given managed space and, when the window sits
    /// on a different display than `screen`, remaps its position
    /// proportionally onto that screen's visible frame — the window keeps its
    /// size and its relative placement, clamped so it stays reachable.
    public func move(toManagedSpace spaceID: CGSSpaceID, remappingOnto screen: NSScreen) async throws {
        try WindowSpaces.move(windowID: id, toManagedSpace: spaceID)

        guard let displayID = screen.directDisplayID else { return }
        let targetDisplayBounds = CGDisplayBounds(displayID)
        guard !targetDisplayBounds.intersects(bounds) else { return }

        let visible = ScreenCoordinates.axRect(fromAppKit: screen.visibleFrame)
        try await setPosition(Self.remappedOrigin(for: bounds, from: sourceDisplayBounds(), into: visible))
    }

    /// Display bounds the window currently occupies, from its owning display
    /// when known, otherwise the display it overlaps most.
    private func sourceDisplayBounds() -> CGRect? {
        if let owningDisplayID {
            return CGDisplayBounds(owningDisplayID)
        }
        return NSScreen.screens
            .compactMap { screen in screen.directDisplayID.map { CGDisplayBounds($0) } }
            .filter { $0.intersects(bounds) }
            .max { intersectionArea(with: $0) < intersectionArea(with: $1) }
    }

    private func intersectionArea(with rect: CGRect) -> CGFloat {
        let intersection = rect.intersection(bounds)
        if intersection.isNull || intersection.isEmpty {
            return 0
        }
        return intersection.width * intersection.height
    }

    /// Maps a window's position proportionally from its source display into
    /// the target display's visible area, clamped so the window stays reachable.
    private static func remappedOrigin(for bounds: CGRect, from sourceBounds: CGRect?, into visible: CGRect) -> CGPoint {
        var origin: CGPoint
        if let source = sourceBounds, source.width > 0, source.height > 0 {
            origin = CGPoint(
                x: visible.minX + (bounds.minX - source.minX) / source.width * visible.width,
                y: visible.minY + (bounds.minY - source.minY) / source.height * visible.height
            )
        } else {
            origin = CGPoint(x: visible.midX - bounds.width / 2, y: visible.midY - bounds.height / 2)
        }
        origin.x = min(max(origin.x, visible.minX), max(visible.minX, visible.maxX - bounds.width))
        origin.y = min(max(origin.y, visible.minY), max(visible.minY, visible.maxY - bounds.height))
        return origin
    }
}

final class SkyLightSpaceOperator {
    static let shared = SkyLightSpaceOperator()

    private let connection: CGSConnectionID
    private var spaceID: CGSSpaceID?

    private init() {
        connection = CGSMainConnectionID()
    }

    private func ensureSpace() -> CGSSpaceID? {
        if let spaceID { return spaceID }

        guard let sid = slsCreateSpace(connection) else {
            Logger.error("SkyLightSpace: failed to create space")
            return nil
        }

        slsSetSpaceAbsoluteLevel(connection, sid, .notificationCenterAtScreenLock)
        slsShowSpaces(connection, [sid])
        spaceID = sid
        Logger.info("SkyLightSpace: created space \(sid) at level 400")
        return sid
    }

    func addWindow(_ windowID: CGWindowID) {
        guard let sid = ensureSpace() else { return }
        slsSpaceAddWindows(connection, sid, [windowID])
        Logger.debug("SkyLightSpace: moved window \(windowID) to space \(sid)")
    }
}
