import BackgroundTasks
import OrbitCore
import SwiftUI
import UserNotifications

/// "Tell me before it passes over": local notifications planned from the
/// satellites you watch, your last location and the elements on the phone.
/// Nothing leaves the phone. iOS keeps at most 64 pending notifications, so
/// the next two days are planned whenever the app opens, closes or moves, and
/// again in the background when iOS allows (`backgroundRefresh`).
@MainActor
@Observable
final class PassAlerts: NSObject, UNUserNotificationCenterDelegate {
    struct Watched: Codable, Hashable, Identifiable {
        var entry: TleEntry
        var updated: Date
        /// The category it was watched from, so a tapped alert opens it where
        /// it lives (nil: it belongs to none, or it was watched before 2.0.0's fix).
        var categoryId: String?
        var id: Int { entry.norad ?? 0 }
    }

    /// One planned notification.
    struct Planned: Hashable, Identifiable {
        let norad: Int
        let name: String
        let pass: Pass
        let fire: Date
        var id: String { "pass-\(norad)-\(Int(pass.rise.time.timeIntervalSince1970))" }
    }

    static let refreshTaskId = "com.kotatko.sattracker.passes"
    static let leadChoices = [5, 10, 15, 30]
    static let peakChoices = [10, 20, 30, 45]
    nonisolated private static let horizon: TimeInterval = 2 * 86400
    nonisolated private static let maxPending = 60

    private(set) var watched: [Watched]
    var leadMinutes: Int { didSet { settingsChanged() } }
    var minPeakDeg: Int { didSet { settingsChanged() } }
    var visibleOnly: Bool { didSet { settingsChanged() } }
    private(set) var authorization = UNAuthorizationStatus.notDetermined
    /// What is scheduled now, soonest first.
    private(set) var planned: [Planned] = []

    @ObservationIgnored var observer: () -> Geodetic? = { SharedStore.observer }
    @ObservationIgnored var onOpen: ((Int, TleEntry?, String?) -> Void)?
    @ObservationIgnored private let tle: TleRepository
    /// Goes up with every plan; a plan finishing after a newer one started
    /// throws its result away.
    @ObservationIgnored private var generation = 0

    private let defaults = UserDefaults.standard

    init(tle: TleRepository) {
        self.tle = tle
        watched = defaults.data(forKey: "alerts.watched").flatMap { try? JSONDecoder().decode([Watched].self, from: $0) } ?? []
        leadMinutes = defaults.object(forKey: "alerts.lead") as? Int ?? 10
        minPeakDeg = defaults.object(forKey: "alerts.minPeak") as? Int ?? 20
        visibleOnly = defaults.bool(forKey: "alerts.visibleOnly")
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    func isWatched(_ norad: Int) -> Bool { watched.contains { $0.id == norad } }

    /// Watch a satellite, or stop watching it. The first one asks for
    /// permission to notify.
    func toggle(_ entry: TleEntry, categoryId: String?) async {
        guard let norad = entry.norad else { return }
        if isWatched(norad) {
            watched.removeAll { $0.id == norad }
        } else {
            if authorization == .notDetermined { await requestAuthorization() }
            guard !isWatched(norad) else { return }     // a second tap while the permission was asked
            watched.append(Watched(entry: entry, updated: .now, categoryId: categoryId))
        }
        saveWatched()
        await reschedule()
    }

    func remove(_ norads: [Int]) {
        watched.removeAll { norads.contains($0.id) }
        saveWatched()
        Task { await reschedule() }
    }

    func requestAuthorization() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        await refreshAuthorization()
    }

