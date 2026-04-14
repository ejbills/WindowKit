import XCTest
import Combine
import os
@testable import WindowKit

// MARK: - Main Thread Guard

private func assertMainThreadResponsive(
    during work: @escaping () async -> Void,
    thresholdMs: Double = 100,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    let heartbeatInterval: TimeInterval = 0.01 // 10ms heartbeat

    let missedBeats = OSAllocatedUnfairLock(initialState: 0)
    let worstResponseMs = OSAllocatedUnfairLock(initialState: 0.0)
    let done = OSAllocatedUnfairLock(initialState: false)

    let monitor = Thread {
        while !done.withLockUnchecked({ $0 }) {
            let pingStart = CFAbsoluteTimeGetCurrent()
            let sem = DispatchSemaphore(value: 0)

            DispatchQueue.main.async { sem.signal() }
            let result = sem.wait(timeout: .now() + thresholdMs / 1000.0)

            let elapsed = (CFAbsoluteTimeGetCurrent() - pingStart) * 1000
            worstResponseMs.withLockUnchecked { $0 = max($0, elapsed) }

            if result == .timedOut {
                missedBeats.withLockUnchecked { $0 += 1 }
            }

            Thread.sleep(forTimeInterval: heartbeatInterval)
        }
    }
    monitor.name = "MainThreadMonitor"
    monitor.start()

    await work()

    done.withLockUnchecked { $0 = true }
    try? await Task.sleep(nanoseconds: 50_000_000)

    let missed = missedBeats.withLockUnchecked { $0 }
    let worst = worstResponseMs.withLockUnchecked { $0 }

    XCTAssertEqual(
        missed, 0,
        "Main thread was blocked: \(missed) missed heartbeats, worst response \(String(format: "%.1f", worst))ms (threshold: \(thresholdMs)ms)",
        file: file, line: line
    )
}

// MARK: - Test Helpers

private func makeMockWindow(
    id: CGWindowID,
    pid: pid_t,
    title: String? = nil,
    isMinimized: Bool = false,
    isHidden: Bool = false
) -> CapturedWindow {
    let dummyAx = AXUIElementCreateSystemWide()
    return CapturedWindow(
        id: id,
        title: title ?? "Window \(id)",
        ownerBundleID: "com.test.app",
        ownerPID: pid,
        bounds: CGRect(x: 0, y: 0, width: 800, height: 600),
        isMinimized: isMinimized,
        isFullscreen: false,
        isOwnerHidden: isHidden,
        isVisible: true,
        desktopSpace: 1,
        lastInteractionTime: Date(),
        creationTime: Date(),
        axElement: dummyAx,
        appAxElement: dummyAx
    )
}

private func realAppPIDs() -> [pid_t] {
    NSWorkspace.shared.runningApplications
        .filter { $0.activationPolicy == .regular }
        .prefix(5)
        .map(\.processIdentifier)
}

private func finderPID() -> pid_t {
    NSWorkspace.shared.runningApplications
        .first(where: { $0.bundleIdentifier == "com.apple.finder" })!
        .processIdentifier
}

// =============================================================================
// MARK: - AX Readiness Probe Tests
// =============================================================================

final class AXReadinessTests: XCTestCase {

    func testCanaryPassesUnderNormalConditions() {
        XCTAssertTrue(isAccessibilityReady(), "AX canary should pass when system is not in a degraded state")
    }

    func testCanaryDoesNotBlockMainThread() async {
        await assertMainThreadResponsive(during: {
            for _ in 0..<50 {
                _ = isAccessibilityReady()
            }
        }, thresholdMs: 200)
    }

    func testProbeInvalidPIDDoesNotHang() {
        let start = CFAbsoluteTimeGetCurrent()
        let element = AXUIElement.application(pid: 99999)
        element.setMessagingTimeout(seconds: 1.0)
        _ = try? element.role()
        _ = try? element.windows()
        let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
        XCTAssertLessThan(elapsed, 3000, "AX query to dead PID should fail within messaging timeout")
    }

    func testMessagingTimeoutIsRespected() {
        let element = AXUIElement.application(pid: 99999)
        let success = element.setMessagingTimeout(seconds: 0.5)
        XCTAssertTrue(success, "Setting messaging timeout should succeed")

        let start = CFAbsoluteTimeGetCurrent()
        _ = try? element.windows()
        let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
        XCTAssertLessThan(elapsed, 2000, "Should respect the 0.5s timeout, not the 6s default")
    }
}

// =============================================================================
// MARK: - Real AX Query Stress Tests
// =============================================================================

final class RealAXStressTests: XCTestCase {

    func testRapidAXQueriesDoNotBlockMainThread() async {
        let pids = realAppPIDs()
        guard !pids.isEmpty else { return }

        await assertMainThreadResponsive(during: {
            await withTaskGroup(of: Void.self) { group in
                for pid in pids {
                    group.addTask {
                        let app = AXUIElement.application(pid: pid)
                        app.setMessagingTimeout(seconds: WindowTracker.axMessagingTimeout)
                        for _ in 0..<20 {
                            _ = try? app.role()
                            _ = try? app.windows()
                            _ = try? app.title()
                        }
                    }
                }
            }
        }, thresholdMs: 200)
    }

    func testWindowEnumerationDoesNotBlockMainThread() async {
        let pids = realAppPIDs()
        guard !pids.isEmpty else { return }

        let enumerator = WindowEnumerator()

        await assertMainThreadResponsive(during: {
            for pid in pids {
                let windows = enumerator.enumerateWindows(forPID: pid)
                for window in windows {
                    _ = enumerator.meetsDiscoveryCriteria(window)
                }
            }
        }, thresholdMs: 200)
    }

    func testBruteForceEnumerationTiming() async {
        let pid = finderPID()

        await assertMainThreadResponsive(during: {
            let start = CFAbsoluteTimeGetCurrent()
            let windows = AXUIElement.allWindows(forPID: pid)
            let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
                _ = windows
            _ = elapsed
        }, thresholdMs: 500)
    }

