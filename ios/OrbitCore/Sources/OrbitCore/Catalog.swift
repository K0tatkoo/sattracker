import Foundation

/// A group of satellites the user can switch on and off: one Celestrak GROUP.
public struct SatCategory: Sendable, Hashable, Identifiable {
    public let id: String
    /// Celestrak's GROUP parameter.
    public let group: String
    public let label: String
    /// Never more than this many on the globe (Starlink alone is thousands).
    public let cap: Int
    public let defaultOn: Bool
    public let gnss: Bool
}

/// The page's CATEGORIES and resolveMeta, value for value.
public enum Catalog {
    public static let categories: [SatCategory] = [
        SatCategory(id: "stations", group: "stations", label: "ISS & Stations", cap: 40, defaultOn: true, gnss: false),
        SatCategory(id: "gps", group: "gps-ops", label: "GPS", cap: 40, defaultOn: true, gnss: true),
        SatCategory(id: "glonass", group: "glo-ops", label: "GLONASS", cap: 40, defaultOn: false, gnss: true),
        SatCategory(id: "galileo", group: "galileo", label: "Galileo", cap: 40, defaultOn: false, gnss: true),
        SatCategory(id: "beidou", group: "beidou", label: "BeiDou", cap: 60, defaultOn: false, gnss: true),
        SatCategory(id: "starlink", group: "starlink", label: "Starlink", cap: 300, defaultOn: false, gnss: false),
        SatCategory(id: "weather", group: "weather", label: "Weather", cap: 40, defaultOn: false, gnss: false),
        SatCategory(id: "science", group: "science", label: "Science", cap: 40, defaultOn: false, gnss: false),
    ]

    /// Satellites found by searching Celestrak that belong to none of the
    /// groups above. iPhone only.
    public static let pinned = SatCategory(id: "pinned", group: "", label: "Pinned", cap: 50, defaultOn: true, gnss: false)

    public static func category(id: String) -> SatCategory? {
        id == pinned.id ? pinned : categories.first { $0.id == id }
    }

    /// The ISS's catalogue number: the widget's satellite.
    public static let issNorad = 25544

    public struct Meta: Sendable, Hashable {
        public var country: String
        public var operatorName: String
        public var purpose: String
    }

    /// Country, operator and purpose from the group and a few well-known names.
    public static func meta(name: String, group: String) -> Meta {
        let n = name.uppercased()
        let base: (String, String, String) = switch group {
        case "gps-ops": ("USA", "US Space Force", "Navigation (GPS)")
        case "glo-ops": ("Russia", "Roscosmos / VKS", "Navigation (GLONASS)")
        case "galileo": ("European Union", "EUSPA / ESA", "Navigation (Galileo)")
        case "beidou": ("China", "CNSA", "Navigation (BeiDou)")
        case "starlink": ("USA", "SpaceX", "Broadband internet")
        case "stations": ("International", "Multiple agencies", "Crewed space station")
        case "weather": ("Various", "Meteorological agencies", "Weather observation")
        case "science": ("Various", "Research institutions", "Scientific research")
        default: ("Unknown", "Unknown", "—")
        }
        var m = Meta(country: base.0, operatorName: base.1, purpose: base.2)
        if n.contains("ISS") || n.contains("ZARYA") {
            m = Meta(country: "International", operatorName: "NASA / Roscosmos / ESA / JAXA / CSA", purpose: "Crewed space station")
        } else if n.contains("CSS") || n.contains("TIANHE") {
            m = Meta(country: "China", operatorName: "CMSA", purpose: "Crewed space station")
        } else if n.contains("NOAA") {
            m = Meta(country: "USA", operatorName: "NOAA", purpose: "Weather observation")
        } else if n.contains("METEOR") {
            m = Meta(country: "Russia", operatorName: "Roshydromet", purpose: "Weather observation")
        } else if n.contains("METOP") {
            m = Meta(country: "European Union", operatorName: "EUMETSAT", purpose: "Weather observation")
        } else if n.contains("HUBBLE") || n.contains("HST") {
            m = Meta(country: "USA", operatorName: "NASA / ESA", purpose: "Space telescope")
        } else if n.contains("TERRA") || n.contains("AQUA") || n.contains("LANDSAT") {
            m = Meta(country: "USA", operatorName: "NASA / USGS", purpose: "Earth observation")
        }
        return m
    }
}
