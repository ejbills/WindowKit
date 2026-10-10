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

/// A shown, unmanaged Space for the calling process's own windows. They take
/// no part in Space transitions: they neither slide with an outgoing Space nor
/// re-appear at commit, which is how the native Dock and menu bar behave.
/// Uses raw SkyLight calls, which work for the calling process's own windows
/// (foreign windows need the bridged `WindowStash` path). The Space outlives
/// the process until logout; keep one per process.
///
/// The absolute level moves, because no single level works (all measured):
///
/// - At level 0 windows order by window level against every managed Space,
///   so menus, Control Center, Notification Center and its banners, the
///   Screenshot UI and Picture-in-Picture draw over a member whose level is
///   below theirs, and drags reach members. Members still draw over Mission
///   Control. But a Space commit's window band composites over the Space:
///   `occlusionState` loses `.visible` for ~170ms, starting ~150ms before
///   the active Space flips, a visible flicker.
/// - Any higher level clears the flicker, but the Space then composites over
///   every managed-Space window regardless of window level and no drag
///   reaches it. Notification Center, Control Center and the Screenshot UI
///   sit outside every Space and post no SkyLight event when they appear, so
///   covering windows cannot be detected to lower around them.
///
/// So the Space rests at 0 and rises to `elevatedLevel` only around a commit:
/// while a holder keeps it up (`setElevationHeld`, e.g. Mission Control,
/// whose exit can commit another Space), and from a `WindowKit.focusWindow`
/// call for a window on no visible Space until the Space change settles.
/// Commits started elsewhere (Cmd-Tab, swipes, Ctrl-arrow) have no early
/// signal and keep the flicker, unless `restsElevated` is set.
///
/// Do not raise `elevatedLevel` past 100: 200/300/400 are the system shields
/// (`WindowStash` uses 400) and a Space there would draw over the lock screen.
@MainActor
public final class WindowOverlaySpace {
    public let id: CGSSpaceID

    /// Level the Space rises to around a Space commit. 0 pins the Space at
    /// rest for its lifetime.
    public let elevatedLevel: Int32

    /// Rests at `elevatedLevel` so no Space commit flickers, dropping to 0 only while a drag
    /// is in flight or a foreign menu covers a member.
    public var restsElevated = false {
        didSet {
            guard restsElevated != oldValue else { return }
            updateRestingLevel()
        }
    }

    private let connection: CGSConnectionID
    private var currentLevel = WindowOverlaySpace.restingLevel
    private var held = false
    private var commitRelease: DispatchWorkItem?
    private var subscriptions = Set<AnyCancellable>()

    private var elevatedAtRest = false
    private let dragPasteboard = NSPasteboard(name: .drag)
    private let ownPID = getpid()
    private var mouseMonitors: [Any] = []
    private var dragPasteboardBaseline = 0
    private var dragInFlight = false
    private var dragCheck: DispatchWorkItem?
    private var membershipNotifier: SkyLightConnectionNotifier?
    private let members = NSHashTable<NSWindow>.weakObjects()

    /// Foreign menus covering a member, with how many Spaces each is on; menus join every
    /// shown Space and leave all but one, so only the last leave releases.
    private var coveringWindows: [CGWindowID: Int] = [:]

    private static let restingLevel: Int32 = 0

    private static let popUpMenuLevel = Int(CGWindowLevelForKey(.popUpMenuWindow))

    /// Drag-pasteboard check interval between a press and its release.
    private static let pressPollInterval: TimeInterval = 0.06

    /// Delay after a drag's release before rising, so the drop lands while routable.
    private static let dragRestoreDelay: TimeInterval = 0.25

    /// How long a commit hold waits for the Space change before dropping.
    private static let commitTimeout: TimeInterval = 1.0

    /// How long the Space stays up after the Space change lands.
    private static let commitSettle: TimeInterval = 0.25

    public init(elevatedLevel: Int32 = 100) throws {
        connection = CGSMainConnectionID()
        guard let spaceID = slsCreateSpace(connection) else {
            throw WindowSpaceError.operationUnavailable("SLSSpaceCreate")
        }
        self.elevatedLevel = max(0, elevatedLevel)
        slsSetSpaceAbsoluteLevel(connection, spaceID, Self.restingLevel)
        slsShowSpaces(connection, [spaceID])
        id = spaceID

        installCommitSignals()
    }

    deinit {
        dragCheck?.cancel()
        let installedMonitors = mouseMonitors
        DispatchQueue.main.async {
            installedMonitors.forEach(NSEvent.removeMonitor)
        }
    }

    /// Keeps the Space elevated while `isHeld`. Releasing keeps it up through
    /// the Space commit that may follow.
    public func setElevationHeld(_ isHeld: Bool) {
        guard elevatedLevel != Self.restingLevel, isHeld != held else { return }
        held = isHeld
        if isHeld {
            commitRelease?.cancel()
            commitRelease = nil
            applyLevel()
        } else {
            awaitCommit()
        }
    }

