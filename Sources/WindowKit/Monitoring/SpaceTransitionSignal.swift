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
    public var transitionStarted: AnyPublisher<SpaceTransitionStart, Never> { subject.eraseToAnyPublisher() }

    private let subject = PassthroughSubject<SpaceTransitionStart, Never>()
    private var registered = false
    private var connectionID: CGSConnectionID = 0
    private var confirmTimer: Timer?
    private var confirmTicks = 0
    private var lastPublishTime: CFAbsoluteTime = 0
    private struct DisplaySpaces {
        let spaceIDs: [CGSSpaceID]
        let currentSpaceID: CGSSpaceID
        let extent: CGFloat
    }

    private var cachedDisplays: [DisplaySpaces] = []
    private var cachedDisplaysAt: CFAbsoluteTime = 0

    /// How long the managed-Space ID list is reused across confirm-burst reads;
    /// the Space table itself is stable within a burst, only the transforms move.
    private static let spaceIDCacheLifetime: CFAbsoluteTime = 1.0

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

    /// The consumer knows a Space switch is about to start (it is raising a
    /// window whose Space is not current on any display). Publishes at once
    /// instead of waiting for the transforms: under heavy WindowServer load the
    /// compositor can take longer than the confirm burst's cap to start moving,
    /// and a late publish is worse than none. A trailing 913 or transform
    /// confirmation for the same switch is absorbed by the dedupe window; the
    /// consumer's commit/fallback handling restores if the switch never lands.
    public func noteImminentSpaceSwitch() {
        cancelConfirmBurst()
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastPublishTime > Self.publishDedupeWindow else {
            Logger.debug("SpaceTransitionSignal: imminent hint deduped", details: "sincePublish=\(String(format: "%.3f", now - lastPublishTime))")
            return
        }
        lastPublishTime = now
        Logger.debug("SpaceTransitionSignal: publish (imminent)")
        subject.send(SpaceTransitionStart(progress: 0))
    }

    /// Synchronous read of whether any managed Space is still mid-translation.
    /// Lets a consumer's commit-fallback distinguish "transition still animating
    /// (or finger still holding the swipe) — keep waiting" from "transition
    /// evaporated without a commit — restore". Read failures report false.
    public func isTransitionUnderway() -> Bool {
        transitionProgress(assumeTransitioningOnReadFailure: false) != nil
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
        guard let progress = transitionProgress(assumeTransitioningOnReadFailure: assumeTransitioningOnReadFailure) else {
            return false
        }
        let now = CFAbsoluteTimeGetCurrent()
        if now - lastPublishTime > Self.publishDedupeWindow {
            lastPublishTime = now
            Logger.debug("SpaceTransitionSignal: publish (transforms moving)", details: "source=\(assumeTransitioningOnReadFailure ? "913" : "confirm burst tick \(confirmTicks)") progress=\(String(format: "%.2f", progress))")
            subject.send(SpaceTransitionStart(progress: progress))
        } else {
            Logger.debug("SpaceTransitionSignal: transforms moving, deduped", details: "sincePublish=\(String(format: "%.3f", now - lastPublishTime))")
        }
        return true
    }

    /// How far the transition has progressed when any managed Space on any
    /// display is mid-translation, `nil` when none is. Progress is the outgoing
    /// (still-current) Space's translation over its display's extent, 0 when
    /// only a non-current Space reads as moving. Reads are a single synchronous
    /// pass per call.
    private func transitionProgress(assumeTransitioningOnReadFailure: Bool) -> CGFloat? {
        guard let displays = currentDisplays() else { return assumeTransitioningOnReadFailure ? 0 : nil }
        var moving = false
        var progress: CGFloat = 0
        for display in displays {
            for spaceID in display.spaceIDs {
                let transform = cgsSpaceTransform(spaceID)
                let translation = max(abs(transform.tx), abs(transform.ty))
                guard translation >= Self.translationThreshold else { continue }
                moving = true
                if spaceID == display.currentSpaceID, display.extent > 0 {
                    progress = max(progress, min(translation / display.extent, 1))
                }
            }
        }
        return moving ? progress : nil
    }

    private func currentDisplays() -> [DisplaySpaces]? {
        let now = CFAbsoluteTimeGetCurrent()
        if !cachedDisplays.isEmpty, now - cachedDisplaysAt < Self.spaceIDCacheLifetime {
            return cachedDisplays
        }
        guard let displays = try? WindowSpaces.managedDisplays() else { return nil }
        cachedDisplays = displays.map { display in
            let frame = display.screen?.frame ?? .zero
            return DisplaySpaces(
                spaceIDs: display.spaces.map(\.id),
                currentSpaceID: display.currentSpaceID,
                extent: max(frame.width, frame.height)
            )
        }
        cachedDisplaysAt = now
        return cachedDisplays
    }
}

/// Payload of `SpaceTransitionSignal.transitionStarted`.
public struct SpaceTransitionStart: Sendable {
    /// 0 when the switch has not visibly begun (input edge, imminent raise, or
    /// the first confirm-burst tick), rising toward 1 as the outgoing Space
    /// slides off. A late 913 (settle glide) reports close to 1; consumers use
    /// it to skip a reaction that could no longer complete before commit.
    public let progress: CGFloat
}
