import Cocoa

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

    var captureQuality: WindowCaptureQuality = .nominal

    /// Integer divisor applied to captured image dimensions before returning
    /// (1 = keep capture resolution). Downscaled captures — and 1:1 deep-color
    /// captures — are redrawn into an 8-bit bitmap to halve their resident cost.
    var downsampleFactor: Int = 1

    public init() {}

    public func captureWindow(id windowID: CGWindowID) throws -> CGImage {
        guard !headless, SystemPermissions.hasScreenRecording() else {
            throw ScreenshotError.permissionDenied
        }

        let connection = cgsMainConnection()
        var windowIDValue = UInt32(windowID)

        let resolutionOption: CaptureOptions = captureQuality == .best ? .fullResolution : .efficientResolution
        let options: CaptureOptions = [.ignoreClipping, resolutionOption]

        guard let images = CGSHWCaptureWindowList(
            connection,
            &windowIDValue,
            1,
            options
        ) as? [CGImage],
        let image = images.first else {
            throw ScreenshotError.captureFailure
        }

        if let scaled = Self.downsampled(image, factor: downsampleFactor) {
            return scaled
        }
        Self.cgImageSetCachingFlags?(image, Self.kCGImageCachingTransient)
        return image
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
}
