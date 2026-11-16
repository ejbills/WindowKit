import Cocoa
import ScreenCaptureKit

public enum ScreenshotError: Error, Sendable {
    case permissionDenied
    case captureFailure
    case invalidWindow
    case timeout
}

/// Resolution a window capture is taken at. `.nominal` captures at 1x point
/// resolution (half the linear pixels of a Retina backing — cheaper to cache and
/// composite); `.best` captures at the window's full backing resolution.
public enum WindowCaptureQuality: String, CaseIterable, Sendable {
    case nominal
    case best
}

public struct ScreenshotService: Sendable {
    var headless: Bool = false

    public var captureQuality: WindowCaptureQuality = .nominal

    /// Integer divisor applied to captured image dimensions before returning
    /// (1 = keep capture resolution). Downscaled captures — and 1:1 deep-color
    /// captures — are redrawn into an 8-bit bitmap to halve their resident cost.
    var downsampleFactor: Int = 1

    public init() {}

    public init(captureQuality: WindowCaptureQuality) {
        self.captureQuality = captureQuality
    }

    /// The whole window, wherever it sits: minimized, hidden, on another Space, or mostly outside
    /// every display. Stage Manager strip windows exist only as thumbnails in a window-list image,
    /// so with Stage Manager on the WindowServer capture is taken as well and kept when it holds
    /// the larger picture. Synchronous WindowServer work.
    public func captureWindow(id windowID: CGWindowID) throws -> CGImage {
        guard !headless, SystemPermissions.hasScreenRecording() else {
            throw ScreenshotError.permissionDenied
        }

        var image = wholeWindowImage(id: windowID).flatMap { Self.sampledCoverage($0) > 0 ? $0 : nil }
        if image == nil || Self.isStageManagerEnabled,
           let composited = serverCompositedImage(id: windowID)
        {
            let coverage = Self.sampledCoverage(composited)
            let pixels = composited.width * composited.height
            if let whole = image {
                if coverage >= 0.5, pixels > whole.width * whole.height { image = composited }
            } else if coverage > 0 {
                image = composited
            }
        }
        guard let image else { throw ScreenshotError.captureFailure }

        if let scaled = Self.downsampled(image, factor: downsampleFactor) {
            return scaled
        }
        Self.cgImageSetCachingFlags?(image, Self.kCGImageCachingTransient)
        return image
    }

    /// Window-list image of one window by ID. Unlike `CGSHWCaptureWindowList` it is not clipped to
    /// the displays, and unlike `CGWindowListCreateImage` it also returns minimized and hidden windows.
    private func wholeWindowImage(id windowID: CGWindowID) -> CGImage? {
        guard let createImageFromArray = Self.createImageFromArray else { return nil }
        var windows: [UnsafeRawPointer?] = [UnsafeRawPointer(bitPattern: UInt(windowID))]
        guard let windowArray = CFArrayCreate(nil, &windows, 1, nil) else { return nil }
        let resolution: CGWindowImageOption = captureQuality == .best ? .bestResolution : .nominalResolution
        return createImageFromArray(.null, windowArray, CGWindowImageOption.boundsIgnoreFraming.rawValue | resolution.rawValue)?
            .takeRetainedValue()
    }

    /// WindowServer capture of one window, clipped to the displays on macOS 26 and later. With
    /// `.stageManagerFullSize` it returns Stage Manager strip windows at full size where the system still renders them.
    private func serverCompositedImage(id windowID: CGWindowID) -> CGImage? {
        var windowIDValue = UInt32(windowID)
        let resolutionOption: CaptureOptions = captureQuality == .best ? .fullResolution : .efficientResolution
        let options: CaptureOptions = [.ignoreClipping, .stageManagerFullSize, resolutionOption]
        return (CGSHWCaptureWindowList(cgsMainConnection(), &windowIDValue, 1, options) as? [CGImage])?.first
    }

    private static let windowManagerDefaults = UserDefaults(suiteName: "com.apple.WindowManager")

    private static var isStageManagerEnabled: Bool {
        windowManagerDefaults?.bool(forKey: "GloballyEnabled") ?? false
    }

    /// Marks captures transient so drawing them doesn't insert their decoded
    /// pixels into CoreGraphics' process-global image cache.
    private static let cgImageSetCachingFlags: (@convention(c) (CGImage, UInt32) -> Void)? = {
        guard let sym = dlsym(dlopen(nil, RTLD_LAZY), "CGImageSetCachingFlags") else { return nil }
        return unsafeBitCast(sym, to: (@convention(c) (CGImage, UInt32) -> Void).self)
    }()

    /// From WebKit's CoreGraphicsSPI.h: kCGImageCachingTransient = 1,
    /// kCGImageCachingTemporary = 3 (the default). 0 is not a defined flag value.
    private static let kCGImageCachingTransient: UInt32 = 1

