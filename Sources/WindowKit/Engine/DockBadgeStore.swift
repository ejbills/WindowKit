import ApplicationServices
import Cocoa

public final class DockBadgeStore: @unchecked Sendable {
    private var badges: [pid_t: String] = [:]
    private let lock = NSLock()

    /// Cached dock AXUIElement references keyed by app name for fast polling.
    private var cachedDockElements: [String: AXUIElement] = [:]

    public init() {}

    public func badge(forPID pid: pid_t) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return badges[pid]
    }

    public func removeBadge(forPID pid: pid_t) {
        lock.lock()
        defer { lock.unlock() }
        badges.removeValue(forKey: pid)
    }

    /// Refresh badge for a single PID. Returns true if the badge value changed.
    @discardableResult
    public func refresh(forPID pid: pid_t) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid),
              let appName = app.localizedName else { return false }

        // Try fast path: use cached dock element
        if let cachedElement = getCachedElement(for: appName) {
            let statusLabel = try? cachedElement.attribute("AXStatusLabel", as: String.self)
            return updateBadge(forPID: pid, statusLabel: statusLabel)
        }

        // Slow path: traverse dock hierarchy and rebuild cache
        rebuildCache()

        if let cachedElement = getCachedElement(for: appName) {
            let statusLabel = try? cachedElement.attribute("AXStatusLabel", as: String.self)
            return updateBadge(forPID: pid, statusLabel: statusLabel)
        }

        return updateBadge(forPID: pid, statusLabel: nil)
    }

    /// Refresh all badges in a single dock traversal. Returns the set of PIDs whose badge changed.
    public func refreshAll(pids: [pid_t]) -> Set<pid_t> {
        // Build PID -> app name lookup
        var pidsByName: [String: pid_t] = [:]
        for pid in pids {
            guard let app = NSRunningApplication(processIdentifier: pid),
                  let name = app.localizedName else { continue }
            pidsByName[name] = pid
        }

        guard !pidsByName.isEmpty else { return [] }

        // Ensure cache is populated
        lock.lock()
        let cacheEmpty = cachedDockElements.isEmpty
        lock.unlock()
        if cacheEmpty {
            rebuildCache()
        }

        // Single pass: read AXStatusLabel from cached elements
        var changed = Set<pid_t>()
        var found = Set<String>()

        lock.lock()
        let cache = cachedDockElements
        lock.unlock()

        for (name, pid) in pidsByName {
            if let element = cache[name] {
                let statusLabel = try? element.attribute("AXStatusLabel", as: String.self)
                if updateBadge(forPID: pid, statusLabel: statusLabel) {
                    changed.insert(pid)
                }
                found.insert(name)
            }
        }

        // Clear badges for apps not found in dock
        for (name, pid) in pidsByName where !found.contains(name) {
            if updateBadge(forPID: pid, statusLabel: nil) {
                changed.insert(pid)
            }
        }

        return changed
    }

    /// Invalidates cached dock element references. Call when dock items may have changed
    /// (app launch, app termination).
    public func invalidateCache() {
        lock.lock()
        cachedDockElements.removeAll()
        lock.unlock()
    }

    // MARK: - Private

    private func getCachedElement(for appName: String) -> AXUIElement? {
        lock.lock()
        defer { lock.unlock() }
        return cachedDockElements[appName]
    }

    private func rebuildCache() {
        guard let dockPID = NSWorkspace.shared.runningApplications
            .first(where: { $0.bundleIdentifier == "com.apple.dock" })?
            .processIdentifier else { return }

        let dockApp = AXUIElement.application(pid: dockPID)
        guard let children = try? dockApp.children(),
              let list = children.first(where: { (try? $0.role()) == kAXListRole as String }),
              let dockItems = try? list.children() else { return }

        lock.lock()
        cachedDockElements.removeAll()
        for item in dockItems {
            guard let subrole = try? item.subrole(),
                  subrole == "AXApplicationDockItem",
                  let title = try? item.title() else { continue }
            cachedDockElements[title] = item
        }
        lock.unlock()
    }

    /// Updates the stored badge and returns true if the value changed.
    private func updateBadge(forPID pid: pid_t, statusLabel: String?) -> Bool {
        lock.lock()
        let oldValue = badges[pid]
        if let statusLabel {
            badges[pid] = statusLabel
        } else {
            badges.removeValue(forKey: pid)
        }
        lock.unlock()
        return oldValue != statusLabel
    }
}
