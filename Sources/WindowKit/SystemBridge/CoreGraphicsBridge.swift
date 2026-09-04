import Cocoa
import ApplicationServices

public typealias CGSConnectionID = UInt32
public typealias CGSSpaceID = UInt64

typealias CGSSpaceMask = UInt64
let kCGSAllSpacesMask: CGSSpaceMask = 0x7

public struct CaptureOptions: OptionSet, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public static let ignoreClipping = CaptureOptions(rawValue: 1 << 11)
    public static let efficientResolution = CaptureOptions(rawValue: 1 << 9)
    public static let fullResolution = CaptureOptions(rawValue: 1 << 8)
    public static let stageManagerFullSize = CaptureOptions(rawValue: 1 << 19)
}

// Private API declarations

@_silgen_name("CGSMainConnectionID")
func CGSMainConnectionID() -> CGSConnectionID

@_silgen_name("CGSHWCaptureWindowList")
func CGSHWCaptureWindowList(
    _ connection: CGSConnectionID,
    _ windowList: UnsafePointer<UInt32>,
    _ count: UInt32,
    _ options: CaptureOptions
) -> CFArray?

@_silgen_name("CGSCopySpacesForWindows")
func CGSCopySpacesForWindows(
    _ connection: CGSConnectionID,
    _ mask: CGSSpaceMask,
    _ windowIDs: CFArray
) -> CFArray?

@_silgen_name("CGSGetWindowLevel")
func CGSGetWindowLevel(
    _ connection: CGSConnectionID,
    _ windowID: UInt32,
    _ outLevel: UnsafeMutablePointer<Int32>
) -> Int32

@_silgen_name("CGSCopyWindowProperty")
func CGSCopyWindowProperty(
    _ connection: CGSConnectionID,
    _ windowID: UInt32,
    _ key: CFString,
    _ outValue: UnsafeMutablePointer<CFTypeRef?>
) -> Int32

@_silgen_name("_AXUIElementGetWindow") @discardableResult
func _AXUIElementGetWindow(_ element: AXUIElement, _ outWindowID: inout CGWindowID) -> AXError

@_silgen_name("_AXUIElementCreateWithRemoteToken")
func _AXUIElementCreateWithRemoteToken(_ token: CFData) -> Unmanaged<AXUIElement>?

// SkyLight framework bridge

struct ProcessSerialNumber {
    var highLongOfPSN: UInt32 = 0
    var lowLongOfPSN: UInt32 = 0
}

