import Foundation
import ServiceManagement
import MacConnectCore

/// Wraps `SMAppService.mainApp` so the rest of the app sees a small,
/// throwing surface instead of the raw service status enum.
///
/// SMAppService requires the running .app bundle to be in a registered
/// location (typically /Applications). Ad-hoc dev builds launched out of
/// `build/` will fail with `Operation not permitted`; the caller must
/// surface that to the user rather than crashing.
@MainActor
public enum LoginItem {
    public static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    public static func setEnabled(_ enabled: Bool) throws {
        let service = SMAppService.mainApp
        if enabled {
            try service.register()
            Log.app.info("Registered MacConnect as a login item")
        } else {
            try service.unregister()
            Log.app.info("Unregistered MacConnect login item")
        }
    }
}
