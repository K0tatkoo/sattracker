import CoreLocation
import OrbitCore
import SwiftUI
import WidgetKit

/// The sheet on screen. One at a time: the satellite's card, or one of the
/// toolbar's three.
enum ActiveSheet: String, Identifiable {
    case card, search, alerts, about
    var id: String { rawValue }
}

/// A camera move the globe should make on its next frame.
enum CameraRequest {
    /// Swing round to face this point on the Earth (the first location fix).
    case face(latDeg: Double, lonDeg: Double)
    /// Turn to a satellite, backing off far enough to see it.
    case satellite(norad: Int)
}

struct Toast: Equatable {
    let id = UUID()
    let text: String
}

enum LocationAccess {
    case unknown, allowed, denied
}

/// Everything the app knows that the screen shows: which categories are on,
/// what is selected, where you are. The globe reads the satellites themselves
/// from `store`, every frame, outside SwiftUI.
@MainActor
@Observable
final class AppModel {
    @ObservationIgnored let store = SatStore()
    @ObservationIgnored let tle = TleRepository()
    @ObservationIgnored private let location = LocationProvider()
    let alerts: PassAlerts

    private(set) var enabled: Set<String>
    private(set) var loading: Set<String> = []
    private(set) var selectedNorad: Int?
    var sheet: ActiveSheet?
    private(set) var observer: Geodetic?
    private(set) var locationAccess = LocationAccess.unknown
    /// "Contacting satellites…" until the first category arrives.
    private(set) var booting = true
    private(set) var toast: Toast?
    /// The camera keeps the selected satellite in front of you.
    var following = false
    /// Satellites found on Celestrak that belong to no category.
    private(set) var pinned: [TleEntry]
    /// The last satellites opened, newest first (the search sheet's suggestions).
    private(set) var recent: [Int]

    /// Read and cleared by the globe.
    @ObservationIgnored var cameraRequest: CameraRequest?
    @ObservationIgnored private var pendingSelection: TleEntry?
    @ObservationIgnored private var loadedAt: [String: Date] = [:]
    @ObservationIgnored private var sharedObserver: Geodetic?
    @ObservationIgnored private var plannedObserver: Geodetic?
    @ObservationIgnored private var centred = false
    @ObservationIgnored private var started = false

    private static let enabledKey = "categories.enabled"
    private static let pinnedKey = "pinned"
    private static let recentKey = "recent"

    init() {
        let d = UserDefaults.standard
        enabled = (d.stringArray(forKey: Self.enabledKey)).map(Set.init)
            ?? Set(Catalog.categories.filter(\.defaultOn).map(\.id) + [Catalog.pinned.id])
        pinned = d.data(forKey: Self.pinnedKey).flatMap { try? JSONDecoder().decode([TleEntry].self, from: $0) } ?? []
        recent = (d.array(forKey: Self.recentKey) as? [Int]) ?? []
        alerts = PassAlerts(tle: tle)
        observer = SharedStore.observer
        sharedObserver = observer
        alerts.observer = { [weak self] in self?.observer ?? SharedStore.observer }
        alerts.onOpen = { [weak self] norad, entry, category in self?.openSatellite(norad, entry: entry, categoryId: category) }
        location.onLocation = { [weak self] in self?.located($0) }
        location.onAccess = { [weak self] granted in self?.accessChanged(granted) }
    }

    /// The categories, the pinned one only once something is pinned.
    var categories: [SatCategory] {
        Catalog.categories + (pinned.isEmpty ? [] : [Catalog.pinned])
    }

    var selected: SatStore.Sat? { selectedNorad.flatMap { store.sat(norad: $0) } }

    // MARK: - Life

    func start() {
        guard !started else { return }
        started = true
        for c in categories where enabled.contains(c.id) { load(c) }
        Task {
            // Never leave the spinner up: even with nothing at all, after 8 s.
            try? await Task.sleep(for: .seconds(8))
            booting = false
        }
        Task { await refreshPinned() }
    }

    /// The app came to the front (true) or left it (false).
    func setActive(_ active: Bool) {
        if active {
            location.start()
            for c in categories where enabled.contains(c.id) {
                if let at = loadedAt[c.id], Date().timeIntervalSince(at) > 3 * 3600 { load(c) }
            }
            Task { await alerts.refreshAuthorization() }
        } else {
            location.stop()
            alerts.scheduleBackgroundRefresh()
        }
        Task { await alerts.reschedule() }
    }

