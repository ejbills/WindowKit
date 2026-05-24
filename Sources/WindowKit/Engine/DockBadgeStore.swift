import ApplicationServices
import Cocoa

public final class DockBadgeStore: @unchecked Sendable {
    private var badges: [pid_t: String] = [:]
    private let lock = NSLock()

    /// Cached dock AXUIElement references keyed by stable app identity for fast polling.
    private var cachedDockElements: [DockAppKey: CachedDockElement] = [:]
    private var lastRebuildTime: CFAbsoluteTime = 0

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

    @discardableResult
    public func removeAllBadges() -> Set<pid_t> {
        lock.lock()
        defer { lock.unlock() }
        let removed = Set(badges.keys)
        badges.removeAll()
        return removed
    }

    /// Refresh badge for a single PID. Returns true if the badge value changed.
    @discardableResult
    public func refresh(forPID pid: pid_t) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
        let appKeys = DockAppKey.keys(for: app)
        guard !appKeys.isEmpty else { return false }

        // Try fast path: use cached dock element
        if let cachedElement = getCachedElement(for: appKeys) {
            let statusLabel = try? cachedElement.attribute("AXStatusLabel", as: String.self)
            return updateBadge(forPID: pid, statusLabel: statusLabel)
        }

        // Slow path: traverse dock hierarchy and rebuild cache
        rebuildCache()

        if let cachedElement = getCachedElement(for: appKeys) {
            let statusLabel = try? cachedElement.attribute("AXStatusLabel", as: String.self)
            return updateBadge(forPID: pid, statusLabel: statusLabel)
        }

