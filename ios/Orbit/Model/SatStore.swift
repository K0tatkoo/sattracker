import Foundation
import OrbitCore
import simd

/// The satellites on the globe and where each one is this frame. Not
/// observable on purpose: it changes 60 times a second, and SwiftUI must not
/// redraw for that. The globe reads it every frame; the card reads it on its
/// own one-second clock.
@MainActor
final class SatStore {
    struct Sat {
        let entry: TleEntry
        let satrec: Satrec
        let category: SatCategory
        let norad: Int
        /// Propagated this frame (false when its orbit could not be worked out).
        var alive = false
        /// Scene position: the sub-point at 1 + height / 6371 Earth radii.
        var pos = SIMD3<Float>.zero
        var latDeg = 0.0
        var lonDeg = 0.0
        var heightKm = 0.0
        /// km/s
        var speed = 0.0
    }

    private(set) var sats: [Sat] = []
    /// Goes up whenever the list itself changes.
    private(set) var version = 0

    /// Earth radius in km that one scene unit stands for.
    static let earthRadiusKm = 6371.0

    /// A whole category's satellites, replacing what it had.
    func replace(_ category: SatCategory, with entries: [TleEntry]) {
        sats.removeAll { $0.category.id == category.id }
        for e in entries {
            guard let rec = e.satrec, let norad = e.norad else { continue }
            sats.append(Sat(entry: e, satrec: rec, category: category, norad: norad))
        }
        version += 1
    }

    func remove(category id: String) {
        sats.removeAll { $0.category.id == id }
        version += 1
    }

    func contains(category id: String) -> Bool { sats.contains { $0.category.id == id } }

    /// The first satellite with that number, in catalogue order (the ISS, not
    /// a ship docked to it, when both are listed).
    func index(norad: Int) -> Int? { sats.firstIndex { $0.norad == norad } }

    func sat(norad: Int) -> Sat? { index(norad: norad).map { sats[$0] } }

    /// Every satellite to `jd`. Recomputed every frame, so they move smoothly;
    /// one bad element set only takes itself off the globe.
    func propagate(jd: Double) {
        let gmst = Julian.gstime(jd)
        for i in sats.indices {
            guard let pv = sats[i].satrec.propagate(jd: jd) else {
                sats[i].alive = false
                continue
            }
            let gd = Coordinates.eciToGeodetic(pv.position, gmst: gmst)
            let r = 1 + gd.height / Self.earthRadiusKm
            let lat = gd.latitudeDeg, lon = gd.longitudeDeg
            let v = Self.sceneVector(latDeg: lat, lonDeg: lon, radius: r)
            guard v.x.isFinite, v.y.isFinite, v.z.isFinite else {
                sats[i].alive = false
                continue
            }
            sats[i].pos = v
            sats[i].latDeg = lat
            sats[i].lonDeg = lon
            sats[i].heightKm = gd.height
            sats[i].speed = (pv.velocity * pv.velocity).sum().squareRoot()
            sats[i].alive = true
        }
    }

    /// The page's llToVec3: Greenwich on +X, 90° west on +Z, north up.
    nonisolated static func sceneVector(latDeg: Double, lonDeg: Double, radius r: Double) -> SIMD3<Float> {
        let lat = latDeg * .pi / 180, lon = lonDeg * .pi / 180
        return SIMD3(Float(r * cos(lat) * cos(lon)), Float(r * sin(lat)), Float(-r * cos(lat) * sin(lon)))
    }
}