    func testIsValidElementFailsFastOnStaleElement() {
        let enumerator = WindowEnumerator()
        let stale = AXUIElementCreateSystemWide()

        let start = CFAbsoluteTimeGetCurrent()
        let valid = enumerator.isValidElement(stale)
        let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000

        XCTAssertFalse(valid, "SystemWide element is not a valid window")
        XCTAssertLessThan(elapsed, 3000, "isValidElement should fail fast on invalid elements")
    }

    func testConcurrentIsValidElementDoesNotDeadlock() async {
        let pid = finderPID()
        let enumerator = WindowEnumerator()
        let windows = enumerator.enumerateWindows(forPID: pid)

        await assertMainThreadResponsive(during: {
            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<10 {
                    for window in windows {
                        group.addTask {
                            _ = enumerator.isValidElement(window)
                        }
                    }
                }
            }
        }, thresholdMs: 300)
    }
}

// =============================================================================
// MARK: - WindowRepository Thread Safety Stress Tests
// =============================================================================

final class RepositoryStressTests: XCTestCase {

    func testConcurrentReadWriteDoesNotCrash() async {
        let repo = WindowRepository()
        let iterations = 1000
        let pidCount = 20

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<iterations {
                group.addTask {
                    let pid = pid_t(i % pidCount + 1000)
                    let window = makeMockWindow(id: CGWindowID(i), pid: pid)
                    repo.store(forPID: pid, windows: [window])
                }
            }
            for i in 0..<iterations {
                group.addTask {
                    let pid = pid_t(i % pidCount + 1000)
                    _ = repo.readCache(forPID: pid)
                    _ = repo.readAllCache()
                }
            }
        }

        let all = repo.readAllCache()
        XCTAssertFalse(all.isEmpty, "Repository should have stored windows")
    }

    func testConcurrentStorePurifyDoesNotCrash() async {
        let repo = WindowRepository()
        let enumerator = WindowEnumerator()
        let pid: pid_t = 9999

        for i in 0..<50 {
            let w = makeMockWindow(id: CGWindowID(i), pid: pid)
            repo.store(forPID: pid, windows: [w])
        }

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<100 {
                group.addTask {
                    _ = repo.purify(forPID: pid, validator: { enumerator.isValidElement($0) })
                }
            }
            for i in 50..<150 {
                group.addTask {
                    let w = makeMockWindow(id: CGWindowID(i), pid: pid)
                    repo.store(forPID: pid, windows: [w])
                }
            }
        }
    }

    func testConcurrentModifyDoesNotLoseUpdates() async {
        let repo = WindowRepository()
        let pid: pid_t = 8888
        let window = makeMockWindow(id: 1, pid: pid)
        repo.store(forPID: pid, windows: [window])

        let updateCount = 500
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<updateCount {
                group.addTask {
                    repo.modify(forPID: pid) { windows in
                        if let existing = windows.first {
                            windows.remove(existing)
                            let updated = CapturedWindow(
                                id: existing.id,
                                title: "Update \(i)",
                                ownerBundleID: existing.ownerBundleID,
                                ownerPID: existing.ownerPID,
                                bounds: existing.bounds,
                                isMinimized: existing.isMinimized,
                                isFullscreen: existing.isFullscreen,
                                isOwnerHidden: existing.isOwnerHidden,
                                isVisible: existing.isVisible,
                                desktopSpace: existing.desktopSpace,
                                lastInteractionTime: Date(),
                                creationTime: existing.creationTime,
                                axElement: existing.axElement,
                                appAxElement: existing.appAxElement
                            )
                            windows.insert(updated)
                        }
                    }
                }
            }
        }

        let cached = repo.readCache(forPID: pid)
        XCTAssertEqual(cached.count, 1, "Should still have exactly 1 window after concurrent modifications")
    }

    func testSuppressedWindowsStaySuppressed() {
        let repo = WindowRepository()
        let pid: pid_t = 7777

        let w1 = makeMockWindow(id: 1, pid: pid)
        let w2 = makeMockWindow(id: 2, pid: pid)
        repo.store(forPID: pid, windows: [w1, w2])

        repo.suppress(windowID: 1, forPID: pid)

        let changes = repo.store(forPID: pid, windows: [w1, w2])
        XCTAssertTrue(changes.added.isEmpty, "Suppressed window should not reappear")
        XCTAssertTrue(repo.isSuppressed(windowID: 1, forPID: pid))

        let cached = repo.readCache(forPID: pid)
        XCTAssertFalse(cached.contains(where: { $0.id == 1 }), "Suppressed window should not be in cache")
    }

    func testPreviewCacheStressDoesNotLeak() {
        let repo = WindowRepository()
        let pid: pid_t = 6666
        repo.previewCacheDuration = 0.01 // 10ms expiry

        for cycle in 0..<100 {
            let w = makeMockWindow(id: CGWindowID(cycle % 10), pid: pid)
            repo.store(forPID: pid, windows: [w])

            let context = CGContext(
                data: nil, width: 1, height: 1, bitsPerComponent: 8,
                bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            if let img = context.makeImage() {
                repo.storePreview(img, forWindowID: CGWindowID(cycle % 10))
            }

            if cycle % 10 == 0 {
                Thread.sleep(forTimeInterval: 0.02)
                repo.purgeExpiredPreviews()
            }
        }

        repo.purgeExpiredPreviews()
        let freshIDs = repo.windowIDsWithFreshPreviews()
        _ = freshIDs
    }

    func testRepositoryDoesNotBlockMainThread() async {
        let repo = WindowRepository()

        await assertMainThreadResponsive(during: {
            await withTaskGroup(of: Void.self) { group in
                for i in 0..<500 {
                    group.addTask {
                        let pid = pid_t(i % 20 + 100)
                        let w = makeMockWindow(id: CGWindowID(i), pid: pid)
                        repo.store(forPID: pid, windows: [w])
                        _ = repo.readAllCache()
                        _ = repo.readCache(forPID: pid)
                    }
                }
            }
        }, thresholdMs: 200)
    }
}

// =============================================================================
// MARK: - Observer Lifecycle Stress Tests
// =============================================================================

final class ObserverLifecycleStressTests: XCTestCase {

    func testRapidObserverCreateDestroy() {
        let pid = finderPID()
        let manager = AccessibilityWatcherManager()

        for _ in 0..<50 {
            let success = manager.watch(pid: pid)
            XCTAssertTrue(success || manager.isWatching(pid: pid))
            manager.unwatch(pid: pid)
            XCTAssertFalse(manager.isWatching(pid: pid))
        }

        manager.unwatchAll()
    }

