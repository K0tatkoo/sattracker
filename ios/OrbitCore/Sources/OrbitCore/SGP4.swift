import Foundation

// SGP4 / SDP4, ported line for line from satellite.js 5.0.0 — the copy the
// Android app's page runs (app/src/main/assets/lib/satellite.min.js), which is
// itself David Vallado's 2006 C++ ("Revisiting Spacetrack Report #3"), with
// the WGS-72 constants and the "improved" operation mode.
//
// Where satellite.js orders a sum differently from Vallado's C++ (the minifier
// keeps the JavaScript's own order), this file follows satellite.js, so the
// two apps agree to the last bits; the fixtures in OrbitCoreTests hold them
// together. Names are Vallado's, as in the unminified satellite.js.
//
// Two things satellite.js does that this keeps on purpose:
// - The deep-space resonance integrator restarts from epoch on every call
//   (satellite.js never writes atime/xli/xni back), so a propagation never
//   depends on the one before it.
// - propagate() takes a Julian date made from the UTC calendar fields, the way
//   satellite.js's jday(Date) does, not from a running seconds count.

/// WGS-72, as satellite.js has them. `xke` is 60/sqrt(earthRadius³/mu) with
/// the cube already taken, exactly as the minified file carries it.
public enum SGP4Constants {
    public static let pi = Double.pi
    public static let twoPi = 2 * Double.pi
    public static let deg2rad = Double.pi / 180
    public static let rad2deg = 180 / Double.pi
    public static let minutesPerDay = 1440.0
    public static let mu = 398600.8
    public static let earthRadius = 6378.135
    public static let xke = 60 / (650942.9922085947).squareRoot()
    public static let vkmpersec = earthRadius * xke / 60
    public static let tumin = 1 / xke
    public static let j2 = 0.001082616
    public static let j3 = -0.00000253881
    public static let j4 = -0.00000165597
    public static let j3oj2 = j3 / j2
    public static let x2o3 = 2.0 / 3.0
}

private let pi = SGP4Constants.pi
private let twoPi = SGP4Constants.twoPi
private let deg2rad = SGP4Constants.deg2rad
private let earthRadius = SGP4Constants.earthRadius
private let xke = SGP4Constants.xke
private let vkmpersec = SGP4Constants.vkmpersec
private let tumin = SGP4Constants.tumin
private let j2 = SGP4Constants.j2
private let j4 = SGP4Constants.j4
private let j3oj2 = SGP4Constants.j3oj2
private let x2o3 = SGP4Constants.x2o3

/// A position and velocity in TEME (the true-equator, mean-equinox frame SGP4
/// works in), km and km/s.
public struct StateVector: Sendable, Equatable {
    public var position: SIMD3<Double>
    public var velocity: SIMD3<Double>
}

/// One satellite's orbit, initialised from its two-line element set.
/// A value: propagating it changes nothing, so it can be shared freely.
public struct Satrec: Sendable {
    // From the TLE
    public var satnum = ""
    public var epochyr = 0
    public var epochdays = 0.0
    public var ndot = 0.0
    public var nddot = 0.0
    public var bstar = 0.0
    public var inclo = 0.0
    public var nodeo = 0.0
    public var ecco = 0.0
    public var argpo = 0.0
    public var mo = 0.0
    /// Mean motion, radians per minute (un-Kozai'd once initialised).
    public var no = 0.0
    public var jdsatepoch = 0.0

    /// 0 when fine; Vallado's codes otherwise (1 eccentricity, 2 mean motion,
    /// 3 perturbed eccentricity, 4 semi-latus rectum, 6 decayed).
    public var error = 0

    // Set by sgp4init
    var isimp = 0
    var deepSpace = false
    var aycof = 0.0, con41 = 0.0, cc1 = 0.0, cc4 = 0.0, cc5 = 0.0
    var d2 = 0.0, d3 = 0.0, d4 = 0.0, delmo = 0.0, eta = 0.0
    var argpdot = 0.0, omgcof = 0.0, sinmao = 0.0
    var t2cof = 0.0, t3cof = 0.0, t4cof = 0.0, t5cof = 0.0
    var x1mth2 = 0.0, x7thm1 = 0.0, mdot = 0.0, nodedot = 0.0
    var xlcof = 0.0, xmcof = 0.0, nodecf = 0.0
    var irez = 0
    var d2201 = 0.0, d2211 = 0.0, d3210 = 0.0, d3222 = 0.0, d4410 = 0.0, d4422 = 0.0
    var d5220 = 0.0, d5232 = 0.0, d5421 = 0.0, d5433 = 0.0
    var dedt = 0.0, del1 = 0.0, del2 = 0.0, del3 = 0.0, didt = 0.0, dmdt = 0.0, dnodt = 0.0, domdt = 0.0
    var e3 = 0.0, ee2 = 0.0, peo = 0.0, pgho = 0.0, pho = 0.0, pinco = 0.0, plo = 0.0
    var se2 = 0.0, se3 = 0.0, sgh2 = 0.0, sgh3 = 0.0, sgh4 = 0.0, sh2 = 0.0, sh3 = 0.0
    var si2 = 0.0, si3 = 0.0, sl2 = 0.0, sl3 = 0.0, sl4 = 0.0
    public internal(set) var gsto = 0.0
    var xfact = 0.0, xgh2 = 0.0, xgh3 = 0.0, xgh4 = 0.0, xh2 = 0.0, xh3 = 0.0
    var xi2 = 0.0, xi3 = 0.0, xl2 = 0.0, xl3 = 0.0, xl4 = 0.0, xlamo = 0.0
    var zmol = 0.0, zmos = 0.0, atime = 0.0, xli = 0.0, xni = 0.0
    /// Semi-major axis in Earth radii, and apogee / perigee heights above the
    /// surface, also in Earth radii.
    public internal(set) var a = 0.0
    public internal(set) var alta = 0.0
    public internal(set) var altp = 0.0

    /// The orbital period in minutes.
    public var periodMinutes: Double { twoPi / no }

