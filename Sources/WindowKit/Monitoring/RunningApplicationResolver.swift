import AppKit

final class InPlaceReexecApplication: NSRunningApplication, @unchecked Sendable {
    let base: NSRunningApplication
    private let pid: pid_t

    init(base: NSRunningApplication, pid: pid_t) {
        self.base = base
        self.pid = pid
        super.init()
    }

    override var processIdentifier: pid_t { pid }
    override var bundleIdentifier: String? { base.bundleIdentifier }
    override var bundleURL: URL? { base.bundleURL }
    override var executableURL: URL? { base.executableURL }
    override var localizedName: String? { base.localizedName }
    override var icon: NSImage? { base.icon }
    override var launchDate: Date? { base.launchDate }
    override var activationPolicy: NSApplication.ActivationPolicy { base.activationPolicy }
    override var executableArchitecture: Int { base.executableArchitecture }
    override var isActive: Bool { base.isActive }
    override var isHidden: Bool { base.isHidden }
    override var isTerminated: Bool { base.isTerminated }
    override var isFinishedLaunching: Bool { base.isFinishedLaunching }
    override var ownsMenuBar: Bool { base.ownsMenuBar }
    override var hash: Int { Int(pid) }

    override func isEqual(_ object: Any?) -> Bool {
        (object as? NSRunningApplication)?.processIdentifier == pid
    }

    override func hide() -> Bool { base.hide() }
    override func unhide() -> Bool { base.unhide() }
    override func activate(options: NSApplication.ActivationOptions) -> Bool { base.activate(options: options) }

    override func activate(from application: NSRunningApplication, options: NSApplication.ActivationOptions) -> Bool {
        base.activate(from: application, options: options)
    }

    override func terminate() -> Bool { base.terminate() }
    override func forceTerminate() -> Bool { base.forceTerminate() }
}

public enum RunningApplicationResolver {
    public static func application(forProcessIdentifier pid: pid_t) -> NSRunningApplication? {
        NSRunningApplication(processIdentifier: pid).map { pinning($0, to: pid) }
    }

    public static func resolving(_ app: NSRunningApplication) -> NSRunningApplication {
        guard app.processIdentifier == -1, let pid = inPlaceReexecProcessIdentifier(of: app) else { return app }
        return InPlaceReexecApplication(base: app, pid: pid)
    }

    public static func resolving(_ apps: [NSRunningApplication]) -> [NSRunningApplication] {
        guard apps.contains(where: { $0.processIdentifier == -1 }) else { return apps }
        return apps.map { resolving($0) }
    }

    static func pinning(_ app: NSRunningApplication, to pid: pid_t) -> NSRunningApplication {
        pid > 0 && app.processIdentifier == -1 ? InPlaceReexecApplication(base: app, pid: pid) : app
    }

    static func observationTarget(_ app: NSRunningApplication) -> NSRunningApplication {
        (app as? InPlaceReexecApplication)?.base ?? app
    }

    private static func inPlaceReexecProcessIdentifier(of app: NSRunningApplication) -> pid_t? {
        guard !app.isTerminated,
              let executablePath = app.executableURL?.resolvingSymlinksInPath().path
        else { return nil }

        var pids = [pid_t](repeating: 0, count: Int(proc_listallpids(nil, 0)) + 64)
        let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)

        return pids.prefix(max(count, 0)).first { pid in
            pid > 0 &&
                proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count)) > 0 &&
                URL(fileURLWithPath: String(cString: pathBuffer)).resolvingSymlinksInPath().path == executablePath &&
                NSRunningApplication(processIdentifier: pid)?.isEqual(app) == true
        }
    }
}