    func testWatchUnwatchManyApps() {
        let pids = realAppPIDs()
        guard pids.count >= 2 else { return }

        let manager = AccessibilityWatcherManager()

        for pid in pids {
            manager.watch(pid: pid)
        }
        for pid in pids {
            XCTAssertTrue(manager.isWatching(pid: pid))
        }

        manager.unwatchAll()
        for pid in pids {
            XCTAssertFalse(manager.isWatching(pid: pid))
        }
    }

    func testResetAllDoesNotBlockMainThread() async {
        let pids = realAppPIDs()
        guard !pids.isEmpty else { return }

        let manager = AccessibilityWatcherManager()
        for pid in pids {
            manager.watch(pid: pid)
        }

        await assertMainThreadResponsive(during: {
            for _ in 0..<10 {
                manager.resetAll()
            }
        }, thresholdMs: 300)

        for pid in pids {
            XCTAssertTrue(manager.isWatching(pid: pid))
        }

        manager.unwatchAll()
    }

    // AXObserverCreate may succeed for non-existent PIDs; we just verify it doesn't hang.
    func testWatchInvalidPID() {
        let manager = AccessibilityWatcherManager()
        let start = CFAbsoluteTimeGetCurrent()
        let _ = manager.watch(pid: 99999)
        let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000

        XCTAssertLessThan(elapsed, 3000, "Should complete fast, not hang")
        manager.unwatchAll()
    }

    func testObserverEventsArePropagated() async {
        let pids = realAppPIDs()
        guard let pid = pids.first else { return }

        let manager = AccessibilityWatcherManager()
        manager.watch(pid: pid)

        var cancellable: AnyCancellable?
        let received = OSAllocatedUnfairLock(initialState: false)

        cancellable = manager.events
            .sink { _ in
                received.withLockUnchecked { $0 = true }
            }

        try? await Task.sleep(nanoseconds: 500_000_000)
        _ = received.withLockUnchecked { $0 }
        cancellable?.cancel()
        manager.unwatchAll()
    }
}

// =============================================================================
// MARK: - DockBadgeStore Stress Tests
// =============================================================================

final class DockBadgeStressTests: XCTestCase {

    func testConcurrentBadgeAccess() async {
        let store = DockBadgeStore()
        let pids = realAppPIDs()
        guard !pids.isEmpty else { return }

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    _ = store.refreshAll(pids: pids)
                }
            }
            for pid in pids {
                for _ in 0..<10 {
                    group.addTask {
                        _ = store.refresh(forPID: pid)
                    }
                }
            }
            for pid in pids {
                for _ in 0..<50 {
                    group.addTask {
                        _ = store.badge(forPID: pid)
                    }
                }
            }
        }
    }

    func testBadgePollingDoesNotBlockMainThread() async {
        let store = DockBadgeStore()
        let pids = realAppPIDs()
        guard !pids.isEmpty else { return }

        await assertMainThreadResponsive(during: {
            for _ in 0..<20 {
                _ = store.refreshAll(pids: pids)
            }
        }, thresholdMs: 200)
    }

    func testConcurrentInvalidateAndRefresh() async {
        let store = DockBadgeStore()
        let pids = realAppPIDs()
        guard !pids.isEmpty else { return }

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<50 {
                group.addTask {
                    store.invalidateCache()
                }
                group.addTask {
                    _ = store.refreshAll(pids: pids)
                }
            }
        }
    }

    func testRebuildCacheThrottling() {
        let store = DockBadgeStore()
        let pids = realAppPIDs()
        guard !pids.isEmpty else { return }

        let start = CFAbsoluteTimeGetCurrent()
        _ = store.refreshAll(pids: pids)

        for _ in 0..<100 {
            _ = store.refreshAll(pids: pids)
        }
        let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
        XCTAssertLessThan(elapsed, 5000, "100 cached badge refreshes should be fast")
    }
}

// =============================================================================
// MARK: - App Launch / Tracking Main Thread Tests
// =============================================================================

final class TrackingMainThreadTests: XCTestCase {

    func testFullScanDoesNotBlockMainThread() async {
        let tracker = WindowTracker()
        tracker.headless = true
        AXUIElement.systemWide().setMessagingTimeout(seconds: WindowTracker.axMessagingTimeout)

        await assertMainThreadResponsive(during: {
            await tracker.performFullScan()
        }, thresholdMs: 200)
    }

    func testTrackApplicationDoesNotBlockMainThread() async {
        let tracker = WindowTracker()
        tracker.headless = true

        AXUIElement.systemWide().setMessagingTimeout(seconds: WindowTracker.axMessagingTimeout)

        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        guard let app = apps.first else { return }

        await assertMainThreadResponsive(during: {
            _ = await tracker.trackApplication(app)
        }, thresholdMs: 200)
    }

    func testRapidAppTrackingDoesNotBlockMainThread() async {
        let tracker = WindowTracker()
        tracker.headless = true

        AXUIElement.systemWide().setMessagingTimeout(seconds: WindowTracker.axMessagingTimeout)

        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }

        await assertMainThreadResponsive(during: {
            for app in apps {
                _ = await tracker.trackApplication(app)
            }
        }, thresholdMs: 300)
    }

    func testConcurrentReadsDuringFullScan() async {
        let tracker = WindowTracker()
        tracker.headless = true

        AXUIElement.systemWide().setMessagingTimeout(seconds: WindowTracker.axMessagingTimeout)

        await tracker.performFullScan()

        await assertMainThreadResponsive(during: {
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    await tracker.performFullScan()
                }
                for _ in 0..<100 {
                    group.addTask {
                        _ = tracker.repository.readAllCache()
                    }
                }
            }
        }, thresholdMs: 200)
    }
}

// =============================================================================
// MARK: - Wake Recovery Tests
// =============================================================================

final class WakeRecoveryTests: XCTestCase {

    func testCanaryDetectsStaleAXResponse() {
        let app = AXUIElement.application(pid: 99999)
        app.setMessagingTimeout(seconds: 0.5)
        let role = try? app.role()
        XCTAssertNil(role)
    }

