import Foundation
import Testing
@testable import OrbitCore

/// The Swift port against satellite.js itself: Fixtures/satellitejs.json is
/// what satellite.min.js (the Android page's copy) computed for the same TLEs,
/// moments and observers (`node ios/tools/sgp4-fixtures.mjs`).
///
/// Tolerances: both sides do the same IEEE arithmetic in the same order; only
/// the libm functions (V8's fdlibm port against Darwin's) may differ in the
/// last bit, which the Kepler iteration and the resonance integration carry
/// along. Measured on 2026-10-22: 6e-11 km worst in position (a few hundred
/// nanometres of slack is left below), 4e-15 rad in angle; a wrong term in
/// SGP4 is kilometres off.
@Suite struct SatelliteJsTests {
    nonisolated(unsafe) static let fixture: [String: Any] = {
        let url = Bundle.module.url(forResource: "satellitejs", withExtension: "json", subdirectory: "Fixtures")!
        return try! JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    }()
    static var satellites: [[String: Any]] { fixture["satellites"] as! [[String: Any]] }

    static func vec(_ any: Any?) -> SIMD3<Double>? {
        guard let a = any as? [Double], a.count == 3 else { return nil }
        return SIMD3(a[0], a[1], a[2])
    }

    static func maxDiff(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
        let d = a - b
        return max(abs(d.x), abs(d.y), abs(d.z))
    }

    @Test func initialisesLikeSatelliteJs() throws {
        for s in Self.satellites {
            let rec = try #require(Satrec(line1: s["line1"] as! String, line2: s["line2"] as! String))
            let i = s["init"] as! [String: Any]
            let name = s["name"] as! String
            for (key, mine) in [("no", rec.no), ("ecco", rec.ecco), ("inclo", rec.inclo), ("nodeo", rec.nodeo),
                                ("argpo", rec.argpo), ("mo", rec.mo), ("bstar", rec.bstar),
                                ("jdsatepoch", rec.jdsatepoch), ("gsto", rec.gsto)]
            {
                let theirs = i[key] as! Double
                #expect(abs(mine - theirs) <= 1e-12 * max(1, abs(theirs)), "\(name) \(key): \(mine) vs \(theirs)")
            }
            #expect(rec.deepSpace == ((i["method"] as! String) == "d"), "\(name) method")
            #expect(rec.irez == (i["irez"] as! Int), "\(name) irez")
            #expect(rec.isimp == (i["isimp"] as! Int), "\(name) isimp")
        }
    }

    @Test func propagatesLikeSatelliteJs() throws {
        var worstR = 0.0, worstV = 0.0
        for s in Self.satellites {
            let rec = try #require(Satrec(line1: s["line1"] as! String, line2: s["line2"] as! String))
            let name = s["name"] as! String
            for case let step as [String: Any] in s["sgp4"] as! [Any] {
                let m = step["tsince"] as! Double
                let mine = rec.sgp4(tsince: m)
                guard let result = step["result"] as? [String: Any] else {
                    #expect(mine == nil, "\(name) at \(m) min should fail as in satellite.js")
                    continue
                }
                let got = try #require(mine, "\(name) at \(m) min failed; satellite.js propagated it")
                let dr = Self.maxDiff(got.position, Self.vec(result["r"])!)
                let dv = Self.maxDiff(got.velocity, Self.vec(result["v"])!)
                worstR = max(worstR, dr)
                worstV = max(worstV, dv)
                #expect(dr < 1e-8, "\(name) at \(m) min: position off by \(dr) km")
                #expect(dv < 1e-12, "\(name) at \(m) min: velocity off by \(dv) km/s")
            }
        }
        print("sgp4: worst position \(worstR) km, velocity \(worstV) km/s")
    }