        return updateBadge(forPID: pid, statusLabel: nil)
    }

    /// Refresh all badges in a single dock traversal. Returns the set of PIDs whose badge changed.
    public func refreshAll(pids: [pid_t]) -> Set<pid_t> {
        // Build app identity lookup. Bundle/path keys avoid localized-title collisions.
        var appKeysByPID: [pid_t: [DockAppKey]] = [:]
        for pid in pids {
            guard let app = NSRunningApplication(processIdentifier: pid) else { continue }
            let keys = DockAppKey.keys(for: app)
            if !keys.isEmpty {
                appKeysByPID[pid] = keys
            }
        }

        guard !appKeysByPID.isEmpty else { return [] }

        // Ensure cache is populated
        lock.lock()
        let cacheEmpty = cachedDockElements.isEmpty
        lock.unlock()
        if cacheEmpty {
            rebuildCache()
        }

        // Single pass: read AXStatusLabel from cached elements
        var changed = Set<pid_t>()
        var found = Set<pid_t>()

        lock.lock()
        let cache = cachedDockElements
        lock.unlock()

        guard !cache.isEmpty else { return [] }

        for (pid, appKeys) in appKeysByPID {
            if let element = DockAppKey.element(for: appKeys, in: cache) {
                let statusLabel = try? element.attribute("AXStatusLabel", as: String.self)
                if updateBadge(forPID: pid, statusLabel: statusLabel) {
                    changed.insert(pid)
                }
                found.insert(pid)
            }
        }

        // Clear badges for apps not found in dock
        for pid in appKeysByPID.keys where !found.contains(pid) {
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
        lastRebuildTime = 0
        lock.unlock()
    }

    // MARK: - Private

    private func getCachedElement(for appKeys: [DockAppKey]) -> AXUIElement? {
        lock.lock()
        defer { lock.unlock() }
        return DockAppKey.element(for: appKeys, in: cachedDockElements)
    }

    private func rebuildCache() {
        lock.lock()
        let now = CFAbsoluteTimeGetCurrent()
        if now - lastRebuildTime < 2.0 {
            lock.unlock()
            return
        }
        lock.unlock()

        guard let dockPID = NSWorkspace.shared.runningApplications
            .first(where: { $0.bundleIdentifier == "com.apple.dock" })?
            .processIdentifier else { return }

        let dockApp = AXUIElement.application(pid: dockPID)
        guard let children = try? dockApp.children(),
              let list = children.first(where: { (try? $0.role()) == kAXListRole as String }),
              let dockItems = try? list.children() else { return }

        lock.lock()
        lastRebuildTime = CFAbsoluteTimeGetCurrent()
        cachedDockElements.removeAll()
        for item in dockItems {
            guard let subrole = try? item.subrole(),
                  subrole == "AXApplicationDockItem" else { continue }
            for key in DockAppKey.keys(forDockItem: item) {
                cachedDockElements[key, default: .element(item)].merge(item)
            }
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

enum CachedDockElement {
    case element(AXUIElement)
    case ambiguous

    var element: AXUIElement? {
        switch self {
        case .element(let element):
            return element
        case .ambiguous:
            return nil
        }
    }

    mutating func merge(_ newElement: AXUIElement) {
        switch self {
        case .element(let existingElement) where CFEqual(existingElement, newElement):
            break
        case .element:
            self = .ambiguous
        case .ambiguous:
            break
        }
    }
}

struct DockAppKey: Hashable {
    private enum Kind: Hashable {
        case bundleIdentifier
        case bundlePath
        case localizedName
    }

    private let kind: Kind
    private let value: String

    static func keys(for app: NSRunningApplication) -> [DockAppKey] {
        var keys: [DockAppKey] = []
        if let bundleIdentifier = normalized(app.bundleIdentifier) {
            keys.append(DockAppKey(kind: .bundleIdentifier, value: bundleIdentifier))
        }
        if let bundleURL = app.bundleURL,
           let bundlePath = normalizedPath(bundleURL) {
            keys.append(DockAppKey(kind: .bundlePath, value: bundlePath))
        }
        if let localizedName = normalized(app.localizedName) {
            keys.append(DockAppKey(kind: .localizedName, value: localizedName))
        }
        return keys
    }

    static func keys(forDockItem item: AXUIElement) -> [DockAppKey] {
        var keys: [DockAppKey] = []
        if let url = dockItemURL(item) {
            if let bundleIdentifier = Bundle(url: url)?.bundleIdentifier,
               let normalizedBundleIdentifier = normalized(bundleIdentifier) {
                keys.append(DockAppKey(kind: .bundleIdentifier, value: normalizedBundleIdentifier))
            }
            if let bundlePath = normalizedPath(url) {
                keys.append(DockAppKey(kind: .bundlePath, value: bundlePath))
            }
        }
        if let title = try? item.title(),
           let normalizedTitle = normalized(title) {
            keys.append(DockAppKey(kind: .localizedName, value: normalizedTitle))
        }
        return keys
    }

    static func element(for keys: [DockAppKey], in cache: [DockAppKey: CachedDockElement]) -> AXUIElement? {
        for key in keys {
            if let element = cache[key]?.element {
                return element
            }
        }
        return nil
    }

    static func parsedBadgeCount(from label: String) -> Int? {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        if let exact = Int(trimmed) { return exact }
        if let formatted = formattedInteger(from: trimmed) { return formatted }

        let words = trimmed.components(separatedBy: .whitespacesAndNewlines)
        for word in words {
            if let formatted = formattedInteger(from: word) {
                return formatted
            }
        }

        return nil
    }

    private static func formattedInteger(from value: String) -> Int? {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = .current
        formatter.generatesDecimalNumbers = false
        formatter.isLenient = false

        guard let number = formatter.number(from: value) else { return nil }
        return number.intValue
    }

    private static func dockItemURL(_ item: AXUIElement) -> URL? {
        guard let nsURL = try? item.attribute(kAXURLAttribute, as: NSURL.self) else { return nil }
        return nsURL as URL
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func normalizedPath(_ url: URL) -> String? {
        let path = url.standardizedFileURL.path
        return normalized(path)
    }
}
