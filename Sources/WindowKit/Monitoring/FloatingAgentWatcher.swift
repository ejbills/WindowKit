import Cocoa
import Combine

/// The live window frames of one floating agent, in AX (top-left origin)
/// coordinates. Empty when the agent has no windows or has quit.
public struct AgentWindowsEvent: Sendable {
    public let pid: pid_t
    public let frames: [CGRect]
}

/// Watches accessory agents whose windows float over everything yet are
/// invisible to window tracking and to SkyLight's Space-membership events:
/// the Screenshot toolbar (level 1499) and its thumbnail. Each agent's window
/// set is read live on every AX window create/destroy rather than tracked per
/// element, since a destroyed element arrives with its geometry already gone
/// and the live list self-heals a missed notification. A thumbnail dragged
/// away leaves the list at once but its destroy notification comes seconds
/// later; the frame is deliberately kept until then rather than polled for.
final class FloatingAgentWatcher {
    static let bundleIDs: Set<String> = ["com.apple.screencaptureui"]

    var events: AnyPublisher<AgentWindowsEvent, Never> { subject.eraseToAnyPublisher() }

    private let subject = PassthroughSubject<AgentWindowsEvent, Never>()
    private let axQueue: DispatchQueue
    private var watchers: [pid_t: (watcher: AccessibilityWatcher, subscription: AnyCancellable)] = [:]

    /// `axQueue` is the tracker's serial AX queue, so these reads share its
    /// discipline: never on main, never on the notification-delivery queue,
    /// bounded by the tracker's process-wide AX messaging timeout.
    init(axQueue: DispatchQueue) {
        self.axQueue = axQueue
    }

    func watch(_ agent: NSRunningApplication) {
        let pid = agent.processIdentifier
        guard watchers[pid] == nil, let watcher = AccessibilityWatcher(pid: pid) else { return }
        let subscription = watcher.events.sink { [weak self] event in
            switch event {
            case .windowCreated, .windowDestroyed:
                self?.axQueue.async { self?.publishFrames(of: pid) }
            default:
                break
            }
        }
        watchers[pid] = (watcher, subscription)
    }

    func forget(pid: pid_t) {
        guard watchers.removeValue(forKey: pid) != nil else { return }
        subject.send(AgentWindowsEvent(pid: pid, frames: []))
    }

    private func publishFrames(of pid: pid_t) {
        let windows = (try? AXUIElement.application(pid: pid).windows()) ?? []
        let frames = windows.compactMap { window -> CGRect? in
            guard let origin = try? window.position(), let size = try? window.size() else { return nil }
            return CGRect(origin: origin, size: size)
        }
        subject.send(AgentWindowsEvent(pid: pid, frames: frames))
    }
}
