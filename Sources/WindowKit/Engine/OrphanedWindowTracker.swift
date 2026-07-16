import AppKit
import ApplicationServices
import Combine
import os

// MARK: - Public model

/// A minimized window as the native macOS Dock reports it (an
/// `AXMinimizedWindowDockItem`), including app-less ones from menu-bar/agent apps.
public struct DockMinimizedWindow: Identifiable, Equatable {
    public let id: String
    public let windowID: CGWindowID?
    public let ownerPID: pid_t
    public let title: String
    public let preview: CGImage?

    public static func == (lhs: DockMinimizedWindow, rhs: DockMinimizedWindow) -> Bool {
        lhs.id == rhs.id && lhs.title == rhs.title && (lhs.preview != nil) == (rhs.preview != nil)
    }
}

// MARK: - Tracker

/// Surfaces the Dock's minimized windows, driven by Dock AX notifications (no
/// polling). Restore is `AXPress` on the Dock item.
final class OrphanedWindowTracker: @unchecked Sendable {
    /// Wait out the minimize animation before capturing the thumbnail.
    static let captureSettleDelay: TimeInterval = 0.6
    /// Backoff delays for re-attempting a failed thumbnail capture. Captures can
    /// fail transiently right after process launch (permission preflight, window
    /// server warm-up); without a retry the tile never surfaces, because rebuilds
    /// are AX-notification-driven and a static minimized window produces none.
    static let captureRetryDelays: [TimeInterval] = [1.0, 3.0]
    /// Extra rebuilds after `start()` to recover from a transiently failed or
    /// empty initial read (launch races, Dock still rebuilding its AX tree).
    /// Publishing is change-gated, so these are no-ops when the first read stuck.
    static let startSettleRebuildDelays: [TimeInterval] = [2.0, 8.0]
    private let queue = DispatchQueue(label: "com.windowkit.dockMinimized", qos: .userInitiated)
    private var screenshotService = ScreenshotService()

    var previewCaptureQuality: WindowCaptureQuality = .nominal {
        didSet { screenshotService.captureQuality = previewCaptureQuality }
    }

    var previewResolutionScale: Int = 1 {
        didSet { screenshotService.downsampleFactor = previewResolutionScale }
    }

    var windowsPublisher: AnyPublisher<[DockMinimizedWindow], Never> { subject.eraseToAnyPublisher() }
    private let subject = CurrentValueSubject<[DockMinimizedWindow], Never>([])

    private let isActive = OSAllocatedUnfairLock(initialState: false)
    // id -> live Dock AX item, for AXPress on restore. Read off the main actor.
    private let itemElements = OSAllocatedUnfairLock<[String: AXUIElement]>(initialState: [:])

    // Touched only on `queue`.
    private var previewCache: [CGWindowID: CGImage] = [:]
    private var scheduledCaptures: Set<CGWindowID> = []
    private var suppressedIDs: Set<String> = []
    private var rebuildScheduled = false
    // Monotonic order each window was first seen minimized, for oldest-first sorting.
    private var firstSeenOrder: [CGWindowID: Int] = [:]
    private var seenCounter = 0

    // Shared Dock AX observer; fires `scheduleRebuild` on item add/remove.
    private let dockObserver = DockAXObserver()

    init() {}
    deinit { stop() }

    // MARK: Lifecycle

