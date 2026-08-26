import Cocoa
import ObjectiveC.runtime

/// Invokes one of SkyLight's `SLSBridged*Operation` classes.
///
/// Foreign windows can only be manipulated through these: the Dock runs the
/// operation on the caller's behalf, while the matching C entry points
/// (`SLSSpaceCreate`, `SLSSpaceAddWindowsAndRemoveFromSpaces`, `CGSOrderWindow`,
/// `CGSSetWindowAlpha`) act only on windows owned by the calling connection and
/// are silent no-ops for anything else.
enum BridgedWindowManagementOperation {
    /// Allocates an operation and runs its designated initializer. `initialize`
    /// receives the allocation, the selector, and the initializer's IMP so the
    /// caller can cast it to the operation's own `@convention(c)` signature.
    static func make(
        _ className: String,
        selector selectorName: String,
        initialize: (AnyObject, Selector, IMP) -> AnyObject
    ) throws -> AnyObject {
        let selector = NSSelectorFromString(selectorName)
        guard let operationClass = NSClassFromString(className) as? NSObject.Type,
              let initializer = class_getInstanceMethod(operationClass, selector),
              let allocation = class_createInstance(operationClass, 0) as AnyObject?
        else {
            throw WindowSpaceError.operationUnavailable(className)
        }
        return initialize(allocation, selector, method_getImplementation(initializer))
    }

    /// Runs an asynchronous operation (`SLSAsynchronousBridgedWindowManagementOperation`).
    /// The window server applies the change a frame or two later, so callers
    /// must not read the result back synchronously.
    static func perform(_ operation: AnyObject) throws {
        let selector = NSSelectorFromString("performWithWMBridgeDelegate")
        guard let method = class_getInstanceMethod(type(of: operation), selector) else {
            throw WindowSpaceError.operationUnavailable("performWithWMBridgeDelegate")
        }
        typealias PerformFunction = @convention(c) (AnyObject, Selector) -> Void
        unsafeBitCast(method_getImplementation(method), to: PerformFunction.self)(operation, selector)
    }

    /// Runs a synchronous operation (`SLSSynchronousBridgedWindowManagementOperation`)
    /// and returns its result object.
    static func performReturningResult(_ operation: AnyObject) throws -> AnyObject {
        let selector = NSSelectorFromString("performWithWMBridgeDelegate")
        guard let method = class_getInstanceMethod(type(of: operation), selector) else {
            throw WindowSpaceError.operationUnavailable("performWithWMBridgeDelegate")
        }
        typealias PerformFunction = @convention(c) (AnyObject, Selector) -> Unmanaged<AnyObject>?
        guard let result = unsafeBitCast(method_getImplementation(method), to: PerformFunction.self)(
            operation, selector
        )?.takeUnretainedValue() else {
            throw WindowSpaceError.operationUnavailable(String(describing: type(of: operation)))
        }
        return result
    }

    /// Reads a `UInt64` property off an operation result object.
    static func unsignedValue(_ result: AnyObject, forKey key: String) throws -> UInt64 {
        let selector = NSSelectorFromString(key)
        guard let method = class_getInstanceMethod(type(of: result), selector) else {
            throw WindowSpaceError.operationUnavailable(key)
        }
        typealias ValueFunction = @convention(c) (AnyObject, Selector) -> UInt64
        return unsafeBitCast(method_getImplementation(method), to: ValueFunction.self)(result, selector)
    }
}

/// Takes windows off screen by moving them into a Space no display shows.
///
/// This is the only way to hide a single window of another app: `AXHidden` is
/// app-wide, minimizing runs the Dock's animation and leaves a Dock tile, and
/// parking a window off screen is clamped back by the window server.
public enum WindowStash {
    /// Level 400 (`kCGSSpaceAbsoluteLevelNotificationCenterAtScreenLock`) keeps
    /// the Space out of the display's normal Space ordering.
    private static let stashSpaceLevel: Int32 = 400

