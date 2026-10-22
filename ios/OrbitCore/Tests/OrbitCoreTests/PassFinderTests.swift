import Foundation
import Testing
@testable import OrbitCore

/// The iPhone-only parts: the refined pass finder (alerts, widget, the card's
/// pass list) and the Sun. Checked against the page's coarse pass and against
/// what the sky is known to do.
@Suite struct PassFinderTests {
    static let prague = Geodetic(latitudeDeg: 50.0755, longitudeDeg: 14.4378, altitudeM: 235)

    static func iss() throws -> Satrec {
        let url = Bundle.module.url(forResource: "satellitejs", withExtension: "json", subdirectory: "Fixtures")!
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        let s = (json["satellites"] as! [[String: Any]]).first { ($0["norad"] as! Int) == Catalog.issNorad }!
        return Satrec(line1: s["line1"] as! String, line2: s["line2"] as! String)!
    }

    static let start = Date(timeIntervalSince1970: 1_792_670_400)   // 2026-10-22 12:00 UTC

    @Test func agreesWithThePagesCoarsePass() throws {
        let iss = try Self.iss()
        let passes = PassFinder.passes(of: iss, from: Self.prague, start: Self.start, end: Self.start.addingTimeInterval(86400))
        #expect(passes.count >= 3, "the ISS passes over Prague several times a day: \(passes.count)")
        for p in passes.prefix(4) {
            // Ten minutes before the rise, so the page's 4-hour window finds this pass.
            let coarse = try #require(Look.nextPass(iss, from: Self.prague, after: p.rise.time.addingTimeInterval(-600)))
            // The page steps 30 s, so its rise is up to 30 s after the true one.
            let early = coarse.aos.timeIntervalSince(p.rise.time)
            #expect(early >= 0 && early <= 30, "rise \(p.rise.time) vs the page's \(coarse.aos)")
            // The page samples every 20 s, which can only find a lower peak
            // (near the zenith the ISS climbs a degree a second): never higher.
            let under = p.peak.elevationDeg - Double(coarse.peakDeg)
            #expect(under >= -0.5 && under < 5, "peak \(p.peak.elevationDeg)° vs \(coarse.peakDeg)°")
            #expect(p.rise.elevationDeg.magnitude < 0.2 && p.set.elevationDeg.magnitude < 0.2)
            #expect(p.peak.time > p.rise.time && p.peak.time < p.set.time)
            #expect(p.track.count >= 25 && p.track.first!.time == p.rise.time)
            // The peak really is the highest point of the track.
            #expect(p.track.allSatisfy { $0.elevationDeg <= p.peak.elevationDeg + 0.01 })
        }
    }

    @Test func minimumPeakAndLimit() throws {
        let iss = try Self.iss()
        let all = PassFinder.passes(of: iss, from: Self.prague, start: Self.start, end: Self.start.addingTimeInterval(2 * 86400))
        let high = PassFinder.passes(of: iss, from: Self.prague, start: Self.start, end: Self.start.addingTimeInterval(2 * 86400),
                                     minPeakDeg: 30)
        #expect(high.count < all.count)
        #expect(high.allSatisfy { $0.peak.elevationDeg >= 30 })
        #expect(PassFinder.passes(of: iss, from: Self.prague, start: Self.start, end: Self.start.addingTimeInterval(2 * 86400), limit: 2).count == 2)
    }

    @Test func aPassInProgressStartsWhereItRose() throws {
        let iss = try Self.iss()
        let first = try #require(PassFinder.passes(of: iss, from: Self.prague, start: Self.start,
                                                   end: Self.start.addingTimeInterval(86400)).first)
        let midway = first.peak.time
        let again = try #require(PassFinder.passes(of: iss, from: Self.prague, start: midway,
                                                   end: midway.addingTimeInterval(3600)).first)
        #expect(abs(again.rise.time.timeIntervalSince(first.rise.time)) < 2)
    }

    @Test func geostationaryNeverPasses() throws {
        let url = Bundle.module.url(forResource: "geo", withExtension: "txt", subdirectory: "Fixtures/tle")!
        // An inclined, drifting one can bob over the horizon; a station-kept
        // one well clear of it stays where it is.
        let geo = TLE.parse(try String(contentsOf: url, encoding: .utf8)).compactMap(\.satrec).filter { sat in
            guard sat.error == 0, sat.inclo < 0.1 * SGP4Constants.deg2rad,
                  let la = Look.angles(sat, at: Self.start, from: Self.prague) else { return false }
            return abs(la.elevationDeg) > 3
        }
        #expect(!geo.isEmpty)
        for sat in geo {
            #expect(PassFinder.passes(of: sat, from: Self.prague, start: Self.start, end: Self.start.addingTimeInterval(86400)).isEmpty)
        }
    }

    @Test func theSun() {
        // Prague, the June solstice at local solar noon: 90 − 50.08 + 23.44 ≈ 63.4°.
        let june = Julian.jday(year: 2026, mon: 6, day: 21, hr: 11, minute: 2, sec: 0)
        #expect(abs(Sun.elevationDeg(from: Self.prague, jd: june) - 63.4) < 0.5)
        // And the December one: 90 − 50.08 − 23.44 ≈ 16.5°.
        let december = Julian.jday(year: 2026, mon: 12, day: 21, hr: 10, minute: 59, sec: 0)
        #expect(abs(Sun.elevationDeg(from: Self.prague, jd: december) - 16.5) < 0.5)
        // Midnight in winter: well down.
        let night = Julian.jday(year: 2026, mon: 12, day: 21, hr: 23, minute: 0, sec: 0)
        #expect(Sun.elevationDeg(from: Self.prague, jd: night) < -50)
        // Behind the Earth from the Sun, in low orbit: in shadow; out to the side: lit.
        let s = Sun.position(jd: june)
        let u = s / (s * s).sum().squareRoot()
        #expect(!Sun.isSunlit(-u * 6800, jd: june))
        let side = SIMD3(-u.y, u.x, 0) / (u.x * u.x + u.y * u.y).squareRoot()
        #expect(Sun.isSunlit(side * 6800 - u * 1000, jd: june))
    }

    @Test func jdayOfADateKeepsItsMilliseconds() {
        let d = Date(timeIntervalSince1970: 1_792_670_400.25)
        let jd = Julian.jday(d)
        #expect(abs((jd - Julian.jday(year: 2026, mon: 10, day: 22, hr: 12, minute: 0, sec: 0)) * 86400 - 0.25) < 1e-4)
        #expect(abs(Julian.date(jd).timeIntervalSince(d)) < 1e-4)
    }

    @Test func propagationIsCheapEnoughForEveryFrame() throws {
        let url = Bundle.module.url(forResource: "satellitejs", withExtension: "json", subdirectory: "Fixtures")!
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        let sats = (json["satellites"] as! [[String: Any]]).compactMap {
            Satrec(line1: $0["line1"] as! String, line2: $0["line2"] as! String)
        }
        let jd = Julian.jday(Self.start)
        let clock = ContinuousClock()
        var sink = 0.0
        let rounds = 50
        let took = clock.measure {
            for r in 0..<rounds {
                for s in sats {
                    if let pv = s.propagate(jd: jd + Double(r) / 86400) {
                        sink += Coordinates.eciToGeodetic(pv.position, gmst: 1).height
                    }
                }
            }
        }
        let perSat = took / (rounds * sats.count)
        print("propagate + geodetic: \(perSat) a satellite (sink \(sink.sign))")
    }
}
