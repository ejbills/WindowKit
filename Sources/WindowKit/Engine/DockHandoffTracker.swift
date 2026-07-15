import AppKit
import ApplicationServices
import Combine
import os

// MARK: - Public model

/// A Handoff activity as the native macOS Dock reports it (an
/// `AXHandoffDockItem`), advertised by a nearby device on the same iCloud
/// account. No icon is exposed over accessibility, so consumers resolve the
/// app icon from `appName`.
public struct DockHandoffItem: Identifiable, Equatable {
    public let id: String
    /// The advertising app's display name (the item's `AXTitle`), e.g. "Mail".
    public let appName: String
    /// The source device's raw status label (the item's `AXStatusLabel`),
    /// e.g. "com.apple.iphone-16-pro-max-1". Consumers derive a friendly name.
    public let deviceStatusLabel: String?

    public static func == (lhs: DockHandoffItem, rhs: DockHandoffItem) -> Bool {
        lhs.id == rhs.id && lhs.appName == rhs.appName && lhs.deviceStatusLabel == rhs.deviceStatusLabel
    }
}

// MARK: - Tracker

/// Surfaces the Dock's Handoff tiles, driven by the shared Dock AX observer (no
/// polling). Activation is `AXPress` on the Dock item — mirroring a click on the
/// native Handoff tile.
final class DockHandoffTracker: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.windowkit.dockHandoff", qos: .userInitiated)

    var itemsPublisher: AnyPublisher<[DockHandoffItem], Never> { subject.eraseToAnyPublisher() }
    private let subject = CurrentValueSubject<[DockHandoffItem], Never>([])

    private let isActive = OSAllocatedUnfairLock(initialState: false)
    // id -> live Dock AX item, for AXPress on activate. Read off the main actor.
    private let itemElements = OSAllocatedUnfairLock<[String: AXUIElement]>(initialState: [:])

    private var rebuildScheduled = false
    private let dockObserver = DockAXObserver()

    init() {}
    deinit { stop() }

    // MARK: Lifecycle

    func start(processEvents: AnyPublisher<ProcessEvent, Never>?) {
        guard !isActive.withLock({ $0 }) else { return }
        isActive.withLock { $0 = true }
        Logger.info("Starting native-dock handoff tracking")
        dockObserver.onChange = { [weak self] in self?.scheduleRebuild() }
        dockObserver.start(processEvents: processEvents)
        scheduleRebuild()
    }

    func stop() {
        guard isActive.withLock({ $0 }) else { return }
        isActive.withLock { $0 = false }
        Logger.info("Stopping native-dock handoff tracking")
        dockObserver.stop()
        itemElements.withLock { $0 = [:] }
        queue.async { [weak self] in self?.rebuildScheduled = false }
        if !subject.value.isEmpty { subject.send([]) }
    }

    /// Forces a rebuild. The set is otherwise maintained by Dock AX
    /// notifications, not polling.
    func refreshNow() {
        scheduleRebuild()
    }

    /// Presses the Handoff tile's live Dock item (`AXPress`) to resume the
    /// activity. `id` is a `DockHandoffItem.id`.
    func activate(id: String) {
        let element = itemElements.withLock { $0[id] }
        guard let element else { return }
        queue.async { _ = AXUIElementPerformAction(element, "AXPress" as CFString) }
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

        var items: [DockHandoffItem] = []
        var elements: [String: AXUIElement] = [:]
        for (index, item) in handoffItems().enumerated() {
            // Stable within a publish; the Dock rarely shows more than one.
            let id = "handoff:\(index):\(item.appName)"
            items.append(DockHandoffItem(id: id, appName: item.appName, deviceStatusLabel: item.statusLabel))
            elements[id] = item.element
        }

        itemElements.withLock { $0 = elements }
        publish(items)
    }

    private func publish(_ items: [DockHandoffItem]) {
        guard isActive.withLock({ $0 }), subject.value != items else { return }
        Logger.debug("Dock handoff items updated", details: "count=\(items.count)")
        subject.send(items)
    }

    // MARK: Accessibility reads (queue only)

    private struct HandoffItem { let element: AXUIElement; let appName: String; let statusLabel: String? }

    private func handoffItems() -> [HandoffItem] {
        guard let list = dockObserver.dockItemList(),
              let children = DockAXObserver.axCopy(list, kAXChildrenAttribute) as? [AXUIElement] else { return [] }
        return children
            .filter { DockAXObserver.axString($0, kAXSubroleAttribute) == "AXHandoffDockItem" }
            .map {
                HandoffItem(
                    element: $0,
                    appName: DockAXObserver.axString($0, kAXTitleAttribute) ?? "",
                    statusLabel: DockAXObserver.axString($0, "AXStatusLabel")
                )
            }
    }
}
