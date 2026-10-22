import Foundation

/// Where a satellite is in the sky, and when it passes over.
public enum Look {
    /// The page's `lookAnglesAt`: propagate, rotate into the Earth-fixed
    /// frame, look from the observer. Nil when the orbit cannot be propagated.
    public static func angles(_ sat: Satrec, jd: Double, from observer: Geodetic) -> LookAngles? {
        guard let pv = sat.propagate(jd: jd) else { return nil }
        let ecf = Coordinates.eciToEcf(pv.position, gmst: Julian.gstime(jd))
        return Coordinates.ecfToLookAngles(observer, ecf)
    }

    public static func angles(_ sat: Satrec, at date: Date, from observer: Geodetic) -> LookAngles? {
        angles(sat, jd: Julian.jday(date), from: observer)
    }

    /// The page's `nextRise`: the first moment, on a 30-second grid after
    /// `from`, that the satellite is at `maskDeg` or higher having been below
    /// it, looking `horizonMinutes` ahead.
    public static func nextRise(_ sat: Satrec, from observer: Geodetic, after from: Date,
                                maskDeg: Double = 5, horizonMinutes: Double = 180) -> (time: Date, seconds: Double)?
    {
        guard var prev = angles(sat, at: from, from: observer) else { return nil }
        let step = 30.0
        let end = horizonMinutes * 60
        var s = step
        while s <= end {
            let d = from.addingTimeInterval(s)
            if let la = angles(sat, at: d, from: observer) {
                if prev.elevationDeg < maskDeg && la.elevationDeg >= maskDeg { return (d, s) }
                prev = la
            }
            s += step
        }
        return nil
    }

    /// The page's `nextPass` (the card's one line): the next rise above the
    /// horizon within 4 hours, the highest it gets (20-second steps, whole
    /// degrees) and roughly how long it stays up, in whole minutes.
    public static func nextPass(_ sat: Satrec, from observer: Geodetic, after from: Date)
        -> (aos: Date, peakDeg: Int, minutes: Int?)?
    {
        guard let rise = nextRise(sat, from: observer, after: from, maskDeg: 0, horizonMinutes: 240) else { return nil }
        var peak = 0.0
        var setAt: Double?
        var s = 0.0
        while s < 40 * 60 {
            guard let la = angles(sat, at: rise.time.addingTimeInterval(s), from: observer) else { break }
            if la.elevationDeg > peak { peak = la.elevationDeg }
            if la.elevationDeg < 0 { setAt = s; break }
            s += 20
        }
        return (rise.time, jsRound(peak), setAt.map { jsRound($0 / 60) })
    }

    /// JavaScript's Math.round: halves go up.
    static func jsRound(_ x: Double) -> Int {
        let f = floor(x)
        return Int(x - f >= 0.5 ? f + 1 : f)
    }
}

/// A point on a pass's path across the sky.
public struct SkyPoint: Sendable, Hashable, Codable {
    public var time: Date
    public var azimuthDeg: Double
    public var elevationDeg: Double

    public init(time: Date, azimuthDeg: Double, elevationDeg: Double) {
        self.time = time
        self.azimuthDeg = azimuthDeg
        self.elevationDeg = elevationDeg
    }
}

/// One pass of a satellite over an observer, rise to set.
public struct Pass: Sendable, Hashable, Codable {
    public var rise: SkyPoint
    public var peak: SkyPoint
    public var set: SkyPoint
    /// Some of it can be seen with the naked eye: above 10°, in sunlight,
    /// while the sky where you are is dark (the Sun 6° or more below).
    public var visible: Bool
    /// The path across the sky, rise to set, about 30 points.
    public var track: [SkyPoint]

    public var duration: TimeInterval { self.set.time.timeIntervalSince(rise.time) }

    public init(rise: SkyPoint, peak: SkyPoint, set: SkyPoint, visible: Bool, track: [SkyPoint]) {
        self.rise = rise
        self.peak = peak
        self.set = set
        self.visible = visible
        self.track = track
    }
}

/// Every pass in a window, with rise, peak and set found to about a second.
/// The alerts and the widget use this; the card's one-line pass is the
/// page's own `Look.nextPass`, so the two apps say the same thing there.
public enum PassFinder {
    public static func passes(of sat: Satrec, from observer: Geodetic, start: Date, end: Date,
                              minPeakDeg: Double = 0, limit: Int = .max) -> [Pass]
    {
        // Low orbits need a fine grid or a short, low pass falls between two
        // samples; a 12-hour orbit drifts slowly.
        let step: TimeInterval = sat.periodMinutes < 225 ? 30 : 120
        func el(_ t: Date) -> Double {
            Look.angles(sat, at: t, from: observer)?.elevationDeg ?? -90
        }

        var out: [Pass] = []
        var t = start
        var prevEl = el(t)
        // Already up: go back to where this pass rose.
        if prevEl > 0 {
            var back = start
            let limitBack = start.addingTimeInterval(-sat.periodMinutes * 60)
            while back > limitBack && el(back) > 0 { back.addTimeInterval(-step) }
            if el(back) > 0 { t = start } else { t = back; prevEl = el(t) }
        }

        while t < end && out.count < limit {
            let next = t.addingTimeInterval(step)
            let nextEl = el(next)
            if prevEl <= 0 && nextEl > 0 {
                let rise = crossing(el, t, next, rising: true)
                // Walk to the set, tracking the highest sample.
                var u = next, uEl = nextEl, best = next, bestEl = nextEl
                let giveUp = rise.addingTimeInterval(max(sat.periodMinutes * 60, 3600))
                while uEl > 0 && u < giveUp {
                    u.addTimeInterval(step)
                    uEl = el(u)
                    if uEl > bestEl { best = u; bestEl = uEl }
                }
                guard uEl <= 0 else { break }    // never sets (geostationary): not a pass
                let set = crossing(el, u.addingTimeInterval(-step), u, rising: false)
                let peak = peakTime(el, around: best, step: step, lower: rise, upper: set)
                if let pass = makePass(sat, observer, rise: rise, peak: peak, set: set), pass.peak.elevationDeg >= minPeakDeg {
                    out.append(pass)
                }
                t = u
                prevEl = uEl
                continue
            }
            t = next
            prevEl = nextEl
        }
        return out
    }

