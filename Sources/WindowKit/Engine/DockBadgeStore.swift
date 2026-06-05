import ApplicationServices
import Cocoa

public final class DockBadgeStore: @unchecked Sendable {
    private var badges: [pid_t: String] = [:]
    private var identityBadges: [DockAppKey: String] = [:]
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

    public func badge(forBundleIdentifier bundleIdentifier: String) -> String? {
        let key = DockAppKey.bundleIdentifier(bundleIdentifier)
        lock.lock()
        defer { lock.unlock() }
        return key.flatMap { identityBadges[$0] }
    }

    public func badge(forBundleURL bundleURL: URL) -> String? {
        let key = DockAppKey.bundlePath(bundleURL)
        lock.lock()
        defer { lock.unlock() }
        return key.flatMap { identityBadges[$0] }
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
        identityBadges.removeAll()
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
            let badgeLabel = resolvedBadgeLabel(for: cachedElement)
            return updateBadge(forPID: pid, badgeLabel: badgeLabel)
        }

        // Slow path: traverse dock hierarchy and rebuild cache
        rebuildCache()

        if let cachedElement = getCachedElement(for: appKeys) {
            let badgeLabel = resolvedBadgeLabel(for: cachedElement)
            return updateBadge(forPID: pid, badgeLabel: badgeLabel)
        }

