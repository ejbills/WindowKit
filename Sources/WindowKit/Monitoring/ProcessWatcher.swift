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
    private var pendingFinishObservations: [pid_t: PolicyObservation] = [:]
    private var pidsByIdentity: [ObjectIdentifier: (app: NSRunningApplication, pid: pid_t)] = [:]
    private var retiredObservations: [PolicyObservation] = []
    private var retirementDrain: DispatchWorkItem?
    private var retirementDeadline: DispatchTime?
    private let activationQueue = DispatchQueue(label: "com.windowkit.activation-policy", qos: .userInitiated)
    private var deliveredPIDs: [ObjectIdentifier: (app: NSRunningApplication, pid: pid_t)] = [:]
    private var deliveredOrder: [ObjectIdentifier] = []

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

    /// Backstop for a launching app whose `isFinishedLaunching` never flips.
    private static let launchFinishTimeout: TimeInterval = 30

    /// Quiet period after the last launch or exit before retired observations are invalidated.
    private static let retirementQuietPeriod: TimeInterval = 1.5

    /// Longest a retired observation waits while launches and exits keep arriving.
    private static let retirementMaxDelay: TimeInterval = 10

    public private(set) var frontmostApplication: NSRunningApplication?

    public init() {
        self.events = eventSubject.eraseToAnyPublisher()
        frontmostApplication = NSWorkspace.shared.frontmostApplication.map { RunningApplicationResolver.resolving($0) }
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
        pendingFinishObservations.values.forEach { $0.invalidate() }
        pendingFinishObservations.removeAll()
        retirementDrain?.cancel()
        drainRetiredObservations()
        pidsByIdentity.removeAll()
    }

    /// Invalidates on main, where AppKit's observer bookkeeping lives, once launches and exits have been
    /// quiet for `retirementQuietPeriod`: each removal is a LaunchServices round-trip that stalls during exits.
    private func retire(_ observations: [PolicyObservation]) {
        retiredObservations.append(contentsOf: observations)
        guard !retiredObservations.isEmpty else { return }
        let now = DispatchTime.now()
        let deadline = retirementDeadline ?? now + Self.retirementMaxDelay
        retirementDeadline = deadline
        retirementDrain?.cancel()
        let drain = DispatchWorkItem { [weak self] in self?.drainRetiredObservations() }
        retirementDrain = drain
        DispatchQueue.main.asyncAfter(deadline: min(now + Self.retirementQuietPeriod, deadline), execute: drain)
    }

    private func drainRetiredObservations() {
        let retired = retiredObservations
        retiredObservations.removeAll()
        retirementDrain = nil
        retirementDeadline = nil
        retired.forEach { $0.invalidate() }
    }

    /// Reads `app.activationPolicy` on `activationQueue` and, for a `.regular` app, runs `deliver`
    /// on main in notification order. Activation notifications carry fresh instances, so the read is
    /// a synchronous LaunchServices fetch that stalls while an app exits.
    private func deliverIfRegular(
        _ app: NSRunningApplication,
        _ deliver: @escaping (ProcessWatcher, NSRunningApplication) -> Void
    ) {
        activationQueue.async { [weak self] in
            guard app.activationPolicy == .regular else { return }
            let app = RunningApplicationResolver.resolving(app)
            let pid = app.processIdentifier
            DispatchQueue.main.async {
                guard let self else { return }
                self.rememberDelivered(app, pid: pid)
                deliver(self, app)
            }
        }
    }

    /// The pid read with the activation policy for an app delivered in an activation event.
    func deliveredProcessIdentifier(of app: NSRunningApplication) -> pid_t? {
        deliveredPIDs[ObjectIdentifier(app)]?.pid
    }

    /// Keeps the most recently delivered instances (retained, so identifiers stay unique).
    private func rememberDelivered(_ app: NSRunningApplication, pid: pid_t) {
        let identity = ObjectIdentifier(app)
        if deliveredPIDs.updateValue((app, pid), forKey: identity) == nil {
            deliveredOrder.append(identity)
        }
        while deliveredOrder.count > 8 {
            deliveredPIDs.removeValue(forKey: deliveredOrder.removeFirst())
        }
    }

    public func runningApplications() -> [NSRunningApplication] {
        RunningApplicationResolver.resolving(NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular })
    }

    /// Whether a PID is tracked, so its exit is reported even when it was never marked
    /// launched (it turned `.regular` after its policy-flip window expired).
    var isTrackedPID: ((pid_t) -> Bool)?

    /// Event-driven backstop for apps the NSWorkspace notifications miss.
    /// Processes spawned by exec'ing an app binary directly (Bambu Studio project
    /// windows, Parallels Coherence winapps) never fire
    /// didLaunch/didTerminateApplicationNotification. Membership changes surface
    /// through KVO on runningApplications; a process that joins the list before it
    /// is .regular gets a per-app activationPolicy observation until it flips.
    private func reconcileRunningApps() {
        let current = NSWorkspace.shared.runningApplications
        var currentPIDs = Set<pid_t>(minimumCapacity: current.count)
        var currentIdentities = Set<ObjectIdentifier>(minimumCapacity: current.count)

        for app in current {
            let identity = ObjectIdentifier(app)
            currentIdentities.insert(identity)
            if let cached = pidsByIdentity[identity] {
                currentPIDs.insert(cached.pid)
                continue
            }

            let resolved = RunningApplicationResolver.resolving(app)
            let pid = resolved.processIdentifier
            pidsByIdentity[identity] = (app, pid)
            currentPIDs.insert(pid)
            guard !knownPIDs.contains(pid) else { continue }
            if app.activationPolicy == .regular {
                markLaunched(resolved)
            } else if pendingPolicyObservations[pid] == nil {
                observePolicyFlip(of: resolved)
            }
        }

        var departedPIDs = knownPIDs.subtracting(currentPIDs)
        for (identity, entry) in pidsByIdentity where !currentIdentities.contains(identity) {
            pidsByIdentity.removeValue(forKey: identity)
            if !currentPIDs.contains(entry.pid), !knownPIDs.contains(entry.pid), isTrackedPID?(entry.pid) == true {
                Logger.info("Exit of app never seen launching", details: "pid=\(entry.pid), bundleID=\(entry.app.bundleIdentifier ?? "-")")
                departedPIDs.insert(entry.pid)
            }
        }
        for pid in departedPIDs {
            knownPIDs.remove(pid)
            eventSubject.send(.applicationTerminated(pid))
        }
        var departedObservations: [PolicyObservation] = []
        for pid in Set(pendingPolicyObservations.keys).subtracting(currentPIDs) {
            if let observation = pendingPolicyObservations.removeValue(forKey: pid) {
                departedObservations.append(observation)
            }
        }
        for pid in Set(pendingFinishObservations.keys).subtracting(currentPIDs) {
            if let observation = pendingFinishObservations.removeValue(forKey: pid) {
                departedObservations.append(observation)
            }
        }
        retire(departedObservations)
    }

    /// `.applicationWillLaunch` at membership insertion, `.applicationLaunched`
    /// when `isFinishedLaunching` flips.
    private func markLaunched(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        let policyObservation = pendingPolicyObservations.removeValue(forKey: pid)
        defer {
            if let policyObservation { retire([policyObservation]) }
        }
        guard !knownPIDs.contains(pid) else { return }
        knownPIDs.insert(pid)

        guard !app.isFinishedLaunching else {
            eventSubject.send(.applicationLaunched(app))
            return
        }

        eventSubject.send(.applicationWillLaunch(app))
        let token = RunningApplicationResolver.observationTarget(app).observe(\.isFinishedLaunching) { [weak self] _, _ in
            DispatchQueue.main.async {
                guard let self, app.isFinishedLaunching, !app.isTerminated else { return }
                guard let pending = self.pendingFinishObservations.removeValue(forKey: pid) else { return }
                self.retire([pending])
                self.eventSubject.send(.applicationLaunched(app))
            }
        }
        pendingFinishObservations[pid] = PolicyObservation(app: app, token: token)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.launchFinishTimeout) { [weak self] in
            guard let self, let pending = self.pendingFinishObservations.removeValue(forKey: pid) else { return }
            self.retire([pending])
            if !pending.app.isTerminated {
                self.eventSubject.send(.applicationLaunched(pending.app))
            }
        }
    }

    private func observePolicyFlip(of app: NSRunningApplication) {
        let pid = app.processIdentifier
        let token = RunningApplicationResolver.observationTarget(app).observe(\.activationPolicy) { [weak self] _, _ in
            DispatchQueue.main.async {
                guard let self, app.activationPolicy == .regular, !app.isTerminated else { return }
                self.markLaunched(app)
            }
        }
        pendingPolicyObservations[pid] = PolicyObservation(app: app, token: token)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.policyFlipTimeout) { [weak self] in
            guard let self, let pending = self.pendingPolicyObservations.removeValue(forKey: pid) else { return }
            self.retire([pending])
        }
    }

    private func setupObservers() {
        let center = NSWorkspace.shared.notificationCenter
        knownPIDs = Set(runningApplications().map(\.processIdentifier))

        observations.append(center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.deliverIfRegular(app) { watcher, app in
                watcher.frontmostApplication = app
                watcher.eventSubject.send(.applicationActivated(app))
            }
        })

        observations.append(center.addObserver(
            forName: NSWorkspace.didDeactivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.deliverIfRegular(app) { watcher, app in
                watcher.eventSubject.send(.applicationDeactivated(app))
            }
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
