import Cocoa
import Combine

public enum ProcessEvent: Sendable {
    case applicationWillLaunch(NSRunningApplication)
    case applicationLaunched(NSRunningApplication)
    case applicationTerminated(pid_t)
    case applicationActivated(NSRunningApplication)
    case applicationDeactivated(NSRunningApplication)
    case spaceChanged
}

public final class ProcessWatcher {
    public let events: AnyPublisher<ProcessEvent, Never>
    private let eventSubject = PassthroughSubject<ProcessEvent, Never>()
    private var observations: [NSObjectProtocol] = []
    private var knownPIDs: Set<pid_t> = []
    private var runningAppsObservation: NSKeyValueObservation?
    private var pendingPolicyObservations: [pid_t: PolicyObservation] = [:]

    private struct PolicyObservation {
        let app: NSRunningApplication
        let token: NSKeyValueObservation

        func invalidate() {
            token.invalidate()
        }
    }

    /// How long to watch a non-.regular process for a late activation-policy flip.
    /// Apps that spawn per-window child processes by exec'ing their own binary
    /// (Bambu Studio, Parallels winapps) appear in runningApplications immediately
    /// but only become .regular once they connect to the window server — sometimes
    /// many seconds later, and without any NSWorkspace launch notification.
    private static let policyFlipTimeout: TimeInterval = 120

    public private(set) var frontmostApplication: NSRunningApplication?

    public init() {
        self.events = eventSubject.eraseToAnyPublisher()
        frontmostApplication = NSWorkspace.shared.frontmostApplication
        setupObservers()
    }

    deinit { stopWatching() }

    public func startWatching() {
        guard observations.isEmpty else { return }
        setupObservers()
    }

    public func stopWatching() {
        let center = NSWorkspace.shared.notificationCenter
        observations.forEach { center.removeObserver($0) }
        observations.removeAll()
        runningAppsObservation?.invalidate()
        runningAppsObservation = nil
        pendingPolicyObservations.values.forEach { $0.invalidate() }
        pendingPolicyObservations.removeAll()
    }

    public func runningApplications() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
    }

    /// Event-driven backstop for apps the NSWorkspace notifications miss.
    /// Processes spawned by exec'ing an app binary directly (Bambu Studio project
    /// windows, Parallels Coherence winapps) never fire
    /// didLaunch/didTerminateApplicationNotification. Membership changes surface
    /// through KVO on runningApplications; a process that joins the list before it
    /// is .regular gets a per-app activationPolicy observation until it flips.
    private func reconcileRunningApps() {
        let current = NSWorkspace.shared.runningApplications
        let currentPIDs = Set(current.map(\.processIdentifier))

        for app in current {
            let pid = app.processIdentifier
            guard !knownPIDs.contains(pid) else { continue }
            if app.activationPolicy == .regular {
                markLaunched(app)
            } else if pendingPolicyObservations[pid] == nil {
                observePolicyFlip(of: app)
            }
        }

        for pid in knownPIDs.subtracting(currentPIDs) {
            knownPIDs.remove(pid)
            eventSubject.send(.applicationTerminated(pid))
        }
        for pid in Set(pendingPolicyObservations.keys).subtracting(currentPIDs) {
            pendingPolicyObservations.removeValue(forKey: pid)?.invalidate()
        }
    }

    private func markLaunched(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        pendingPolicyObservations.removeValue(forKey: pid)?.invalidate()
        guard !knownPIDs.contains(pid) else { return }
        knownPIDs.insert(pid)
        // Back-door launches never fire willLaunchApplicationNotification, so a
        // still-starting app gets its launching state here — consumers dedupe by
        // PID against the notification-driven event. This is the earliest point a
        // back-door process is provably an app (vs. a background helper), and its
        // first window can still be seconds away.
        if !app.isFinishedLaunching {
            eventSubject.send(.applicationWillLaunch(app))
        }
        eventSubject.send(.applicationLaunched(app))
    }

    private func observePolicyFlip(of app: NSRunningApplication) {
        let pid = app.processIdentifier
        let token = app.observe(\.activationPolicy) { [weak self] app, _ in
            DispatchQueue.main.async {
                guard let self, app.activationPolicy == .regular, !app.isTerminated else { return }
                self.markLaunched(app)
            }
        }
        pendingPolicyObservations[pid] = PolicyObservation(app: app, token: token)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.policyFlipTimeout) { [weak self] in
            self?.pendingPolicyObservations.removeValue(forKey: pid)?.invalidate()
        }
    }

    private func setupObservers() {
        let center = NSWorkspace.shared.notificationCenter
        knownPIDs = Set(runningApplications().map(\.processIdentifier))

        observations.append(center.addObserver(
            forName: NSWorkspace.willLaunchApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.activationPolicy == .regular else { return }
            self?.eventSubject.send(.applicationWillLaunch(app))
        })

        observations.append(center.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.activationPolicy == .regular else { return }
            self?.markLaunched(app)
        })

        observations.append(center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let self,
                  let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pid = app.processIdentifier
            pendingPolicyObservations.removeValue(forKey: pid)?.invalidate()
            knownPIDs.remove(pid)
            eventSubject.send(.applicationTerminated(pid))
        })

        observations.append(center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let self,
                  let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.activationPolicy == .regular else { return }
            self.frontmostApplication = app
            self.eventSubject.send(.applicationActivated(app))
        })

        observations.append(center.addObserver(
            forName: NSWorkspace.didDeactivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.activationPolicy == .regular else { return }
            self?.eventSubject.send(.applicationDeactivated(app))
        })

        observations.append(center.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.eventSubject.send(.spaceChanged)
        })

        // Membership-only at setup (knownPIDs is seeded above): attaching policy
        // observations to every pre-existing background process would be waste.
        runningAppsObservation = NSWorkspace.shared.observe(\.runningApplications) { [weak self] _, _ in
            DispatchQueue.main.async { self?.reconcileRunningApps() }
        }
    }
}
