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
                        OrbitMark(lineWidth: 1.5)
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

                Section {
                    Link("Orbit for Android, and the other apps", destination: URL(string: "https://n3d-store.com/apps")!)
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
