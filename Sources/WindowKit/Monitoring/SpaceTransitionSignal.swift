import Cocoa
import Combine

/// SkyLight connection-notify event that fires ~140ms into a Space transition,
/// at the START of the animation. Generic across transition kinds and also fires
/// for same-Space application switches (it means "a compositor transition began",
/// not "the active Space changed"), so consumers must validate it. Idle-safe: at
/// idle only the unrelated 30Hz heartbeat (818) fires, never 913.
private let spaceTransitionStartedEvent: UInt32 = 913

/// Bridges the non-capturing C callback to the live signal. Set while a signal is
/// registered, `nil` after teardown so a late callback is a no-op. A single
/// `SpaceTransitionSignal` is the only writer.
private nonisolated(unsafe) var spaceTransitionSignalHandler: (() -> Void)?

/// Top-level, non-capturing callback handed to SkyLight. It must NOT call back
/// into SkyLight synchronously; it only hops to the main queue and invokes the
/// global handler, which performs the transform validation and publishes.
private func spaceTransitionNotifyProc(
    _: UInt32,
    _: UnsafeMutableRawPointer?,
    _: UInt32,
    _: UnsafeMutableRawPointer?
) {
    DispatchQueue.main.async {
        spaceTransitionSignalHandler?()
    }
}

/// Publishes the early edge of a REAL Space transition (fullscreen enter/exit,
/// Desktop switch, Mission Control) so a consumer can react at the start of the
/// animation instead of at commit.
///
/// The raw SkyLight 913 marker also fires for same-Space application switches, so
/// each marker is validated against the live Space transforms before publishing:
/// a real transition is already translating a Space by the time 913 arrives
/// (`tx`/`ty` well off identity), while an app switch leaves every Space at
/// identity. Only translating markers are forwarded on `transitionStarted`.
///
/// Singleton-free — a consumer owns one instance, calls `start()`, subscribes to
/// `transitionStarted`, and calls `stop()` (or releases it) to deregister.
@MainActor
public final class SpaceTransitionSignal {
    public var transitionStarted: AnyPublisher<Void, Never> { subject.eraseToAnyPublisher() }

    private let subject = PassthroughSubject<Void, Never>()
    private var registered = false
    private var connectionID: CGSConnectionID = 0

    /// Minimum |tx|/|ty| (points) in a Space's live transform for it to count as
    /// actively translating. A real transition reads well above this by the time
    /// 913 fires; an app switch reads exactly identity.
    private static let translationThreshold: CGFloat = 1.0

    public init() {}

    deinit {
        spaceTransitionSignalHandler = nil
        if registered {
            _ = slsRemoveConnectionNotify(connectionID, spaceTransitionNotifyProc, spaceTransitionStartedEvent, nil)
        }
    }

    /// Registers the 913 notify proc on the main SkyLight connection. Idempotent.
    public func start() {
        guard !registered else { return }
        connectionID = cgsMainConnection()
        spaceTransitionSignalHandler = { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.isSpaceActuallyTransitioning() else { return }
                self.subject.send()
            }
        }
        let result = slsRegisterConnectionNotify(connectionID, spaceTransitionNotifyProc, spaceTransitionStartedEvent, nil)
        registered = result == 0
        if !registered {
            spaceTransitionSignalHandler = nil
        }
    }

    /// Deregisters the notify proc. Idempotent.
    public func stop() {
        spaceTransitionSignalHandler = nil
        guard registered else { return }
        _ = slsRemoveConnectionNotify(connectionID, spaceTransitionNotifyProc, spaceTransitionStartedEvent, nil)
        registered = false
    }

    /// True when any managed Space on any display is mid-translation, i.e. the
    /// 913 marker belongs to a real Space transition rather than an app switch.
    /// Reads are a single synchronous pass on the 913 main-thread hop; by that
    /// point a real transition's transform is already moving. Errors resolve to
    /// `true` so a genuine transition is never suppressed by a read failure.
    private func isSpaceActuallyTransitioning() -> Bool {
        guard let displays = try? WindowSpaces.managedDisplays() else { return true }
        for display in displays {
            for space in display.spaces {
                let transform = cgsSpaceTransform(space.id)
                if abs(transform.tx) >= Self.translationThreshold || abs(transform.ty) >= Self.translationThreshold {
                    return true
                }
            }
        }
        return false
    }
}
