import Cocoa

/// SkyLight connection-notify event codes this package relies on. All
/// undocumented; every entry was measured on macOS 27. Only delivered to
/// connections that own on-screen windows, and all silent at idle.
enum SkyLightEvent: UInt32 {
    /// A window was added to a Space, in any process. Payload: Space ID
    /// (UInt64) then window ID (UInt32). A window on several Spaces fires once
    /// per Space; menus join every shown Space and leave all but the current
    /// one within the same millisecond. Windows of floating agents such as
    /// `screencaptureui` join no Space and never fire this.
    case windowAddedToSpace = 1325
    /// A window left a Space; same payload as `windowAddedToSpace`.
    case windowRemovedFromSpace = 1326
    /// An Exposé transition begins, in both directions: ~500ms before the
    /// Space change on Mission Control entry and exit, ~300ms before Mission
    /// Control's window is torn down on exit.
    case exposeTransitionBegan = 1327
    /// The Dock's Exposé state changed: at the start of Show Desktop (~120ms
    /// before the windows move) and when it ends; at Mission Control entry,
    /// but only after commit on Mission Control exit.
    case dockExposeStateChanged = 1508

    /// Window ID from a Space-membership payload.
    static func windowID(in payload: Data) -> CGWindowID? {
        guard payload.count >= 12 else { return nil }
        return payload.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 8, as: CGWindowID.self) }
    }
}

private let registryLock = NSLock()
private nonisolated(unsafe) var handlersByToken: [UInt: @MainActor (SkyLightEvent, Data) -> Void] = [:]
private nonisolated(unsafe) var nextToken: UInt = 1

/// Top-level, non-capturing callback handed to SkyLight. It must NOT call back
/// into SkyLight synchronously; it copies the payload and hops to main. The
/// context is the owner's registry token, so a callback that lands after the
/// owner is gone finds no handler and drops.
private func skyLightConnectionNotifyProc(
    _ event: UInt32,
    _ data: UnsafeMutableRawPointer?,
    _ length: UInt32,
    _ context: UnsafeMutableRawPointer?
) {
    let token = UInt(bitPattern: context)
    registryLock.lock()
    let handler = handlersByToken[token]
    registryLock.unlock()
    guard let handler, let event = SkyLightEvent(rawValue: event) else { return }
    let payload = data.map { Data(bytes: $0, count: Int(length)) } ?? Data()
    DispatchQueue.main.async {
        MainActor.assumeIsolated { handler(event, payload) }
    }
}

/// One registration of SkyLight connection-notify events on the main
/// connection. `handler` runs on the main queue with the event and its raw
/// payload; the registration lives as long as the notifier.
final class SkyLightConnectionNotifier {
    private let token: UInt
    private let connection: CGSConnectionID
    private let registeredEvents: [SkyLightEvent]

    /// Nil when none of `events` could be registered.
    init?(events: [SkyLightEvent], handler: @escaping @MainActor (SkyLightEvent, Data) -> Void) {
        let connection = cgsMainConnection()
        self.connection = connection
        registryLock.lock()
        token = nextToken
        nextToken += 1
        handlersByToken[token] = handler
        registryLock.unlock()

        let context = UnsafeMutableRawPointer(bitPattern: token)
        registeredEvents = events.filter {
            slsRegisterConnectionNotify(connection, skyLightConnectionNotifyProc, $0.rawValue, context) == 0
        }
        if registeredEvents.isEmpty {
            registryLock.lock()
            handlersByToken[token] = nil
            registryLock.unlock()
            return nil
        }
    }

    deinit {
        registryLock.lock()
        handlersByToken[token] = nil
        registryLock.unlock()
        let context = UnsafeMutableRawPointer(bitPattern: token)
        for event in registeredEvents {
            _ = slsRemoveConnectionNotify(connection, skyLightConnectionNotifyProc, event.rawValue, context)
        }
    }
}
