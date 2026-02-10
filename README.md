# WindowKit

Window discovery, tracking, and manipulation for macOS.

> **Warning**: This package uses private macOS APIs. It may break with any macOS update.

## Installation

Add WindowKit to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/ejbills/WindowKit.git", branch: "main")
]
```

Then add it to your target:

```swift
.target(name: "YourApp", dependencies: ["WindowKit"])
```

Requires macOS 12+ and Swift 5.7+.

## Permissions

WindowKit needs two system permissions:

- **Accessibility** — window tracking and manipulation
- **Screen Recording** — window preview capture

```swift
let status = WindowKit.shared.permissionStatus

status.accessibilityGranted  // Bool
status.screenCaptureGranted  // Bool
status.allGranted            // both true

// Prompt the user for access
SystemPermissions.shared.requestAccessibility()
SystemPermissions.shared.requestScreenRecording()

// Or open System Settings directly
SystemPermissions.shared.openPrivacySettings(for: .accessibility)
SystemPermissions.shared.openPrivacySettings(for: .screenRecording)
```

`SystemPermissions.shared` is an `ObservableObject` — its `currentState` updates automatically via polling.

## Usage

```swift
import WindowKit

// Start tracking all windows on the system
WindowKit.shared.beginTracking()

// Query windows
let all     = await WindowKit.shared.allWindows()
let safari  = await WindowKit.shared.windows(bundleID: "com.apple.Safari")
let byPID   = await WindowKit.shared.windows(pid: 1234)
let byApp   = await WindowKit.shared.windows(application: someApp)
let single  = await WindowKit.shared.window(withID: windowID)

// Force a refresh for one app or everything
await WindowKit.shared.refresh(application: someApp)
await WindowKit.shared.refreshAll()

// Stop when done
WindowKit.shared.endTracking()
```

### CapturedWindow

Each window is a `CapturedWindow` struct:

```swift
// Identity
window.id                  // CGWindowID
window.title               // String?
window.ownerBundleID       // String?
window.ownerPID            // pid_t
window.ownerApplication    // NSRunningApplication?

// Geometry
window.bounds              // CGRect

// State
window.isMinimized         // Bool
window.isOwnerHidden       // Bool
window.isVisible           // Bool
window.desktopSpace        // Int?

// Timestamps
window.lastInteractionTime // Date
window.creationTime        // Date

// Preview
window.preview             // CGImage?

// Accessibility elements
window.axElement           // AXUIElement (the window)
window.appAxElement        // AXUIElement (the owning app)
window.closeButton         // AXUIElement?
```

### Events

Subscribe to window lifecycle changes via Combine:

```swift
WindowKit.shared.events
    .sink { event in
        switch event {
        case .windowAppeared(let window):
            // new window discovered
        case .windowDisappeared(let id):
            // window closed or owning app terminated
        case .windowChanged(let window):
            // title, bounds, minimized, or hidden state changed
        case .previewCaptured(let id, let image):
            // screenshot captured for window
        }
    }
    .store(in: &cancellables)
```

### Manipulation

```swift
var window = await WindowKit.shared.window(withID: someID)!

// Focus
try window.bringToFront()

// Minimize / restore
try window.minimize()
try window.restore()
try window.toggleMinimize()     // returns new state

// Hide / show the owning application
try window.hide()
try window.unhide()
try window.toggleHidden()       // returns new state

// Fullscreen
try window.enterFullScreen()
try window.exitFullScreen()
try window.toggleFullScreen()

// Close window or quit app
try window.close()
window.quit()                   // graceful termination
window.quit(force: true)        // force kill

// Positioning
try window.setPosition(CGPoint(x: 100, y: 100))
try window.setSize(CGSize(width: 800, height: 600))
try window.setPositionAndSize(
    position: CGPoint(x: 100, y: 100),
    size: CGSize(width: 800, height: 600)
)
```

## Configuration

```swift
// Skip screenshot capture when you only need window metadata
WindowKit.shared.headless = true

// Control how long preview images stay cached (default 30s)
WindowKit.shared.previewCacheDuration = 60

// Enable debug logging (uses os_log under the hood)
WindowKit.shared.logging = true

// Or pipe logs to your own handler
WindowKit.shared.logHandler = { level, message, details in
    print("[\(level)] \(message) \(details ?? "")")
}
```

## License

MIT — see [LICENSE](LICENSE).

Thanks to [Louis Pontoise](https://github.com/lwouis) ([AltTab](https://github.com/lwouis/alt-tab-macos)) for permitting use of his private API work under MIT.
