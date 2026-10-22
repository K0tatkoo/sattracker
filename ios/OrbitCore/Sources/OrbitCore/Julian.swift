import Foundation

/// Julian dates and sidereal time, as satellite.js 5.0.0 computes them.
public enum Julian {
    /// satellite.js `jday(year, mon, day, hr, minute, sec, msec)`.
    public static func jday(year: Double, mon: Double, day: Double, hr: Double, minute: Double, sec: Double, msec: Double = 0) -> Double {
        367 * year - floor(7 * (year + floor((mon + 9) / 12)) * 0.25) + floor(275 * mon / 9) + day + 1721013.5
            + ((msec / 60000 + sec / 60 + minute) / 60 + hr) / 24
    }

    /// satellite.js `jday(date)`: the UTC calendar fields of `date`, its
    /// milliseconds included. The fields come from plain arithmetic on the
    /// Unix time (no Calendar), so this is cheap enough to call every frame.
    public static func jday(_ date: Date) -> Double {
        let ms = date.timeIntervalSince1970 * 1000
        let days = floor(ms / 86_400_000)
        var rest = ms - days * 86_400_000
        let hr = floor(rest / 3_600_000); rest -= hr * 3_600_000
        let minute = floor(rest / 60_000); rest -= minute * 60_000
        let sec = floor(rest / 1000); rest -= sec * 1000
        let (y, m, d) = civil(fromDays: Int(days))
        return jday(year: Double(y), mon: Double(m), day: Double(d), hr: hr, minute: minute, sec: sec, msec: rest)
    }

    /// The date a Julian date (UTC) stands for.
    public static func date(_ jd: Double) -> Date {
        Date(timeIntervalSince1970: (jd - 2440587.5) * 86400)
    }

    /// Year, month and day of the `days`-th day after 1970-01-01 (proleptic
    /// Gregorian; Howard Hinnant's algorithm).
    static func civil(fromDays z0: Int) -> (Int, Int, Int) {
        let z = z0 + 719468
        let era = (z >= 0 ? z : z - 146096) / 146097
        let doe = z - era * 146097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
        let y = yoe + era * 400
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        return (m <= 2 ? y + 1 : y, m, d)
    }

    /// satellite.js `days2mdhms`: a day of the year with its fraction into
    /// month, day, hour, minute and seconds.
    public static func days2mdhms(year: Int, days: Double) -> (mon: Int, day: Int, hr: Int, minute: Int, sec: Double) {
        let lmonth = [31, year % 4 == 0 ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        let dayofyr = Int(floor(days))
        var i = 1
        var inttemp = 0
        while dayofyr > inttemp + lmonth[i - 1] && i < 12 {
            inttemp += lmonth[i - 1]
            i += 1
        }
        let mon = i
        let day = dayofyr - inttemp
        var temp = (days - Double(dayofyr)) * 24
        let hr = floor(temp)
        temp = (temp - hr) * 60
        let minute = floor(temp)
        let sec = (temp - minute) * 60
        return (mon, day, Int(hr), Int(minute), sec)
    }

    /// satellite.js `gstime`: Greenwich mean sidereal time, radians, for a
    /// Julian date (UT1, taken as UTC).
    public static func gstime(_ jdut1: Double) -> Double {
        let tut1 = (jdut1 - 2451545) / 36525
        var temp = -6.2e-6 * tut1 * tut1 * tut1 + 0.093104 * tut1 * tut1 + 3164400184.812866 * tut1 + 67310.54841
        temp = (temp * SGP4Constants.deg2rad / 240).truncatingRemainder(dividingBy: SGP4Constants.twoPi)
        if temp < 0 { temp += SGP4Constants.twoPi }
        return temp
    }
}

/// A place on the WGS-84 ellipsoid: radians, and km above it.
public struct Geodetic: Sendable, Hashable, Codable {
    public var latitude: Double
    public var longitude: Double
    public var height: Double

    public init(latitude: Double, longitude: Double, height: Double) {
        self.latitude = latitude
        self.longitude = longitude
        self.height = height
    }

    /// From degrees and metres, the way the page builds its observer.
    public init(latitudeDeg: Double, longitudeDeg: Double, altitudeM: Double) {
        self.init(latitude: latitudeDeg * SGP4Constants.deg2rad, longitude: longitudeDeg * SGP4Constants.deg2rad,
                  height: altitudeM / 1000)
    }

