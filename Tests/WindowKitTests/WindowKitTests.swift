import XCTest
@testable import WindowKit

final class WindowKitTests: XCTestCase {

    func testPermissionState() {
        let granted = PermissionState(accessibilityGranted: true, screenCaptureGranted: true)
        XCTAssertTrue(granted.allGranted)

        let partial = PermissionState(accessibilityGranted: true, screenCaptureGranted: false)
        XCTAssertFalse(partial.allGranted)

        let none = PermissionState(accessibilityGranted: false, screenCaptureGranted: false)
        XCTAssertFalse(none.allGranted)
    }

    func testWindowIDExtensions() {
        let invalidID: CGWindowID = 0
        XCTAssertNil(invalidID.title())
        XCTAssertEqual(invalidID.spaces(), [])
    }

    func testEmptyChangeReport() {
        let empty = ChangeReport.empty
        XCTAssertFalse(empty.hasChanges)
        XCTAssertTrue(empty.added.isEmpty)
        XCTAssertTrue(empty.removed.isEmpty)
        XCTAssertTrue(empty.modified.isEmpty)
    }

    func testFuzzyTitleMatching() {
        XCTAssertTrue(WindowEnumerator.isFuzzyTitleMatch("Safari", "Safari"))

        XCTAssertTrue(WindowEnumerator.isFuzzyTitleMatch("Safari - Google", "Safari"))
        XCTAssertTrue(WindowEnumerator.isFuzzyTitleMatch("Safari", "Safari - Google"))

        XCTAssertFalse(WindowEnumerator.isFuzzyTitleMatch("Safari", "Chrome"))
        XCTAssertFalse(WindowEnumerator.isFuzzyTitleMatch("Finder", "Terminal"))
    }

    func testMinimumWindowSize() {
        XCTAssertEqual(WindowEnumerator.minimumWindowSize, CGSize(width: 100, height: 100))
    }

    func testPreviewCacheConstants() {
        XCTAssertEqual(WindowRepository.previewCacheDuration, 30.0)
        XCTAssertEqual(WindowRepository.maxCachedPreviews, 100)
    }

    func testRepositoryMergeStrategy() async {
        // Test that store() merges windows instead of replacing them
        // This ensures windows on other spaces (not re-discovered due to CGS timing)
        // remain in cache until they fail isValidElement check

        let repo = WindowRepository()
        let pid: pid_t = 12345

        // Simulate: first scan finds window A and B
        let mockWindowA = makeMockWindow(id: 100, pid: pid)
        let mockWindowB = makeMockWindow(id: 200, pid: pid)
        let firstScan: Set<CapturedWindow> = [mockWindowA, mockWindowB]

        let changes1 = await repo.store(forPID: pid, windows: firstScan)
        XCTAssertEqual(changes1.added.count, 2)
        XCTAssertEqual(changes1.removed.count, 0)

        // Simulate: second scan only finds window A (window B on other space, CGS returned empty spaces)
        let secondScan: Set<CapturedWindow> = [mockWindowA]

        let changes2 = await repo.store(forPID: pid, windows: secondScan)
        // Window B should NOT be removed - merge strategy keeps it
        XCTAssertEqual(changes2.removed.count, 0, "Merge strategy should not remove windows that weren't re-discovered")

        // Note: fetch() calls purifyWindows which may remove invalid elements
        // In this test with mock windows, they'll be purged since axElement is invalid
        // The key assertion is that store() didn't remove window B
        XCTAssertEqual(changes2.removed.count, 0)
    }

    // Helper to create mock CapturedWindow for testing
    // Note: These have invalid axElements and will be purged on fetch
    private func makeMockWindow(id: CGWindowID, pid: pid_t) -> CapturedWindow {
        let dummyAx = AXUIElementCreateSystemWide()
        return CapturedWindow(
            id: id,
            title: "Test Window \(id)",
            ownerBundleID: "com.test.app",
            ownerPID: pid,
            bounds: CGRect(x: 0, y: 0, width: 800, height: 600),
            isMinimized: false,
            isOwnerHidden: false,
            isVisible: true,
            desktopSpace: 1,
            lastInteractionTime: Date(),
            creationTime: Date(),
            axElement: dummyAx,
            appAxElement: dummyAx,
            closeButton: nil
        )
    }
}
