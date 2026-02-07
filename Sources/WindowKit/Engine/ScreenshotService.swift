import Cocoa

public enum ScreenshotError: Error, Sendable {
    case permissionDenied
    case captureFailure
    case invalidWindow
    case timeout
}

public struct ScreenshotService: Sendable {
    var headless: Bool = false

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

        return image
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
