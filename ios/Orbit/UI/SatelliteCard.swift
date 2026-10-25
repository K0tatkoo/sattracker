import OrbitCore
import SwiftUI

/// The tapped satellite: a glass sheet that floats over the bottom of the
/// globe and leaves it usable (tap another dot and the card follows it).
/// Pulled up, it lists the passes of the next day. Where the width is regular
/// it is a floating panel instead (`floating`), with everything in it at once.
struct SatelliteCard: View {
    static let compact: CGFloat = 356

    var floating = false

    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme
    @State private var detent = PresentationDetent.height(Self.compact)
    @State private var nextPass: String?
    @State private var passes: [Pass]?

    var body: some View {
        Group {
            if let sat = model.selected {
                content(sat)
            } else {
                ContentUnavailableView("Not on the globe any more", systemImage: "circle.dashed",
                                       description: Text("Its category was switched off."))
            }
        }
        .presentationDetents([.height(Self.compact), .large], selection: $detent)
        .presentationBackgroundInteraction(.enabled(upThrough: .height(Self.compact)))
        .presentationDragIndicator(.visible)
        .task(id: PassKey(norad: model.selectedNorad, observer: model.observer)) { await computePasses() }
    }

    private struct PassKey: Hashable {
        let norad: Int?
        let observer: Geodetic?
    }

    private func content(_ sat: SatStore.Sat) -> some View {
        let palette = Palette.of(scheme)
        let color = Color(palette.color(for: sat.category.id))
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(sat.entry.name.isEmpty ? "Unknown" : sat.entry.name)
                            .font(.title2.bold())
                            .lineLimit(2)
                            .minimumScaleFactor(0.7)
                        Text(sat.category.label)
                            .font(.caption.weight(.bold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(color, in: .capsule)
                            .foregroundStyle(Color(palette.tagInk))
                    }
                    Spacer(minLength: 0)
                    HeaderButtons(sat: sat)
                }

                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    if let live = model.store.sat(norad: sat.norad) { Facts(sat: live) }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Next pass over you").font(.caption).foregroundStyle(.secondary)
                    Text(passLine)
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                }

                if floating || detent == .large {
                    upcoming
                    More(sat: sat)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 12)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private var passLine: String {
        guard model.observer != nil else {
            return model.locationAccess == .denied ? "Turn on location for passes" : "Waiting for your location…"
        }
        return nextPass ?? "Calculating…"
    }

    @ViewBuilder private var upcoming: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Passes in the next 24 hours").font(.headline)
            if model.observer == nil {
                Text("Orbit needs your location to work them out.").foregroundStyle(.secondary)
            } else if let passes {
                if passes.isEmpty {
                    Text("None: it never rises over you in that time.").foregroundStyle(.secondary)
                } else {
                    ForEach(passes, id: \.rise.time) { PassRow(pass: $0) }
                }
            } else {
                ProgressView()
            }
        }
        .padding(.top, 6)
    }

    /// The page's one line (so the two apps say the same), and the day's
    /// passes found to the second for the list.
    private func computePasses() async {
        nextPass = nil
        passes = nil
        guard let sat = model.selected, let observer = model.observer else { return }
        let rec = sat.satrec
        let result = await Task.detached(priority: .userInitiated) { () -> (String, [Pass]) in
            let now = Date()
            // A pass that never clears a degree is behind the first tree.
            let list = PassFinder.passes(of: rec, from: observer, start: now, end: now.addingTimeInterval(86400),
                                         minPeakDeg: 1, limit: 16)
            let t = Date.FormatStyle(date: .omitted, time: .shortened)
            let line: String
            if let la = Look.angles(rec, at: now, from: observer), la.elevationDeg > 0 {
                if let current = list.first, current.rise.time <= now {
                    line = "Up now, \(Int(la.elevationDeg.rounded()))° high · sets \(current.set.time.formatted(t))"
                } else {
                    line = "Up now, \(Int(la.elevationDeg.rounded()))° high · stays up"
                }
            } else if let p = Look.nextPass(rec, from: observer, after: now) {
                line = "\(p.aos.formatted(t)) · peak \(p.peakDeg)°" + (p.minutes.map { " · ~\($0) min" } ?? "")
            } else if let p = list.first(where: { $0.rise.time > now }) {
                // Past the page's 4-hour window, but the day's list knows it.
                let day = Calendar.current.isDateInToday(p.rise.time) ? t : Date.FormatStyle().weekday(.abbreviated).hour().minute()
                line = "\(p.rise.time.formatted(day)) · peak \(Int(p.peak.elevationDeg.rounded()))° · ~\(Int((p.duration / 60).rounded())) min"
            } else {
                line = "None in the next 24 h"
            }
            return (line, list.filter { $0.set.time > now })
        }.value
        guard !Task.isCancelled else { return }
        nextPass = result.0
        passes = result.1
    }
}

