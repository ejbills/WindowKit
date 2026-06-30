import XCTest
import os
@testable import WindowKit

// MARK: - Main thread guard (file-local; mirrors StressTests' pattern)

private func assertMainThreadResponsive(
    during work: @escaping () async -> Void,
    thresholdMs: Double = 250,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    let missed = OSAllocatedUnfairLock(initialState: 0)
    let done = OSAllocatedUnfairLock(initialState: false)
    let monitor = Thread {
        while !done.withLockUnchecked({ $0 }) {
            let sem = DispatchSemaphore(value: 0)
            DispatchQueue.main.async { sem.signal() }
            if sem.wait(timeout: .now() + thresholdMs / 1000.0) == .timedOut {
                missed.withLockUnchecked { $0 += 1 }
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
    }
    monitor.start()
    await work()
    done.withLockUnchecked { $0 = true }
    try? await Task.sleep(nanoseconds: 50_000_000)
    XCTAssertEqual(missed.withLockUnchecked { $0 }, 0, "Main thread was blocked", file: file, line: line)
}

// MARK: - Public surface

@MainActor
final class DockMinimizedPublicSurfaceTests: XCTestCase {
    func testTracksOrphanedMinimizedWindowsDefaultsTrue() {
        XCTAssertTrue(WindowKit.shared.tracksOrphanedMinimizedWindows)
    }

    func testOrphanedMinimizedWindowsStartsEmpty() {
        XCTAssertTrue(WindowKit.shared.orphanedMinimizedWindows.isEmpty)
    }

    func testRefreshWhenNotTrackingReturnsPromptly() async {
        await assertMainThreadResponsive {
            await WindowKit.shared.refreshOrphanedMinimizedWindows()
        }
    }

    func testRestoreUnknownIDIsNoOp() {
        // Must not crash when the id doesn't map to any live dock item.
        WindowKit.shared.restoreOrphanedMinimizedWindow(id: "win:999999999")
    }
}

// MARK: - Lifecycle (crash-free, main-thread safe)

@MainActor
final class DockMinimizedLifecycleTests: XCTestCase {
    func testStartThenStopIsCrashFree() async {
        let tracker = OrphanedWindowTracker()
        tracker.start()
        try? await Task.sleep(nanoseconds: 100_000_000)
        tracker.stop()
    }

    func testRapidStartStopDoesNotCrash() async {
        let tracker = OrphanedWindowTracker()
        for _ in 0..<20 { tracker.start(); tracker.stop() }
        try? await Task.sleep(nanoseconds: 100_000_000)
    }

    func testRefreshAndRestoreAreMainThreadSafe() async {
        let tracker = OrphanedWindowTracker()
        tracker.start()
        await assertMainThreadResponsive {
            tracker.refreshNow()
            tracker.restore(id: "win:1")
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        tracker.stop()
    }
}

// MARK: - Model

final class DockMinimizedModelTests: XCTestCase {
    func testEqualityByIDAndTitle() {
        let a = DockMinimizedWindow(id: "win:1", windowID: 1, ownerPID: 10, title: "Doc", preview: nil)
        let b = DockMinimizedWindow(id: "win:1", windowID: 1, ownerPID: 10, title: "Doc", preview: nil)
        let c = DockMinimizedWindow(id: "win:1", windowID: 1, ownerPID: 10, title: "Other", preview: nil)
        let d = DockMinimizedWindow(id: "win:2", windowID: 2, ownerPID: 10, title: "Doc", preview: nil)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
        XCTAssertNotEqual(a, d)
    }

    func testIdentifiableUsesStableID() {
        let w = DockMinimizedWindow(id: "dock:0:Untitled", windowID: nil, ownerPID: 10, title: "Untitled", preview: nil)
        XCTAssertEqual(w.id, "dock:0:Untitled")
        XCTAssertNil(w.windowID)
    }
}
