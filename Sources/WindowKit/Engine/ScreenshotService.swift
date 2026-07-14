import Cocoa

public enum ScreenshotError: Error, Sendable {
    case permissionDenied
    case captureFailure
    case invalidWindow
    case timeout
}

public struct ScreenshotService: Sendable {
    var headless: Bool = false

    /// When set, captured images whose longest edge exceeds this many pixels are
    /// redrawn into an 8-bit sRGB bitmap at the capped size before being returned.
    /// A raw `CGSHWCaptureWindowList` capture is a full-Retina-resolution deep-color
    /// bitmap (~24MB for a 14" window); a client rendering ~500pt preview cards
    /// needs a small fraction of that.
    var maxPixelDimension: CGFloat?

    public init() {}

    public func captureWindow(id windowID: CGWindowID) throws -> CGImage {
        guard !headless, SystemPermissions.hasScreenRecording() else {
            throw ScreenshotError.permissionDenied
        }

        let connection = cgsMainConnection()
        var windowIDValue = UInt32(windowID)

        let options: CaptureOptions = [.ignoreClipping, .efficientResolution]

        guard let images = CGSHWCaptureWindowList(
            connection,
            &windowIDValue,
            1,
            options
        ) as? [CGImage],
        let image = images.first else {
            throw ScreenshotError.captureFailure
        }

        if let cap = maxPixelDimension, let scaled = Self.downsampled(image, maxDimension: cap) {
            return scaled
        }
        return image
    }

    /// CGImageSetCachingFlags(image, transient): drawing a raw multi-megapixel capture
    /// inserts its decoded pixels into CoreGraphics' process-global image cache under
    /// the cache lock, and a burst of captures (an app quit re-triggers discovery)
    /// stalls concurrent main-thread drawing — measured as dock animation stutter.
    /// Transient images bypass that cache; each capture is drawn exactly once here.
    private static let cgImageSetCachingFlags: (@convention(c) (CGImage, UInt32) -> Void)? = {
        guard let sym = dlsym(dlopen(nil, RTLD_LAZY), "CGImageSetCachingFlags") else { return nil }
        return unsafeBitCast(sym, to: (@convention(c) (CGImage, UInt32) -> Void).self)
    }()

    static func downsampled(_ image: CGImage, maxDimension: CGFloat) -> CGImage? {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let longest = max(width, height)
        guard longest > 0 else { return nil }

        let scale = min(1, maxDimension / longest)
        // Deep-color captures (16 bits/channel) are redrawn even at 1:1 so the
        // retained bitmap is 8-bit — half the resident cost for identical preview output.
        guard scale < 1 || image.bitsPerComponent > 8 else { return nil }

        cgImageSetCachingFlags?(image, 0) // kCGImageCachingTransient

        let targetWidth = max(1, Int(width * scale))
        let targetHeight = max(1, Int(height * scale))
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