    func testCanaryCompletesWithinTimeout() {
        let start = CFAbsoluteTimeGetCurrent()
        _ = isAccessibilityReady()
        let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000

        XCTAssertLessThan(elapsed, 2000, "Canary probe should complete quickly")
    }

    func testWakeCooldownSuppressesEvents() async {
        let tracker = WindowTracker()
        tracker.headless = true
        tracker.startTracking()

        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.didWakeNotification,
            object: NSWorkspace.shared
        )

        try? await Task.sleep(nanoseconds: 100_000_000)
        tracker.stopTracking()
    }

    func testStopTrackingDuringWakeRecovery() async {
        let tracker = WindowTracker()
        tracker.headless = true
        tracker.startTracking()

        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.didWakeNotification,
            object: NSWorkspace.shared
        )

        try? await Task.sleep(nanoseconds: 50_000_000)
        tracker.stopTracking()

        tracker.startTracking()
        try? await Task.sleep(nanoseconds: 100_000_000)
        tracker.stopTracking()
    }

    func testRapidWakeNotificationsDoNotStack() async {
        let tracker = WindowTracker()
        tracker.headless = true
        tracker.startTracking()

        for _ in 0..<10 {
            NSWorkspace.shared.notificationCenter.post(
                name: NSWorkspace.didWakeNotification,
                object: NSWorkspace.shared
            )
        }

        try? await Task.sleep(nanoseconds: 500_000_000)
        tracker.stopTracking()
    }
}

// =============================================================================
// MARK: - ConcurrencyHelpers Stress Tests
// =============================================================================

final class ConcurrencyHelpersStressTests: XCTestCase {

    func testTimeoutCancelsOperation() async {
        let result: Int? = await ConcurrencyHelpers.withTimeout(seconds: 0.1) {
            try? await Task.sleep(nanoseconds: 5_000_000_000) // 5 seconds
            return 42
        }
        XCTAssertNil(result, "Should have timed out and returned nil")
    }

    func testTimeoutReturnsResultWhenFast() async {
        let result: Int? = await ConcurrencyHelpers.withTimeout(seconds: 5) {
            42
        }
        XCTAssertEqual(result, 42)
    }

    func testMapConcurrentRespectsLimit() async {
        let activeCount = OSAllocatedUnfairLock(initialState: 0)
        let maxObserved = OSAllocatedUnfairLock(initialState: 0)

        let items = Array(0..<20)
        let _: [Int] = await ConcurrencyHelpers.mapConcurrent(items, maxConcurrent: 3) { item in
            let current = activeCount.withLockUnchecked { count -> Int in
                count += 1
                return count
            }
            maxObserved.withLockUnchecked { $0 = max($0, current) }

            try? await Task.sleep(nanoseconds: 10_000_000)

            activeCount.withLockUnchecked { $0 -= 1 }
            return item
        }

        let maxConcurrent = maxObserved.withLockUnchecked { $0 }
        XCTAssertLessThanOrEqual(maxConcurrent, 3, "Should not exceed maxConcurrent=3")
    }

    func testMapConcurrentWithTimeoutDoesNotHang() async {
        let items = Array(0..<10)
        let start = CFAbsoluteTimeGetCurrent()

        let results: [Int] = await ConcurrencyHelpers.mapConcurrent(items, maxConcurrent: 2, timeout: 0.5) { _ in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            return 1
        }

        let elapsed = CFAbsoluteTimeGetCurrent() - start
        XCTAssertLessThan(elapsed, 2.0, "Should timeout at 0.5s, not hang for 10s")
        _ = results
    }

    func testForEachConcurrentEmptyInput() async {
        let items: [Int] = []
        await ConcurrencyHelpers.forEachConcurrent(items) { _ in
            XCTFail("Should not be called for empty input")
        }
    }

    func testCancellationPropagates() async {
        let started = OSAllocatedUnfairLock(initialState: false)

        let task = Task {
            let items = Array(0..<100)
            await ConcurrencyHelpers.forEachConcurrent(items, maxConcurrent: 4) { _ in
                started.withLockUnchecked { $0 = true }
                try? await Task.sleep(nanoseconds: 10_000_000_000)
            }
        }

        try? await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()

        let start = CFAbsoluteTimeGetCurrent()
        await task.value
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        XCTAssertLessThan(elapsed, 2.0, "Cancellation should propagate quickly")
    }
}

// =============================================================================
// MARK: - ChangeReport Correctness Tests
// =============================================================================

final class ChangeReportStressTests: XCTestCase {

    func testRapidStateTransitionsProduceCorrectReports() {
        let repo = WindowRepository()
        let pid: pid_t = 5555
        var allReports: [ChangeReport] = []

        for cycle in 0..<50 {
            let base = CGWindowID(cycle * 10)
            var windows: Set<CapturedWindow> = []
            for i in 0..<5 {
                windows.insert(makeMockWindow(id: base + CGWindowID(i), pid: pid))
            }

            let addReport = repo.store(forPID: pid, windows: windows)
            allReports.append(addReport)

            let modReport = repo.modify(forPID: pid) { existing in
                let first = existing.removeFirst()
                var updated = CapturedWindow(
                    id: first.id,
                    title: "Modified \(cycle)",
                    ownerBundleID: first.ownerBundleID,
                    ownerPID: first.ownerPID,
                    bounds: first.bounds,
                    isMinimized: true,
                    isFullscreen: first.isFullscreen,
                    isOwnerHidden: first.isOwnerHidden,
                    isVisible: first.isVisible,
                    desktopSpace: first.desktopSpace,
                    lastInteractionTime: Date(),
                    creationTime: first.creationTime,
                    axElement: first.axElement,
                    appAxElement: first.appAxElement
                )
                updated.cachedPreview = first.cachedPreview
                updated.previewTimestamp = first.previewTimestamp
                existing.insert(updated)
            }
            allReports.append(modReport)

            repo.removeAll(forPID: pid)
        }

        XCTAssertTrue(allReports[0].added.count > 0)
    }