    // MARK: - Categories

    func toggle(_ c: SatCategory) {
        if enabled.contains(c.id) {
            enabled.remove(c.id)
            store.remove(category: c.id)
            // A choice still waiting for its category is overtaken by this one.
            pendingSelection = nil
            if let n = selectedNorad, store.index(norad: n) == nil { deselect() }
        } else {
            enabled.insert(c.id)
            load(c)
        }
        saveEnabled()
    }

    private func saveEnabled() {
        UserDefaults.standard.set(Array(enabled), forKey: Self.enabledKey)
    }

    private func load(_ c: SatCategory) {
        if c.id == Catalog.pinned.id {
            store.replace(c, with: pinned)
            afterLoad()
            return
        }
        guard !loading.contains(c.id) else { return }
        loading.insert(c.id)
        Task {
            let r = await tle.tle(for: c.group)
            loading.remove(c.id)
            guard enabled.contains(c.id) else { return }     // switched off while it was downloading
            let entries = TLE.parse(r.text, cap: c.cap)
            store.replace(c, with: entries)
            loadedAt[c.id] = .now
            booting = false
            switch r.source {
            case .offline: show("\(c.label): showing offline data (couldn't reach Celestrak)")
            case .none: show("\(c.label): no live data — check connection")
            default: break
            }
            if c.id == "stations", let iss = entries.first(where: { $0.norad == Catalog.issNorad }) {
                shareIss(iss)
            }
            afterLoad()
        }
    }

    /// A satellite chosen before its category was on the globe: select it now
    /// it is here, or pin it when the category's cap left it out. Nothing is
    /// decided while categories are still arriving — including at a cold
    /// launch from a notification or the widget, before `start()` has run.
    private func afterLoad() {
        guard let want = pendingSelection, let norad = want.norad else { return }
        let waiting = !started || !loading.isEmpty
        if store.index(norad: norad) != nil {
            pendingSelection = nil
            select(norad: norad)
            fly(to: norad)
        } else if !waiting {
            pendingSelection = nil
            pin(want)
            select(norad: norad)
            fly(to: norad)
        }
    }

    // MARK: - Selection

    func select(norad: Int) {
        if selectedNorad != norad { following = false }
        selectedNorad = norad
        sheet = .card
        recent.removeAll { $0 == norad }
        recent.insert(norad, at: 0)
        recent = Array(recent.prefix(8))
        UserDefaults.standard.set(recent, forKey: Self.recentKey)
    }

    func deselect() {
        selectedNorad = nil
        following = false
        if sheet == .card { sheet = nil }
    }

    /// A tap on the globe: a satellite, or nothing (which puts the card away).
    func tapped(norad: Int?) {
        if let norad { select(norad: norad) } else { deselect() }
    }

    func open(_ s: ActiveSheet) {
        if s != .card {
            selectedNorad = nil
            following = false
        }
        sheet = s
    }

    /// A sheet went away. When nothing replaced it (the card was swiped down),
    /// nothing is selected any more; when another sheet replaced it, the one
    /// that opened decided.
    func sheetDismissed() {
        if sheet == nil {
            selectedNorad = nil
            following = false
        }
    }

    func fly(to norad: Int) {
        cameraRequest = .satellite(norad: norad)
    }

    /// A satellite picked in search. Shown where it lives: its category is
    /// switched on if it was off; one that belongs to none is pinned.
    func choose(_ entry: TleEntry, categoryId: String?) {
        guard let norad = entry.norad else { return }
        sheet = nil
        pendingSelection = nil      // a new choice replaces one still waiting
        if store.index(norad: norad) != nil {
            select(norad: norad)
            fly(to: norad)
            return
        }
        if let id = categoryId, let c = Catalog.category(id: id), c.id != Catalog.pinned.id {
            pendingSelection = entry
            if !enabled.contains(id) {
                toggle(c)
            } else {
                afterLoad()
            }
        } else {
            pin(entry)
            select(norad: norad)
            fly(to: norad)
        }
    }

