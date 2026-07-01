import Combine
import XCTest
@testable import WindowKit

final class AppSwitcherObserverTests: XCTestCase {

    func testStartStopIsIdempotent() {
        let observer = AppSwitcherObserver()
        // Repeated start/stop must not crash or leak run-loop sources.
        observer.start()
        observer.start()
        observer.stop()
        observer.stop()
    }

    func testSelectionPublisherStartsNil() {
        let observer = AppSwitcherObserver()
        var received: AppSwitcherSelection??
        let cancellable = observer.selectionPublisher.sink { received = $0 }
        defer { cancellable.cancel() }
        XCTAssertEqual(received, .some(.none))
    }

    func testStopResetsSelectionToNil() {
        let observer = AppSwitcherObserver()
        var values: [AppSwitcherSelection?] = []
        let cancellable = observer.selectionPublisher.sink { values.append($0) }
        defer { cancellable.cancel() }

        observer.start()
        observer.stop()

        // Last published value is always nil after stop.
        XCTAssertEqual(values.last, .some(.none))
    }

    func testSelectionEquatable() {
        let a = AppSwitcherSelection(ownerPID: 42, bundleIdentifier: "com.apple.Safari", title: "Safari", frame: .zero)
        let b = AppSwitcherSelection(ownerPID: 42, bundleIdentifier: "com.apple.Safari", title: "Safari", frame: .zero)
        let c = AppSwitcherSelection(ownerPID: 43, bundleIdentifier: "com.apple.Safari", title: "Safari", frame: .zero)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }
}
