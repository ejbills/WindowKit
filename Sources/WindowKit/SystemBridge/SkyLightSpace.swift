import Cocoa
import Combine
import ObjectiveC.runtime

public struct ManagedDisplay: Identifiable, Hashable, Sendable {
    public var id: String { displayIdentifier }

    public let displayIdentifier: String
    public let currentSpaceID: CGSSpaceID
    public let spaces: [ManagedSpace]

    /// The NSScreen backing this managed display, matched by either the
    /// CGDirectDisplayID string or the display UUID that SkyLight reports
    /// as the display identifier.
    public var screen: NSScreen? {
        NSScreen.screens.first { screen in
            if let directDisplayID = screen.directDisplayID, String(directDisplayID) == displayIdentifier {
                return true
            }
            return screen.displayUUIDString == displayIdentifier
        }
    }
}

public struct ManagedSpace: Identifiable, Hashable, Sendable {
    public let id: CGSSpaceID
    public let displayIdentifier: String
    public let uuid: String?
    public let type: Int
    public let isCurrent: Bool

    /// A user Desktop space (CGS type 0) — the kind listed in Mission Control
    /// and targetable by `WindowSpaces.move`.
    public var isUserDesktop: Bool { type == 0 }

    /// A space created for a fullscreen app (CGS type 4).
    public var isFullscreen: Bool { type == 4 }
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

        let windows = windowsToMove.map { NSNumber(value: UInt32($0)) } as NSArray
        let operation = try BridgedWindowManagementOperation.make(
            "SLSBridgedMoveWindowsToManagedSpaceOperation",
            selector: "initWithWindows:spaceID:"
        ) { allocation, selector, implementation in
            typealias Initializer = @convention(c) (AnyObject, Selector, AnyObject, UInt64) -> AnyObject
            return unsafeBitCast(implementation, to: Initializer.self)(
                allocation, selector, windows, spaceID
            )
        }
        try BridgedWindowManagementOperation.perform(operation)
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

extension NSScreen {
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

    /// Moves the window to the given managed space and, when the window sits
    /// on a different display than `screen`, remaps its position
    /// proportionally onto that screen's visible frame — the window keeps its
    /// size and its relative placement, clamped so it stays reachable.
    public func move(toManagedSpace spaceID: CGSSpaceID, remappingOnto screen: NSScreen) async throws {
        try WindowSpaces.move(windowID: id, toManagedSpace: spaceID)

        guard let displayID = screen.directDisplayID else { return }
        let targetDisplayBounds = CGDisplayBounds(displayID)
        guard !targetDisplayBounds.intersects(bounds) else { return }

        let visible = ScreenCoordinates.axRect(fromAppKit: screen.visibleFrame)
        try await setPosition(Self.remappedOrigin(for: bounds, from: sourceDisplayBounds(), into: visible))
    }

    /// Display bounds the window currently occupies, from its owning display
    /// when known, otherwise the display it overlaps most.
    private func sourceDisplayBounds() -> CGRect? {
        if let owningDisplayID {
            return CGDisplayBounds(owningDisplayID)
        }
        return NSScreen.screens
            .compactMap { screen in screen.directDisplayID.map { CGDisplayBounds($0) } }
            .filter { $0.intersects(bounds) }
            .max { intersectionArea(with: $0) < intersectionArea(with: $1) }
    }

    private func intersectionArea(with rect: CGRect) -> CGFloat {
        let intersection = rect.intersection(bounds)
        if intersection.isNull || intersection.isEmpty {
            return 0
        }
        return intersection.width * intersection.height
    }