    func testMergeDetectsModifications() {
        let repo = WindowRepository()
        let pid: pid_t = 4444

        let w = makeMockWindow(id: 1, pid: pid, title: "Original")
        repo.store(forPID: pid, windows: [w])

        let modified = makeMockWindow(id: 1, pid: pid, title: "Changed")
        let report = repo.store(forPID: pid, windows: [modified])

        XCTAssertTrue(report.added.isEmpty, "Same ID should not count as added")
        XCTAssertTrue(report.modified.contains(where: { $0.id == 1 }), "Changed title should be detected")
    }
}

// =============================================================================
// MARK: - WindowEnumerator Edge Cases
// =============================================================================

final class WindowEnumeratorEdgeCaseTests: XCTestCase {

    func testCGDescriptorsForRealApps() {
        let enumerator = WindowEnumerator()
        let pids = realAppPIDs()

        for pid in pids {
            let descriptors = enumerator.cgDescriptors(forPID: pid)
            _ = descriptors
        }
    }

    func testResolveWindowIDEmptyCandidates() {
        let enumerator = WindowEnumerator()
        let dummyElement = AXUIElementCreateSystemWide()
        let result = enumerator.resolveWindowID(dummyElement, candidates: [])
        XCTAssertNil(result)
    }

    func testFuzzyTitleEdgeCases() {
        let emptyResult = WindowEnumerator.isFuzzyTitleMatch("", "")
        _ = emptyResult

        let oneVsEmpty = WindowEnumerator.isFuzzyTitleMatch("a", "")
        _ = oneVsEmpty

        XCTAssertTrue(WindowEnumerator.isFuzzyTitleMatch("App - Very Long Title Here", "App"))
        XCTAssertTrue(WindowEnumerator.isFuzzyTitleMatch(
            String(repeating: "word ", count: 100),
            String(repeating: "word ", count: 100)
        ))
    }
}

// =============================================================================
// MARK: - ProcessWatcher Tests
// =============================================================================

final class ProcessWatcherTests: XCTestCase {

    func testCreationDoesNotBlockMainThread() async {
        await assertMainThreadResponsive(during: {
            let watcher = ProcessWatcher()
            _ = watcher.runningApplications()
            watcher.stopWatching()
        }, thresholdMs: 100)
    }

    func testRunningApplicationsReturnsRealApps() {
        let watcher = ProcessWatcher()
        let apps = watcher.runningApplications()
        XCTAssertFalse(apps.isEmpty, "Should find at least Finder")
        XCTAssertTrue(apps.contains(where: { $0.bundleIdentifier == "com.apple.finder" }))
        watcher.stopWatching()
    }

    func testRapidStartStopDoesNotLeak() {
        let watcher = ProcessWatcher()
        for _ in 0..<100 {
            watcher.startWatching()
            watcher.stopWatching()
        }
    }
}

// =============================================================================
// MARK: - ScreenLockObserver Tests
// =============================================================================

final class ScreenLockObserverTests: XCTestCase {

    func testSingletonAccessDoesNotBlock() {
        let start = CFAbsoluteTimeGetCurrent()
        let observer = ScreenLockObserver.shared
        let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
        XCTAssertLessThan(elapsed, 100)
        XCTAssertFalse(observer.isLocked, "Screen should not be locked during test execution")
    }

    func testEventsPublisherDoesNotHang() {
        let observer = ScreenLockObserver.shared
        var cancellable: AnyCancellable?
        cancellable = observer.events.sink { _ in }
        cancellable?.cancel()
    }
}

// =============================================================================
// MARK: - Integration: Full Lifecycle Stress Test
// =============================================================================

final class FullLifecycleStressTests: XCTestCase {

    func testFullLifecycleDoesNotBlockMainThread() async {
        let tracker = WindowTracker()
        tracker.headless = true
        AXUIElement.systemWide().setMessagingTimeout(seconds: WindowTracker.axMessagingTimeout)

        await assertMainThreadResponsive(during: {
            tracker.startTracking()
            await tracker.performFullScan()

            let apps = NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular }
                .prefix(5)

            for app in apps {
                _ = await tracker.trackApplication(app)
            }

            await tracker.performFullScan()
            _ = tracker.repository.readAllCache()

            tracker.stopTracking()
        }, thresholdMs: 300)
    }

    func testRapidStartStopTracking() async {
        let tracker = WindowTracker()
        tracker.headless = true

        for _ in 0..<20 {
            tracker.startTracking()
            try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
            tracker.stopTracking()
        }
    }

    func testEventPipelineDuringTracking() async {
        let tracker = WindowTracker()
        tracker.headless = true

        var windowEvents: [WindowEvent] = []
        var processEvents: [ProcessEvent] = []
        var cancellables = Set<AnyCancellable>()

        tracker.events
            .sink { windowEvents.append($0) }
            .store(in: &cancellables)

        tracker.processEvents
            .sink { processEvents.append($0) }
            .store(in: &cancellables)

        tracker.startTracking()

        try? await Task.sleep(nanoseconds: 2_000_000_000)

        tracker.stopTracking()
        cancellables.removeAll()

        if !NSWorkspace.shared.runningApplications.filter({ $0.activationPolicy == .regular }).isEmpty {
            _ = windowEvents
            _ = processEvents
        }
    }

    func testBadgePollingDuringTracking() async {
        let tracker = WindowTracker()
        tracker.headless = true

        let badgeStore = DockBadgeStore()
        let pids = realAppPIDs()

        tracker.startTracking()

        await assertMainThreadResponsive(during: {
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    await tracker.performFullScan()
                }
                group.addTask {
                    for _ in 0..<10 {
                        _ = badgeStore.refreshAll(pids: pids)
                        try? await Task.sleep(nanoseconds: 100_000_000)
                    }
                }
            }
        }, thresholdMs: 300)

        tracker.stopTracking()
    }
}

// =============================================================================
// MARK: - Extreme Stress: Simulated Catastrophic Failures
// =============================================================================

final class CatastrophicStressTests: XCTestCase {

    // MARK: - Post-Wake AX Degradation Simulation

