import SwiftUI

/// What Orbit is, where its numbers come from, and whether it may use your
/// location.
struct AboutSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(spacing: 10) {
                        OrbitMark()
                            .frame(width: 64, height: 64)
                            .foregroundStyle(.tint)
                        Text("Orbit").font(.title.bold())
                        Text("Version \(version)").font(.subheadline).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .listRowBackground(Color.clear)
                }

                Section {
                    Text("Real satellites in real time, propagated on your iPhone from Celestrak orbital elements. Free, no ads, no accounts, and your location never leaves the device.")
                }

                Section("Where it comes from") {
                    Link(destination: URL(string: "https://celestrak.org")!) {
                        LabeledContent("Orbits", value: "Celestrak")
                    }
                    LabeledContent("Propagation", value: "SGP4, as in satellite.js")
                    LabeledContent("Drawing", value: "Metal")
                }

                Section("Location") {
                    LabeledContent("Your location", value: locationText)
                    if model.locationAccess == .denied {
                        Button("Open Settings") { openURL(URL(string: UIApplication.openSettingsURLString)!) }
                    }
                }

                // The privacy policy must be reachable from inside the app (App
                // Store rule 5.1.1). No "for Android" here: the App Store turns
                // away apps that name other mobile platforms (rule 2.3.10).
                Section {
                    Link("Privacy policy", destination: URL(string: "https://n3d-store.com/orbit-privacy")!)
                    Link("Support", destination: URL(string: "https://n3d-store.com/app-support#orbit")!)
                }
            }
            .navigationTitle("About")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { model.sheet = nil }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    private var locationText: String {
        switch model.locationAccess {
        case .allowed: model.observer == nil ? "Allowed, no fix yet" : "In use while Orbit is open"
        case .denied: "Off"
        case .unknown: model.observer == nil ? "Not asked yet" : "Last known"
        }
    }
}