    /// The moment between `a` and `b` that the elevation crosses 0°, to half a second.
    static func crossing(_ el: (Date) -> Double, _ a: Date, _ b: Date, rising: Bool) -> Date {
        var lo = a, hi = b
        while hi.timeIntervalSince(lo) > 0.5 {
            let mid = lo.addingTimeInterval(hi.timeIntervalSince(lo) / 2)
            if (el(mid) > 0) == rising { hi = mid } else { lo = mid }
        }
        return rising ? hi : lo
    }

    /// The highest moment near `around`, by golden-section search, to a second.
    static func peakTime(_ el: (Date) -> Double, around: Date, step: TimeInterval, lower: Date, upper: Date) -> Date {
        var a = max(around.addingTimeInterval(-step), lower)
        var b = min(around.addingTimeInterval(step), upper)
        let g = (5.0.squareRoot() - 1) / 2
        var c = b.addingTimeInterval(-g * b.timeIntervalSince(a))
        var d = a.addingTimeInterval(g * b.timeIntervalSince(a))
        var fc = el(c), fd = el(d)
        while b.timeIntervalSince(a) > 1 {
            if fc > fd {
                b = d; d = c; fd = fc
                c = b.addingTimeInterval(-g * b.timeIntervalSince(a)); fc = el(c)
            } else {
                a = c; c = d; fc = fd
                d = a.addingTimeInterval(g * b.timeIntervalSince(a)); fd = el(d)
            }
        }
        return a.addingTimeInterval(b.timeIntervalSince(a) / 2)
    }

    static func makePass(_ sat: Satrec, _ observer: Geodetic, rise: Date, peak: Date, set: Date) -> Pass? {
        func point(_ t: Date) -> SkyPoint? {
            guard let la = Look.angles(sat, at: t, from: observer) else { return nil }
            return SkyPoint(time: t, azimuthDeg: la.azimuthDeg, elevationDeg: la.elevationDeg)
        }
        guard let r = point(rise), let p = point(peak), let s = point(set) else { return nil }
        let samples = 30
        let span = set.timeIntervalSince(rise)
        var track: [SkyPoint] = []
        var visible = false
        for i in 0...samples {
            let t = rise.addingTimeInterval(span * Double(i) / Double(samples))
            guard let sp = point(t) else { continue }
            track.append(sp)
            if !visible && sp.elevationDeg >= 10 {
                let jd = Julian.jday(t)
                if let pv = sat.propagate(jd: jd), Sun.isSunlit(pv.position, jd: jd),
                   Sun.elevationDeg(from: observer, jd: jd) <= -6
                {
                    visible = true
                }
            }
        }
        return Pass(rise: r, peak: p, set: s, visible: visible, track: track)
    }
}

/// The Sun, to the hundredth of a degree or so: enough to say whether a
/// satellite is lit and the sky is dark.
public enum Sun {
    /// The Sun in the same Earth-centred frame as SGP4's output, km
    /// (Astronomical Almanac low-precision formulae).
    public static func position(jd: Double) -> SIMD3<Double> {
        let d2r = SGP4Constants.deg2rad
        let n = jd - 2451545.0
        let l = (280.460 + 0.9856474 * n) * d2r
        let g = (357.528 + 0.9856003 * n) * d2r
        let lambda = l + (1.915 * sin(g) + 0.020 * sin(2 * g)) * d2r
        let epsilon = (23.439 - 0.0000004 * n) * d2r
        let au = 1.00014 - 0.01671 * cos(g) - 0.00014 * cos(2 * g)
        let km = au * 149_597_870.7
        return SIMD3(km * cos(lambda), km * cos(epsilon) * sin(lambda), km * sin(epsilon) * sin(lambda))
    }

    /// Outside the Earth's shadow (a cylinder; the penumbra is a few seconds).
    public static func isSunlit(_ satellite: SIMD3<Double>, jd: Double) -> Bool {
        let s = position(jd: jd)
        let u = s / (s * s).sum().squareRoot()
        let along = (satellite * u).sum()
        if along > 0 { return true }
        let perp = satellite - along * u
        return (perp * perp).sum().squareRoot() > 6378.137
    }

    /// How high the Sun is over the observer, degrees.
    public static func elevationDeg(from observer: Geodetic, jd: Double) -> Double {
        let ecf = Coordinates.eciToEcf(position(jd: jd), gmst: Julian.gstime(jd))
        return Coordinates.ecfToLookAngles(observer, ecf).elevationDeg
    }
}
