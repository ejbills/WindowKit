import Cocoa
import Combine

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
    private var notifier: SkyLightConnectionNotifier?

    public init() {}

    /// Registers the notify proc on the main SkyLight connection. Idempotent.
    public func start() {
        guard notifier == nil else { return }
        notifier = SkyLightConnectionNotifier(events: [.exposeTransitionBegan, .dockExposeStateChanged]) { [weak self] event, _ in
            self?.subject.send(event == .exposeTransitionBegan ? .transitionBegan : .stateChanged)
        }
    }

    /// Deregisters the notify proc. Idempotent.
    public func stop() {
        notifier = nil
    }
}