    /// satellite.js `twoline2satrec`. The fields are cut by column and read
    /// the way JavaScript's parseFloat/parseInt read them, quirks included.
    /// Returns nil only for lines too short to be a TLE; a TLE that parses
    /// but cannot be propagated comes back with `error` set.
    public init?(line1: String, line2: String) {
        let l1 = Array(line1.utf8), l2 = Array(line2.utf8)
        guard l1.count >= 61, l2.count >= 63 else { return nil }
        let xpdotp = 1440 / (2 * pi)

        satnum = Self.sub(l1, 2, 7)
        epochyr = Int(JS.parseInt(Self.sub(l1, 18, 20)) ?? 0)
        epochdays = JS.parseFloat(Self.sub(l1, 20, 32))
        ndot = JS.parseFloat(Self.sub(l1, 33, 43))
        nddot = JS.parseFloat("." + JS.parseIntString(Self.sub(l1, 44, 50)) + "E" + Self.sub(l1, 50, 52))
        bstar = JS.parseFloat(Self.sub(l1, 53, 54) + "." + JS.parseIntString(Self.sub(l1, 54, 59)) + "E" + Self.sub(l1, 59, 61))
        inclo = JS.parseFloat(Self.sub(l2, 8, 16))
        nodeo = JS.parseFloat(Self.sub(l2, 17, 25))
        ecco = JS.parseFloat("." + Self.sub(l2, 26, 33))
        argpo = JS.parseFloat(Self.sub(l2, 34, 42))
        mo = JS.parseFloat(Self.sub(l2, 43, 51))
        no = JS.parseFloat(Self.sub(l2, 52, 63))

        no /= xpdotp
        inclo *= deg2rad
        nodeo *= deg2rad
        argpo *= deg2rad
        mo *= deg2rad

        let year = epochyr < 57 ? epochyr + 2000 : epochyr + 1900
        let t = Julian.days2mdhms(year: year, days: epochdays)
        jdsatepoch = Julian.jday(year: Double(year), mon: Double(t.mon), day: Double(t.day),
                                 hr: Double(t.hr), minute: Double(t.minute), sec: t.sec)
        sgp4init(epoch: jdsatepoch - 2433281.5)
    }

    /// The NORAD catalogue number, as the page reads it: parseInt of columns
    /// 2–7 of line 2 (an Alpha-5 number reads as nil, as it reads NaN there).
    public static func noradId(line2: String) -> Int? {
        let l2 = Array(line2.utf8)
        guard let n = JS.parseInt(sub(l2, 2, 7)) else { return nil }
        return Int(exactly: n)
    }

    /// JavaScript's String.substring on an ASCII line.
    static func sub(_ s: [UInt8], _ a: Int, _ b: Int) -> String {
        let lo = max(0, min(a, b, s.count)), hi = max(0, min(max(a, b), s.count))
        return String(decoding: s[lo..<hi], as: UTF8.self)
    }

    // MARK: - Propagation

    /// Position and velocity at `jd`, a Julian date (UTC), or nil when the
    /// orbit cannot be propagated to then (it has decayed, say).
    public func propagate(jd: Double) -> StateVector? {
        sgp4(tsince: (jd - jdsatepoch) * SGP4Constants.minutesPerDay)
    }

    /// Position and velocity at `date`. Use `propagate(jd:)` in a loop: the
    /// Julian date of a moment is the same for every satellite.
    public func propagate(_ date: Date) -> StateVector? {
        propagate(jd: Julian.jday(date))
    }

