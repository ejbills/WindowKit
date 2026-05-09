import Cocoa
import ObjectiveC.runtime

public struct ManagedDisplay: Identifiable, Hashable, Sendable {
    public var id: String { displayIdentifier }

    public let displayIdentifier: String
    public let currentSpaceID: CGSSpaceID
    public let spaces: [ManagedSpace]
}

public struct ManagedSpace: Identifiable, Hashable, Sendable {
    public let id: CGSSpaceID
    public let displayIdentifier: String
    public let uuid: String?
    public let type: Int
    public let isCurrent: Bool
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

private extension NSScreen {
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
