import Foundation

/// An app's active downloads into the user's Downloads folder.
public struct AppDownloadProgress: Equatable, Sendable {
    /// Overall completion across the app's downloads, quantized to 1%; nil while any total is unknown.
    public let fraction: Double?
    public let count: Int
}

/// Follows file progress published for downloads into ~/Downloads and credits each download
/// to the app that was frontmost when it began. Published progress carries no publisher
/// identity (filecoordinationd brokers it) and Firefox writes to a random `.part` file, so the
/// frontmost app is the attribution that needs no file access. Event driven; idle costs nothing.
@MainActor
final class DownloadProgressTracker {
    private final class Download {
        let bundleIdentifier: String
        let progress: Progress
        var observation: NSKeyValueObservation?

        init(bundleIdentifier: String, progress: Progress) {
            self.bundleIdentifier = bundleIdentifier
            self.progress = progress
        }
    }

    private static let publishInterval: TimeInterval = 0.25

    private let frontmostBundleIdentifier: () -> String?
    private let onChange: (Set<String>) -> Void
    private var subscriber: Any?
    private var downloads: [ObjectIdentifier: Download] = [:]
    private var published: [String: AppDownloadProgress] = [:]
    private var publishScheduled = false

    /// `frontmostBundleIdentifier` names the app a new download is credited to; `onChange`
    /// receives the bundle identifiers whose progress changed.
    init(frontmostBundleIdentifier: @escaping () -> String?, onChange: @escaping (Set<String>) -> Void) {
        self.frontmostBundleIdentifier = frontmostBundleIdentifier
        self.onChange = onChange
    }

    var isEnabled = false {
        didSet {
            guard oldValue != isEnabled else { return }
            isEnabled ? start() : stop()
        }
    }

    func progress(forBundleIdentifier bundleIdentifier: String) -> AppDownloadProgress? {
        published[bundleIdentifier]
    }

    private func start() {
        guard subscriber == nil,
              let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        else { return }
        subscriber = Progress.addSubscriber(forFileURL: folder) { [weak self] progress in
            let tracker = self
            let id = ObjectIdentifier(progress)
            Task { @MainActor in tracker?.begin(progress) }
            return { Task { @MainActor in tracker?.end(id) } }
        }
    }

    private func stop() {
        if let subscriber {
            Progress.removeSubscriber(subscriber)
        }
        subscriber = nil
        downloads.removeAll()
        publish()
    }

    private func begin(_ progress: Progress) {
        guard isEnabled, let bundleIdentifier = frontmostBundleIdentifier() else { return }
        let download = Download(bundleIdentifier: bundleIdentifier, progress: progress)
        download.observation = progress.observe(\.fractionCompleted) { [weak self] _, _ in
            let tracker = self
            Task { @MainActor in tracker?.schedulePublish() }
        }
        downloads[ObjectIdentifier(progress)] = download
        schedulePublish()
    }

    private func end(_ id: ObjectIdentifier) {
        guard downloads.removeValue(forKey: id) != nil else { return }
        publish()
    }

    private func schedulePublish() {
        guard !publishScheduled else { return }
        publishScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.publishInterval) { [weak self] in
            self?.publishScheduled = false
            self?.publish()
        }
    }

    /// Folds downloads into one entry per app, skipping file operations other than downloads.
    private func publish() {
        var totals: [String: (completed: Int64, total: Int64, count: Int, indeterminate: Bool)] = [:]
        for download in downloads.values {
            let progress = download.progress
            if let kind = progress.fileOperationKind, kind != .downloading { continue }
            var entry = totals[download.bundleIdentifier] ?? (0, 0, 0, false)
            entry.count += 1
            if progress.totalUnitCount > 0 {
                entry.completed += progress.completedUnitCount
                entry.total += progress.totalUnitCount
            } else {
                entry.indeterminate = true
            }
            totals[download.bundleIdentifier] = entry
        }
        var next: [String: AppDownloadProgress] = [:]
        for (bundleIdentifier, entry) in totals {
            next[bundleIdentifier] = AppDownloadProgress(
                fraction: entry.indeterminate || entry.total == 0 ? nil : (Double(entry.completed) / Double(entry.total) * 100).rounded() / 100,
                count: entry.count
            )
        }
        let changed = Set(next.keys).union(published.keys).filter { next[$0] != published[$0] }
        published = next
        if !changed.isEmpty {
            onChange(changed)
        }
    }
}