    /// Share of a 16x16 sample grid with non-zero alpha; 1 for formats it can't read. Some apps
    /// (Electron/Chromium hosts under Stage Manager, backgrounded GPU-composited windows) hand back
    /// an all-zero-alpha surface, which must fail the capture rather than be cached as a blank preview.
    static func sampledCoverage(_ image: CGImage) -> Double {
        let alphaLeads: Bool
        switch image.alphaInfo {
        case .premultipliedFirst, .first: alphaLeads = true
        case .premultipliedLast, .last: alphaLeads = false
        default: return 1
        }
        let isLittleEndian = image.byteOrderInfo == .order32Little
        let alphaOffset = alphaLeads != isLittleEndian ? 0 : 3
        guard image.bitsPerPixel == 32,
              let data = image.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data)
        else { return 1 }
        let length = CFDataGetLength(data)
        let stepX = max(image.width / 16, 1)
        let stepY = max(image.height / 16, 1)
        var samples = 0
        var visible = 0
        var y = 0
        while y < image.height {
            var x = 0
            while x < image.width {
                let offset = y * image.bytesPerRow + x * 4 + alphaOffset
                samples += 1
                if offset < length, bytes[offset] != 0 { visible += 1 }
                x += stepX
            }
            y += stepY
        }
        return samples > 0 ? Double(visible) / Double(samples) : 0
    }

    static func downsampled(_ image: CGImage, factor: Int) -> CGImage? {
        let divisor = max(1, factor)
        // Deep-color captures (16 bits/channel) are redrawn even at 1:1 so the
        // retained bitmap is 8-bit — half the resident cost for identical preview output.
        guard divisor > 1 || image.bitsPerComponent > 8 else { return nil }

        cgImageSetCachingFlags?(image, kCGImageCachingTransient)

        let targetWidth = max(1, image.width / divisor)
        let targetHeight = max(1, image.height / divisor)
        let colorSpace = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil }
            ?? CGColorSpace(name: CGColorSpace.sRGB)!

        guard let context = CGContext(
            data: nil,
            width: targetWidth,
            height: targetHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        return context.makeImage()
    }

    public func captureBatch(_ windowIDs: [CGWindowID], concurrencyLimit: Int = 4) async -> [CGWindowID: CGImage] {
        guard !headless, SystemPermissions.hasScreenRecording() else {
            return [:]
        }

        var results: [CGWindowID: CGImage] = [:]

        await withTaskGroup(of: (CGWindowID, CGImage?).self) { group in
            var inFlight = 0

            for windowID in windowIDs {
                if inFlight >= concurrencyLimit {
                    if let (id, image) = await group.next() {
                        if let image = image {
                            results[id] = image
                        }
                        inFlight -= 1
                    }
                }

                group.addTask {
                    let image = try? self.captureWindow(id: windowID)
                    return (windowID, image)
                }
                inFlight += 1
            }

            for await (id, image) in group {
                if let image = image {
                    results[id] = image
                }
            }
        }

        return results
    }

    private static let createImageFromArray: (@convention(c) (CGRect, CFArray, UInt32) -> Unmanaged<CGImage>?)? = {
        guard let sym = dlsym(dlopen(nil, RTLD_LAZY), "CGWindowListCreateImageFromArray") else { return nil }
        return unsafeBitCast(sym, to: (@convention(c) (CGRect, CFArray, UInt32) -> Unmanaged<CGImage>?).self)
    }()

    /// Each display composited at full resolution from its on-screen windows, desktop included, leaving out
    /// `excludedWindows` and every window `excludedOwner` owns. Synchronous WindowServer work; call off the main thread.
    public func captureDisplays(
        _ displayIDs: [CGDirectDisplayID],
        excludingWindows excludedWindows: Set<CGWindowID>,
        excludingOwner excludedOwner: pid_t
    ) -> [CGDirectDisplayID: CGImage] {
        guard !headless, SystemPermissions.hasScreenRecording(), let createImageFromArray = Self.createImageFromArray else {
            return [:]
        }
        var windows: [UnsafeRawPointer?] = cgOnScreenWindowDescriptors(layer: nil, includingDesktop: true)
            .filter { !excludedWindows.contains($0.windowID) && $0.ownerPID != excludedOwner }
            .map { UnsafeRawPointer(bitPattern: UInt($0.windowID)) }
        guard let windowArray = CFArrayCreate(nil, &windows, windows.count, nil) else { return [:] }
        let lock = NSLock()
        var images: [CGDirectDisplayID: CGImage] = [:]
        DispatchQueue.concurrentPerform(iterations: displayIDs.count) { index in
            let displayID = displayIDs[index]
            guard let image = createImageFromArray(
                CGDisplayBounds(displayID), windowArray, CGWindowImageOption.bestResolution.rawValue
            )?.takeRetainedValue() else { return }
            Self.cgImageSetCachingFlags?(image, Self.kCGImageCachingTransient)
            lock.withLock { images[displayID] = image }
        }
        return images
    }

    /// Composited screen contents of `rect` (global display coordinates, top-left origin) on one display, without the cursor.
    public func captureDisplayRegion(_ rect: CGRect, displayID: CGDirectDisplayID, scale: CGFloat) async throws -> CGImage {
        guard !headless, SystemPermissions.hasScreenRecording() else {
            throw ScreenshotError.permissionDenied
        }
        let content: SCShareableContent? = await ConcurrencyHelpers.withTimeoutOptional {
            try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        }
        guard let display = content?.displays.first(where: { $0.displayID == displayID }) else {
            throw ScreenshotError.captureFailure
        }

        let displayBounds = CGDisplayBounds(displayID)
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = rect.offsetBy(dx: -displayBounds.minX, dy: -displayBounds.minY)
        configuration.width = Int(rect.width * scale)
        configuration.height = Int(rect.height * scale)
        configuration.showsCursor = false

        do {
            return try await SCScreenshotManager.captureImage(
                contentFilter: SCContentFilter(display: display, excludingWindows: []),
                configuration: configuration
            )
        } catch {
            throw ScreenshotError.captureFailure
        }
    }
}