/// The page's eight facts, live.
private struct Facts: View {
    let sat: SatStore.Sat
    @Environment(AppModel.self) private var model

    var body: some View {
        let meta = Catalog.meta(name: sat.entry.name, group: sat.category.group)
        let cells: [(String, String)] = [
            ("Country", meta.country),
            ("Operator", meta.operatorName),
            ("Purpose", meta.purpose),
            ("NORAD ID", String(sat.norad)),
            ("Altitude", sat.alive ? "\(Int(sat.heightKm.rounded()).formatted()) km" : "—"),
            ("Speed", sat.alive ? String(format: "%.2f km/s", sat.speed) : "—"),
            ("Sub-point", sat.alive ? String(format: "%.1f°, %.1f°", sat.latDeg, sat.lonDeg) : "—"),
            ("From you", fromYou),
        ]
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
            ForEach(0..<4, id: \.self) { row in
                GridRow {
                    cell(cells[row * 2])
                    cell(cells[row * 2 + 1])
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.fill.quinary, in: .rect(cornerRadius: 20))
    }

    private var fromYou: String {
        guard let o = model.observer else { return "Enable location" }
        guard let la = Look.angles(sat.satrec, at: .now, from: o) else { return "—" }
        return la.elevationDeg > 0
            ? "\(Int(la.elevationDeg.rounded()))° up, \(Compass.point(la.azimuthDeg))"
            : "Below horizon"
    }

    private func cell(_ kv: (String, String)) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(kv.0).font(.caption).foregroundStyle(.secondary)
            Text(kv.1)
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .lineLimit(2)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// Alert me, follow, close: glass buttons in the card's corner, lit when on.
private struct HeaderButtons: View {
    let sat: SatStore.Sat
    @Environment(AppModel.self) private var model

    var body: some View {
        let watched = model.alerts.isWatched(sat.norad)
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                round(watched ? "Stop pass alerts" : "Alert me before it passes", watched ? "bell.fill" : "bell", on: watched) {
                    Task { await model.alerts.toggle(sat.entry, categoryId: sat.category.id) }
                }
                round(model.following ? "Stop following" : "Follow it", "scope", on: model.following) {
                    model.following.toggle()
                }
                round("Close", "xmark", on: false) { model.deselect() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .controlSize(.large)
    }

    @ViewBuilder
    private func round(_ title: String, _ symbol: String, on: Bool, action: @escaping () -> Void) -> some View {
        let button = Button(title, systemImage: symbol, action: action)
            .labelStyle(.iconOnly)
            .buttonBorderShape(.circle)
        if on {
            button.buttonStyle(.glassProminent)
        } else {
            button.buttonStyle(.glass)
        }
    }
}

/// Pulled up: the full record elsewhere, and unpinning.
private struct More: View {
    let sat: SatStore.Sat
    @Environment(AppModel.self) private var model

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                Link(destination: URL(string: "https://www.n2yo.com/satellite/?s=\(sat.norad)")!) {
                    Label("Full record on N2YO", systemImage: "arrow.up.right")
                }
                .buttonStyle(.glass)
                if model.isPinned(sat.norad) {
                    Button("Unpin", systemImage: "pin.slash") { model.unpin(sat.norad) }
                        .buttonStyle(.glass)
                }
            }
        }
        .controlSize(.large)
        .padding(.top, 4)
    }
}

/// One pass: when, how high, how long, from where to where.
struct PassRow: View {
    let pass: Pass

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(pass.rise.time, format: .dateTime.weekday(.abbreviated).hour().minute())
                    .font(.subheadline.weight(.semibold))
                Text("\(Compass.point(pass.rise.azimuthDeg)) → \(Compass.point(pass.set.azimuthDeg)) · \(Int((pass.duration / 60).rounded())) min")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if pass.visible {
                Image(systemName: "eye")
                    .foregroundStyle(.tint)
                    .accessibilityLabel("Visible")
            }
            Text("\(Int(pass.peak.elevationDeg.rounded()))°")
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .frame(minWidth: 44, alignment: .trailing)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}
