import CoreLocation
import OrbitCore
import SwiftUI
import WidgetKit

@main
struct OrbitWidgets: WidgetBundle {
    var body: some Widget {
        NextIssPassWidget()
    }
}

/// When the ISS next passes over you, from the place the app last saw you and
/// the elements it last fetched (both in the App Group). Worked out here, on
/// the phone, with the same SGP4 as the app.
struct NextIssPassWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: SharedStore.widgetKind, provider: PassProvider()) { entry in
            PassWidgetView(entry: entry)
                .widgetURL(SharedStore.url(norad: Catalog.issNorad))
        }
        .configurationDisplayName("Next ISS pass")
        .description("When the International Space Station next flies over you, and how high.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryInline, .accessoryCircular])
    }
}

struct PassEntry: TimelineEntry {
    enum State {
        /// The pass, and whether it is happening now.
        case pass(Pass, now: Bool)
        case noLocation
        case noOrbit
        case noPass
    }

    let date: Date
    let state: State

    static let sample: PassEntry = {
        let now = Date()
        func point(_ s: TimeInterval, _ az: Double, _ el: Double) -> SkyPoint {
            SkyPoint(time: now.addingTimeInterval(s), azimuthDeg: az, elevationDeg: el)
        }
        let track = (0...30).map { i -> SkyPoint in
            let f = Double(i) / 30
            return point(3600 + f * 360, 225 + f * 130, sin(f * .pi) * 54)
        }
        return PassEntry(date: now, state: .pass(Pass(rise: track.first!, peak: track[15], set: track.last!,
                                                      visible: true, track: track), now: false))
    }()
}

/// Where the phone is, found by the widget itself: for when it cannot read the
/// app's (a free Apple ID registers no App Group). Needs NSWidgetWantsLocation
/// and the app's location permission ("While Using the App or Widgets"), and
/// gives up after ten seconds.
@MainActor
final class WidgetLocation: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var waiting: CheckedContinuation<CLLocation?, Never>?

    static func current() async -> Geodetic? {
        guard let loc = await WidgetLocation().locate() else { return nil }
        return Geodetic(latitudeDeg: loc.coordinate.latitude, longitudeDeg: loc.coordinate.longitude,
                        altitudeM: loc.verticalAccuracy >= 0 ? loc.altitude : 0)
    }

    private func locate() async -> CLLocation? {
        if let last = manager.location, Date().timeIntervalSince(last.timestamp) < 2 * 3600 { return last }
        guard manager.isAuthorizedForWidgetUpdates else { return manager.location }
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
        return await withCheckedContinuation { c in
            waiting = c
            manager.requestLocation()
            Task {
                try? await Task.sleep(for: .seconds(10))
                self.finish(self.manager.location)
            }
        }
    }

    private func finish(_ location: CLLocation?) {
        waiting?.resume(returning: location)
        waiting = nil
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let last = locations.last
        Task { @MainActor in self.finish(last) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.finish(self.manager.location) }
    }
}

/// WidgetKit's completion handlers are not Sendable; this carries one into
/// the task that computes the timeline (it is called exactly once).
private struct Once<T>: @unchecked Sendable {
    let call: T
}

struct PassProvider: TimelineProvider {
    func placeholder(in context: Context) -> PassEntry { .sample }