    /// Creates a Space that no display shows: it never appears in Mission
    /// Control and is absent from `SLSCopyManagedDisplaySpaces`.
    ///
    /// The Space outlives the creating process, so a caller that dies with
    /// windows still stashed leaks it until logout. Destroy it once the last
    /// window has been restored.
    public static func createSpace() throws -> CGSSpaceID {
        let operation = try BridgedWindowManagementOperation.make(
            "SLSBridgedSpaceCreateOperation",
            selector: "initWithOptions:values:"
        ) { allocation, selector, implementation in
            typealias Initializer = @convention(c) (AnyObject, Selector, UInt32, AnyObject) -> AnyObject
            return unsafeBitCast(implementation, to: Initializer.self)(
                allocation, selector, 1, [:] as NSDictionary
            )
        }

        let result = try BridgedWindowManagementOperation.performReturningResult(operation)
        let spaceID = try BridgedWindowManagementOperation.unsignedValue(result, forKey: "spaceID")
        guard spaceID != 0 else {
            throw WindowSpaceError.operationUnavailable("SLSBridgedSpaceCreateOperation")
        }

        try setAbsoluteLevel(stashSpaceLevel, of: spaceID)
        return spaceID
    }

    /// Moves the windows into `spaceID`, removing them from every Space they
    /// currently occupy. The window leaves the screen with no animation and no
    /// Dock tile, and stays alive and enumerable.
    ///
    /// The move is asynchronous: `isStashed(windowID:)` still reports the old
    /// Space for a frame or two after this returns.
    public static func move(windowIDs: [CGWindowID], toSpace spaceID: CGSSpaceID) throws {
        guard !windowIDs.isEmpty else { return }
        let windows = windowIDs.map { NSNumber(value: UInt32($0)) } as NSArray
        let operation = try BridgedWindowManagementOperation.make(
            "SLSBridgedSpaceAddWindowsAndRemoveFromSpacesOperation",
            selector: "initWithSpaceID:windows:options:"
        ) { allocation, selector, implementation in
            typealias Initializer = @convention(c) (AnyObject, Selector, CGSSpaceID, AnyObject, UInt32) -> AnyObject
            return unsafeBitCast(implementation, to: Initializer.self)(
                allocation, selector, spaceID, windows, 7
            )
        }
        try BridgedWindowManagementOperation.perform(operation)
    }

    public static func destroySpace(_ spaceID: CGSSpaceID) throws {
        let operation = try BridgedWindowManagementOperation.make(
            "SLSBridgedSpaceDestroyOperation",
            selector: "initWithSpaceID:"
        ) { allocation, selector, implementation in
            typealias Initializer = @convention(c) (AnyObject, Selector, CGSSpaceID) -> AnyObject
            return unsafeBitCast(implementation, to: Initializer.self)(allocation, selector, spaceID)
        }
        try BridgedWindowManagementOperation.perform(operation)
    }

    /// Whether the window occupies no Space at all, which is what a stashed
    /// window looks like. Minimized and hidden windows keep their Space, so
    /// this identifies a stash even across a restart of the stashing process.
    public static func isStashed(windowID: CGWindowID) -> Bool {
        WindowSpaces.spaces(forWindowID: windowID).isEmpty
    }

    private static func setAbsoluteLevel(_ level: Int32, of spaceID: CGSSpaceID) throws {
        let operation = try BridgedWindowManagementOperation.make(
            "SLSBridgedSpaceSetAbsoluteLevelOperation",
            selector: "initWithSpaceID:level:"
        ) { allocation, selector, implementation in
            typealias Initializer = @convention(c) (AnyObject, Selector, CGSSpaceID, Int32) -> AnyObject
            return unsafeBitCast(implementation, to: Initializer.self)(allocation, selector, spaceID, level)
        }
        try BridgedWindowManagementOperation.perform(operation)
    }
}
