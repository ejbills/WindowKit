import Cocoa

final class SkyLightSpaceOperator {
    static let shared = SkyLightSpaceOperator()

    private let connection: CGSConnectionID
    private var spaceID: CGSSpaceID?

    private init() {
        connection = CGSMainConnectionID()
    }

    private func ensureSpace() -> CGSSpaceID? {
        if let spaceID { return spaceID }

        guard let sid = slsCreateSpace(connection) else {
            Logger.error("SkyLightSpace: failed to create space")
            return nil
        }

        slsSetSpaceAbsoluteLevel(connection, sid, .notificationCenterAtScreenLock)
        slsShowSpaces(connection, [sid])
        spaceID = sid
        Logger.info("SkyLightSpace: created space \(sid) at level 400")
        return sid
    }

    func addWindow(_ windowID: CGWindowID) {
        guard let sid = ensureSpace() else { return }
        slsSpaceAddWindows(connection, sid, [windowID])
        Logger.debug("SkyLightSpace: moved window \(windowID) to space \(sid)")
    }
}