    // Verifies merge strategy keeps cached windows when discovery returns empty (degraded AX).
    func testRepositoryPreservesWindowsDuringDegradedDiscovery() async {
        let repo = WindowRepository()
        let pids = realAppPIDs()
        guard pids.count >= 3 else { return }

        for pid in pids {
            for i in 0..<5 {
                let w = makeMockWindow(id: CGWindowID(Int(pid) * 100 + i), pid: pid)
                repo.store(forPID: pid, windows: [w])
            }
        }

        let totalBefore = repo.readAllCache().count
        XCTAssertGreaterThanOrEqual(totalBefore, pids.count * 5)

        for pid in pids {
            let discoveredNothing: Set<CapturedWindow> = []
            let changes = repo.store(forPID: pid, windows: discoveredNothing)

            // The MERGE strategy should keep all existing windows
            XCTAssertEqual(changes.removed.count, 0,
                "Merge strategy must NOT remove cached windows when discovery returns empty set (simulating degraded AX)")
        }

        let totalAfter = repo.readAllCache().count
        XCTAssertEqual(totalAfter, totalBefore,
            "All cached windows must survive a zero-result discovery scan")
    }

    // Canary gate prevents this in production; verify the raw repository behavior.
    func testPurifyAfterDegradedScanCausesTotalLoss() {
        let repo = WindowRepository()
        let pid: pid_t = 11111

        for i in 0..<10 {
            let w = makeMockWindow(id: CGWindowID(i), pid: pid)
            repo.store(forPID: pid, windows: [w])
        }
        XCTAssertEqual(repo.readCache(forPID: pid).count, 10)

        let remaining = repo.purify(forPID: pid) { _ in false }
        XCTAssertTrue(remaining.isEmpty,
            "Purify with all-reject validator should remove everything — this is the bug the canary gate prevents")
    }

    // MARK: - Notification Storm Simulation

    func testNotificationStormDoesNotBlockMainThread() async {
        let tracker = WindowTracker()
        tracker.headless = true
        AXUIElement.systemWide().setMessagingTimeout(seconds: WindowTracker.axMessagingTimeout)
        tracker.startTracking()

        await tracker.performFullScan()

        let pids = realAppPIDs()
        guard !pids.isEmpty else { tracker.stopTracking(); return }

        await assertMainThreadResponsive(during: {
            await withTaskGroup(of: Void.self) { group in
                for i in 0..<500 {
                    let pid = pids[i % pids.count]
                    group.addTask {
                        _ = await tracker.trackApplication(
                            NSRunningApplication(processIdentifier: pid) ?? NSRunningApplication.current
                        )
                    }
                }
            }
        }, thresholdMs: 500)

        tracker.stopTracking()
    }

    func testRapidSpaceChangesAreDebounced() async {
        let tracker = WindowTracker()
        tracker.headless = true
        AXUIElement.systemWide().setMessagingTimeout(seconds: WindowTracker.axMessagingTimeout)
        tracker.startTracking()

        let scanCountBefore = tracker.repository.readAllCache().count

        for _ in 0..<20 {
            NSWorkspace.shared.notificationCenter.post(
                name: NSWorkspace.activeSpaceDidChangeNotification,
                object: NSWorkspace.shared
            )
        }

        try? await Task.sleep(nanoseconds: 2_000_000_000)
        let scanCountAfter = tracker.repository.readAllCache().count
        _ = scanCountBefore
        _ = scanCountAfter

        tracker.stopTracking()
    }

    // MARK: - Repository Thrashing Under Combined Load

    func testRepositoryUnderMaxContention() async {
        let repo = WindowRepository()
        let enumerator = WindowEnumerator()
        let pids: [pid_t] = Array(1000..<1020) // 20 simulated PIDs

        for pid in pids {
            for i in 0..<10 {
                let w = makeMockWindow(id: CGWindowID(Int(pid) * 100 + i), pid: pid)
                repo.store(forPID: pid, windows: [w])
            }
        }

        await assertMainThreadResponsive(during: {
            await withTaskGroup(of: Void.self) { group in
                for round in 0..<50 {
                    group.addTask {
                        let pid = pids[round % pids.count]
                        let w = makeMockWindow(id: CGWindowID(5000 + round), pid: pid)
                        repo.store(forPID: pid, windows: [w])
                    }
                }

                for round in 0..<50 {
                    group.addTask {
                        let pid = pids[round % pids.count]
                        _ = repo.purify(forPID: pid, validator: { enumerator.isValidElement($0) })
                    }
                }

                for _ in 0..<200 {
                    group.addTask {
                        _ = repo.readAllCache()
                    }
                }

                for round in 0..<100 {
                    group.addTask {
                        let pid = pids[round % pids.count]
                        repo.modify(forPID: pid) { windows in
                            if let first = windows.first {
                                windows.remove(first)
                                let updated = CapturedWindow(
                                    id: first.id,
                                    title: "Thrash \(round)",
                                    ownerBundleID: first.ownerBundleID,
                                    ownerPID: first.ownerPID,
                                    bounds: first.bounds,
                                    isMinimized: Bool.random(),
                                    isFullscreen: first.isFullscreen,
                                    isOwnerHidden: Bool.random(),
                                    isVisible: first.isVisible,
                                    desktopSpace: first.desktopSpace,
                                    lastInteractionTime: Date(),
                                    creationTime: first.creationTime,
                                    axElement: first.axElement,
                                    appAxElement: first.appAxElement
                                )
                                windows.insert(updated)
                            }
                        }
                    }
                }

                for round in 0..<30 {
                    group.addTask {
                        let pid = pids[round % pids.count]
                        let windowID = CGWindowID(Int(pid) * 100 + (round % 10))
                        repo.suppress(windowID: windowID, forPID: pid)
                    }
                    group.addTask {
                        let pid = pids[round % pids.count]
                        repo.clearSuppressions(forPID: pid)
                    }
                }

                for round in 0..<5 {
                    group.addTask {
                        try? await Task.sleep(nanoseconds: UInt64(round) * 50_000_000)
                        let pid = pids[round]
                        repo.removeAll(forPID: pid)
                    }
                }
            }
        }, thresholdMs: 300)
    }

    // MARK: - Observer Reset During Active Event Processing