    private func installCommitSignals() {
        guard elevatedLevel != Self.restingLevel else { return }

        WindowKit.shared.focusRequests
            .receive(on: DispatchQueue.main)
            .sink { [weak self] windowID in
                MainActor.assumeIsolated { self?.handleFocusRequest(windowID) }
            }
            .store(in: &subscriptions)

        WindowKit.shared.processEvents
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                guard case .spaceChanged = event else { return }
                MainActor.assumeIsolated { self?.handleSpaceChange() }
            }
            .store(in: &subscriptions)
    }

    private func handleFocusRequest(_ windowID: CGWindowID) {
        guard !isOnVisibleSpace(windowID) else { return }
        awaitCommit()
    }

    /// Whether some display already shows a Space the window is on, so
    /// focusing it commits nothing.
    private func isOnVisibleSpace(_ windowID: CGWindowID) -> Bool {
        let spaces = cgsWindowSpaces(connection, windowID)
        return !spaces.isEmpty && !activeSpaceIDs().isDisjoint(with: spaces)
    }

    private func handleSpaceChange() {
        guard !held, commitRelease != nil else { return }
        scheduleCommitRelease(after: Self.commitSettle)
    }

    private func awaitCommit() {
        scheduleCommitRelease(after: Self.commitTimeout)
        applyLevel()
    }

    private func scheduleCommitRelease(after delay: TimeInterval) {
        commitRelease?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            commitRelease = nil
            applyLevel()
        }
        commitRelease = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func updateRestingLevel() {
        if restsElevated, elevatedLevel != Self.restingLevel {
            elevatedAtRest = installYieldGates()
        } else {
            removeYieldGates()
            elevatedAtRest = false
        }
        applyLevel()
    }

    /// Press/release monitors for the drag check and Space-membership events for covering
    /// menus. False without a global mouse monitor, since no drop could then reach a member.
    private func installYieldGates() -> Bool {
        let mask: NSEvent.EventTypeMask = [
            .leftMouseDown, .rightMouseDown, .otherMouseDown,
            .leftMouseUp, .rightMouseUp, .otherMouseUp,
        ]
        guard let globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handleMouseEvent(event) }
        }) else {
            Logger.error("Overlay Space: no global mouse monitor, resting at 0")
            return false
        }
        mouseMonitors.append(globalMonitor)
        if let localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handleMouseEvent(event) }
            return event
        }) {
            mouseMonitors.append(localMonitor)
        }

        membershipNotifier = SkyLightConnectionNotifier(events: [.windowAddedToSpace, .windowRemovedFromSpace]) { [weak self] event, payload in
            guard let windowID = SkyLightEvent.windowID(in: payload) else { return }
            self?.handleMembershipEvent(event, windowID: windowID)
        }

        if NSEvent.pressedMouseButtons != 0 {
            dragPasteboardBaseline = dragPasteboard.changeCount
            checkPress()
        }
        return true
    }

    private func removeYieldGates() {
        mouseMonitors.forEach(NSEvent.removeMonitor)
        mouseMonitors.removeAll()
        membershipNotifier = nil
        dragCheck?.cancel()
        dragCheck = nil
        dragInFlight = false
        coveringWindows.removeAll()
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

    /// Lowers once the drag pasteboard changes during a press. A press alone must not lower:
    /// a click that activates an app on another Space commits it with the button down.
    private func checkPress() {
        guard NSEvent.pressedMouseButtons != 0 else {
            if dragInFlight {
                scheduleDragCheck(after: Self.dragRestoreDelay) { $0.restoreAfterDrag() }
            }
            return
        }

        if !dragInFlight, dragPasteboard.changeCount != dragPasteboardBaseline {
            dragInFlight = true
            applyLevel()
        }
        scheduleDragCheck(after: Self.pressPollInterval) { $0.checkPress() }
    }

    private func restoreAfterDrag() {
        guard NSEvent.pressedMouseButtons == 0 else {
            checkPress()
            return
        }
        dragInFlight = false
        applyLevel()
    }

    private func scheduleDragCheck(after delay: TimeInterval, _ body: @escaping (WindowOverlaySpace) -> Void) {
        dragCheck?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            dragCheck = nil
            body(self)
        }
        dragCheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
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

    /// Whether a foreign on-screen popup menu overlaps a visible member. Only the menu level
    /// counts, so Mission Control's window never lowers the Space mid-commit.
    private func isCoveringMember(_ windowID: CGWindowID) -> Bool {
        guard let window = cgWindowDescriptor(forWindowID: windowID),
              window.ownerPID != ownPID, window.isOnScreen, window.layer == Self.popUpMenuLevel else { return false }
        return members.allObjects.contains { $0.isVisible && ScreenCoordinates.axRect(fromAppKit: $0.frame).intersects(window.bounds) }
    }

    private func applyLevel() {
        let raised = elevatedAtRest
            ? !dragInFlight && coveringWindows.isEmpty
            : held || commitRelease != nil
        setLevel(raised ? elevatedLevel : Self.restingLevel)
    }

    private func setLevel(_ level: Int32) {
        guard level != currentLevel else { return }
        Logger.debug(
            "Overlay Space level \(currentLevel) -> \(level)",
            details: "held=\(held), awaitingCommit=\(commitRelease != nil), elevatedAtRest=\(elevatedAtRest), drag=\(dragInFlight), covering=\(Array(coveringWindows.keys))"
        )
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