    /// Maps a window's position proportionally from its source display into
    /// the target display's visible area, clamped so the window stays reachable.
    private static func remappedOrigin(for bounds: CGRect, from sourceBounds: CGRect?, into visible: CGRect) -> CGPoint {
        var origin: CGPoint
        if let source = sourceBounds, source.width > 0, source.height > 0 {
            origin = CGPoint(
                x: visible.minX + (bounds.minX - source.minX) / source.width * visible.width,
                y: visible.minY + (bounds.minY - source.minY) / source.height * visible.height
            )
        } else {
            origin = CGPoint(x: visible.midX - bounds.width / 2, y: visible.midY - bounds.height / 2)
        }
        origin.x = min(max(origin.x, visible.minX), max(visible.minX, visible.maxX - bounds.width))
        origin.y = min(max(origin.y, visible.minY), max(visible.minY, visible.maxY - bounds.height))
        return origin
    }
}

/// A shown, unmanaged Space above the managed Spaces. Windows added to it are
/// composited over every managed Space on every display and take no part in
/// Space transitions: they neither slide with an outgoing Space nor re-appear
/// at commit, which is how the native Dock and menu bar behave.
/// Uses raw SkyLight calls, which work for the calling process's own windows
/// (foreign windows need the bridged `WindowStash` path). The Space outlives
/// the process until logout; keep one per process.
///
/// The absolute level moves, because no single level works (all measured):
///
/// - At level 0 a Space commit's window band composites OVER this Space:
///   `occlusionState` loses `.visible` for ~170ms as a new desktop Space
///   settles after Mission Control, a visible flicker. Any higher level
///   clears it.
/// - Above level 0 no drag reaches the Space (levels 1, 2, 10, 25, 50, 75 and
///   99 all block `draggingEntered`), and the Space's windows composite over
///   every managed-Space window regardless of window level, so a menu or
///   tooltip overlapping them is drawn underneath.
///
/// So the Space rests at `elevatedLevel` and drops to 0 while a drag is in
/// flight or a foreign window is covering a member:
///
/// - A drag is detected from the drag pasteboard's `changeCount`; routing is
///   re-evaluated per drag event, so lowering mid-drag still routes it. A
///   press alone must NOT lower: clicking an icon that activates an app on
///   another Space commits that Space with the button down, which brought the
///   flicker back on every such click.
/// - A covering window is detected two ways, each for what only it sees. The
///   SkyLight Space-membership events report every process's windows joining
///   and leaving Spaces: a foreign on-screen window at the popup-menu level
///   intersecting a visible member counts until its last leave. That catches
///   context menus from any app, tracked or not, and nothing else. Floating
///   agents' windows (the Screenshot toolbar and thumbnail, the
///   Picture-in-Picture window) either join no Space or sit at a level the
///   filter ignores and get moved by the user, so their live frames come from
///   `WindowKit.agentWindowEvents` instead. No event exists for foreign
///   window moves or z-order changes.
///
/// Lowering only restores window-level ordering: at level 0 a member still
/// draws over any foreign window whose level is below the member's own. The
/// Picture-in-Picture window sits at the utility level (19), so members that
/// should yield to it must be ordered below that level themselves.
///
/// Do not raise `elevatedLevel` past 100: 200/300/400 are the system shields
/// (`WindowStash` uses 400) and a Space there would draw over the lock screen.
@MainActor
public final class WindowOverlaySpace {
    public let id: CGSSpaceID

    /// Level the Space rests at when nothing forces it down. 0 pins the Space
    /// at the routing level for its lifetime and disables both gates.
    public let elevatedLevel: Int32

    private let connection: CGSConnectionID
    private let dragPasteboard = NSPasteboard(name: .drag)
    private var currentLevel: Int32
    private var monitors: [Any] = []
    private var dragPasteboardBaseline = 0
    private var dragInFlight = false
    private let ownPID = getpid()
    private var membershipNotifier: SkyLightConnectionNotifier?
    private var agentSubscription: AnyCancellable?

    /// Windows this process has moved into the Space, held weakly.
    private let members = NSHashTable<NSWindow>.weakObjects()

    /// Foreign windows found covering a member when they joined a Space, with
    /// the number of Spaces each is on. A menu joins every shown Space and
    /// leaves all but the current one within the same millisecond, so a window
    /// is released only when its last leave lands.
    private var coveringWindows: [CGWindowID: Int] = [:]