    @Test func datesSiderealTimeAndLookAngles() throws {
        let observers = (Self.fixture["observers"] as! [[String: Any]]).map {
            Geodetic(latitudeDeg: $0["lat"] as! Double, longitudeDeg: $0["lon"] as! Double, altitudeM: $0["alt"] as! Double)
        }
        var worst = (r: 0.0, ang: 0.0, h: 0.0)
        for s in Self.satellites {
            let rec = try #require(Satrec(line1: s["line1"] as! String, line2: s["line2"] as! String))
            let name = s["name"] as! String
            for case let at as [String: Any] in s["at"] as! [Any] {
                let date = Date(timeIntervalSince1970: (at["ms"] as! Double) / 1000)
                let jd = Julian.jday(date)
                #expect(abs(jd - (at["jd"] as! Double)) < 1e-9, "\(name): jday \(jd) vs \(at["jd"]!)")
                let gmst = Julian.gstime(jd)
                #expect(abs(gmst - (at["gmst"] as! Double)) < 1e-9, "\(name): gstime")
                let mine = rec.propagate(jd: jd)
                guard let result = at["result"] as? [String: Any] else {
                    #expect(mine == nil, "\(name) should fail at \(date) as in satellite.js")
                    continue
                }
                let got = try #require(mine)
                let dr = Self.maxDiff(got.position, Self.vec(result["r"])!)
                worst.r = max(worst.r, dr)
                #expect(dr < 1e-8, "\(name) at \(date): \(dr) km")

                let gd = Coordinates.eciToGeodetic(got.position, gmst: gmst)
                let want = at["geodetic"] as! [Double]
                let dAng = max(abs(gd.latitude - want[0]), abs(gd.longitude - want[1]))
                worst.ang = max(worst.ang, dAng)
                worst.h = max(worst.h, abs(gd.height - want[2]))
                #expect(dAng < 1e-12, "\(name): sub-point off by \(dAng) rad")
                #expect(abs(gd.height - want[2]) < 1e-8, "\(name): height")

                let ecf = Coordinates.eciToEcf(got.position, gmst: gmst)
                for (o, look) in zip(observers, at["look"] as! [[Double]]) {
                    let la = Coordinates.ecfToLookAngles(o, ecf)
                    #expect(abs(la.azimuth - look[0]) < 1e-11 && abs(la.elevation - look[1]) < 1e-11,
                            "\(name): look angles \(la) vs \(look)")
                    #expect(abs(la.range - look[2]) < 1e-8, "\(name): range")
                }
            }
        }
        print("propagate: worst position \(worst.r) km, sub-point \(worst.ang) rad, height \(worst.h) km")
    }

    @Test func passesLikeThePage() throws {
        let observers = Dictionary(uniqueKeysWithValues: (Self.fixture["observers"] as! [[String: Any]]).map {
            ($0["name"] as! String,
             Geodetic(latitudeDeg: $0["lat"] as! Double, longitudeDeg: $0["lon"] as! Double, altitudeM: $0["alt"] as! Double))
        })
        let byNorad = Dictionary(Self.satellites.map { ($0["norad"] as! Int, $0) }, uniquingKeysWith: { a, _ in a })
        for p in Self.fixture["passes"] as! [[String: Any]] {
            let s = byNorad[p["norad"] as! Int]!
            let rec = try #require(Satrec(line1: s["line1"] as! String, line2: s["line2"] as! String))
            let obs = observers[p["observer"] as! String]!
            let from = Date(timeIntervalSince1970: (p["from"] as! Double) / 1000)
            let label = "\(s["name"]!) over \(p["observer"]!) from \(from)"

            let rise = Look.nextRise(rec, from: obs, after: from)
            if let want = p["rise"] as? [String: Any] {
                let got = try #require(rise, "\(label): no rise; the page found one")
                #expect(abs(got.time.timeIntervalSince1970 * 1000 - (want["ms"] as! Double)) < 0.5, "\(label): rise")
                #expect(got.seconds == want["secs"] as! Double, "\(label): rise seconds")
            } else {
                #expect(rise == nil, "\(label): a rise the page did not find")
            }

            let pass = Look.nextPass(rec, from: obs, after: from)
            if let want = p["pass"] as? [String: Any] {
                let got = try #require(pass, "\(label): no pass; the page found one")
                #expect(abs(got.aos.timeIntervalSince1970 * 1000 - (want["aos"] as! Double)) < 0.5, "\(label): AOS")
                #expect(got.peakDeg == want["peakEl"] as! Int, "\(label): peak")
                #expect(got.minutes == want["durMin"] as? Int, "\(label): duration")
            } else {
                #expect(pass == nil, "\(label): a pass the page did not find")
            }
        }
    }

    @Test func calendarArithmetic() {
        for c in Self.fixture["calendar"] as! [[String: Any]] {
            let a = c["args"] as! [Double]
            let jd = Julian.jday(year: a[0], mon: a[1], day: a[2], hr: a[3], minute: a[4], sec: a[5], msec: a[6])
            #expect(jd == c["jday"] as! Double, "jday \(a)")
            #expect(abs(Julian.gstime(jd) - (c["gstime"] as! Double)) < 1e-12, "gstime \(a)")
        }
    }

    @Test func readsCelestrakFilesWithCrlf() throws {
        let dir = Bundle.module.url(forResource: "tle", withExtension: nil, subdirectory: "Fixtures")!
        for f in try FileManager.default.contentsOfDirectory(atPath: dir.path) where f.hasSuffix(".txt") {
            let text = try String(contentsOf: dir.appendingPathComponent(f), encoding: .utf8)
            #expect(text.contains("\r\n"))
            let entries = TLE.parse(text)
            #expect(entries.count == 12, "\(f): \(entries.count)")
            #expect(entries.allSatisfy { $0.norad != nil && !$0.name.isEmpty })
            #expect(TLE.looksLikeTle(text))
        }
        // The page's resync: a missing name line costs one satellite, not the file.
        let lines = try String(contentsOf: dir.appendingPathComponent("geo.txt"), encoding: .utf8)
            .split(separator: "\r\n").map(String.init)
        let broken = (Array(lines[1...]) ).joined(separator: "\r\n")
        #expect(TLE.parse(broken).count == 11)
        #expect(TLE.parse("x\n1 2\n", cap: 5).isEmpty)
    }
}