    func getSnapshot(in context: Context, completion: @escaping (PassEntry) -> Void) {
        let done = Once(call: completion)
        if context.isPreview {
            completion(.sample)
            return
        }
        Task { done.call(await Self.entries(now: .now).first ?? .sample) }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<PassEntry>) -> Void) {
        let done = Once(call: completion)
        Task {
            let now = Date()
            let entries = await Self.entries(now: now)
            // Elements drift: work it out again within a few hours even when
            // the next pass is days away.
            let last = entries.last.map { $0.date } ?? now
            let reload = min(max(last.addingTimeInterval(60), now.addingTimeInterval(15 * 60)), now.addingTimeInterval(4 * 3600))
            done.call(Timeline(entries: entries, policy: .after(reload)))
        }
    }

    /// Now, then a change at every rise (the pass is on) and every set (the
    /// next one is shown).
    static func entries(now: Date) async -> [PassEntry] {
        // The app's last location when it can share it (the App Group), else
        // the widget's own, which also covers an app not opened for a while.
        var found = SharedStore.observer
        if found == nil, let here = await WidgetLocation.current() {
            found = here
            SharedStore.observer = here
        }
        guard let observer = found else { return [PassEntry(date: now, state: .noLocation)] }
        var stored = SharedStore.iss
        if stored == nil || now.timeIntervalSince(stored!.fetched) > 2 * 86400 {
            if let fresh = await TleRepository().satellite(norad: Catalog.issNorad) {
                stored = .init(entry: fresh, fetched: now)
                SharedStore.iss = stored
            }
        }
        guard let rec = stored?.entry.satrec else { return [PassEntry(date: now, state: .noOrbit)] }
        let passes = PassFinder.passes(of: rec, from: observer, start: now, end: now.addingTimeInterval(2 * 86400),
                                       minPeakDeg: 10, limit: 4)
        guard let first = passes.first else { return [PassEntry(date: now, state: .noPass)] }
        var out = [PassEntry(date: now, state: .pass(first, now: first.rise.time <= now))]
        for (i, p) in passes.enumerated() {
            if p.rise.time > now { out.append(PassEntry(date: p.rise.time, state: .pass(p, now: true))) }
            let next = i + 1 < passes.count ? PassEntry.State.pass(passes[i + 1], now: false) : .noPass
            out.append(PassEntry(date: p.set.time, state: next))
        }
        return out
    }
}

