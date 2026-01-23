import Cocoa
import ApplicationServices

public typealias CGSConnectionID = UInt32
public typealias CGSSpaceID = UInt64

typealias CGSSpaceMask = UInt64
let kCGSAllSpacesMask: CGSSpaceMask = 0xFFFF_FFFF_FFFF_FFFF

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

private var skyLightHandle: UnsafeMutableRawPointer?
private var setFrontProcessPtr: SLPSSetFrontProcessWithOptionsType?
private var postEventRecordPtr: SLPSPostEventRecordToType?

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

public func activeSpaceIDs() -> Set<Int> {
    var result = Set<Int>()
    let connection = cgsMainConnection()

    guard let windowList = CGWindowListCopyWindowInfo([.excludeDesktopElements], kCGNullWindowID) as? [[String: AnyObject]] else {
        return result
    }

    for dict in windowList {
        let layer = (dict[kCGWindowLayer as String] as? NSNumber)?.intValue ?? -1
        let isOnScreen = (dict[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false

        guard layer == 0, isOnScreen else { continue }

        if let windowNumber = (dict[kCGWindowNumber as String] as? NSNumber)?.uint32Value {
            let spaces = cgsWindowSpaces(connection, CGWindowID(windowNumber))
            result.formUnion(spaces)
        }
    }

    return result
}