    func refreshAuthorization() async {
        authorization = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    private func settingsChanged() {
        defaults.set(leadMinutes, forKey: "alerts.lead")
        defaults.set(minPeakDeg, forKey: "alerts.minPeak")
        defaults.set(visibleOnly, forKey: "alerts.visibleOnly")
        Task { await reschedule() }
    }

    private func saveWatched() {
        defaults.set(try? JSONEncoder().encode(watched), forKey: "alerts.watched")
    }

    /// Plans the next two days again, from scratch. Plans overlap (a scene
    /// change, a move and a setting can each start one), so only the newest
    /// one is kept, and it swaps the pending notifications in one step with no
    /// suspension in between.
    func reschedule() async {
        generation += 1
        let mine = generation
        let center = UNUserNotificationCenter.current()
        guard let observer = observer(), !watched.isEmpty else {
            center.removeAllPendingNotificationRequests()
            planned = []
            return
        }
        let leadMinutes = self.leadMinutes
        let watched = self.watched, lead = TimeInterval(leadMinutes * 60)
        let minPeak = Double(minPeakDeg), visibleOnly = self.visibleOnly
        let task = Task.detached(priority: .utility) { () -> [Planned] in
            let now = Date()
            var plans: [Planned] = []
            for w in watched {
                guard let sat = w.entry.satrec, let norad = w.entry.norad else { continue }
                for p in PassFinder.passes(of: sat, from: observer, start: now, end: now.addingTimeInterval(Self.horizon),
                                           minPeakDeg: minPeak)
                where !visibleOnly || p.visible {
                    let fire = p.rise.time.addingTimeInterval(-lead)
                    if fire > now.addingTimeInterval(5) {
                        plans.append(Planned(norad: norad, name: w.entry.name, pass: p, fire: fire))
                    }
                }
            }
            return Array(plans.sorted { $0.fire < $1.fire }.prefix(Self.maxPending))
        }
        let plans = await task.value
        guard mine == generation else { return }
        let allowed = authorization == .authorized || authorization == .provisional || authorization == .ephemeral
        Self.replacePending(with: allowed ? plans : [], leadMinutes: leadMinutes, in: center)
        planned = plans
    }

    /// Swaps every pending alert for these. Synchronous on purpose: with no
    /// suspension point, no other plan can clear the list halfway through
    /// filling it.
    private static func replacePending(with plans: [Planned], leadMinutes: Int, in center: UNUserNotificationCenter) {
        center.removeAllPendingNotificationRequests()
        for p in plans {
            let content = UNMutableNotificationContent()
            content.title = "\(p.name) in \(leadMinutes) min"
            content.body = describe(p.pass)
            content.sound = .default
            content.threadIdentifier = "pass-\(p.norad)"
            content.userInfo = ["norad": p.norad]
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, p.fire.timeIntervalSinceNow), repeats: false)
            center.add(UNNotificationRequest(identifier: p.id, content: content, trigger: trigger), withCompletionHandler: nil)
        }
    }

    /// "Rises 21:42 in the SW, highest 54° in the S at 21:45, sets 21:48 in the E."
    nonisolated static func describe(_ p: Pass) -> String {
        let t = Date.FormatStyle(date: .omitted, time: .shortened)
        var s = "Rises \(p.rise.time.formatted(t)) in the \(Compass.point(p.rise.azimuthDeg)), "
            + "highest \(Int(p.peak.elevationDeg.rounded()))° in the \(Compass.point(p.peak.azimuthDeg)) at \(p.peak.time.formatted(t)), "
            + "sets \(p.set.time.formatted(t)) in the \(Compass.point(p.set.azimuthDeg))."
        if p.visible { s += " It will be in sunlight against a dark sky: look for a steady star that moves." }
        return s
    }

    // MARK: - Background

    func scheduleBackgroundRefresh() {
        guard !watched.isEmpty else { return }
        let request = BGAppRefreshTaskRequest(identifier: Self.refreshTaskId)
        request.earliestBeginDate = Date().addingTimeInterval(6 * 3600)
        try? BGTaskScheduler.shared.submit(request)
    }

    /// iOS woke the app in the background: newer elements for what is
    /// watched, then plan again.
    func backgroundRefresh() async {
        for w in watched where Date().timeIntervalSince(w.updated) > 12 * 3600 {
            guard let norad = w.entry.norad, let fresh = await tle.satellite(norad: norad),
                  let i = watched.firstIndex(where: { $0.id == norad })   // the list may have changed meanwhile
            else { continue }
            watched[i] = Watched(entry: fresh, updated: .now, categoryId: watched[i].categoryId)
        }
        saveWatched()
        await refreshAuthorization()
        await reschedule()
        scheduleBackgroundRefresh()
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification)
        async -> UNNotificationPresentationOptions
    {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let norad = response.notification.request.content.userInfo["norad"] as? Int else { return }
        await MainActor.run {
            let w = watched.first { $0.id == norad }
            onOpen?(norad, w?.entry, w?.categoryId)
        }
    }
}