    /// Floating agents' window frames by pid, in AX coordinates.
    private var agentFrames: [pid_t: [CGRect]] = [:]

    /// The pending press poll or restore. They are mutually exclusive - a press
    /// cancels a pending restore, a release ends the poll - so one slot holds
    /// both, and scheduling either cancels whatever was in flight.
    private var scheduledCheck: DispatchWorkItem?

    private static let routingLevel: Int32 = 0

    /// Interval the press check runs at. It exists only between a press and its
    /// release.
    private static let pressPollInterval: TimeInterval = 0.06

    /// Delay after release before returning to `elevatedLevel`, so a drop's
    /// `performDragOperation`/`draggingEnded` still land while routable.
    ///
    /// The restore cannot hang off the mouse-up event: AppKit's drag tracking
    /// loop consumes the release, so neither monitor sees it (measured - the
    /// Space stayed at 0 forever after one drag). `pressedMouseButtons` is
    /// polled instead.
    private static let restoreDelay: TimeInterval = 0.25

    public init(elevatedLevel: Int32 = 100) throws {
        connection = CGSMainConnectionID()
        guard let spaceID = slsCreateSpace(connection) else {
            throw WindowSpaceError.operationUnavailable("SLSSpaceCreate")
        }
        self.elevatedLevel = max(0, elevatedLevel)
        currentLevel = self.elevatedLevel
        slsSetSpaceAbsoluteLevel(connection, spaceID, currentLevel)
        slsShowSpaces(connection, [spaceID])
        id = spaceID

        installDragRoutingGate()
        installCoveringGate()
        if NSEvent.pressedMouseButtons != 0 {
            dragPasteboardBaseline = dragPasteboard.changeCount
            checkPress()
        }
    }

    deinit {
        scheduledCheck?.cancel()
        let installedMonitors = monitors
        DispatchQueue.main.async {
            installedMonitors.forEach(NSEvent.removeMonitor)
        }
    }

