import Cocoa

public struct ChangeReport: Sendable {
    public let added: Set<CapturedWindow>
    public let removed: Set<CGWindowID>
    public let modified: Set<CapturedWindow>
    public var hasChanges: Bool { !added.isEmpty || !removed.isEmpty || !modified.isEmpty }
    public static let empty = ChangeReport(added: [], removed: [], modified: [])
}

public final class WindowRepository: @unchecked Sendable {
    public static let defaultPreviewCacheDuration: TimeInterval = 30.0
    public var previewCacheDuration: TimeInterval = WindowRepository.defaultPreviewCacheDuration

    private var entries: [pid_t: Set<CapturedWindow>] = [:]
    private let cacheLock = NSLock()

    public init() {}

    public func trackedApplications() -> [NSRunningApplication] {
        cacheLock.lock()
        let pids = Array(entries.keys)
        cacheLock.unlock()
        return pids.compactMap { NSRunningApplication(processIdentifier: $0) }
    }

    public func readCache(forPID pid: pid_t) -> [CapturedWindow] {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return Array(entries[pid] ?? [])
    }

    public func readCache(bundleID: String) -> [CapturedWindow] {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return entries.values.flatMap { $0 }.filter { $0.ownerBundleID == bundleID }
    }

    public func readAllCache() -> [CapturedWindow] {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return entries.values.flatMap { $0 }.sorted { $0.lastInteractionTime > $1.lastInteractionTime }
    }

    public func readCache(windowID: CGWindowID) -> CapturedWindow? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        for windowSet in entries.values {
            if let window = windowSet.first(where: { $0.id == windowID }) {
                return window
            }
        }
        return nil
    }

    public func fetch(forPID pid: pid_t) async -> Set<CapturedWindow> {
        Set(readCache(forPID: pid))
    }

    public func fetch(windowID: CGWindowID) async -> CapturedWindow? {
        readCache(windowID: windowID)
    }

    public func fetchAll() async -> [CapturedWindow] {
        readAllCache()
    }

    public func fetch(bundleID: String) async -> [CapturedWindow] {
        readCache(bundleID: bundleID)
    }

    @discardableResult
    public func store(forPID pid: pid_t, windows: Set<CapturedWindow>) -> ChangeReport {
        cacheLock.lock()
        defer { cacheLock.unlock() }

        let oldWindows = entries[pid] ?? []
        var merged = oldWindows

        for window in windows {
            var windowToInsert = window

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
        cacheLock.lock()
        defer { cacheLock.unlock() }

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

    public func updateCache(forPID pid: pid_t, update: (inout Set<CapturedWindow>) -> Void) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        var currentWindowSet = entries[pid] ?? []
        update(&currentWindowSet)
        entries[pid] = currentWindowSet
    }

    public func removeEntry(pid: pid_t, windowID: CGWindowID) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        removeEntryInternal(pid: pid, windowID: windowID)
    }

    public func removeAll(forPID pid: pid_t) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        entries.removeValue(forKey: pid)
    }

    public func clear() {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        entries.removeAll()
    }

    @discardableResult
    public func purify(forPID pid: pid_t, validator: (AXUIElement) -> Bool) -> Set<CapturedWindow> {
        cacheLock.lock()
        let windows = entries[pid] ?? []
        cacheLock.unlock()

        if windows.isEmpty {
            return []
        }

        Logger.debug("Purify checking", details: "pid=\(pid), cached=\(windows.count)")

        var validWindows = Set<CapturedWindow>()
        var invalidIDs = [CGWindowID]()

        for window in windows {
            if validator(window.axElement) {
                validWindows.insert(window)
            } else {
                invalidIDs.append(window.id)
            }
        }

        if !invalidIDs.isEmpty {
            cacheLock.lock()
            defer { cacheLock.unlock() }
            Logger.debug("Purging invalid windows", details: "pid=\(pid), count=\(invalidIDs.count), ids=\(invalidIDs)")
            for windowID in invalidIDs {
                removeEntryInternal(pid: pid, windowID: windowID)
            }
        }

        return validWindows
    }

    public func storePreview(_ image: CGImage, forWindowID windowID: CGWindowID) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        let now = Date()
        for (pid, var windowSet) in entries {
            if let window = windowSet.first(where: { $0.id == windowID }) {
                var updatedWindow = window
                updatedWindow.cachedPreview = image
                updatedWindow.previewTimestamp = now
                windowSet.remove(window)
                windowSet.insert(updatedWindow)
                entries[pid] = windowSet
                return
            }
        }
    }

    public func fetchPreview(forWindowID windowID: CGWindowID) -> CGImage? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        for windowSet in entries.values {
            if let window = windowSet.first(where: { $0.id == windowID }) {
                return window.cachedPreview
            }
        }
        return nil
    }

    public func purgeExpiredPreviews() {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        let now = Date()
        for (pid, windowSet) in entries {
            var modified = false
            var updatedSet = windowSet
            for window in windowSet {
                if let timestamp = window.previewTimestamp,
                   now.timeIntervalSince(timestamp) > previewCacheDuration {
                    var updatedWindow = window
                    updatedWindow.cachedPreview = nil
                    updatedWindow.previewTimestamp = nil
                    updatedSet.remove(window)
                    updatedSet.insert(updatedWindow)
                    modified = true
                }
            }
            if modified {
                entries[pid] = updatedSet
            }
        }
    }

    public func windowIDsWithFreshPreviews() -> Set<CGWindowID> {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        let now = Date()
        let cacheDuration = previewCacheDuration
        var freshIDs = Set<CGWindowID>()
        for windowSet in entries.values {
            for window in windowSet {
                if window.cachedPreview != nil,
                   let timestamp = window.previewTimestamp,
                   now.timeIntervalSince(timestamp) <= cacheDuration {
                    freshIDs.insert(window.id)
                }
            }
        }
        return freshIDs
    }

    public func windowIDsWithFreshPreviews(forPID pid: pid_t) -> Set<CGWindowID> {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        let now = Date()
        let cacheDuration = previewCacheDuration
        guard let windows = entries[pid] else { return [] }
        return Set(windows.compactMap { window -> CGWindowID? in
            guard window.cachedPreview != nil,
                  let timestamp = window.previewTimestamp,
                  now.timeIntervalSince(timestamp) <= cacheDuration
            else { return nil }
            return window.id
        })
    }

    private func removeEntryInternal(pid: pid_t, windowID: CGWindowID) {
        entries[pid]?.remove(where: { $0.id == windowID })
        if entries[pid]?.isEmpty == true {
            entries.removeValue(forKey: pid)
        }
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
