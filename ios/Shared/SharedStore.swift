import Foundation
import OrbitCore

/// What the app leaves for its widget (and for itself in the background), in
/// the App Group: where you were last, and the ISS's newest elements.
enum SharedStore {
    static let appGroup = "group.com.kotatko.sattracker"
    /// The widget's kind, for reloading its timelines.
    static let widgetKind = "NextISSPass"
    /// Opens the app on one satellite: sattracker://sat/25544
    static let urlScheme = "sattracker"

    static var defaults: UserDefaults { UserDefaults(suiteName: appGroup) ?? .standard }

    private static func load<T: Decodable>(_ key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private static func save<T: Encodable>(_ value: T?, _ key: String) {
        if let value, let data = try? JSONEncoder().encode(value) {
            defaults.set(data, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    /// Where the phone was last seen. Stays on the phone.
    static var observer: Geodetic? {
        get { load("observer") }
        set { save(newValue, "observer") }
    }

    struct StoredTle: Codable {
        var entry: TleEntry
        var fetched: Date
    }

    /// The ISS's elements and when they were fetched.
    static var iss: StoredTle? {
        get { load("iss") }
        set { save(newValue, "iss") }
    }

    static func url(norad: Int) -> URL { URL(string: "\(urlScheme)://sat/\(norad)")! }

    /// The catalogue number in a sattracker://sat/<n> link.
    static func norad(from url: URL) -> Int? {
        guard url.scheme == urlScheme, url.host() == "sat" else { return nil }
        return Int(url.lastPathComponent)
    }
}
