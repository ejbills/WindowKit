# WindowKit

A Swift package for macOS window discovery, tracking, manipulation, and preview capture.

> **Warning**: This package uses private macOS APIs. It may break with any macOS update. No guarantees, no warranty, use at your own risk.

## Requirements

- macOS 12.0+
- Swift 5.9+

## Permissions Required

- **Accessibility**: Window manipulation
- **Screen Recording**: Window preview capture

## Usage

### Basic Setup

```swift
import WindowKit

// Start tracking windows
WindowKit.shared.beginTracking()

// Fetch all windows (validated - invalid windows are automatically purged)
let windows = await WindowKit.shared.allWindows()

// Fetch by various criteria
let byPID = await WindowKit.shared.windows(pid: 1234)
let byApp = await WindowKit.shared.windows(application: someApp)
let byBundle = await WindowKit.shared.windows(bundleID: "com.apple.Safari")
let byID = await WindowKit.shared.window(withID: windowID)

// Manual refresh (equivalent to getActiveWindows being called on dock hover in DockDoor)
await WindowKit.shared.refresh(application: someApp)
await WindowKit.shared.refreshAll()

// Stop tracking
WindowKit.shared.endTracking()
```

### Window Events

```swift
WindowKit.shared.events
    .sink { event in
        switch event {
        case .windowAppeared(let window):
            print("New window: \(window.title ?? "untitled")")
        case .windowDisappeared(let windowID):
            print("Window closed: \(windowID)")
        case .windowChanged(let window):
            print("Window updated: \(window.title ?? "untitled")")
        case .previewCaptured(let windowID, let image):
            print("Preview captured for: \(windowID)")
        }
    }
    .store(in: &cancellables)
```

### Window Manipulation

```swift
var window = await WindowKit.shared.window(withID: someID)!

// Focus and bring to front
try window.bringToFront()

// Minimize/Restore
try window.minimize()
try window.restore()
try window.toggleMinimize()  // Returns new state

// Hide/Show application
try window.hide()
try window.unhide()
try window.toggleHidden()  // Returns new state

// Fullscreen
try window.enterFullScreen()
try window.exitFullScreen()
try window.toggleFullScreen()

// Close window or quit app
try window.close()
window.quit()             // Graceful termination
window.quit(force: true)  // Force termination

// Position and size
try window.setPosition(CGPoint(x: 100, y: 100))
try window.setSize(CGSize(width: 800, height: 600))
try window.setPositionAndSize(
    position: CGPoint(x: 100, y: 100),
    size: CGSize(width: 800, height: 600)
)
```

### Direct Accessibility Access

For advanced use cases, you can access the underlying accessibility elements:

```swift
let window = await WindowKit.shared.window(withID: someID)!

// Access AX elements directly
let axElement = window.axElement        // Window's AXUIElement
let appElement = window.appAxElement    // App's AXUIElement
let closeBtn = window.closeButton       // Close button (if available)

// Perform custom AX operations
try axElement.performAction(kAXRaiseAction)
try axElement.setAttribute(kAXPositionAttribute, value: someValue)
```

## CapturedWindow Properties

```swift
// Identity
window.id                 // CGWindowID
window.title              // String?
window.ownerBundleID      // String?
window.ownerPID           // pid_t
window.ownerApplication   // NSRunningApplication?

// Geometry
window.bounds             // CGRect

// State
window.isMinimized        // Bool
window.isOwnerHidden      // Bool
window.isVisible          // Bool
window.desktopSpace       // Int? (space ID)

// Timestamps
window.lastInteractionTime // Date
window.creationTime        // Date

// Preview
window.preview            // CGImage?

// Accessibility (for manipulation)
window.axElement          // AXUIElement
window.appAxElement       // AXUIElement
window.closeButton        // AXUIElement?
```

## Permissions

Check and request permissions:

```swift
// Check current state
let status = WindowKit.shared.permissionStatus
print("Accessibility: \(status.accessibility)")
print("Screen Recording: \(status.screenRecording)")
```

## License & Acknowledgements

MIT

Special thanks to [Louis Pontoise](https://github.com/lwouis) ([AltTab](https://github.com/lwouis/alt-tab-macos)) for graciously permitting use of his private API work under MIT.
