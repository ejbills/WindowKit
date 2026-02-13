import Cocoa
import Combine

public enum ProcessEvent: Sendable {
    case applicationWillLaunch(NSRunningApplication)
    case applicationLaunched(NSRunningApplication)
    case applicationTerminated(pid_t)
    case applicationActivated(NSRunningApplication)
    case spaceChanged
}

public final class ProcessWatcher {
    public let events: AnyPublisher<ProcessEvent, Never>
    private let eventSubject = PassthroughSubject<ProcessEvent, Never>()
    private var observations: [NSObjectProtocol] = []

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
    }

    public func runningApplications() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
    }

    private func setupObservers() {
        let center = NSWorkspace.shared.notificationCenter

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
            self?.eventSubject.send(.applicationLaunched(app))
        })

        observations.append(center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
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
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.eventSubject.send(.spaceChanged)
        })
    }
}
