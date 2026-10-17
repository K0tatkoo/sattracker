import SwiftUI

/// Orbit's whole interface is the web page the Android app shows
/// (`app/src/main/assets`, shared, not copied). This target is only the shell
/// around it: the WebView, and the few things a page cannot do for itself —
/// fetching orbits, knowing where you are, opening links, following the
/// phone's dark mode.
@main
struct OrbitApp: App {
    var body: some Scene {
        WindowGroup {
            GlobeView().ignoresSafeArea()
        }
    }
}

private struct GlobeView: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> GlobeViewController { GlobeViewController() }
    func updateUIViewController(_ controller: GlobeViewController, context: Context) {}
}
