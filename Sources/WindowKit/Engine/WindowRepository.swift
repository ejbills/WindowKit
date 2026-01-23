import Cocoa

public struct ChangeReport: Sendable {
    public let added: Set<CapturedWindow>
    public let removed: Set<CGWindowID>
    public let modified: Set<CapturedWindow>
    public var hasChanges: Bool { !added.isEmpty || !removed.isEmpty || !modified.isEmpty }
    public static let empty = ChangeReport(added: [], removed: [], modified: [])
}

struct TimestampedPreview {
    let image: CGImage
    let timestamp: Date
}

public actor WindowRepository {
    static let previewCacheDuration: TimeInterval = 30.0
    static let maxCachedPreviews: Int = 100

    private var entries: [pid_t: Set<CapturedWindow>] = [:]
    private var previews: [CGWindowID: TimestampedPreview] = [:]
    private var previewAccessOrder: [CGWindowID] = []
    private let enumerator = WindowEnumerator()

    public init() {}

    public func fetch(forPID pid: pid_t) -> Set<CapturedWindow> {
        entries[pid] ?? []
    }

    public func fetch(windowID: CGWindowID) -> CapturedWindow? {
        for (_, windowSet) in entries {
            if let window = windowSet.first(where: { $0.id == windowID }) {
                return window
            }
        }
        return nil
    }

    public func fetchAll() -> [CapturedWindow] {
        entries.values.flatMap { $0 }.sorted { $0.lastInteractionTime > $1.lastInteractionTime }
    }

    public func fetch(bundleID: String) -> [CapturedWindow] {
        fetchAll().filter { $0.ownerBundleID == bundleID }
    }

    @discardableResult
    public func purify(forPID pid: pid_t) -> Set<CapturedWindow> {
        let windows = entries[pid] ?? []

        if !windows.isEmpty {
            Logger.debug("Purify checking", details: "pid=\(pid), cached=\(windows.count)")
        }

        var validWindows = Set<CapturedWindow>()
        var invalidIDs = [CGWindowID]()

        for window in windows {
            if enumerator.isValidElement(window.axElement) {
                validWindows.insert(window)
            } else {
                invalidIDs.append(window.id)
            }
        }

        if !invalidIDs.isEmpty {
            Logger.debug("Purging invalid windows", details: "pid=\(pid), count=\(invalidIDs.count), ids=\(invalidIDs)")
            for windowID in invalidIDs {
                removeEntryInternal(pid: pid, windowID: windowID)
            }
        }

        return validWindows
    }

    private func removeEntryInternal(pid: pid_t, windowID: CGWindowID) {
        entries[pid]?.remove(where: { $0.id == windowID })
        if entries[pid]?.isEmpty == true {
            entries.removeValue(forKey: pid)
        }
        previews.removeValue(forKey: windowID)
        previewAccessOrder.removeAll { $0 == windowID }
    }

    @discardableResult
    public func store(forPID pid: pid_t, windows: Set<CapturedWindow>) -> ChangeReport {
        let oldWindows = entries[pid] ?? []

        // Merge strategy: keep existing windows, add/update new ones
        var merged = oldWindows

        // Add or update windows from new set, preserving previews
        for window in windows {
            var windowToInsert = window

            // Preserve existing preview if new window doesn't have one
            if windowToInsert.cachedPreview == nil,
               let oldWindow = merged.first(where: { $0.id == window.id }),
               oldWindow.cachedPreview != nil {
                windowToInsert.cachedPreview = oldWindow.cachedPreview
                windowToInsert.previewTimestamp = oldWindow.previewTimestamp
            }

            merged.remove(where: { $0.id == window.id })
            merged.insert(windowToInsert)
        }

        entries[pid] = merged

        Logger.debug("Store merge result", details: "pid=\(pid), old=\(oldWindows.count), discovered=\(windows.count), merged=\(merged.count)")

        let changes = computeChanges(old: oldWindows, new: merged)
        if changes.hasChanges {
            Logger.debug("Repository updated", details: "pid=\(pid), added=\(changes.added.count), removed=\(changes.removed.count), modified=\(changes.modified.count)")
        }
        return changes
    }

    @discardableResult
    public func modify(forPID pid: pid_t, _ mutation: (inout Set<CapturedWindow>) -> Void) -> ChangeReport {
        var currentWindows = entries[pid] ?? []
        let oldWindows = currentWindows
        mutation(&currentWindows)
        if currentWindows.isEmpty {
            entries.removeValue(forKey: pid)
        } else {
            entries[pid] = currentWindows
        }
        return computeChanges(old: oldWindows, new: currentWindows)
    }

    public func removeEntry(pid: pid_t, windowID: CGWindowID) {
        removeEntryInternal(pid: pid, windowID: windowID)
    }

    public func removeAll(forPID pid: pid_t) {
        if let windows = entries.removeValue(forKey: pid) {
            for window in windows {
                previews.removeValue(forKey: window.id)
                previewAccessOrder.removeAll { $0 == window.id }
            }
        }
    }

    public func clear() {
        entries.removeAll()
        previews.removeAll()
        previewAccessOrder.removeAll()
    }

    public func storePreview(_ image: CGImage, forWindowID windowID: CGWindowID) {
        previews[windowID] = TimestampedPreview(image: image, timestamp: Date())
        previewAccessOrder.removeAll { $0 == windowID }
        previewAccessOrder.append(windowID)
        while previewAccessOrder.count > Self.maxCachedPreviews {
            let evictID = previewAccessOrder.removeFirst()
            previews.removeValue(forKey: evictID)
        }
    }

    public func fetchPreview(forWindowID windowID: CGWindowID) -> CGImage? {
        guard let preview = previews[windowID] else { return nil }
        previewAccessOrder.removeAll { $0 == windowID }
        previewAccessOrder.append(windowID)
        return preview.image
    }

    public func purgeExpiredPreviews() {
        let now = Date()
        let expiredIDs = previews.filter { now.timeIntervalSince($0.value.timestamp) > Self.previewCacheDuration }.map(\.key)
        for windowID in expiredIDs {
            previews.removeValue(forKey: windowID)
            previewAccessOrder.removeAll { $0 == windowID }
        }
    }

    public func windowIDsWithFreshPreviews() -> Set<CGWindowID> {
        let now = Date()
        return Set(previews.compactMap { now.timeIntervalSince($0.value.timestamp) <= Self.previewCacheDuration ? $0.key : nil })
    }

    private func computeChanges(old: Set<CapturedWindow>, new: Set<CapturedWindow>) -> ChangeReport {
        let oldIDs = Set(old.map(\.id))
        let newIDs = Set(new.map(\.id))
        let addedIDs = newIDs.subtracting(oldIDs)
        let removedIDs = oldIDs.subtracting(newIDs)
        let persistingIDs = oldIDs.intersection(newIDs)

        let added = new.filter { addedIDs.contains($0.id) }
        var modified: Set<CapturedWindow> = []

        for windowID in persistingIDs {
            guard let oldWindow = old.first(where: { $0.id == windowID }),
                  let newWindow = new.first(where: { $0.id == windowID }) else { continue }
            if oldWindow.title != newWindow.title ||
               oldWindow.isMinimized != newWindow.isMinimized ||
               oldWindow.isOwnerHidden != newWindow.isOwnerHidden ||
               oldWindow.bounds != newWindow.bounds {
                modified.insert(newWindow)
            }
        }
        return ChangeReport(added: added, removed: removedIDs, modified: modified)
    }
}

extension Set {
    mutating func remove(where predicate: (Element) -> Bool) {
        self = self.filter { !predicate($0) }
    }
}
