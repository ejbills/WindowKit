import Cocoa
import Combine

/// SkyLight connection-notify events around Exposé (Show Desktop, Mission
/// Control). Measured on macOS 27:
/// - 1327 fires when an Exposé transition BEGINS, in both directions: ~500ms
///   before the Space change on Mission Control entry and exit, and ~300ms
///   before Mission Control's window is torn down on exit.
/// - 1508 fires when the Dock's Exposé state changes: at the start of Show
///   Desktop (~120ms before the windows begin moving) and again when it ends;
///   at Mission Control entry, but only after commit on Mission Control exit.
/// Only delivered to connections that own on-screen windows. Silent at idle.
private let exposeTransitionBeganEvent: UInt32 = 1327
private let exposeStateChangedEvent: UInt32 = 1508

/// Bridges the non-capturing C callback to the live signal. Set while a signal
/// is registered, `nil` after teardown so a late callback is a no-op.
private nonisolated(unsafe) var exposeStateSignalHandler: ((UInt32) -> Void)?

/// Top-level, non-capturing callback handed to SkyLight. It must NOT call back
/// into SkyLight synchronously; it only hops to the main queue.
private func exposeStateNotifyProc(
    _ event: UInt32,
    _: UnsafeMutableRawPointer?,
    _: UInt32,
    _: UnsafeMutableRawPointer?
) {
    DispatchQueue.main.async {
        exposeStateSignalHandler?(event)
    }
}

public enum ExposeEvent: Sendable {
    /// An Exposé transition (into or out of Mission Control / Show Desktop) is
    /// starting; nothing has moved yet.
    case transitionBegan
    /// The Dock's Exposé state changed.
    case stateChanged
}

/// Publishes Exposé state changes (Show Desktop, Mission Control) so a consumer
/// can re-read window geometry at exactly the moments it changes, instead of
/// polling. The event carries no payload; the consumer validates the state
/// (for Show Desktop, every window animating off screen) itself. A consumer
/// owns one instance, calls `start()`, and `stop()`s or releases it.
@MainActor
public final class ExposeStateSignal {
    public var events: AnyPublisher<ExposeEvent, Never> { subject.eraseToAnyPublisher() }

    private let subject = PassthroughSubject<ExposeEvent, Never>()
    private var registered = false
    private var connectionID: CGSConnectionID = 0

    public init() {}

    deinit {
        exposeStateSignalHandler = nil
        if registered {
            _ = slsRemoveConnectionNotify(connectionID, exposeStateNotifyProc, exposeTransitionBeganEvent, nil)
            _ = slsRemoveConnectionNotify(connectionID, exposeStateNotifyProc, exposeStateChangedEvent, nil)
        }
    }

    /// Registers the notify proc on the main SkyLight connection. Idempotent.
    public func start() {
        guard !registered else { return }
        connectionID = cgsMainConnection()
        exposeStateSignalHandler = { [weak self] event in
            MainActor.assumeIsolated {
                self?.subject.send(event == exposeTransitionBeganEvent ? .transitionBegan : .stateChanged)
            }
        }
        let began = slsRegisterConnectionNotify(connectionID, exposeStateNotifyProc, exposeTransitionBeganEvent, nil)
        let changed = slsRegisterConnectionNotify(connectionID, exposeStateNotifyProc, exposeStateChangedEvent, nil)
        registered = began == 0 || changed == 0
        if !registered {
            exposeStateSignalHandler = nil
        }
    }

    /// Deregisters the notify proc. Idempotent.
    public func stop() {
        exposeStateSignalHandler = nil
        if registered {
            _ = slsRemoveConnectionNotify(connectionID, exposeStateNotifyProc, exposeTransitionBeganEvent, nil)
            _ = slsRemoveConnectionNotify(connectionID, exposeStateNotifyProc, exposeStateChangedEvent, nil)
            registered = false
        }
    }
}
