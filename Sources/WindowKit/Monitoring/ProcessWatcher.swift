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
    private var runLoopObserver: CFRunLoopObserver?
    private var lastReconcileTime: CFAbsoluteTime = 0
    private var lastSeenCount = 0
    private var knownPIDs: Set<pid_t> = []

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
        if let observer = runLoopObserver {
            CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)
            runLoopObserver = nil
        }
    }

    public func runningApplications() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
    }

    private func diffRunningApps() {
        let current = runningApplications()
        let currentPIDs = Set(current.map(\.processIdentifier))

        let appeared = currentPIDs.subtracting(knownPIDs)
        let disappeared = knownPIDs.subtracting(currentPIDs)
        guard !appeared.isEmpty || !disappeared.isEmpty else { return }

        knownPIDs = currentPIDs

        for app in current where appeared.contains(app.processIdentifier) {
            eventSubject.send(.applicationLaunched(app))
        }
        for pid in disappeared {
            eventSubject.send(.applicationTerminated(pid))
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
            self?.knownPIDs.insert(app.processIdentifier)
            self?.eventSubject.send(.applicationLaunched(app))
        })

        observations.append(center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.knownPIDs.remove(app.processIdentifier)
            self?.eventSubject.send(.applicationTerminated(app.processIdentifier))
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

        lastSeenCount = NSWorkspace.shared.runningApplications.count
        lastReconcileTime = CFAbsoluteTimeGetCurrent()
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, 0) { [weak self] _, _ in
            guard let self else { return }
            let now = CFAbsoluteTimeGetCurrent()
            guard now - self.lastReconcileTime >= 1.0 else { return }
            self.lastReconcileTime = now
            let count = NSWorkspace.shared.runningApplications.count
            guard count != self.lastSeenCount else { return }
            self.lastSeenCount = count
            self.diffRunningApps()
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        runLoopObserver = observer
    }
}