    /// Watches mouse presses so a drag can be spotted while it is in flight.
    /// The monitors are press/release only: they add no wake on mouse movement,
    /// keystrokes or at idle. The global monitor is observe-only by
    /// construction (its handler returns Void, so it cannot consume an event),
    /// and the local one returns every event unmodified.
    ///
    /// Without the global monitor the gate could never lower the Space, which
    /// would break every drop into it. Stay at the routing level in that case
    /// and accept the commit flicker.
    private func installDragRoutingGate() {
        guard elevatedLevel != Self.routingLevel else { return }

        let mask: NSEvent.EventTypeMask = [
            .leftMouseDown, .rightMouseDown, .otherMouseDown,
            .leftMouseUp, .rightMouseUp, .otherMouseUp,
        ]

        guard let globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handleMouseEvent(event) }
        }) else {
            setLevel(Self.routingLevel)
            return
        }
        monitors.append(globalMonitor)

        if let localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handleMouseEvent(event) }
            return event
        }) {
            monitors.append(localMonitor)
        }
    }

    private func installCoveringGate() {
        guard elevatedLevel != Self.routingLevel else { return }

        membershipNotifier = SkyLightConnectionNotifier(events: [.windowAddedToSpace, .windowRemovedFromSpace]) { [weak self] event, payload in
            guard let windowID = SkyLightEvent.windowID(in: payload) else { return }
            self?.handleMembershipEvent(event, windowID: windowID)
        }

        agentSubscription = WindowKit.shared.agentWindowEvents
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                MainActor.assumeIsolated {
                    self?.agentFrames[event.pid] = event.frames.isEmpty ? nil : event.frames
                    self?.applyLevel()
                }
            }
    }

    private func handleMembershipEvent(_ event: SkyLightEvent, windowID: CGWindowID) {
        switch event {
        case .windowAddedToSpace:
            if let count = coveringWindows[windowID] {
                coveringWindows[windowID] = count + 1
            } else if isCoveringMember(windowID) {
                coveringWindows[windowID] = 1
                applyLevel()
            }
        case .windowRemovedFromSpace:
            guard let count = coveringWindows[windowID] else { return }
            if count > 1 {
                coveringWindows[windowID] = count - 1
            } else {
                coveringWindows[windowID] = nil
                applyLevel()
            }
        default:
            break
        }
    }

    /// Whether a foreign on-screen menu window overlaps a visible member. Only
    /// the popup-menu window level counts: anything else that joins a Space
    /// above the dock (Mission Control's display-sized window, Launchpad,
    /// shields) must not lower it, since that puts the Space at 0 for exactly
    /// the Space commit the elevated level exists to survive. One
    /// WindowServer lookup, for the foreign window; the members are this
    /// process's own windows and AppKit answers for them.
    private func isCoveringMember(_ windowID: CGWindowID) -> Bool {
        guard let window = cgWindowDescriptor(forWindowID: windowID),
              window.ownerPID != ownPID, window.isOnScreen, window.layer == Self.popUpMenuLevel else { return false }
        return members.allObjects.contains { $0.isVisible && ScreenCoordinates.axRect(fromAppKit: $0.frame).intersects(window.bounds) }
    }

    private static let popUpMenuLevel = Int(CGWindowLevelForKey(.popUpMenuWindow))

    /// Whether a floating agent window overlaps a visible member.
    private var isCoveredByAgent: Bool {
        guard !agentFrames.isEmpty else { return false }
        let visible = members.allObjects.filter(\.isVisible).map { ScreenCoordinates.axRect(fromAppKit: $0.frame) }
        return agentFrames.values.joined().contains { frame in visible.contains { $0.intersects(frame) } }
    }

    private func handleMouseEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            dragPasteboardBaseline = dragPasteboard.changeCount
        default:
            break
        }
        checkPress()
    }

    /// A press alone is not a drag. Clicking an icon that activates an app on
    /// another Space commits that Space while the button is still down, so
    /// lowering on the press put the Space at 0 for exactly that commit and the
    /// flicker came back. The drag pasteboard's `changeCount` is quiet through a
    /// plain click and bumps when a drag session starts, system-wide - measured
    /// from a process that was neither the drag's source nor its destination.
    private func checkPress() {
        guard NSEvent.pressedMouseButtons != 0 else {
            if dragInFlight {
                schedule(after: Self.restoreDelay) { $0.restoreAfterDrag() }
            }
            return
        }

        if !dragInFlight, dragPasteboard.changeCount != dragPasteboardBaseline {
            dragInFlight = true
            applyLevel()
        }
        schedule(after: Self.pressPollInterval) { $0.checkPress() }
    }

    private func restoreAfterDrag() {
        guard NSEvent.pressedMouseButtons == 0 else {
            checkPress()
            return
        }
        dragInFlight = false
        applyLevel()
    }

    private func applyLevel() {
        setLevel(dragInFlight || !coveringWindows.isEmpty || isCoveredByAgent ? Self.routingLevel : elevatedLevel)
    }

    private func schedule(after delay: TimeInterval, _ body: @escaping (WindowOverlaySpace) -> Void) {
        scheduledCheck?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            scheduledCheck = nil
            body(self)
        }
        scheduledCheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func setLevel(_ level: Int32) {
        guard level != currentLevel else { return }
        Logger.debug("Overlay Space level \(currentLevel) -> \(level)", details: "drag=\(dragInFlight), covering=\(Array(coveringWindows.keys)), agents=\(agentFrames)")
        currentLevel = level
        slsSetSpaceAbsoluteLevel(connection, id, level)
    }

    /// Moves the window into the overlay Space, removing it from every managed
    /// Space. Call after the window is ordered on screen.
    public func add(_ window: NSWindow) {
        slsSpaceAddWindows(connection, id, [CGWindowID(window.windowNumber)])
        members.add(window)
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
