import Cocoa
import Combine

/// SkyLight connection-notify event that fires when the Dock's Exposé state
/// changes: at the start of Show Desktop (measured ~120ms before the windows
/// begin moving) and again when it ends, and likewise around Mission Control.
/// Only delivered to connections that own on-screen windows. Silent at idle.
private let exposeStateChangedEvent: UInt32 = 1508

/// Bridges the non-capturing C callback to the live signal. Set while a signal
/// is registered, `nil` after teardown so a late callback is a no-op.
private nonisolated(unsafe) var exposeStateSignalHandler: (() -> Void)?

/// Top-level, non-capturing callback handed to SkyLight. It must NOT call back
/// into SkyLight synchronously; it only hops to the main queue.
private func exposeStateNotifyProc(
    _: UInt32,
    _: UnsafeMutableRawPointer?,
    _: UInt32,
    _: UnsafeMutableRawPointer?
) {
    DispatchQueue.main.async {
        exposeStateSignalHandler?()
    }
}

/// Publishes Exposé state changes (Show Desktop, Mission Control) so a consumer
/// can re-read window geometry at exactly the moments it changes, instead of
/// polling. The event carries no payload; the consumer validates the state
/// (for Show Desktop, every window animating off screen) itself. A consumer
/// owns one instance, calls `start()`, and `stop()`s or releases it.
@MainActor
public final class ExposeStateSignal {
    public var stateChanged: AnyPublisher<Void, Never> { subject.eraseToAnyPublisher() }

    private let subject = PassthroughSubject<Void, Never>()
    private var registered = false
    private var connectionID: CGSConnectionID = 0

    public init() {}

    deinit {
        exposeStateSignalHandler = nil
        if registered {
            _ = slsRemoveConnectionNotify(connectionID, exposeStateNotifyProc, exposeStateChangedEvent, nil)
        }
    }

    /// Registers the notify proc on the main SkyLight connection. Idempotent.
    public func start() {
        guard !registered else { return }
        connectionID = cgsMainConnection()
        exposeStateSignalHandler = { [weak self] in
            MainActor.assumeIsolated {
                self?.subject.send()
            }
        }
        let result = slsRegisterConnectionNotify(connectionID, exposeStateNotifyProc, exposeStateChangedEvent, nil)
        registered = result == 0
        if !registered {
            exposeStateSignalHandler = nil
        }
    }

    /// Deregisters the notify proc. Idempotent.
    public func stop() {
        exposeStateSignalHandler = nil
        if registered {
            _ = slsRemoveConnectionNotify(connectionID, exposeStateNotifyProc, exposeStateChangedEvent, nil)
            registered = false
        }
    }
}