    /// From a notification or the widget: open this satellite's card, in
    /// its own category when it has one (pinning is for satellites that
    /// belong to none).
    func openSatellite(_ norad: Int, entry: TleEntry? = nil, categoryId: String? = nil) {
        if let sat = store.sat(norad: norad) {
            choose(sat.entry, categoryId: nil)
            return
        }
        let category = norad == Catalog.issNorad ? "stations" : categoryId
        if let known = entry ?? (norad == Catalog.issNorad ? SharedStore.iss?.entry : nil) {
            choose(known, categoryId: category)
            return
        }
        Task {
            if let e = await tle.satellite(norad: norad) { choose(e, categoryId: category) }
        }
    }

    func open(url: URL) {
        if let norad = SharedStore.norad(from: url) { openSatellite(norad) }
    }

    // MARK: - Pinned

    func isPinned(_ norad: Int) -> Bool { pinned.contains { $0.norad == norad } }

    /// Pins it (once), and shows the pinned ones even if their chip was off.
    func pin(_ entry: TleEntry) {
        guard let norad = entry.norad else { return }
        if !isPinned(norad) {
            pinned.append(entry)
            savePinned()
        }
        if !enabled.contains(Catalog.pinned.id) {
            enabled.insert(Catalog.pinned.id)
            saveEnabled()
        }
        store.replace(Catalog.pinned, with: pinned)
    }

    func unpin(_ norad: Int) {
        pinned.removeAll { $0.norad == norad }
        savePinned()
        store.replace(Catalog.pinned, with: enabled.contains(Catalog.pinned.id) ? pinned : [])
        if selectedNorad == norad, store.index(norad: norad) == nil { deselect() }
    }

    private func savePinned() {
        UserDefaults.standard.set(try? JSONEncoder().encode(pinned), forKey: Self.pinnedKey)
    }

    /// Pinned elements a day old or more are fetched again.
    private func refreshPinned() async {
        var changed = false
        for e in pinned {
            guard let norad = e.norad, let epoch = e.epoch, Date().timeIntervalSince(epoch) > 86400,
                  let fresh = await tle.satellite(norad: norad), fresh.line1 != e.line1,
                  let i = pinned.firstIndex(where: { $0.norad == norad })   // the list may have changed meanwhile
            else { continue }
            pinned[i] = fresh
            changed = true
        }
        if changed {
            savePinned()
            if enabled.contains(Catalog.pinned.id) { store.replace(Catalog.pinned, with: pinned) }
        }
    }

    // MARK: - Location

    private func located(_ loc: CLLocation) {
        let g = Geodetic(latitudeDeg: loc.coordinate.latitude, longitudeDeg: loc.coordinate.longitude,
                         altitudeM: loc.verticalAccuracy >= 0 ? loc.altitude : 0)
        observer = g
        locationAccess = .allowed
        if !centred {
            // On the first fix, swing round so YOU are front and centre —
            // unless the app opened on a satellite (a notification, the
            // widget), which the camera is already turning to.
            centred = true
            if selectedNorad == nil && pendingSelection == nil && cameraRequest == nil {
                cameraRequest = .face(latDeg: g.latitudeDeg, lonDeg: g.longitudeDeg)
            }
        }
        if sharedObserver.map({ Self.km(between: $0, and: g) > 1 }) ?? true {
            sharedObserver = g
            SharedStore.observer = g
            WidgetCenter.shared.reloadTimelines(ofKind: SharedStore.widgetKind)
        }
        if plannedObserver.map({ Self.km(between: $0, and: g) > 5 }) ?? true {
            plannedObserver = g
            Task { await alerts.reschedule() }
        }
    }

    private func accessChanged(_ granted: Bool) {
        locationAccess = granted ? .allowed : .denied
        if !granted { show("Location off — passes disabled") }
    }

    static func km(between a: Geodetic, and b: Geodetic) -> Double {
        let dLat = b.latitude - a.latitude, dLon = b.longitude - a.longitude
        let h = sin(dLat / 2) * sin(dLat / 2) + cos(a.latitude) * cos(b.latitude) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * 6371 * asin(min(1, h.squareRoot()))
    }

    // MARK: - Widget

    private func shareIss(_ iss: TleEntry) {
        guard SharedStore.iss?.entry != iss else { return }
        SharedStore.iss = .init(entry: iss, fetched: .now)
        WidgetCenter.shared.reloadTimelines(ofKind: SharedStore.widgetKind)
    }

    // MARK: - Messages

    func show(_ text: String) {
        let t = Toast(text: text)
        toast = t
        Task {
            try? await Task.sleep(for: .seconds(2.6))
            if toast == t { toast = nil }
        }
    }
}
