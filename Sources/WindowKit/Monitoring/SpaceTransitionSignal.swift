import Cocoa
import Combine

/// SkyLight connection-notify event that fires during a Space transition —
/// measured: at the start of the settle glide, NOT the start of the transition.
/// For gesture-driven switches it arrives around finger release (100–700ms after
/// the Space transforms start moving) and for keyboard switches its lag is
/// direction-asymmetric (~35ms switching one way, ~310ms the other). Generic
/// across transition kinds and also fires for same-Space application switches
/// (it means "a compositor glide began", not "the active Space changed"), so
/// consumers must validate it. Only delivered to connections that own on-screen
/// windows. Idle-safe: at idle only the unrelated 30Hz heartbeat (818) fires,
/// never 913.
private let spaceTransitionGlideStartedEvent: UInt32 = 913

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
/// Two trigger channels feed one validated publisher:
/// - `noteSpaceSwitchInputEdge()` — the consumer feeds Space-switch input edges
///   it observes (trackpad fluid-swipe began, Spaces hotkey dispatch). Measured,
///   these land a few ms BEFORE the compositor starts moving the Space
///   transforms, so each hint runs a short confirm burst that reads the
///   transforms until they report motion (or gives up). Ownership of the input
///   monitoring stays with the consumer; this class never installs event taps.
/// - The SkyLight 913 marker as the catch-all for switches with no input edge
///   (Mission Control clicks, programmatic switches). It is validated the same
///   way but fires late for gestures and direction-asymmetrically for keys, so
///   it is the fallback, not the primary.
///
/// Singleton-free — a consumer owns one instance, calls `start()`, subscribes to
/// `transitionStarted`, and calls `stop()` (or releases it) to deregister.
@MainActor
public final class SpaceTransitionSignal {
    public var transitionStarted: AnyPublisher<Void, Never> { subject.eraseToAnyPublisher() }

    private let subject = PassthroughSubject<Void, Never>()
    private var registered = false
    private var connectionID: CGSConnectionID = 0
    private var confirmTimer: Timer?
    private var confirmTicks = 0
    private var lastPublishTime: CFAbsoluteTime = 0

    /// Minimum |tx|/|ty| (points) in a Space's live transform for it to count as
    /// actively translating. A real transition reads well above this almost
    /// immediately; an app switch reads exactly identity.
    private static let translationThreshold: CGFloat = 1.0

    /// Confirm-burst cadence and cap: an input edge leads transform motion by
    /// 3–8ms, so a handful of 8ms reads catches every real switch; ~30 ticks
    /// (~250ms) bounds the cost of a hint that never becomes a transition
    /// (pinch gesture, unrelated symbolic hotkey).
    private static let confirmInterval: TimeInterval = 0.008
    private static let confirmTickLimit = 30

    /// Suppresses duplicate publishes when 913 trails an already-confirmed input
    /// edge. Longer than the worst edge→913 lag observed for keyboard switches
    /// (~310ms) but short enough that back-to-back switches each get their own
    /// publish; a gesture 913 trailing beyond it double-fires, which the
    /// consumer's transition handling absorbs (that is today's behavior).
    private static let publishDedupeWindow: CFAbsoluteTime = 0.35

    public init() {}

    deinit {
        spaceTransitionSignalHandler = nil
        if registered {
            _ = slsRemoveConnectionNotify(connectionID, spaceTransitionNotifyProc, spaceTransitionGlideStartedEvent, nil)
        }
    }

    /// Registers the 913 notify proc on the main SkyLight connection. Idempotent.
    public func start() {
        guard !registered else { return }
        connectionID = cgsMainConnection()
        spaceTransitionSignalHandler = { [weak self] in
            MainActor.assumeIsolated {
                _ = self?.publishIfTransitioning(assumeTransitioningOnReadFailure: true)
            }
        }
        let result = slsRegisterConnectionNotify(connectionID, spaceTransitionNotifyProc, spaceTransitionGlideStartedEvent, nil)
        registered = result == 0
        if !registered {
            spaceTransitionSignalHandler = nil
        }
    }

    /// Deregisters the notify proc and cancels any confirm burst. Idempotent.
    public func stop() {
        spaceTransitionSignalHandler = nil
        if registered {
            _ = slsRemoveConnectionNotify(connectionID, spaceTransitionNotifyProc, spaceTransitionGlideStartedEvent, nil)
            registered = false
        }
        cancelConfirmBurst()
    }

    /// The consumer observed a Space-switch input edge (fluid-swipe began,
    /// Spaces hotkey dispatch). The transforms usually haven't moved yet — the
    /// edge leads them by a few ms — so poll them briefly; the burst
    /// self-cancels on confirmation or at the tick cap. Safe to call for hints
    /// that turn out not to be Space switches: an unconfirmed burst publishes
    /// nothing.
    public func noteSpaceSwitchInputEdge() {
        guard confirmTimer == nil else { return }
        if publishIfTransitioning(assumeTransitioningOnReadFailure: false) { return }
        confirmTicks = 0
        let timer = Timer(timeInterval: Self.confirmInterval, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else {
                    timer.invalidate()
                    return
                }
                self.confirmTicks += 1
                if self.publishIfTransitioning(assumeTransitioningOnReadFailure: false) || self.confirmTicks >= Self.confirmTickLimit {
                    self.cancelConfirmBurst()
                }
            }
        }
        confirmTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func cancelConfirmBurst() {
        confirmTimer?.invalidate()
        confirmTimer = nil
    }

    /// Validates against the live transforms and publishes once per transition.
    /// `assumeTransitioningOnReadFailure` is true only on the 913 path, where
    /// the marker itself is strong evidence and a read failure must never
    /// suppress a genuine transition; an input-edge hint with unreadable
    /// transforms stays unconfirmed instead.
    @discardableResult
    private func publishIfTransitioning(assumeTransitioningOnReadFailure: Bool) -> Bool {
        guard isSpaceActuallyTransitioning(assumeTransitioningOnReadFailure: assumeTransitioningOnReadFailure) else {
            return false
        }
        let now = CFAbsoluteTimeGetCurrent()
        if now - lastPublishTime > Self.publishDedupeWindow {
            lastPublishTime = now
            subject.send()
        }
        return true
    }

    /// True when any managed Space on any display is mid-translation. Reads are
    /// a single synchronous pass per call.
    private func isSpaceActuallyTransitioning(assumeTransitioningOnReadFailure: Bool) -> Bool {
        guard let displays = try? WindowSpaces.managedDisplays() else { return assumeTransitioningOnReadFailure }
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