    public var latitudeDeg: Double { latitude * SGP4Constants.rad2deg }
    public var longitudeDeg: Double { longitude * SGP4Constants.rad2deg }
}

/// Where a satellite is in the sky from an observer.
public struct LookAngles: Sendable, Equatable {
    /// Radians clockwise from north.
    public var azimuth: Double
    /// Radians above the horizon.
    public var elevation: Double
    /// Distance, km.
    public var range: Double

    public var azimuthDeg: Double { azimuth * SGP4Constants.rad2deg }
    public var elevationDeg: Double { elevation * SGP4Constants.rad2deg }
}

/// satellite.js's coordinate transforms.
public enum Coordinates {
    /// `eciToGeodetic`: latitude by 20 fixed iterations on WGS-84, longitude
    /// wrapped to ±π.
    public static func eciToGeodetic(_ eci: SIMD3<Double>, gmst: Double) -> Geodetic {
        let a = 6378.137
        let b = 6356.7523142
        let r = (eci.x * eci.x + eci.y * eci.y).squareRoot()
        let f = (a - b) / a
        let e2 = 2 * f - f * f
        var longitude = atan2(eci.y, eci.x) - gmst
        while longitude < -SGP4Constants.pi { longitude += SGP4Constants.twoPi }
        while longitude > SGP4Constants.pi { longitude -= SGP4Constants.twoPi }
        var latitude = atan2(eci.z, (eci.x * eci.x + eci.y * eci.y).squareRoot())
        var c = 0.0
        for _ in 0..<20 {
            c = 1 / (1 - e2 * (sin(latitude) * sin(latitude))).squareRoot()
            latitude = atan2(eci.z + a * c * e2 * sin(latitude), r)
        }
        let height = r / cos(latitude) - a * c
        return Geodetic(latitude: latitude, longitude: longitude, height: height)
    }

    /// `eciToEcf`.
    public static func eciToEcf(_ eci: SIMD3<Double>, gmst: Double) -> SIMD3<Double> {
        SIMD3(eci.x * cos(gmst) + eci.y * sin(gmst),
              eci.x * -sin(gmst) + eci.y * cos(gmst),
              eci.z)
    }

    /// `ecfToEci`.
    public static func ecfToEci(_ ecf: SIMD3<Double>, gmst: Double) -> SIMD3<Double> {
        SIMD3(ecf.x * cos(gmst) - ecf.y * sin(gmst),
              ecf.x * sin(gmst) + ecf.y * cos(gmst),
              ecf.z)
    }

    /// `geodeticToEcf`.
    public static func geodeticToEcf(_ g: Geodetic) -> SIMD3<Double> {
        let a = 6378.137
        let b = 6356.7523142
        let f = (a - b) / a
        let e2 = 2 * f - f * f
        let normal = a / (1 - e2 * (sin(g.latitude) * sin(g.latitude))).squareRoot()
        return SIMD3((normal + g.height) * cos(g.latitude) * cos(g.longitude),
                     (normal + g.height) * cos(g.latitude) * sin(g.longitude),
                     (normal * (1 - e2) + g.height) * sin(g.latitude))
    }

    /// `ecfToLookAngles`.
    public static func ecfToLookAngles(_ observer: Geodetic, _ satellite: SIMD3<Double>) -> LookAngles {
        let lon = observer.longitude, lat = observer.latitude
        let o = geodeticToEcf(observer)
        let rx = satellite.x - o.x, ry = satellite.y - o.y, rz = satellite.z - o.z
        let topS = sin(lat) * cos(lon) * rx + sin(lat) * sin(lon) * ry - cos(lat) * rz
        let topE = -sin(lon) * rx + cos(lon) * ry
        let topZ = cos(lat) * cos(lon) * rx + cos(lat) * sin(lon) * ry + sin(lat) * rz
        let range = (topS * topS + topE * topE + topZ * topZ).squareRoot()
        let el = asin(topZ / range)
        let az = atan2(-topE, topS) + SGP4Constants.pi
        return LookAngles(azimuth: az, elevation: el, range: range)
    }
}