        return updateBadge(forPID: pid, badgeLabel: nil)
    }

    /// Refresh badge for an app identity even when the app process is not running.
    /// Returns true if the badge value changed.
    @discardableResult
    public func refresh(bundleIdentifier: String) -> Bool {
        guard let appKey = DockAppKey.bundleIdentifier(bundleIdentifier) else { return false }

        if let cachedElements = getCachedElements(for: [appKey]) {
            return updateBadge(
                forKeys: [appKey],
                resolution: resolvedBadgeLabel(for: cachedElements)
            )
        }

        rebuildCache()

        if let cachedElements = getCachedElements(for: [appKey]) {
            return updateBadge(
                forKeys: [appKey],
                resolution: resolvedBadgeLabel(for: cachedElements)
            )
        }

        return updateBadge(forKeys: [appKey], badgeLabel: nil)
    }

    /// Refresh badge for a specific bundle path even when the app process is not running.
    /// Returns true if the badge value changed.
    @discardableResult
    public func refresh(bundleURL: URL) -> Bool {
        guard let appKey = DockAppKey.bundlePath(bundleURL) else { return false }

        if let cachedElements = getCachedElements(for: [appKey]) {
            return updateBadge(
                forKeys: [appKey],
                resolution: resolvedBadgeLabel(for: cachedElements)
            )
        }

        rebuildCache()

        if let cachedElements = getCachedElements(for: [appKey]) {
            return updateBadge(
                forKeys: [appKey],
                resolution: resolvedBadgeLabel(for: cachedElements)
            )
        }

        return updateBadge(forKeys: [appKey], badgeLabel: nil)
    }

    /// Refresh all badges in a single dock traversal. Returns the set of PIDs whose badge changed.
    public func refreshAll(pids: [pid_t]) -> Set<pid_t> {
        refreshAll(pids: pids, bundleIdentifiers: []).pids
    }

    public func refreshAll(
        pids: [pid_t],
        bundleIdentifiers: [String],
        bundleURLs: [URL] = []
    ) -> DockBadgeRefreshChanges {
        // Build app identity lookup. Bundle/path keys avoid localized-title collisions.
        var appKeysByPID: [pid_t: [DockAppKey]] = [:]
        for pid in pids {
            guard let app = NSRunningApplication(processIdentifier: pid) else { continue }
            let keys = DockAppKey.keys(for: app)
            if !keys.isEmpty {
                appKeysByPID[pid] = keys
            }
        }

        var keysByBundleIdentifier: [String: [DockAppKey]] = [:]
        for bundleIdentifier in bundleIdentifiers {
            guard let key = DockAppKey.bundleIdentifier(bundleIdentifier) else { continue }
            keysByBundleIdentifier[bundleIdentifier] = [key]
        }

        var keysByBundlePath: [String: [DockAppKey]] = [:]
        for bundleURL in bundleURLs {
            guard let key = DockAppKey.bundlePath(bundleURL),
                  let bundlePath = key.bundlePath else { continue }
            keysByBundlePath[bundlePath] = [key]
        }

        guard !appKeysByPID.isEmpty || !keysByBundleIdentifier.isEmpty || !keysByBundlePath.isEmpty else {
            return DockBadgeRefreshChanges()
        }

        // Ensure cache is populated
        lock.lock()
        let cacheEmpty = cachedDockElements.isEmpty
        lock.unlock()
        if cacheEmpty {
            rebuildCache()
        }

        // Single pass: read AXStatusLabel from cached elements
        var changedPIDs = Set<pid_t>()
        var changedBundleIdentifiers = Set<String>()
        var changedBundlePaths = Set<String>()
        var found = Set<pid_t>()
        var foundBundleIdentifiers = Set<String>()
        var foundBundlePaths = Set<String>()

        lock.lock()
        let cache = cachedDockElements
        lock.unlock()

        guard !cache.isEmpty else { return DockBadgeRefreshChanges() }

        for (pid, appKeys) in appKeysByPID {
            if let element = DockAppKey.element(for: appKeys, in: cache) {
                let badgeLabel = resolvedBadgeLabel(for: element)
                if updateBadge(forPID: pid, badgeLabel: badgeLabel) {
                    changedPIDs.insert(pid)
                }
                if updateBadge(forKeys: appKeys, badgeLabel: badgeLabel) {
                    changedBundleIdentifiers.formUnion(DockAppKey.bundleIdentifiers(in: appKeys))
                }
                found.insert(pid)
            }
        }

        // Clear badges for apps not found in dock
        for pid in appKeysByPID.keys where !found.contains(pid) {
            if updateBadge(forPID: pid, badgeLabel: nil) {
                changedPIDs.insert(pid)
            }
            let appKeys = appKeysByPID[pid] ?? []
            if updateBadge(forKeys: appKeys, badgeLabel: nil) {
                changedBundleIdentifiers.formUnion(DockAppKey.bundleIdentifiers(in: appKeys))
            }
        }

        for (bundleIdentifier, appKeys) in keysByBundleIdentifier {
            if let elements = DockAppKey.elements(for: appKeys, in: cache) {
                if updateBadge(
                    forKeys: appKeys,
                    resolution: resolvedBadgeLabel(for: elements)
                ) {
                    changedBundleIdentifiers.insert(bundleIdentifier)
                }
                foundBundleIdentifiers.insert(bundleIdentifier)
            }
        }

        for (bundleIdentifier, appKeys) in keysByBundleIdentifier where !foundBundleIdentifiers.contains(bundleIdentifier) {
            if updateBadge(forKeys: appKeys, badgeLabel: nil) {
                changedBundleIdentifiers.insert(bundleIdentifier)
            }
        }

        for (bundlePath, appKeys) in keysByBundlePath {
            if let elements = DockAppKey.elements(for: appKeys, in: cache) {
                if updateBadge(
                    forKeys: appKeys,
                    resolution: resolvedBadgeLabel(for: elements)
                ) {
                    changedBundlePaths.insert(bundlePath)
                }
                foundBundlePaths.insert(bundlePath)
            }
        }

        for (bundlePath, appKeys) in keysByBundlePath where !foundBundlePaths.contains(bundlePath) {
            if updateBadge(forKeys: appKeys, badgeLabel: nil) {
                changedBundlePaths.insert(bundlePath)
            }
        }

        return DockBadgeRefreshChanges(
            pids: changedPIDs,
            bundleIdentifiers: changedBundleIdentifiers,
            bundlePaths: changedBundlePaths
        )
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

    private func getCachedElements(for appKeys: [DockAppKey]) -> [AXUIElement]? {
        lock.lock()
        defer { lock.unlock() }
        return DockAppKey.elements(for: appKeys, in: cachedDockElements)
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
                cachedDockElements[key, default: .elements([])].merge(item)
            }
        }
        lock.unlock()
    }

    /// Updates the stored badge and returns true if the value changed.
    private func updateBadge(forPID pid: pid_t, badgeLabel: String?) -> Bool {
        lock.lock()
        let oldValue = badges[pid]
        if let badgeLabel {
            badges[pid] = badgeLabel
        } else {
            badges.removeValue(forKey: pid)
        }
        lock.unlock()
        return oldValue != badgeLabel
    }

    private func updateBadge(forKeys keys: [DockAppKey], badgeLabel: String?) -> Bool {
        lock.lock()
        var changed = false
        for key in keys {
            let oldValue = identityBadges[key]
            if let badgeLabel {
                identityBadges[key] = badgeLabel
            } else {
                identityBadges.removeValue(forKey: key)
            }
            changed = changed || oldValue != badgeLabel
        }
        lock.unlock()
        return changed
    }

    private func updateBadge(forKeys keys: [DockAppKey], resolution: BadgeLabelResolution) -> Bool {
        switch resolution {
        case .value(let badgeLabel):
            return updateBadge(forKeys: keys, badgeLabel: badgeLabel)
        case .ambiguous:
            return updateBadge(forKeys: keys, badgeLabel: nil)
        }
    }

    private func resolvedBadgeLabel(for element: AXUIElement) -> String? {
        (try? element.attribute("AXStatusLabel", as: String.self))
            .flatMap(DockAppKey.normalizedBadgeLabel(fromStatusLabel:))
    }

    private func resolvedBadgeLabel(for elements: [AXUIElement]) -> BadgeLabelResolution {
        var resolvedLabel: String?
        var hasResolvedLabel = false

        for element in elements {
            let statusLabel = (try? element.attribute("AXStatusLabel", as: String.self))
                .flatMap(DockAppKey.normalizedBadgeLabel(fromStatusLabel:))
            if !hasResolvedLabel {
                resolvedLabel = statusLabel
                hasResolvedLabel = true
            } else if resolvedLabel != statusLabel {
                return .ambiguous
            }
        }

        return .value(resolvedLabel)
    }
}