    /// satellite.js `sgp4`: position and velocity `tsince` minutes after epoch.
    public func sgp4(tsince: Double) -> StateVector? {
        let t = tsince
        // Secular gravity and atmospheric drag.
        let xmdf = mo + mdot * t
        let argpdf = argpo + argpdot * t
        let nodedf = nodeo + nodedot * t
        var argpm = argpdf
        var mm = xmdf
        let t2 = t * t
        var nodem = nodedf + nodecf * t2
        var tempa = 1 - cc1 * t
        var tempe = bstar * cc4 * t
        var templ = t2cof * t2

        if isimp != 1 {
            let delomg = omgcof * t
            let delmtemp = 1 + eta * cos(xmdf)
            let delm = xmcof * (delmtemp * delmtemp * delmtemp - delmo)
            let temp = delomg + delm
            mm = xmdf + temp
            argpm = argpdf - temp
            let t3 = t2 * t
            let t4 = t3 * t
            tempa = tempa - d2 * t2 - d3 * t3 - d4 * t4
            tempe += bstar * cc5 * (sin(mm) - sinmao)
            templ = templ + t3cof * t3 + t4 * (t4cof + t * t5cof)
        }

        var nm = no
        var em = ecco
        var inclm = inclo
        if deepSpace {
            let d = dspace(t: t, tc: t, em: em, argpm: argpm, inclm: inclm, mm: mm, nodem: nodem, nm: nm)
            em = d.em
            argpm = d.argpm
            inclm = d.inclm
            mm = d.mm
            nodem = d.nodem
            nm = d.nm
        }

        if nm <= 0 { return nil }              // error 2
        let am = pow(xke / nm, x2o3) * tempa * tempa
        nm = xke / pow(am, 1.5)
        em -= tempe
        if em >= 1 || em < -0.001 { return nil }   // error 1
        if em < 1e-6 { em = 1e-6 }
        mm += no * templ
        var xlm = mm + argpm + nodem
        var ep = em
        var xincp = inclm
        argpm = argpm.truncatingRemainder(dividingBy: twoPi)
        var argpp = argpm
        nodem = nodem.truncatingRemainder(dividingBy: twoPi)
        var nodep = nodem
        xlm = xlm.truncatingRemainder(dividingBy: twoPi)
        mm = (xlm - argpm - nodem).truncatingRemainder(dividingBy: twoPi)
        var mp = mm

        var sinip = sin(inclm)
        var cosip = cos(inclm)

        // Lunar-solar periodics.
        var aycof = self.aycof, xlcof = self.xlcof
        var con41 = self.con41, x1mth2 = self.x1mth2, x7thm1 = self.x7thm1
        if deepSpace {
            let p = dpper(t: t, initialising: false, ep: ep, inclp: xincp, nodep: nodep, argpp: argpp, mp: mp)
            ep = p.ep
            nodep = p.nodep
            argpp = p.argpp
            mp = p.mp
            xincp = p.inclp
            if xincp < 0 {
                xincp = -xincp
                nodep += pi
                argpp -= pi
            }
            if ep < 0 || ep > 1 { return nil }   // error 3
            sinip = sin(xincp)
            cosip = cos(xincp)
            aycof = -0.5 * j3oj2 * sinip
            if abs(cosip + 1) > 1.5e-12 {
                xlcof = -0.25 * j3oj2 * sinip * (3 + 5 * cosip) / (1 + cosip)
            } else {
                xlcof = -0.25 * j3oj2 * sinip * (3 + 5 * cosip) / 1.5e-12
            }
        }

        // Long-period periodics.
        let axnl = ep * cos(argpp)
        var temp = 1 / (am * (1 - ep * ep))
        let aynl = ep * sin(argpp) + temp * aycof
        let xl = mp + argpp + nodep + temp * xlcof * axnl

        // Kepler's equation.
        let u = (xl - nodep).truncatingRemainder(dividingBy: twoPi)
        var eo1 = u
        var tem5 = 9999.9
        var ktr = 1
        var sineo1 = 0.0, coseo1 = 0.0
        while abs(tem5) >= 1e-12 && ktr <= 10 {
            sineo1 = sin(eo1)
            coseo1 = cos(eo1)
            tem5 = 1 - coseo1 * axnl - sineo1 * aynl
            tem5 = (u - aynl * coseo1 + axnl * sineo1 - eo1) / tem5
            if abs(tem5) >= 0.95 { tem5 = tem5 > 0 ? 0.95 : -0.95 }
            eo1 += tem5
            ktr += 1
        }

        // Short-period preliminary quantities.
        let ecose = axnl * coseo1 + aynl * sineo1
        let esine = axnl * sineo1 - aynl * coseo1
        let el2 = axnl * axnl + aynl * aynl
        let pl = am * (1 - el2)
        if pl < 0 { return nil }                 // error 4
        let rl = am * (1 - ecose)
        let rdotl = am.squareRoot() * esine / rl
        let rvdotl = pl.squareRoot() / rl
        let betal = (1 - el2).squareRoot()
        temp = esine / (1 + betal)
        let sinu = am / rl * (sineo1 - aynl - axnl * temp)
        let cosu = am / rl * (coseo1 - axnl + aynl * temp)
        var su = atan2(sinu, cosu)
        let sin2u = (cosu + cosu) * sinu
        let cos2u = 1 - 2 * sinu * sinu
        temp = 1 / pl
        let temp1 = 0.5 * j2 * temp
        let temp2 = temp1 * temp

        if deepSpace {
            let cosisq = cosip * cosip
            con41 = 3 * cosisq - 1
            x1mth2 = 1 - cosisq
            x7thm1 = 7 * cosisq - 1
        }

        let mrt = rl * (1 - 1.5 * temp2 * betal * con41) + 0.5 * temp1 * x1mth2 * cos2u
        if mrt < 1 { return nil }                // error 6: decayed
        su -= 0.25 * temp2 * x7thm1 * sin2u
        let xnode = nodep + 1.5 * temp2 * cosip * sin2u
        let xinc = xincp + 1.5 * temp2 * cosip * sinip * cos2u
        let mvt = rdotl - nm * temp1 * x1mth2 * sin2u / xke
        let rvdot = rvdotl + nm * temp1 * (x1mth2 * cos2u + 1.5 * con41) / xke

        // Orientation vectors.
        let sinsu = sin(su)
        let cossu = cos(su)
        let snod = sin(xnode)
        let cnod = cos(xnode)
        let sini = sin(xinc)
        let cosi = cos(xinc)
        let xmx = -snod * cosi
        let xmy = cnod * cosi
        let ux = xmx * sinsu + cnod * cossu
        let uy = xmy * sinsu + snod * cossu
        let uz = sini * sinsu
        let vx = xmx * cossu - cnod * sinsu
        let vy = xmy * cossu - snod * sinsu
        let vz = sini * cossu

        let r = SIMD3(mrt * ux * earthRadius, mrt * uy * earthRadius, mrt * uz * earthRadius)
        let v = SIMD3((mvt * ux + rvdot * vx) * vkmpersec,
                      (mvt * uy + rvdot * vy) * vkmpersec,
                      (mvt * uz + rvdot * vz) * vkmpersec)
        return StateVector(position: r, velocity: v)
    }

    // MARK: - Initialisation

