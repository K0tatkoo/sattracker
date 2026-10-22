import SwiftUI

/// Orbit for iPhone: the Android app's globe, drawn natively (Metal) under
/// Liquid Glass chrome, with the same orbits to the last digit (OrbitCore is
/// satellite.js, ported and checked against it).
@main
struct OrbitApp: App {
    @State private var model = AppModel.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
        }
        // Newer elements and the next two days of pass alerts, when iOS
        // grants the app a moment in the background.
        .backgroundTask(.appRefresh(PassAlerts.refreshTaskId)) {
            await Self.refreshInBackground()
        }
    }

    @MainActor
    private static func refreshInBackground() async {
        await AppModel.shared.alerts.backgroundRefresh()
    }
}

extension AppModel {
    /// The one model: the background task and notifications reach it too.
    static let shared = AppModel()
}