public struct DockBadgeRefreshChanges: Sendable {
    public let pids: Set<pid_t>
    public let bundleIdentifiers: Set<String>
    public let bundlePaths: Set<String>

    public var isEmpty: Bool {
        pids.isEmpty && bundleIdentifiers.isEmpty && bundlePaths.isEmpty
    }

    public init(
        pids: Set<pid_t> = [],
        bundleIdentifiers: Set<String> = [],
        bundlePaths: Set<String> = []
    ) {
        self.pids = pids
        self.bundleIdentifiers = bundleIdentifiers
        self.bundlePaths = bundlePaths
    }
}

private enum BadgeLabelResolution {
    case value(String?)
    case ambiguous
}

enum CachedDockElement {
    case elements([AXUIElement])

    var element: AXUIElement? {
        switch self {
        case .elements(let elements):
            return elements.count == 1 ? elements[0] : nil
        }
    }

    var elements: [AXUIElement] {
        switch self {
        case .elements(let elements):
            return elements
        }
    }

    mutating func merge(_ newElement: AXUIElement) {
        switch self {
        case .elements(var elements):
            guard !elements.contains(where: { CFEqual($0, newElement) }) else { return }
            elements.append(newElement)
            self = .elements(elements)
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

    static func bundleIdentifier(_ bundleIdentifier: String) -> DockAppKey? {
        normalized(bundleIdentifier).map { DockAppKey(kind: .bundleIdentifier, value: $0) }
    }

    static func bundlePath(_ bundleURL: URL) -> DockAppKey? {
        normalizedPath(bundleURL).map { DockAppKey(kind: .bundlePath, value: $0) }
    }

    var bundlePath: String? {
        kind == .bundlePath ? value : nil
    }

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

    static func elements(for keys: [DockAppKey], in cache: [DockAppKey: CachedDockElement]) -> [AXUIElement]? {
        for key in keys {
            if let elements = cache[key]?.elements, !elements.isEmpty {
                return elements
            }
        }
        return nil
    }

    static func bundleIdentifiers(in keys: [DockAppKey]) -> Set<String> {
        Set(keys.compactMap { key in
            key.kind == .bundleIdentifier ? key.value : nil
        })
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

    static func normalizedBadgeLabel(fromStatusLabel label: String) -> String? {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "" }
        if isDotOnlyStatusLabel(trimmed) { return "" }
        if parsedBadgeCount(from: trimmed) == nil && isGenericNotificationStatusLabel(trimmed) {
            return ""
        }
        return trimmed
    }

    private static func isDotOnlyStatusLabel(_ label: String) -> Bool {
        let dotLabels: Set<String> = [".", "•", "●", "·", "∙"]
        return dotLabels.contains(label)
    }

    private static func isGenericNotificationStatusLabel(_ label: String) -> Bool {
        let normalized = label
            .trimmingCharacters(in: .punctuationCharacters.union(.whitespacesAndNewlines))
            .lowercased()
        return normalized == "has notifications" ||
            normalized == "notification" ||
            normalized == "notifications" ||
            normalized == "unread"
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