    func start() {
        guard !isActive.withLock({ $0 }) else { return }
        isActive.withLock { $0 = true }
        Logger.info("Starting native-dock minimized window tracking")
        dockObserver.onChange = { [weak self] in self?.scheduleRebuild() }
        dockObserver.start()
        scheduleRebuild()
        for delay in Self.startSettleRebuildDelays {
            queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.isActive.withLock({ $0 }) else { return }
                self.rebuild()
            }
        }
    }

    func stop() {
        guard isActive.withLock({ $0 }) else { return }
        isActive.withLock { $0 = false }
        Logger.info("Stopping native-dock minimized window tracking")
        dockObserver.stop()
        itemElements.withLock { $0 = [:] }
        queue.async { [weak self] in
            guard let self else { return }
            self.previewCache = [:]
            self.scheduledCaptures = []
            self.suppressedIDs = []
            self.firstSeenOrder = [:]
            self.seenCounter = 0
            self.rebuildScheduled = false
        }
        if !subject.value.isEmpty { subject.send([]) }
    }

    /// Forces a rebuild (e.g. on demand). The set is otherwise maintained by Dock
    /// AX notifications, not polling.
    func refreshNow() {
        scheduleRebuild()
    }

    /// Presses the window's live Dock item (`AXPress`) to restore it, and drops it
    /// from the published set immediately so the tile disappears on click.
    func restore(id: String) {
        let element = itemElements.withLock { $0[id] }
        guard let element else { return }
        queue.async { [weak self] in
            _ = AXUIElementPerformAction(element, "AXPress" as CFString)
            guard let self, self.isActive.withLock({ $0 }) else { return }
            self.suppressedIDs.insert(id)
            self.rebuild()
        }
    }

    // MARK: Rebuild (queue only)

    /// Coalesces a burst of AX notifications into a single rebuild.
    private func scheduleRebuild() {
        queue.async { [weak self] in
            guard let self, self.isActive.withLock({ $0 }), !self.rebuildScheduled else { return }
            self.rebuildScheduled = true
            self.queue.async { [weak self] in
                self?.rebuildScheduled = false
                self?.rebuild()
            }
        }
    }

    private func rebuild() {
        guard isActive.withLock({ $0 }) else { return }

        let items = dockMinimizedItems()
        guard !items.isEmpty else {
            previewCache.removeAll()
            scheduledCaptures.removeAll()
            suppressedIDs.removeAll()
            firstSeenOrder.removeAll()
            itemElements.withLock { $0 = [:] }
            publish([])
            return
        }

        let titleToWindows = minimizedWindowsByTitle()
        var entries: [(window: DockMinimizedWindow, order: Int)] = []
        var newElements: [String: AXUIElement] = [:]
        var liveWindowIDs = Set<CGWindowID>()
        var usedWindowIDs = Set<CGWindowID>()

        for item in items {
            let candidates = titleToWindows[item.title] ?? []
            // No window id means no thumbnail, so skip.
            guard let match = candidates.first(where: { !usedWindowIDs.contains($0.id) }) else { continue }
            let windowID = match.id
            usedWindowIDs.insert(windowID)
            liveWindowIDs.insert(windowID)

            let order = firstSeenOrder[windowID] ?? {
                let next = seenCounter
                firstSeenOrder[windowID] = next
                seenCounter += 1
                return next
            }()

            // Only surface once the thumbnail is captured — no placeholder tile.
            guard let preview = previewCache[windowID] else {
                scheduleCapture(windowID)
                continue
            }

            let id = "win:\(windowID)"
            entries.append((DockMinimizedWindow(id: id, windowID: windowID, ownerPID: match.pid, title: item.title, preview: preview), order))
            newElements[id] = item.element
        }

        // Oldest minimized first; newest last.
        let ordered = entries.sorted { $0.order < $1.order }.map(\.window)
        suppressedIDs.formIntersection(Set(ordered.map(\.id)))
        let visible = ordered.filter { !suppressedIDs.contains($0.id) }

        previewCache = previewCache.filter { liveWindowIDs.contains($0.key) }
        scheduledCaptures = scheduledCaptures.filter { liveWindowIDs.contains($0) }
        firstSeenOrder = firstSeenOrder.filter { liveWindowIDs.contains($0.key) }
        let finalElements = newElements.filter { !suppressedIDs.contains($0.key) }
        itemElements.withLock { $0 = finalElements }
        publish(visible)
    }

    /// Captures the thumbnail once the genie animation has settled, then rebuilds to
    /// republish with the image. Failed captures retry on `captureRetryDelays`
    /// backoff; after the chain exhausts, the next rebuild starts a fresh chain.
    private func scheduleCapture(_ windowID: CGWindowID, attempt: Int = 0) {
        guard !scheduledCaptures.contains(windowID) else { return }
        scheduledCaptures.insert(windowID)
        let delay = attempt == 0 ? Self.captureSettleDelay : Self.captureRetryDelays[attempt - 1]
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.isActive.withLock({ $0 }) else { return }
            self.scheduledCaptures.remove(windowID)
            guard self.previewCache[windowID] == nil else { return }
            if let image = try? self.screenshotService.captureWindow(id: windowID) {
                self.previewCache[windowID] = image
                self.rebuild()
            } else if attempt < Self.captureRetryDelays.count {
                self.scheduleCapture(windowID, attempt: attempt + 1)
            }
        }
    }

    private func publish(_ windows: [DockMinimizedWindow]) {
        guard isActive.withLock({ $0 }), subject.value != windows else { return }
        Logger.debug("Dock minimized windows updated", details: "count=\(windows.count)")
        subject.send(windows)
    }

    // MARK: Accessibility reads (queue only)

    private struct DockItem { let element: AXUIElement; let title: String }

    private func dockMinimizedItems() -> [DockItem] {
        guard let list = dockObserver.dockItemList(),
              let children = DockAXObserver.axCopy(list, kAXChildrenAttribute) as? [AXUIElement] else { return [] }
        return children
            .filter { DockAXObserver.axString($0, kAXSubroleAttribute) == "AXMinimizedWindowDockItem" }
            .map { DockItem(element: $0, title: DockAXObserver.axString($0, kAXTitleAttribute) ?? "") }
    }

    /// Titles -> candidate (window id, owner pid) for every minimized window. No
    /// product filtering here; consumers decide what to show from the owner pid
    /// (e.g. dropping windows whose app already has a dock icon).
    private func minimizedWindowsByTitle() -> [String: [(id: CGWindowID, pid: pid_t)]] {
        let options: CGWindowListOption = [.optionAll, .excludeDesktopElements]
        guard let infos = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: AnyObject]] else {
            return [:]
        }
        var map: [String: [(id: CGWindowID, pid: pid_t)]] = [:]
        for info in infos {
            guard let title = info[kCGWindowName as String] as? String, !title.isEmpty,
                  let windowID = info[kCGWindowNumber as String] as? CGWindowID,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t else { continue }
            map[title, default: []].append((windowID, pid))
        }
        return map
    }
}