struct PassWidgetView: View {
    let entry: PassEntry
    @Environment(\.widgetFamily) private var family
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        content
            .containerBackground(for: .widget) { Color(Palette.of(scheme).bg) }
    }

    @ViewBuilder private var content: some View {
        switch family {
        case .accessoryInline: inline
        case .accessoryCircular: circular
        case .accessoryRectangular: rectangular
        case .systemMedium:
            HStack(spacing: 14) {
                summary
                if case let .pass(p, _) = entry.state {
                    SkyTrack(pass: p).frame(maxWidth: .infinity)
                }
            }
        default: summary
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                OrbitMark().frame(width: 16, height: 16).foregroundStyle(Color(Palette.of(scheme).accent))
                Text("ISS").font(.caption.weight(.heavy))
                Spacer(minLength: 0)
                if case let .pass(p, _) = entry.state, p.visible {
                    Image(systemName: "eye").font(.caption).foregroundStyle(Color(Palette.of(scheme).accent))
                        .accessibilityLabel("Visible")
                }
            }
            Spacer(minLength: 2)
            switch entry.state {
            case let .pass(p, now):
                Text(now ? "OVERHEAD NOW" : "NEXT PASS")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                Text(now ? p.set.time : p.rise.time, style: .time)
                    .font(.system(.title, design: .rounded).weight(.bold))
                    .monospacedDigit()
                    .minimumScaleFactor(0.7)
                    .widgetAccentable()
                Group {
                    if now {
                        Text("sets in \(Text(p.set.time, style: .relative))")
                    } else {
                        Text("in \(Text(p.rise.time, style: .relative))")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                Text("\(Int(p.peak.elevationDeg.rounded()))° · \(Compass.point(p.rise.azimuthDeg)) → \(Compass.point(p.set.azimuthDeg))")
                    .font(.caption.weight(.semibold))
            case .noLocation:
                message("Open Orbit once, so it knows where you are.")
            case .noOrbit:
                message("Open Orbit to fetch the ISS's orbit.")
            case .noPass:
                message("No pass above 10° in the next two days.")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func message(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 1) {
            switch entry.state {
            case let .pass(p, now):
                Text(now ? "ISS overhead" : "ISS pass")
                    .font(.headline).widgetAccentable()
                Text(now ? p.set.time : p.rise.time, style: .time).font(.body.weight(.semibold))
                Text("\(Int(p.peak.elevationDeg.rounded()))° · \(Compass.point(p.rise.azimuthDeg)) → \(Compass.point(p.set.azimuthDeg))")
                    .font(.caption)
            case .noLocation, .noOrbit:
                Text("ISS").font(.headline).widgetAccentable()
                Text("Open Orbit").font(.caption)
            case .noPass:
                Text("ISS").font(.headline).widgetAccentable()
                Text("No pass in 2 days").font(.caption)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var inline: some View {
        if case let .pass(p, now) = entry.state {
            Text("ISS \(now ? "now" : p.rise.time.formatted(date: .omitted, time: .shortened)) · \(Int(p.peak.elevationDeg.rounded()))°")
        } else {
            Text("ISS · no pass soon")
        }
    }

    private var circular: some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: 0) {
                Text("ISS").font(.system(size: 11, weight: .heavy))
                if case let .pass(p, now) = entry.state {
                    Text(now ? "now" : p.rise.time.formatted(.dateTime.hour(.defaultDigits(amPM: .omitted)).minute()))
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .minimumScaleFactor(0.6)
                    Text("\(Int(p.peak.elevationDeg.rounded()))°").font(.system(size: 10, weight: .semibold))
                } else {
                    Text("—").font(.headline)
                }
            }
            .widgetAccentable()
        }
    }
}

/// The pass on a sky plot like the Android app's GNSS one: north up, east to
/// the right, the horizon the circle and straight overhead its centre.
struct SkyTrack: View {
    let pass: Pass
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let palette = Palette.of(scheme)
        Canvas { ctx, size in
            let r = min(size.width, size.height) / 2 - 8
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            func at(_ p: SkyPoint) -> CGPoint {
                let rr = r * (1 - max(0, p.elevationDeg) / 90)
                let a = (p.azimuthDeg - 90) * .pi / 180
                return CGPoint(x: c.x + rr * cos(a), y: c.y + rr * sin(a))
            }
            let faint = GraphicsContext.Shading.color(Color(palette.textFaint).opacity(0.5))
            for f in [1.0, 2.0 / 3, 1.0 / 3] {
                ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r * f, y: c.y - r * f, width: 2 * r * f, height: 2 * r * f)),
                           with: faint, lineWidth: 0.75)
            }
            var cross = Path()
            cross.move(to: CGPoint(x: c.x - r, y: c.y)); cross.addLine(to: CGPoint(x: c.x + r, y: c.y))
            cross.move(to: CGPoint(x: c.x, y: c.y - r)); cross.addLine(to: CGPoint(x: c.x, y: c.y + r))
            ctx.stroke(cross, with: faint, lineWidth: 0.75)
            ctx.draw(Text("N").font(.system(size: 8, weight: .bold)).foregroundStyle(Color(palette.textDim)),
                     at: CGPoint(x: c.x, y: c.y - r - 5))

            var path = Path()
            for (i, p) in pass.track.enumerated() {
                if i == 0 { path.move(to: at(p)) } else { path.addLine(to: at(p)) }
            }
            ctx.stroke(path, with: .color(Color(palette.accent)), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
            let rise = at(pass.rise), peak = at(pass.peak)
            ctx.fill(Path(ellipseIn: CGRect(x: rise.x - 3, y: rise.y - 3, width: 6, height: 6)), with: .color(Color(palette.good)))
            ctx.fill(Path(ellipseIn: CGRect(x: peak.x - 3.5, y: peak.y - 3.5, width: 7, height: 7)), with: .color(Color(palette.accent)))
        }
        .widgetAccentable()
        .accessibilityLabel("Path across the sky, rising in the \(Compass.point(pass.rise.azimuthDeg)), setting in the \(Compass.point(pass.set.azimuthDeg))")
    }
}
