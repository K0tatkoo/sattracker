import OrbitCore
import SwiftUI

/// The satellites you are told about before they pass over, and how.
struct AlertsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL

    var body: some View {
        @Bindable var alerts = model.alerts
        NavigationStack {
            Form {
                permission
                Section {
                    if alerts.watched.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Tap a satellite, then **Alert me**, to be told before it passes over you.")
                                .foregroundStyle(.secondary)
                            Button("Watch the ISS", systemImage: "bell") { watchIss() }
                                .buttonStyle(.glassProminent)
                        }
                        .padding(.vertical, 4)
                    } else {
                        ForEach(alerts.watched) { w in
                            WatchedRow(watched: w, next: alerts.planned.first { $0.norad == w.id })
                        }
                        .onDelete { offsets in alerts.remove(offsets.map { alerts.watched[$0].id }) }
                    }
                } header: {
                    Text("Watching")
                }

                Section {
                    Picker("How early", selection: $alerts.leadMinutes) {
                        ForEach(PassAlerts.leadChoices, id: \.self) { Text("\($0) min before").tag($0) }
                    }
                    Picker("Only passes higher than", selection: $alerts.minPeakDeg) {
                        ForEach(PassAlerts.peakChoices, id: \.self) { Text("\($0)°").tag($0) }
                    }
                    Toggle("Only when I can see it", isOn: $alerts.visibleOnly)
                } header: {
                    Text("Alert me")
                } footer: {
                    Text("A satellite can be seen when it is in sunlight while your sky is dark: the ISS then looks like a bright, steady star sliding across the sky. Low passes hide behind buildings and haze.")
                }

                Section {
                } footer: {
                    Text("Orbit plans the next two days of alerts whenever you open it, and again in the background when iOS allows. Your location stays on this iPhone.")
                }
            }
            .navigationTitle("Pass alerts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { model.sheet = nil }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .task { await model.alerts.refreshAuthorization() }
    }

    @ViewBuilder private var permission: some View {
        let alerts = model.alerts
        if alerts.authorization == .denied {
            Section {
                Label("Notifications are off for Orbit.", systemImage: "bell.slash")
                Button("Open Settings") { openURL(URL(string: UIApplication.openNotificationSettingsURLString)!) }
            }
        } else if alerts.authorization == .notDetermined && !alerts.watched.isEmpty {
            Section {
                Button("Allow notifications", systemImage: "bell.badge") {
                    Task { await alerts.requestAuthorization(); await alerts.reschedule() }
                }
            }
        }
        if model.observer == nil {
            Section {
                Label(model.locationAccess == .denied
                      ? "Location is off, so Orbit cannot work out passes over you."
                      : "Waiting for your location…",
                      systemImage: "location.slash")
                if model.locationAccess == .denied {
                    Button("Open Settings") { openURL(URL(string: UIApplication.openSettingsURLString)!) }
                }
            }
        }
    }

    private func watchIss() {
        let iss = model.store.sat(norad: Catalog.issNorad)?.entry ?? SharedStore.iss?.entry
        if let iss {
            Task { await model.alerts.toggle(iss, categoryId: "stations") }
        } else {
            Task {
                if let e = await model.tle.satellite(norad: Catalog.issNorad) { await model.alerts.toggle(e, categoryId: "stations") }
            }
        }
    }
}

private struct WatchedRow: View {
    let watched: PassAlerts.Watched
    let next: PassAlerts.Planned?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(watched.entry.name).font(.body.weight(.semibold))
            if let next {
                Text("Next alert \(next.fire, format: .dateTime.weekday(.abbreviated).hour().minute()) · rises \(next.pass.rise.time, format: .dateTime.hour().minute()), \(Int(next.pass.peak.elevationDeg.rounded()))° high")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("No pass that fits in the next two days")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