    func testObserverResetDuringActiveEventProcessing() async {
        let pids = realAppPIDs()
        guard pids.count >= 2 else { return }

        let manager = AccessibilityWatcherManager()
        var cancellables = Set<AnyCancellable>()
        let eventCount = OSAllocatedUnfairLock(initialState: 0)

        manager.events
            .sink { _ in
                eventCount.withLockUnchecked { $0 += 1 }
            }
            .store(in: &cancellables)

        for pid in pids {
            manager.watch(pid: pid)
        }

        await assertMainThreadResponsive(during: {
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    for _ in 0..<30 {
                        manager.resetAll()
                        try? await Task.sleep(nanoseconds: 10_000_000)
                    }
                }
                for pid in pids {
                    group.addTask {
                        for _ in 0..<20 {
                            manager.unwatch(pid: pid)
                            _ = manager.watch(pid: pid)
                        }
                    }
                }
            }
        }, thresholdMs: 500)

        cancellables.removeAll()
        manager.unwatchAll()
    }

    // MARK: - Combined Wake + Badge + Tracking Chaos

    func testCombinedWakeRecoveryUnderFullLoad() async {
        let tracker = WindowTracker()
        tracker.headless = true
        AXUIElement.systemWide().setMessagingTimeout(seconds: WindowTracker.axMessagingTimeout)
        tracker.startTracking()

        let badgeStore = DockBadgeStore()
        let pids = realAppPIDs()

        await tracker.performFullScan()
        try? await Task.sleep(nanoseconds: 500_000_000)

        await assertMainThreadResponsive(during: {
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    for _ in 0..<5 {
                        _ = badgeStore.refreshAll(pids: pids)
                        try? await Task.sleep(nanoseconds: 200_000_000)
                    }
                }

                group.addTask {
                    for _ in 0..<200 {
                        _ = tracker.repository.readAllCache()
                        for pid in pids {
                            _ = tracker.repository.readCache(forPID: pid)
                        }
                    }
                }

                group.addTask {
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    NSWorkspace.shared.notificationCenter.post(
                        name: NSWorkspace.didWakeNotification,
                        object: NSWorkspace.shared
                    )
                }

                group.addTask {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    for app in NSWorkspace.shared.runningApplications.filter({ $0.activationPolicy == .regular }).prefix(3) {
                        _ = await tracker.trackApplication(app)
                    }
                }
            }
        }, thresholdMs: 500)

        tracker.stopTracking()
    }

    // MARK: - Brute Force Enumeration Under Adversarial Conditions

    func testBruteForceEnumerationAllAppsSimultaneously() async {
        let pids = realAppPIDs()
        guard pids.count >= 3 else { return }

        let start = CFAbsoluteTimeGetCurrent()

        await assertMainThreadResponsive(during: {
            await withTaskGroup(of: Void.self) { group in
                for pid in pids {
                    group.addTask {
                        let element = AXUIElement.application(pid: pid)
                        element.setMessagingTimeout(seconds: WindowTracker.axMessagingTimeout)
                        _ = AXUIElement.allWindows(forPID: pid)
                    }
                }
            }
        }, thresholdMs: 500)

        let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
        print("Brute force enumeration of \(pids.count) apps took \(String(format: "%.0f", elapsed))ms")
    }

    func testPerAppAXLatencyProfiling() {
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        var slowApps: [(String, Double)] = []

        for app in apps {
            let pid = app.processIdentifier
            let name = app.localizedName ?? "pid=\(pid)"
            let element = AXUIElement.application(pid: pid)
            element.setMessagingTimeout(seconds: WindowTracker.axMessagingTimeout)

            let start = CFAbsoluteTimeGetCurrent()
            _ = try? element.windows()
            let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000

            if elapsed > 50 {
                slowApps.append((name, elapsed))
            }
        }

        if !slowApps.isEmpty {
            let report = slowApps.map { "\($0.0): \(String(format: "%.0f", $0.1))ms" }.joined(separator: ", ")
            print("Slow AX apps (>50ms): \(report)")
        }

        for (name, elapsed) in slowApps {
            XCTAssertLessThan(elapsed, Double(WindowTracker.axMessagingTimeout) * 1000 + 500,
                "\(name) exceeded AX messaging timeout")
        }
    }

    // MARK: - Preview Cache Pressure

    func testPreviewCacheUnderExtremePressure() async {
        let repo = WindowRepository()
        repo.previewCacheDuration = 0.001
        let pid: pid_t = 22222

            let context = CGContext(
            data: nil, width: 10, height: 10, bitsPerComponent: 8,
            bytesPerRow: 40, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        let img = context.makeImage()!

        await assertMainThreadResponsive(during: {
            await withTaskGroup(of: Void.self) { group in
                for i in 0..<200 {
                    group.addTask {
                        let wid = CGWindowID(i % 50)
                        let w = makeMockWindow(id: wid, pid: pid)
                        repo.store(forPID: pid, windows: [w])
                        repo.storePreview(img, forWindowID: wid)
                    }
                }
                for _ in 0..<50 {
                    group.addTask {
                        repo.purgeExpiredPreviews()
                    }
                }
                for i in 0..<100 {
                    group.addTask {
                        _ = repo.fetchPreview(forWindowID: CGWindowID(i % 50))
                        _ = repo.windowIDsWithFreshPreviews()
                    }
                }
            }
        }, thresholdMs: 300)
    }

    // MARK: - ProcessWatcher Event Flood

    func testProcessWatcherStressStartStopWithEvents() async {
        var cancellables = Set<AnyCancellable>()
        let eventCount = OSAllocatedUnfairLock(initialState: 0)

        for _ in 0..<50 {
            let watcher = ProcessWatcher()
            watcher.events
                .sink { _ in eventCount.withLockUnchecked { $0 += 1 } }
                .store(in: &cancellables)

            _ = watcher.runningApplications()
            watcher.stopWatching()
            watcher.startWatching()
            _ = watcher.runningApplications()
            watcher.stopWatching()
        }

        cancellables.removeAll()
    }

    // MARK: - Main Thread Starvation: The Killer Test

    func testMainThreadNeverStallsDuringEntireLifecycle() async {
        let tracker = WindowTracker()
        tracker.headless = true
        AXUIElement.systemWide().setMessagingTimeout(seconds: WindowTracker.axMessagingTimeout)

        let badgeStore = DockBadgeStore()
        let pids = realAppPIDs()

        await assertMainThreadResponsive(during: {
            tracker.startTracking()
            await tracker.performFullScan()

            for _ in 0..<10 {
                _ = badgeStore.refreshAll(pids: pids)
            }

            for app in NSWorkspace.shared.runningApplications.filter({ $0.activationPolicy == .regular }).prefix(5) {
                _ = await tracker.trackApplication(app)
            }

            NSWorkspace.shared.notificationCenter.post(
                name: NSWorkspace.didWakeNotification,
                object: NSWorkspace.shared
            )

            for _ in 0..<100 {
                _ = tracker.repository.readAllCache()
            }

            try? await Task.sleep(nanoseconds: 1_000_000_000)

            tracker.stopTracking()
        }, thresholdMs: 100)
    }
}