    /// satellite.js `sgp4init`, operation mode "i". `epoch` is the Julian date
    /// of the elements minus 2433281.5 (days since 1949-12-31 00:00 UT).
    mutating func sgp4init(epoch: Double) {
        // initl
        let eccsq = ecco * ecco
        let omeosq = 1 - eccsq
        let rteosq = omeosq.squareRoot()
        let cosio = cos(inclo)
        let cosio2 = cosio * cosio
        let ak = pow(xke / no, x2o3)
        let d1 = 0.75 * j2 * (3 * cosio2 - 1) / (rteosq * omeosq)
        var del = d1 / (ak * ak)
        let adel = ak * (1 - del * del - del * (1.0 / 3.0 + 134 * del * del / 81))
        del = d1 / (adel * adel)
        no /= 1 + del
        let ao = pow(xke / no, x2o3)
        let sinio = sin(inclo)
        let po = ao * omeosq
        let con42 = 1 - 5 * cosio2
        con41 = -con42 - cosio2 - cosio2
        let posq = po * po
        let rp = ao * (1 - ecco)
        gsto = Julian.gstime(epoch + 2433281.5)

        a = pow(no * tumin, -2.0 / 3.0)
        alta = a * (1 + ecco) - 1
        altp = a * (1 - ecco) - 1
        error = 0

        guard omeosq >= 0 || no >= 0 else { return }
        isimp = 0
        if rp < 1.034492841559484 { isimp = 1 }     // perigee under 220 km
        var sfour = 1.0122292801892716                 // 78 km above the surface, in Earth radii + 1
        var qzms24 = 1.880279159015271e-9              // ((120 − 78) / earthRadius)⁴
        let perige = (rp - 1) * earthRadius
        // Lower perigees get a lower s and q.
        if perige < 156 {
            sfour = perige - 78
            if perige < 98 { sfour = 20 }
            let qzms24temp = (120 - sfour) / earthRadius
            qzms24 = qzms24temp * qzms24temp * qzms24temp * qzms24temp
            sfour = sfour / earthRadius + 1
        }
        let pinvsq = 1 / posq
        let tsi = 1 / (ao - sfour)
        eta = ao * ecco * tsi
        let etasq = eta * eta
        let eeta = ecco * eta
        let psisq = abs(1 - etasq)
        let coef = qzms24 * pow(tsi, 4)
        let coef1 = coef / pow(psisq, 3.5)
        let cc2 = coef1 * no * (ao * (1 + 1.5 * etasq + eeta * (4 + etasq))
            + 0.375 * j2 * tsi / psisq * con41 * (8 + 3 * etasq * (8 + etasq)))
        cc1 = bstar * cc2
        var cc3 = 0.0
        if ecco > 1e-4 { cc3 = -2 * coef * tsi * j3oj2 * no * sinio / ecco }
        x1mth2 = 1 - cosio2
        cc4 = 2 * no * coef1 * ao * omeosq * (eta * (2 + 0.5 * etasq) + ecco * (0.5 + 2 * etasq)
            - j2 * tsi / (ao * psisq) * (-3 * con41 * (1 - 2 * eeta + etasq * (1.5 - 0.5 * eeta))
                + 0.75 * x1mth2 * (2 * etasq - eeta * (1 + etasq)) * cos(2 * argpo)))
        cc5 = 2 * coef1 * ao * omeosq * (1 + 2.75 * (etasq + eeta) + eeta * etasq)
        let cosio4 = cosio2 * cosio2
        let temp1 = 1.5 * j2 * pinvsq * no
        let temp2 = 0.5 * temp1 * j2 * pinvsq
        let temp3 = -0.46875 * j4 * pinvsq * pinvsq * no
        mdot = no + 0.5 * temp1 * rteosq * con41 + 0.0625 * temp2 * rteosq * (13 - 78 * cosio2 + 137 * cosio4)
        argpdot = -0.5 * temp1 * con42 + 0.0625 * temp2 * (7 - 114 * cosio2 + 395 * cosio4)
            + temp3 * (3 - 36 * cosio2 + 49 * cosio4)
        let xhdot1 = -temp1 * cosio
        nodedot = xhdot1 + (0.5 * temp2 * (4 - 19 * cosio2) + 2 * temp3 * (3 - 7 * cosio2)) * cosio
        let xpidot = argpdot + nodedot
        omgcof = bstar * cc3 * cos(argpo)
        xmcof = 0
        if ecco > 1e-4 { xmcof = -x2o3 * coef * bstar / eeta }
        nodecf = 3.5 * omeosq * xhdot1 * cc1
        t2cof = 1.5 * cc1
        // Divide by zero guard for an inclination of 180°.
        if abs(cosio + 1) > 1.5e-12 {
            xlcof = -0.25 * j3oj2 * sinio * (3 + 5 * cosio) / (1 + cosio)
        } else {
            xlcof = -0.25 * j3oj2 * sinio * (3 + 5 * cosio) / 1.5e-12
        }
        aycof = -0.5 * j3oj2 * sinio
        let delmotemp = 1 + eta * cos(mo)
        delmo = delmotemp * delmotemp * delmotemp
        sinmao = sin(mo)
        x7thm1 = 7 * cosio2 - 1

        // Deep space: a period of 225 minutes or more.
        if 2 * pi / no >= 225 {
            deepSpace = true
            isimp = 1
            let inclm = inclo
            let ds = Self.dscom(epoch: epoch, ep: ecco, argpp: argpo, tc: 0, inclp: inclo, nodep: nodeo, np: no)
            e3 = ds.e3; ee2 = ds.ee2
            peo = 0; pgho = 0; pho = 0; pinco = 0; plo = 0
            se2 = ds.se2; se3 = ds.se3; sgh2 = ds.sgh2; sgh3 = ds.sgh3; sgh4 = ds.sgh4
            sh2 = ds.sh2; sh3 = ds.sh3; si2 = ds.si2; si3 = ds.si3
            sl2 = ds.sl2; sl3 = ds.sl3; sl4 = ds.sl4
            xgh2 = ds.xgh2; xgh3 = ds.xgh3; xgh4 = ds.xgh4; xh2 = ds.xh2; xh3 = ds.xh3
            xi2 = ds.xi2; xi3 = ds.xi3; xl2 = ds.xl2; xl3 = ds.xl3; xl4 = ds.xl4
            zmol = ds.zmol; zmos = ds.zmos
            // dpper while initialising applies nothing (satellite.js calls it
            // anyway, with init "y"); left out.
            dsinit(ds: ds, cosim: ds.cosim, emsq: ds.emsq, sinim: ds.sinim, em: ds.em,
                   inclm: inclm, nm: ds.nm, xpidot: xpidot, eccsq: eccsq)
        }

        if isimp != 1 {
            let cc1sq = cc1 * cc1
            d2 = 4 * ao * tsi * cc1sq
            let temp = d2 * tsi * cc1 / 3
            d3 = (17 * ao + sfour) * temp
            d4 = 0.5 * temp * ao * tsi * (221 * ao + 31 * sfour) * cc1
            t3cof = d2 + 2 * cc1sq
            t4cof = 0.25 * (3 * d3 + cc1 * (12 * d2 + 10 * cc1sq))
            t5cof = 0.2 * (3 * d4 + 12 * cc1 * d3 + 6 * d2 * d2 + 15 * cc1sq * (2 * d2 + cc1sq))
        }
        // satellite.js ends with sgp4(satrec, 0); it only sets `error`.
        if sgp4(tsince: 0) == nil { error = 6 }
    }

    // MARK: - Deep space