@_silgen_name("GetProcessForPID")
func GetProcessForPID(_ pid: pid_t, _ psn: UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus

enum SLPSMode: UInt32 {
    case allWindows = 0x100
    case userGenerated = 0x200
    case noWindows = 0x400
}

private typealias SLPSSetFrontProcessWithOptionsType = @convention(c) (
    UnsafeMutableRawPointer,
    CGWindowID,
    UInt32
) -> CGError

private typealias SLPSPostEventRecordToType = @convention(c) (
    UnsafeMutableRawPointer,
    UnsafeMutablePointer<UInt8>
) -> CGError

// SkyLight space management types

private typealias SLSSpaceCreateType = @convention(c) (
    CGSConnectionID, Int32, Int32
) -> CGSSpaceID

private typealias SLSSpaceSetAbsoluteLevelType = @convention(c) (
    CGSConnectionID, CGSSpaceID, Int32
) -> Void

private typealias SLSShowSpacesType = @convention(c) (
    CGSConnectionID, CFArray
) -> Void

private typealias SLSSpaceAddWindowsAndRemoveFromSpacesType = @convention(c) (
    CGSConnectionID, CGSSpaceID, CFArray, Int32
) -> Void

/// Copy-rule return must come back as Unmanaged: a `@convention(c)` type
/// treats a CF class return as +0, so the callee's +1 leaked one spaces
/// array per call (measured: ~600 leaked space dictionaries per half hour).
private typealias SLSCopyManagedDisplaySpacesType = @convention(c) (
    CGSConnectionID
) -> Unmanaged<CFArray>?

/// Connection-notify callback SkyLight invokes for registered event codes.
/// Parameters: (event type, data, data length, context). Must be a top-level
/// non-capturing C function and must never call back into SkyLight.
typealias SLSConnectionNotifyProc = @convention(c) (
    UInt32, UnsafeMutableRawPointer?, UInt32, UnsafeMutableRawPointer?
) -> Void

private typealias SLSRegisterConnectionNotifyProcType = @convention(c) (
    CGSConnectionID, SLSConnectionNotifyProc, UInt32, UnsafeMutableRawPointer?
) -> Int32

private typealias SLSRemoveConnectionNotifyProcType = @convention(c) (
    CGSConnectionID, SLSConnectionNotifyProc, UInt32, UnsafeMutableRawPointer?
) -> Int32

enum SLSSpaceAbsoluteLevel: Int32 {
    case `default` = 0
    case setupAssistant = 100
    case securityAgent = 200
    case screenLock = 300
    case notificationCenterAtScreenLock = 400
    case bootProgress = 500
    case voiceOver = 600
}

private var skyLightHandle: UnsafeMutableRawPointer?
private var setFrontProcessPtr: SLPSSetFrontProcessWithOptionsType?
private var postEventRecordPtr: SLPSPostEventRecordToType?
private var spaceCreatePtr: SLSSpaceCreateType?
private var spaceSetAbsoluteLevelPtr: SLSSpaceSetAbsoluteLevelType?
private var showSpacesPtr: SLSShowSpacesType?
private var spaceAddWindowsPtr: SLSSpaceAddWindowsAndRemoveFromSpacesType?
private var copyManagedDisplaySpacesPtr: SLSCopyManagedDisplaySpacesType?
private var registerConnectionNotifyPtr: SLSRegisterConnectionNotifyProcType?
private var removeConnectionNotifyPtr: SLSRemoveConnectionNotifyProcType?
private typealias SLSCopyWindowsWithOptionsAndTagsType = @convention(c) (CGSConnectionID, UInt32, CFArray, UInt32, UnsafeMutablePointer<UInt64>, UnsafeMutablePointer<UInt64>) -> Unmanaged<CFArray>?
private var copyWindowsWithOptionsAndTagsPtr: SLSCopyWindowsWithOptionsAndTagsType?

private func loadSkyLightFunctions() {
    guard skyLightHandle == nil else { return }

    let skyLightPath = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"
    guard let handle = dlopen(skyLightPath, RTLD_LAZY) else {
        return
    }

    skyLightHandle = handle

    if let symbol = dlsym(handle, "_SLPSSetFrontProcessWithOptions") {
        setFrontProcessPtr = unsafeBitCast(symbol, to: SLPSSetFrontProcessWithOptionsType.self)
    }

    if let symbol = dlsym(handle, "SLPSPostEventRecordTo") {
        postEventRecordPtr = unsafeBitCast(symbol, to: SLPSPostEventRecordToType.self)
    }

    if let symbol = dlsym(handle, "SLSSpaceCreate") {
        spaceCreatePtr = unsafeBitCast(symbol, to: SLSSpaceCreateType.self)
    }

    if let symbol = dlsym(handle, "SLSSpaceSetAbsoluteLevel") {
        spaceSetAbsoluteLevelPtr = unsafeBitCast(symbol, to: SLSSpaceSetAbsoluteLevelType.self)
    }

    if let symbol = dlsym(handle, "SLSShowSpaces") {
        showSpacesPtr = unsafeBitCast(symbol, to: SLSShowSpacesType.self)
    }

    if let symbol = dlsym(handle, "SLSCopyWindowsWithOptionsAndTags") {
        copyWindowsWithOptionsAndTagsPtr = unsafeBitCast(symbol, to: SLSCopyWindowsWithOptionsAndTagsType.self)
    }

    if let symbol = dlsym(handle, "SLSSpaceAddWindowsAndRemoveFromSpaces") {
        spaceAddWindowsPtr = unsafeBitCast(symbol, to: SLSSpaceAddWindowsAndRemoveFromSpacesType.self)
    }

    if let symbol = dlsym(handle, "SLSCopyManagedDisplaySpaces") {
        copyManagedDisplaySpacesPtr = unsafeBitCast(symbol, to: SLSCopyManagedDisplaySpacesType.self)
    }

    if let symbol = dlsym(handle, "SLSRegisterConnectionNotifyProc") {
        registerConnectionNotifyPtr = unsafeBitCast(symbol, to: SLSRegisterConnectionNotifyProcType.self)
    }

    if let symbol = dlsym(handle, "SLSRemoveConnectionNotifyProc") {
        removeConnectionNotifyPtr = unsafeBitCast(symbol, to: SLSRemoveConnectionNotifyProcType.self)
    }
}

func _SLPSSetFrontProcessWithOptions(
    _ psn: UnsafeMutablePointer<ProcessSerialNumber>,
    _ windowID: CGWindowID,
    _ mode: SLPSMode.RawValue
) -> CGError {
    loadSkyLightFunctions()
    guard let fn = setFrontProcessPtr else { return CGError(rawValue: -1)! }
    return fn(psn, windowID, mode)
}

func SLPSPostEventRecordTo(
    _ psn: UnsafeMutablePointer<ProcessSerialNumber>,
    _ bytes: UnsafeMutablePointer<UInt8>
) -> CGError {
    loadSkyLightFunctions()
    guard let fn = postEventRecordPtr else { return CGError(rawValue: -1)! }
    return fn(psn, bytes)
}

// Public bridge functions

public func cgsMainConnection() -> CGSConnectionID {
    CGSMainConnectionID()
}

public func cgsHardwareCaptureWindows(
    _ connection: CGSConnectionID,
    _ windowIDs: [UInt32],
    _ options: CaptureOptions
) -> [CGImage]? {
    guard !windowIDs.isEmpty else { return nil }

    return windowIDs.withUnsafeBufferPointer { buffer in
        guard let baseAddress = buffer.baseAddress else { return nil }
        let cfArray = CGSHWCaptureWindowList(
            connection,
            baseAddress,
            UInt32(windowIDs.count),
            options
        )
        return cfArray as? [CGImage]
    }
}

public func cgsWindowSpaces(_ connection: CGSConnectionID, _ windowID: CGWindowID) -> [Int] {
    let windowArray: CFArray = [NSNumber(value: UInt32(windowID))] as CFArray
    guard let spaces = CGSCopySpacesForWindows(connection, kCGSAllSpacesMask, windowArray) as? [NSNumber] else {
        return []
    }
    return spaces.map { Int($0.uint64Value) }
}

/// Window → Spaces lookup for a batch of windows in one WindowServer round
/// trip per Space, instead of one per window (`cgsWindowSpaces`). Windows on
/// none of `spaceIDs` are absent from the result; callers fall back per window.
public func cgsWindowSpaceMap(_ connection: CGSConnectionID, spaceIDs: [CGSSpaceID], windowIDs: Set<CGWindowID>) -> [CGWindowID: [Int]] {
    var result: [CGWindowID: [Int]] = [:]
    guard !windowIDs.isEmpty else { return result }
    loadSkyLightFunctions()
    for spaceID in spaceIDs {
        var setTags: UInt64 = 0
        var clearTags: UInt64 = 0
        let spaces: CFArray = [NSNumber(value: spaceID)] as CFArray
        guard let windows = copyWindowsWithOptionsAndTagsPtr?(connection, 0, spaces, 0x2, &setTags, &clearTags)?.takeRetainedValue() as? [NSNumber] else {
            continue
        }
        for number in windows {
            let windowID = CGWindowID(number.uint32Value)
            if windowIDs.contains(windowID) {
                result[windowID, default: []].append(Int(spaceID))
            }
        }
    }
    return result
}

public func cgsWindowLevel(_ connection: CGSConnectionID, _ windowID: CGWindowID) -> Int32 {
    var level: Int32 = 0
    _ = CGSGetWindowLevel(connection, UInt32(windowID), &level)
    return level
}

public func cgsWindowTitle(_ connection: CGSConnectionID, _ windowID: CGWindowID) -> String? {
    var value: CFTypeRef?
    let status = CGSCopyWindowProperty(connection, UInt32(windowID), "kCGSWindowTitle" as CFString, &value)
    guard status == 0, let str = value as? String else { return nil }
    return str
}

public func axElementWindowID(_ element: AXUIElement) -> CGWindowID? {
    var windowID: CGWindowID = 0
    let result = _AXUIElementGetWindow(element, &windowID)
    guard result == .success, windowID != 0 else { return nil }
    return windowID
}

/// Creates AXUIElement from remote token for brute-force enumeration of windows AX doesn't expose
public func axCreateElementFromToken(_ pid: pid_t, _ elementID: UInt64) -> AXUIElement? {
    var token = Data(count: 20)
    token.replaceSubrange(0 ..< 4, with: withUnsafeBytes(of: pid) { Data($0) })
    token.replaceSubrange(4 ..< 8, with: withUnsafeBytes(of: Int32(0)) { Data($0) })
    token.replaceSubrange(8 ..< 12, with: withUnsafeBytes(of: Int32(0x636F_636F)) { Data($0) })
    token.replaceSubrange(12 ..< 20, with: withUnsafeBytes(of: elementID) { Data($0) })

    return _AXUIElementCreateWithRemoteToken(token as CFData)?.takeRetainedValue()
}

public struct CGWindowDescriptor: Sendable {
    public let windowID: CGWindowID
    public let title: String?
    public let bounds: CGRect
    public let ownerPID: pid_t
    public let layer: Int
    public let alpha: CGFloat
    public let isOnScreen: Bool

    init?(from dict: [String: AnyObject]) {
        guard let windowNumber = (dict[kCGWindowNumber as String] as? NSNumber)?.uint32Value else {
            return nil
        }

        self.windowID = CGWindowID(windowNumber)
        self.title = dict[kCGWindowName as String] as? String
        self.ownerPID = (dict[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? 0
        self.layer = (dict[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
        self.alpha = CGFloat((dict[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1.0)
        self.isOnScreen = (dict[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false

        if let boundsDict = dict[kCGWindowBounds as String] as? [String: AnyObject] {
            let x = CGFloat((boundsDict["X"] as? NSNumber)?.doubleValue ?? 0)
            let y = CGFloat((boundsDict["Y"] as? NSNumber)?.doubleValue ?? 0)
            let width = CGFloat((boundsDict["Width"] as? NSNumber)?.doubleValue ?? 0)
            let height = CGFloat((boundsDict["Height"] as? NSNumber)?.doubleValue ?? 0)
            self.bounds = CGRect(x: x, y: y, width: width, height: height)
        } else {
            self.bounds = .zero
        }
    }
}

public func cgWindowDescriptors(forPID pid: pid_t) -> [CGWindowDescriptor] {
    guard let windowList = CGWindowListCopyWindowInfo([.excludeDesktopElements], kCGNullWindowID) as? [[String: AnyObject]] else {
        return []
    }

    return windowList.compactMap { dict -> CGWindowDescriptor? in
        guard let descriptor = CGWindowDescriptor(from: dict),
              descriptor.ownerPID == pid,
              descriptor.layer == 0 else {
            return nil
        }
        return descriptor
    }
}

/// Layer-0 windows currently on screen, front to back.
public func cgOnScreenWindowDescriptors() -> [CGWindowDescriptor] {
    guard let windowList = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
    ) as? [[String: AnyObject]] else {
        return []
    }

    return windowList.compactMap { dict -> CGWindowDescriptor? in
        guard let descriptor = CGWindowDescriptor(from: dict), descriptor.layer == 0 else {
            return nil
        }
        return descriptor
    }
}

public func cgWindowDescriptor(forWindowID id: CGWindowID) -> CGWindowDescriptor? {
    guard let windowList = CGWindowListCopyWindowInfo([.excludeDesktopElements], kCGNullWindowID) as? [[String: AnyObject]] else {
        return nil
    }
    for dict in windowList {
        guard let descriptor = CGWindowDescriptor(from: dict), descriptor.windowID == id else { continue }
        return descriptor
    }
    return nil
}

// MARK: - SkyLight Space Management

func slsCreateSpace(_ connection: CGSConnectionID) -> CGSSpaceID? {
    loadSkyLightFunctions()
    guard let fn = spaceCreatePtr else { return nil }
    let spaceID = fn(connection, 1, 0)
    return spaceID != 0 ? spaceID : nil
}

func slsSetSpaceAbsoluteLevel(
    _ connection: CGSConnectionID,
    _ spaceID: CGSSpaceID,
    _ level: SLSSpaceAbsoluteLevel
) {
    loadSkyLightFunctions()
    spaceSetAbsoluteLevelPtr?(connection, spaceID, level.rawValue)
}

func slsShowSpaces(_ connection: CGSConnectionID, _ spaceIDs: [CGSSpaceID]) {
    loadSkyLightFunctions()
    let cfArray = spaceIDs.map { NSNumber(value: $0) } as CFArray
    showSpacesPtr?(connection, cfArray)
}

func slsSpaceAddWindows(
    _ connection: CGSConnectionID,
    _ spaceID: CGSSpaceID,
    _ windowIDs: [CGWindowID]
) {
    loadSkyLightFunctions()
    let cfArray = windowIDs.map { NSNumber(value: $0) } as CFArray
    spaceAddWindowsPtr?(connection, spaceID, cfArray, 7)
}

func slsCopyManagedDisplaySpaces(_ connection: CGSConnectionID) -> CFArray? {
    loadSkyLightFunctions()
    return copyManagedDisplaySpacesPtr?(connection)?.takeRetainedValue()
}

/// Registers a connection-notify proc for `event` on `connection`. Returns 0 on
/// success. `callback` must be a top-level non-capturing C function.
@discardableResult
func slsRegisterConnectionNotify(
    _ connection: CGSConnectionID,
    _ callback: SLSConnectionNotifyProc,
    _ event: UInt32,
    _ context: UnsafeMutableRawPointer?
) -> Int32 {
    loadSkyLightFunctions()
    guard let fn = registerConnectionNotifyPtr else { return -1 }
    return fn(connection, callback, event, context)
}

/// Deregisters a previously registered connection-notify proc. Must be handed
/// the same `callback`, `event`, and `context` used to register.
@discardableResult
func slsRemoveConnectionNotify(
    _ connection: CGSConnectionID,
    _ callback: SLSConnectionNotifyProc,
    _ event: UInt32,
    _ context: UnsafeMutableRawPointer?
) -> Int32 {
    loadSkyLightFunctions()
    guard let fn = removeConnectionNotifyPtr else { return -1 }
    return fn(connection, callback, event, context)
}

public func activeSpaceIDs() -> Set<Int> {
    var result = Set<Int>()
    let connection = cgsMainConnection()

    // The current Space of every managed display — one SkyLight call. The
    // window-list walk below is only the fallback when that read fails.
    if let displays = try? WindowSpaces.managedDisplays() {
        result.formUnion(displays.map { Int($0.currentSpaceID) })
        if !result.isEmpty { return result }
    }

    guard let windowList = CGWindowListCopyWindowInfo([.excludeDesktopElements], kCGNullWindowID) as? [[String: AnyObject]] else {
        return result
    }

    var windowNumbers: [NSNumber] = []
    for dict in windowList {
        let layer = (dict[kCGWindowLayer as String] as? NSNumber)?.intValue ?? -1
        let isOnScreen = (dict[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false

        guard layer == 0, isOnScreen else { continue }

        if let windowNumber = dict[kCGWindowNumber as String] as? NSNumber {
            windowNumbers.append(windowNumber)
        }
    }
    guard !windowNumbers.isEmpty else { return result }

    // One round trip for the whole batch: the call already returns the union
    // of Spaces for every window passed, which is exactly this set.
    if let spaces = CGSCopySpacesForWindows(connection, kCGSAllSpacesMask, windowNumbers as CFArray) as? [NSNumber] {
        result.formUnion(spaces.map { Int($0.uint64Value) })
    }

    return result
}