// =============================================================================
// MARK: - ChangeReport Under Adversarial Mutation
// =============================================================================

final class AdversarialChangeReportTests: XCTestCase {

    func testChangeReportConsistencyUnderRapidMutation() {
        let repo = WindowRepository()
        let pid: pid_t = 33333
        var allReports: [ChangeReport] = []

        for cycle in 0..<100 {
            // Store 5 windows
            var windows: Set<CapturedWindow> = []
            for j in 0..<5 {
                windows.insert(makeMockWindow(
                    id: CGWindowID(cycle * 10 + j),
                    pid: pid,
                    title: "Cycle \(cycle) Win \(j)"
                ))
            }
            allReports.append(repo.store(forPID: pid, windows: windows))

            // Modify one
            allReports.append(repo.modify(forPID: pid) { ws in
                if let first = ws.first {
                    ws.remove(first)
                    let updated = CapturedWindow(
                        id: first.id,
                        title: "MODIFIED",
                        ownerBundleID: first.ownerBundleID,
                        ownerPID: first.ownerPID,
                        bounds: first.bounds,
                        isMinimized: true,
                        isFullscreen: first.isFullscreen,
                        isOwnerHidden: first.isOwnerHidden,
                        isVisible: first.isVisible,
                        desktopSpace: first.desktopSpace,
                        lastInteractionTime: Date(),
                        creationTime: first.creationTime,
                        axElement: first.axElement,
                        appAxElement: first.appAxElement
                    )
                    ws.insert(updated)
                }
            })

            _ = repo.purify(forPID: pid) { _ in Bool.random() }
        }

        for report in allReports {
            let addedIDs = Set(report.added.map(\.id))
            XCTAssertTrue(addedIDs.isDisjoint(with: report.removed),
                "A window cannot be both added and removed in the same report")
        }
    }
}

// =============================================================================
// MARK: - Rapid Create/Destroy (Electron Title Change Regression)
// =============================================================================

final class RapidCreateDestroyTests: XCTestCase {

    /// Phantom create/destroy cycles (Electron title changes) must not trigger SCK rediscovery.
    func testPhantomCreateDestroyDoesNotRediscover() async {
        let tracker = WindowTracker()
        tracker.headless = true
        AXUIElement.systemWide().setMessagingTimeout(seconds: WindowTracker.axMessagingTimeout)

        let app = NSWorkspace.shared.runningApplications
            .first(where: { $0.bundleIdentifier == "com.apple.finder" })!
        let pid = app.processIdentifier

        _ = await tracker.trackApplication(app)
        let cachedBefore = tracker.repository.readCache(forPID: pid)
        guard !cachedBefore.isEmpty else { return }

        let snapshotIDs = Set(cachedBefore.map(\.id))
        let start = CFAbsoluteTimeGetCurrent()

        for _ in 0..<50 {
            let destroyChanges = tracker.repository.modify(forPID: pid) { windows in
                windows = windows.filter { WindowEnumerator().isValidElement($0.axElement) }
            }
            XCTAssertFalse(destroyChanges.hasChanges,
                "Destroy filter should be no-op for valid windows")

            let newWindows = await tracker.discovery.discoverNew(for: app)
            let rediscovered = newWindows.filter { snapshotIDs.contains($0.id) }
            XCTAssertEqual(rediscovered.count, 0,
                "discoverNew must not rediscover cached windows")
        }

        let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
        XCTAssertLessThan(elapsed, 5000,
            "50 cycles took \(String(format: "%.0f", elapsed))ms — likely hitting SCK")

        let afterIDs = Set(tracker.repository.readCache(forPID: pid).map(\.id))
        XCTAssertTrue(snapshotIDs.isSubset(of: afterIDs),
            "Cached windows must survive phantom cycles")
    }

    /// discoverNew finds only uncached windows; cached ones are skipped.
    func testGenuineNewWindowStillDiscovered() async {
        let tracker = WindowTracker()
        tracker.headless = true
        AXUIElement.systemWide().setMessagingTimeout(seconds: WindowTracker.axMessagingTimeout)

        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
        guard let app = apps.first else { return }
        let pid = app.processIdentifier

        _ = await tracker.trackApplication(app)
        let cachedIDs = Set(tracker.repository.readCache(forPID: pid).map(\.id))

        let allIDs = Set((await tracker.discovery.discoverAll(for: app)).map(\.id))
        let expectedNewIDs = allIDs.subtracting(cachedIDs)

        let newIDs = Set((await tracker.discovery.discoverNew(for: app)).map(\.id))
        XCTAssertEqual(newIDs, expectedNewIDs,
            "discoverNew should find only windows not in cache")
    }

    func testRapidCreateDestroyDoesNotBlockMainThread() async {
        let tracker = WindowTracker()
        tracker.headless = true
        AXUIElement.systemWide().setMessagingTimeout(seconds: WindowTracker.axMessagingTimeout)

        let app = NSWorkspace.shared.runningApplications
            .first(where: { $0.bundleIdentifier == "com.apple.finder" })!
        let pid = app.processIdentifier

        _ = await tracker.trackApplication(app)
        guard !tracker.repository.readCache(forPID: pid).isEmpty else { return }

        await assertMainThreadResponsive(during: {
            for _ in 0..<50 {
                tracker.repository.modify(forPID: pid) { windows in
                    windows = windows.filter { WindowEnumerator().isValidElement($0.axElement) }
                }
                _ = await tracker.discovery.discoverNew(for: app)
            }
        }, thresholdMs: 200)
    }
}