    /// satellite.js `dpper`: the lunar-solar periodics, applied (outside
    /// initialisation) to the mean elements.
    func dpper(t: Double, initialising: Bool, ep: Double, inclp: Double, nodep: Double, argpp: Double, mp: Double)
        -> (ep: Double, inclp: Double, nodep: Double, argpp: Double, mp: Double)
    {
        var ep = ep, inclp = inclp, nodep = nodep, argpp = argpp, mp = mp
        let zns = 1.19459e-5
        let znl = 1.5835218e-4

        // Solar terms.
        var zm = initialising ? zmos : zmos + zns * t
        var zf = zm + 0.0335 * sin(zm)
        var sinzf = sin(zf)
        var f2 = 0.5 * sinzf * sinzf - 0.25
        var f3 = -0.5 * sinzf * cos(zf)
        let ses = se2 * f2 + se3 * f3
        let sis = si2 * f2 + si3 * f3
        let sls = sl2 * f2 + sl3 * f3 + sl4 * sinzf
        let sghs = sgh2 * f2 + sgh3 * f3 + sgh4 * sinzf
        let shs = sh2 * f2 + sh3 * f3

        // Lunar terms.
        zm = initialising ? zmol : zmol + znl * t
        zf = zm + 0.1098 * sin(zm)
        sinzf = sin(zf)
        f2 = 0.5 * sinzf * sinzf - 0.25
        f3 = -0.5 * sinzf * cos(zf)
        var pe = ses + (ee2 * f2 + e3 * f3)
        var pinc = sis + (xi2 * f2 + xi3 * f3)
        var pl = sls + (xl2 * f2 + xl3 * f3 + xl4 * sinzf)
        var pgh = sghs + (xgh2 * f2 + xgh3 * f3 + xgh4 * sinzf)
        var ph = shs + (xh2 * f2 + xh3 * f3)

        if !initialising {
            pl -= plo
            pgh -= pgho
            ph -= pho
            pinc -= pinco
            inclp += pinc
            pe -= peo
            ep += pe
            let sinip = sin(inclp)
            let cosip = cos(inclp)
            if inclp >= 0.2 {
                // Direct periodics.
                ph /= sinip
                pgh -= cosip * ph
                argpp += pgh
                nodep += ph
                mp += pl
            } else {
                // Lyddane's modification, for low inclinations.
                let sinop = sin(nodep)
                let cosop = cos(nodep)
                var alfdp = sinip * sinop
                var betdp = sinip * cosop
                alfdp += ph * cosop + pinc * cosip * sinop
                betdp += -ph * sinop + pinc * cosip * cosop
                nodep = nodep.truncatingRemainder(dividingBy: twoPi)
                var xls = mp + argpp + cosip * nodep
                xls += pl + pgh - pinc * nodep * sinip
                let xnoh = nodep
                nodep = atan2(alfdp, betdp)
                if abs(xnoh - nodep) > pi {
                    if nodep < xnoh { nodep += twoPi } else { nodep -= twoPi }
                }
                mp += pl
                argpp = xls - mp - cosip * nodep
            }
        }
        return (ep, inclp, nodep, argpp, mp)
    }

    /// satellite.js `dspace`: deep-space secular effects and, for the 12 h and
    /// 24 h resonances, the numerical integration from epoch.
    func dspace(t: Double, tc: Double, em: Double, argpm: Double, inclm: Double, mm: Double, nodem: Double, nm: Double)
        -> (em: Double, argpm: Double, inclm: Double, mm: Double, nodem: Double, nm: Double)
    {
        let fasx2 = 0.13130908, fasx4 = 2.8843198, fasx6 = 0.37448087
        let g22 = 5.7686396, g32 = 0.95240898, g44 = 1.8014998, g52 = 1.050833, g54 = 4.4108898
        let rptim = 0.0043752690880113        // satellite.js's literal
        let stepp = 720.0, step2 = 259200.0

        var em = em, argpm = argpm, inclm = inclm, mm = mm, nodem = nodem, nm = nm
        var dndt = 0.0
        var ft = 0.0
        let theta = (gsto + tc * rptim).truncatingRemainder(dividingBy: twoPi)
        em += dedt * t
        inclm += didt * t
        argpm += domdt * t
        nodem += dnodt * t
        mm += dmdt * t

        if irez != 0 {
            // satellite.js never stores the integrator's state, so this always
            // starts again from epoch.
            var atime = self.atime, xni = self.xni, xli = self.xli
            if atime == 0 || t * atime <= 0 || abs(t) < abs(atime) {
                atime = 0
                xni = no
                xli = xlamo
            }
            let delt = t > 0 ? stepp : -stepp
            var xndt = 0.0, xldot = 0.0, xnddt = 0.0
            var iretn = 381
            while iretn == 381 {
                if irez != 2 {
                    // Near-synchronous resonance terms.
                    xndt = del1 * sin(xli - fasx2) + del2 * sin(2 * (xli - fasx4)) + del3 * sin(3 * (xli - fasx6))
                    xldot = xni + xfact
                    xnddt = del1 * cos(xli - fasx2) + 2 * del2 * cos(2 * (xli - fasx4)) + 3 * del3 * cos(3 * (xli - fasx6))
                    xnddt *= xldot
                } else {
                    // Near half-day resonance terms.
                    let xomi = argpo + argpdot * atime
                    let x2omi = xomi + xomi
                    let x2li = xli + xli
                    xndt = d2201 * sin(x2omi + xli - g22) + d2211 * sin(xli - g22)
                        + d3210 * sin(xomi + xli - g32) + d3222 * sin(-xomi + xli - g32)
                        + d4410 * sin(x2omi + x2li - g44) + d4422 * sin(x2li - g44)
                        + d5220 * sin(xomi + xli - g52) + d5232 * sin(-xomi + xli - g52)
                        + d5421 * sin(xomi + x2li - g54) + d5433 * sin(-xomi + x2li - g54)
                    xldot = xni + xfact
                    xnddt = d2201 * cos(x2omi + xli - g22) + d2211 * cos(xli - g22)
                        + d3210 * cos(xomi + xli - g32) + d3222 * cos(-xomi + xli - g32)
                        + d5220 * cos(xomi + xli - g52) + d5232 * cos(-xomi + xli - g52)
                        + 2 * (d4410 * cos(x2omi + x2li - g44) + d4422 * cos(x2li - g44)
                            + d5421 * cos(xomi + x2li - g54) + d5433 * cos(-xomi + x2li - g54))
                    xnddt *= xldot
                }
                if abs(t - atime) >= stepp {
                    iretn = 381
                } else {
                    ft = t - atime
                    iretn = 0
                }
                if iretn == 381 {
                    xli += xldot * delt + xndt * step2
                    xni += xndt * delt + xnddt * step2
                    atime += delt
                }
            }
            nm = xni + xndt * ft + xnddt * ft * ft * 0.5
            let xl = xli + xldot * ft + xndt * ft * ft * 0.5
            if irez != 1 {
                mm = xl - 2 * nodem + 2 * theta
                dndt = nm - no
            } else {
                mm = xl - nodem - argpm + theta
                dndt = nm - no
            }
            nm = no + dndt
        }
        return (em, argpm, inclm, mm, nodem, nm)
    }

