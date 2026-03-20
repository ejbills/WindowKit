import Cocoa
import Combine

public final class ScreenLockObserver {
    public static let shared = ScreenLockObserver()

    public private(set) var isLocked: Bool = false

    public let events: AnyPublisher<Bool, Never>
    private let eventSubject = PassthroughSubject<Bool, Never>()
    private var observations: [NSObjectProtocol] = []

    private init() {
        self.events = eventSubject
            .removeDuplicates()
            .eraseToAnyPublisher()
        setupObservers()
    }

    deinit {
        let center = DistributedNotificationCenter.default()
        observations.forEach { center.removeObserver($0) }
    }

    private func setupObservers() {
        let center = DistributedNotificationCenter.default()

        observations.append(center.addObserver(
            forName: NSNotification.Name("com.apple.screenIsLocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Logger.info("ScreenLock: screen locked")
            self.isLocked = true
            self.eventSubject.send(true)
        })

        observations.append(center.addObserver(
            forName: NSNotification.Name("com.apple.screenIsUnlocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Logger.info("ScreenLock: screen unlocked")
            self.isLocked = false
            self.eventSubject.send(false)
        })

        observations.append(center.addObserver(
            forName: NSNotification.Name("com.apple.screensaver.didStart"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Logger.debug("ScreenLock: screensaver started")
            self.isLocked = true
            self.eventSubject.send(true)
        })

        observations.append(center.addObserver(
            forName: NSNotification.Name("com.apple.screensaver.didStop"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Logger.debug("ScreenLock: screensaver stopped")
            self.isLocked = false
            self.eventSubject.send(false)
        })
    }
}