    struct Dscom {
        var sinim = 0.0, cosim = 0.0, em = 0.0, emsq = 0.0, nm = 0.0
        var s1 = 0.0, s2 = 0.0, s3 = 0.0, s4 = 0.0, s5 = 0.0, s6 = 0.0, s7 = 0.0
        var ss1 = 0.0, ss2 = 0.0, ss3 = 0.0, ss4 = 0.0, ss5 = 0.0, ss6 = 0.0, ss7 = 0.0
        var sz1 = 0.0, sz2 = 0.0, sz3 = 0.0, sz11 = 0.0, sz12 = 0.0, sz13 = 0.0
        var sz21 = 0.0, sz22 = 0.0, sz23 = 0.0, sz31 = 0.0, sz32 = 0.0, sz33 = 0.0
        var z1 = 0.0, z2 = 0.0, z3 = 0.0, z11 = 0.0, z12 = 0.0, z13 = 0.0
        var z21 = 0.0, z22 = 0.0, z23 = 0.0, z31 = 0.0, z32 = 0.0, z33 = 0.0
        var e3 = 0.0, ee2 = 0.0, se2 = 0.0, se3 = 0.0, sgh2 = 0.0, sgh3 = 0.0, sgh4 = 0.0
        var sh2 = 0.0, sh3 = 0.0, si2 = 0.0, si3 = 0.0, sl2 = 0.0, sl3 = 0.0, sl4 = 0.0
        var xgh2 = 0.0, xgh3 = 0.0, xgh4 = 0.0, xh2 = 0.0, xh3 = 0.0
        var xi2 = 0.0, xi3 = 0.0, xl2 = 0.0, xl3 = 0.0, xl4 = 0.0
        var zmol = 0.0, zmos = 0.0
    }

    /// satellite.js `dscom`: the deep-space common terms, the Sun's first and
    /// the Moon's second.
    static func dscom(epoch: Double, ep: Double, argpp: Double, tc: Double, inclp: Double, nodep: Double, np: Double) -> Dscom {
        let zes = 0.01675, zel = 0.0549
        let c1ss = 2.9864797e-6
        let c1l = 4.7968065e-7
        let zsinis = 0.39785416, zcosis = 0.91744867
        let zcosgs = 0.1945905, zsings = -0.98088458

        var r = Dscom()
        r.nm = np
        r.em = ep
        let snodm = sin(nodep)
        let cnodm = cos(nodep)
        let sinomm = sin(argpp)
        let cosomm = cos(argpp)
        r.sinim = sin(inclp)
        r.cosim = cos(inclp)
        r.emsq = r.em * r.em
        let betasq = 1 - r.emsq
        let rtemsq = betasq.squareRoot()

        let day = epoch + 18261.5 + tc / 1440
        let xnodce = (4.523602 - 0.00092422029 * day).truncatingRemainder(dividingBy: twoPi)
        let stem = sin(xnodce)
        let ctem = cos(xnodce)
        let zcosil = 0.91375164 - 0.03568096 * ctem
        let zsinil = (1 - zcosil * zcosil).squareRoot()
        let zsinhl = 0.089683511 * stem / zsinil
        let zcoshl = (1 - zsinhl * zsinhl).squareRoot()
        let gam = 5.8351514 + 0.001944368 * day
        var zx = 0.39785416 * stem / zsinil
        let zy = zcoshl * ctem + 0.91744867 * zsinhl * stem
        zx = atan2(zx, zy)
        zx += gam - xnodce           // satellite.js order: zx + (gam − xnodce)
        let zcosgl = cos(zx)
        let zsingl = sin(zx)

        // First the Sun, then the Moon.
        var zcosg = zcosgs, zsing = zsings, zcosi = zcosis, zsini = zsinis
        var zcosh = cnodm, zsinh = snodm
        var cc = c1ss
        let xnoi = 1 / r.nm
        let emsq = r.emsq
        for lsflg in 1...2 {
            let a1 = zcosg * zcosh + zsing * zcosi * zsinh
            let a3 = -zsing * zcosh + zcosg * zcosi * zsinh
            let a7 = -zcosg * zsinh + zsing * zcosi * zcosh
            let a8 = zsing * zsini
            let a9 = zsing * zsinh + zcosg * zcosi * zcosh
            let a10 = zcosg * zsini
            let a2 = r.cosim * a7 + r.sinim * a8
            let a4 = r.cosim * a9 + r.sinim * a10
            let a5 = -r.sinim * a7 + r.cosim * a8
            let a6 = -r.sinim * a9 + r.cosim * a10

            let x1 = a1 * cosomm + a2 * sinomm
            let x2 = a3 * cosomm + a4 * sinomm
            let x3 = -a1 * sinomm + a2 * cosomm
            let x4 = -a3 * sinomm + a4 * cosomm
            let x5 = a5 * sinomm
            let x6 = a6 * sinomm
            let x7 = a5 * cosomm
            let x8 = a6 * cosomm

            r.z31 = 12 * x1 * x1 - 3 * x3 * x3
            r.z32 = 24 * x1 * x2 - 6 * x3 * x4
            r.z33 = 12 * x2 * x2 - 3 * x4 * x4
            r.z1 = 3 * (a1 * a1 + a2 * a2) + r.z31 * emsq
            r.z2 = 6 * (a1 * a3 + a2 * a4) + r.z32 * emsq
            r.z3 = 3 * (a3 * a3 + a4 * a4) + r.z33 * emsq
            r.z11 = -6 * a1 * a5 + emsq * (-24 * x1 * x7 - 6 * x3 * x5)
            r.z12 = -6 * (a1 * a6 + a3 * a5) + emsq * (-24 * (x2 * x7 + x1 * x8) + -6 * (x3 * x6 + x4 * x5))
            r.z13 = -6 * a3 * a6 + emsq * (-24 * x2 * x8 - 6 * x4 * x6)
            r.z21 = 6 * a2 * a5 + emsq * (24 * x1 * x5 - 6 * x3 * x7)
            r.z22 = 6 * (a4 * a5 + a2 * a6) + emsq * (24 * (x2 * x5 + x1 * x6) - 6 * (x4 * x7 + x3 * x8))
            r.z23 = 6 * a4 * a6 + emsq * (24 * x2 * x6 - 6 * x4 * x8)
            r.z1 = r.z1 + r.z1 + betasq * r.z31
            r.z2 = r.z2 + r.z2 + betasq * r.z32
            r.z3 = r.z3 + r.z3 + betasq * r.z33
            r.s3 = cc * xnoi
            r.s2 = -0.5 * r.s3 / rtemsq
            r.s4 = r.s3 * rtemsq
            r.s1 = -15 * r.em * r.s4
            r.s5 = x1 * x3 + x2 * x4
            r.s6 = x2 * x3 + x1 * x4
            r.s7 = x2 * x4 - x1 * x3

            if lsflg == 1 {
                r.ss1 = r.s1; r.ss2 = r.s2; r.ss3 = r.s3; r.ss4 = r.s4
                r.ss5 = r.s5; r.ss6 = r.s6; r.ss7 = r.s7
                r.sz1 = r.z1; r.sz2 = r.z2; r.sz3 = r.z3
                r.sz11 = r.z11; r.sz12 = r.z12; r.sz13 = r.z13
                r.sz21 = r.z21; r.sz22 = r.z22; r.sz23 = r.z23
                r.sz31 = r.z31; r.sz32 = r.z32; r.sz33 = r.z33
                zcosg = zcosgl
                zsing = zsingl
                zcosi = zcosil
                zsini = zsinil
                zcosh = zcoshl * cnodm + zsinhl * snodm
                zsinh = snodm * zcoshl - cnodm * zsinhl
                cc = c1l
            }
        }

        r.zmol = (0.2299715 * day - gam + 4.7199672).truncatingRemainder(dividingBy: twoPi)
        r.zmos = (6.2565837 + 0.017201977 * day).truncatingRemainder(dividingBy: twoPi)

        // Solar terms.
        r.se2 = 2 * r.ss1 * r.ss6
        r.se3 = 2 * r.ss1 * r.ss7
        r.si2 = 2 * r.ss2 * r.sz12
        r.si3 = 2 * r.ss2 * (r.sz13 - r.sz11)
        r.sl2 = -2 * r.ss3 * r.sz2
        r.sl3 = -2 * r.ss3 * (r.sz3 - r.sz1)
        r.sl4 = -2 * r.ss3 * (-21 - 9 * emsq) * zes
        r.sgh2 = 2 * r.ss4 * r.sz32
        r.sgh3 = 2 * r.ss4 * (r.sz33 - r.sz31)
        r.sgh4 = -18 * r.ss4 * zes
        r.sh2 = -2 * r.ss2 * r.sz22
        r.sh3 = -2 * r.ss2 * (r.sz23 - r.sz21)

        // Lunar terms.
        r.ee2 = 2 * r.s1 * r.s6
        r.e3 = 2 * r.s1 * r.s7
        r.xi2 = 2 * r.s2 * r.z12
        r.xi3 = 2 * r.s2 * (r.z13 - r.z11)
        r.xl2 = -2 * r.s3 * r.z2
        r.xl3 = -2 * r.s3 * (r.z3 - r.z1)
        r.xl4 = -2 * r.s3 * (-21 - 9 * emsq) * zel
        r.xgh2 = 2 * r.s4 * r.z32
        r.xgh3 = 2 * r.s4 * (r.z33 - r.z31)
        r.xgh4 = -18 * r.s4 * zel
        r.xh2 = -2 * r.s2 * r.z22
        r.xh3 = -2 * r.s2 * (r.z23 - r.z21)
        return r
    }

    /// satellite.js `dsinit`: the deep-space secular rates and, for the
    /// resonant orbits, the integrator's coefficients. At t = 0 (always, here)
    /// the element updates it makes are no-ops, so only the rates are kept.
    mutating func dsinit(ds: Dscom, cosim: Double, emsq: Double, sinim: Double, em: Double,
                         inclm: Double, nm: Double, xpidot: Double, eccsq: Double)
    {
        let q22 = 1.7891679e-6, q31 = 2.1460748e-6, q33 = 2.2123015e-7
        let root22 = 1.7891679e-6, root44 = 7.3636953e-9, root54 = 2.1765803e-9
        let rptim = 0.0043752690880113        // satellite.js's literal
        let root32 = 3.7393792e-7, root52 = 1.1428639e-7
        let znl = 1.5835218e-4, zns = 1.19459e-5

        // Is it resonant?
        irez = 0
        if nm < 0.0052359877 && nm > 0.0034906585 { irez = 1 }
        if nm >= 0.00826 && nm <= 0.00924 && em >= 0.5 { irez = 2 }

        // Solar terms.
        var shs = -zns * ds.ss2 * (ds.sz21 + ds.sz23)
        if inclm < 0.052359877 || inclm > pi - 0.052359877 { shs = 0 }
        if sinim != 0 { shs /= sinim }

        // Lunar terms.
        var shll = -znl * ds.s2 * (ds.z21 + ds.z23)
        if inclm < 0.052359877 || inclm > pi - 0.052359877 { shll = 0 }
        domdt = ds.ss4 * zns * (ds.sz31 + ds.sz33 - 6) - cosim * shs + ds.s4 * znl * (ds.z31 + ds.z33 - 6)
        dnodt = shs
        if sinim != 0 {
            domdt -= cosim / sinim * shll
            dnodt += shll / sinim
        }

        let theta = (gsto + 0 * rptim).truncatingRemainder(dividingBy: twoPi)
        dedt = ds.ss1 * zns * ds.ss5 + ds.s1 * znl * ds.s5
        didt = ds.ss2 * zns * (ds.sz11 + ds.sz13) + ds.s2 * znl * (ds.z11 + ds.z13)
        dmdt = -zns * ds.ss3 * (ds.sz1 + ds.sz3 - 14 - 6 * emsq) - znl * ds.s3 * (ds.z1 + ds.z3 - 14 - 6 * emsq)

        // The resonance coefficients.
        guard irez != 0 else { return }
        let aonv = pow(nm / xke, x2o3)

        if irez == 2 {
            // Geopotential resonance for 12-hour orbits.
            let cosisq = cosim * cosim
            let em = ecco
            let emsq = eccsq
            let eoc = em * emsq
            let g201 = -0.306 - 0.44 * (em - 0.64)
            var g211 = 0.0, g310 = 0.0, g322 = 0.0, g410 = 0.0, g422 = 0.0, g520 = 0.0
            var g521 = 0.0, g532 = 0.0, g533 = 0.0
            if em <= 0.65 {
                g211 = 3.616 - 13.247 * em + 16.29 * emsq
                g310 = 117.39 * em - 19.302 - 228.419 * emsq + 156.591 * eoc
                g322 = 109.7927 * em - 18.9068 - 214.6334 * emsq + 146.5816 * eoc
                g410 = 242.694 * em - 41.122 - 471.094 * emsq + 313.953 * eoc
                g422 = 841.88 * em - 146.407 - 1629.014 * emsq + 1083.435 * eoc
                g520 = 3017.977 * em - 532.114 - 5740.032 * emsq + 3708.276 * eoc
            } else {
                g211 = 331.819 * em - 72.099 - 508.738 * emsq + 266.724 * eoc
                g310 = 1582.851 * em - 346.844 - 2415.925 * emsq + 1246.113 * eoc
                g322 = 1554.908 * em - 342.585 - 2366.899 * emsq + 1215.972 * eoc
                g410 = 4758.686 * em - 1052.797 - 7193.992 * emsq + 3651.957 * eoc
                g422 = 16178.11 * em - 3581.69 - 24462.77 * emsq + 12422.52 * eoc
                g520 = em > 0.715
                    ? 29936.92 * em - 5149.66 - 54087.36 * emsq + 31324.56 * eoc
                    : 1464.74 - 4664.75 * em + 3763.64 * emsq
            }
            if em < 0.7 {
                g533 = 4988.61 * em - 919.2277 - 9064.77 * emsq + 5542.21 * eoc
                g521 = 4568.6173 * em - 822.71072 - 8491.4146 * emsq + 5337.524 * eoc
                g532 = 4690.25 * em - 853.666 - 8624.77 * emsq + 5341.4 * eoc
            } else {
                g533 = 161616.52 * em - 37995.78 - 229838.2 * emsq + 109377.94 * eoc
                g521 = 218913.95 * em - 51752.104 - 309468.16 * emsq + 146349.42 * eoc
                g532 = 170470.89 * em - 40023.88 - 242699.48 * emsq + 115605.82 * eoc
            }
            let sini2 = sinim * sinim
            let f220 = 0.75 * (1 + 2 * cosim + cosisq)
            let f221 = 1.5 * sini2
            let f321 = 1.875 * sinim * (1 - 2 * cosim - 3 * cosisq)
            let f322 = -1.875 * sinim * (1 + 2 * cosim - 3 * cosisq)
            let f441 = 35 * sini2 * f220
            let f442 = 39.375 * sini2 * sini2
            let f522 = 9.84375 * sinim * (sini2 * (1 - 2 * cosim - 5 * cosisq) + 0.33333333 * (4 * cosim - 2 + 6 * cosisq))
            let f523 = sinim * (4.92187512 * sini2 * (-2 - 4 * cosim + 10 * cosisq) + 6.56250012 * (1 + 2 * cosim - 3 * cosisq))
            let f542 = 29.53125 * sinim * (2 - 8 * cosim + cosisq * (8 * cosim - 12 + 10 * cosisq))
            let f543 = 29.53125 * sinim * (-2 - 8 * cosim + cosisq * (12 + 8 * cosim - 10 * cosisq))

            var temp1 = nm * nm * 3 * (aonv * aonv)
            var temp = root22 * temp1
            d2201 = temp * f220 * g201
            d2211 = temp * f221 * g211
            temp1 *= aonv
            temp = root32 * temp1
            d3210 = temp * f321 * g310
            d3222 = temp * f322 * g322
            temp1 *= aonv
            temp = 2 * temp1 * root44
            d4410 = temp * f441 * g410
            d4422 = temp * f442 * g422
            temp1 *= aonv
            temp = root52 * temp1
            d5220 = temp * f522 * g520
            d5232 = temp * f523 * g532
            temp = 2 * temp1 * root54
            d5421 = temp * f542 * g521
            d5433 = temp * f543 * g533
            xlamo = (mo + nodeo + nodeo - (theta + theta)).truncatingRemainder(dividingBy: twoPi)
            xfact = mdot + dmdt + 2 * (nodedot + dnodt - rptim) - no
        }

        if irez == 1 {
            // Synchronous resonance terms (24-hour orbits).
            let g200 = 1 + emsq * (0.8125 * emsq - 2.5)
            let g310 = 1 + 2 * emsq
            let g300 = 1 + emsq * (6.60937 * emsq - 6)
            let f220 = 0.75 * (1 + cosim) * (1 + cosim)
            let f311 = 0.9375 * sinim * sinim * (1 + 3 * cosim) - 0.75 * (1 + cosim)
            var f330 = 1 + cosim
            f330 *= 1.875 * f330 * f330
            let d1 = 3 * nm * nm * aonv * aonv
            del2 = 2 * d1 * f220 * g200 * q22
            del3 = 3 * d1 * f330 * g300 * q33 * aonv
            del1 = d1 * f311 * g310 * q31 * aonv
            xlamo = (mo + nodeo + argpo - theta).truncatingRemainder(dividingBy: twoPi)
            xfact = mdot + xpidot + dmdt + domdt + dnodt - (no + rptim)
        }

        xli = xlamo
        xni = no
        atime = 0
    }
}

/// JavaScript's own number parsing, which the TLE columns are read with.
enum JS {
    /// parseFloat: leading white space skipped, then the longest prefix that
    /// is a number; NaN when there is none.
    static func parseFloat(_ s: String) -> Double {
        let t = s.drop { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" }
        guard let first = t.first, first == "+" || first == "-" || first == "." || first.isASCII && first.isNumber else {
            return .nan
        }
        return t.withCString { p -> Double in
            var end: UnsafeMutablePointer<CChar>?
            let v = strtod(p, &end)
            return end == UnsafeMutablePointer(mutating: p) ? .nan : v
        }
    }

    /// parseInt(s, 10): white space, a sign, then digits up to the first
    /// non-digit; nil (NaN) when there are no digits.
    static func parseInt(_ s: String) -> Double? {
        guard let text = parseIntString(s, nanAs: nil) else { return nil }
        return Double(text)
    }

    /// String(parseInt(s, 10)) — the digits without leading zeros, which is
    /// how satellite.js rebuilds the exponent fields ("NaN" when unreadable).
    static func parseIntString(_ s: String) -> String {
        parseIntString(s, nanAs: "NaN")!
    }

    private static func parseIntString(_ s: String, nanAs: String?) -> String? {
        var t = Substring(s).drop { $0 == " " || $0 == "\t" }
        var negative = false
        if let c = t.first, c == "+" || c == "-" {
            negative = c == "-"
            t = t.dropFirst()
        }
        let digits = t.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty else { return nanAs }
        let trimmed = digits.drop { $0 == "0" }
        if trimmed.isEmpty { return "0" }     // -0 prints as "0" in JavaScript too
        return (negative ? "-" : "") + trimmed
    }
}
