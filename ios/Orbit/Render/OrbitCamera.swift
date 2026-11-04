import Foundation
import simd

/// three.js OrbitControls as the page sets them up: orbit the origin, damped
/// (0.08), slow auto-rotation (0.3), zoom 1.25–34 Earth radii (far enough out
/// for GPS and geostationary orbits), no panning. Its per-frame constants are
/// for 60 frames a second; here they are scaled by the real frame time, so the
/// feel is the same at any refresh rate.
struct OrbitCamera {
    static let fovY = 45.0 * Double.pi / 180
    static let minDistance = 1.25
    static let maxDistance = 34.0
    static let rotateSpeed = 0.55
    static let damping = 0.08
    static let zoomSpeed = 1.15
    static let autoRotateSpeed = 0.3

    /// Spherical coordinates of the camera around the origin, as three.js
    /// keeps them: theta about the vertical axis from +Z, phi down from +Y.
    private(set) var radius: Double
    private(set) var theta: Double
    private(set) var phi: Double
    private var deltaTheta = 0.0
    private var deltaPhi = 0.0
    var autoRotate = true

    /// Somewhere to swing to: the camera glides there at a constant pace.
    struct Goal {
        var position: SIMD3<Double>
        /// Start turning by itself again once there (after the first-fix swing).
        var thenAutoRotate: Bool
    }
    var goal: Goal?

    /// A flight in to somewhere (a satellite picked in search): a set time,
    /// starting and stopping gently. It turns the short way round in the
    /// camera's own angles, so north stays up and it never tumbles over a
    /// pole. The zoom waits for the turn when closing in, so the Earth is
    /// seen turning before the dive, and a long hop backs out on the way,
    /// so the Earth is seen turning rather than racing past close up.
    struct Flight {
        let fromTheta, fromPhi, fromRadius: Double
        var toTheta, toPhi, toRadius: Double
        /// How much further out than the straight zoom it is halfway.
        let lift: Double
        let duration: Double
        var elapsed = 0.0
    }
    private(set) var flight: Flight?

    init() {
        radius = 1
        theta = 0
        phi = 0
        set(position: SIMD3(0, 1.2, 3.0))
    }

    var position: SIMD3<Double> {
        SIMD3(radius * sin(phi) * sin(theta), radius * cos(phi), radius * sin(phi) * cos(theta))
    }

    /// How far back the whole Earth fills `share` of the screen's narrower
    /// side. The page keeps three.js's fixed 3.2 radii, which on a phone held
    /// upright puts the Earth's sides off the screen (the field of view is
    /// vertical), and with them its raised rim and the GPS orbits.
    static func fitDistance(aspect: Double, share: Double = 0.86) -> Double {
        let halfFov = atan(tan(fovY / 2) * min(aspect, 1))
        let d = 1 / sin(atan(share * tan(halfFov)))
        return min(max(d, 3.2), maxDistance)
    }

    /// Start where the whole Earth fits, on the same line of sight.
    mutating func fit(aspect: Double) {
        radius = Self.fitDistance(aspect: aspect)
    }

    /// The screen changed shape: keep the zoom the person chose, measured
    /// against the fit, so a whole Earth stays whole.
    mutating func refit(from old: Double, to new: Double) {
        let scale = Self.fitDistance(aspect: new) / Self.fitDistance(aspect: old)
        radius = min(max(radius * scale, Self.minDistance), Self.maxDistance)
        if var g = goal {
            g.position *= scale
            goal = g
        }
    }

    mutating func set(position p: SIMD3<Double>) {
        // A zero or non-finite point would turn every angle into NaN for good.
        guard p.x.isFinite, p.y.isFinite, p.z.isFinite, length(p) > 1e-9 else { return }
        radius = min(max(length(p), Self.minDistance), Self.maxDistance)
        theta = atan2(p.x, p.z)
        phi = acos(min(max(p.y / length(p), -1), 1))
    }

    /// A finger moved `dx`, `dy` points on a view `height` points tall.
    mutating func drag(dx: Double, dy: Double, height: Double) {
        deltaTheta -= 2 * .pi * dx / height * Self.rotateSpeed
        deltaPhi -= 2 * .pi * dy / height * Self.rotateSpeed
    }

    /// Two fingers moved apart by `ratio` since the last call.
    mutating func pinch(ratio: Double) {
        guard ratio > 0 else { return }
        radius = min(max(radius / pow(ratio, Self.zoomSpeed), Self.minDistance), Self.maxDistance)
    }

    /// A finger came down: everything automatic stops.
    mutating func touched() {
        autoRotate = false
        goal = nil
        flight = nil
    }

    /// Fly to look at the Earth's centre from `p`; with `instantly` (Reduce
    /// Motion) just be there.
    mutating func fly(to p: SIMD3<Double>, instantly: Bool = false) {
        guard let to = Self.spherical(p) else { return }
        goal = nil
        deltaTheta = 0
        deltaPhi = 0
        if instantly {
            flight = nil
            (radius, theta, phi) = (to.radius, to.theta, to.phi)
            return
        }
        let angle = acos(min(max(dot(normalize(position), normalize(p)), -1), 1))
        // Halfway round a long hop, far enough out to see what is turning
        // past: the whole Earth for the far side (5 radii), nothing extra for
        // a neighbour.
        let peak = 1 + 4 * sin(angle / 2)
        flight = Flight(fromTheta: theta, fromPhi: phi, fromRadius: radius,
                        toTheta: theta + remainder(to.theta - theta, 2 * .pi), toPhi: to.phi, toRadius: to.radius,
                        lift: max(0, peak - max(radius, to.radius)),
                        duration: min(2.4, 0.9 + 0.45 * angle + 0.2 * abs(log(to.radius / radius))))
    }

    /// The place a flight is going to moved (a satellite does): end there
    /// instead. Small moves only, so the path just bends a little.
    mutating func retarget(_ p: SIMD3<Double>) {
        guard var f = flight, let to = Self.spherical(p) else { return }
        // The same way round as before, even across the ±180° seam.
        f.toTheta += remainder(to.theta - f.toTheta, 2 * .pi)
        f.toPhi = to.phi
        f.toRadius = to.radius
        flight = f
    }

    /// A point as the camera's angles, inside the zoom limits and off the poles.
    private static func spherical(_ p: SIMD3<Double>) -> (radius: Double, theta: Double, phi: Double)? {
        guard p.x.isFinite, p.y.isFinite, p.z.isFinite else { return nil }
        let r = length(p)
        guard r > 1e-9 else { return nil }
        return (min(max(r, minDistance), maxDistance), atan2(p.x, p.z),
                min(max(acos(min(max(p.y / r, -1), 1)), 0.01), .pi - 0.01))
    }

    /// 0 → 1 with no speed and no push at either end.
    private static func smootherstep(_ x: Double) -> Double {
        let t = min(max(x, 0), 1)
        return t * t * t * (t * (6 * t - 15) + 10)
    }

    mutating func update(dt: Double) {
        let frames = min(max(dt, 0), 0.25) * 60
        if var f = flight {
            // At most a 30th of a second a frame: a hitch (the card's sheet
            // coming up at the same moment) holds the flight still for a
            // moment, rather than jumping it ahead to catch up.
            f.elapsed += min(max(dt, 0), 1.0 / 30)
            let t = min(f.elapsed / f.duration, 1)
            let turn = Self.smootherstep(t)
            // Closing in, the zoom starts a quarter of the way in; backing
            // out, it is done three quarters of the way.
            let zoom = Self.smootherstep(f.toRadius < f.fromRadius ? (t - 0.25) / 0.75 : t / 0.75)
            theta = f.fromTheta + (f.toTheta - f.fromTheta) * turn
            phi = f.fromPhi + (f.toPhi - f.fromPhi) * turn
            let r = f.fromRadius * pow(f.toRadius / f.fromRadius, zoom) + f.lift * 4 * turn * (1 - turn)
            radius = min(max(r, Self.minDistance), Self.maxDistance)
            deltaTheta = 0
            deltaPhi = 0
            flight = t < 1 ? f : nil
        } else if let g = goal {
            // The page's swing: lerp 6 % of the way each frame, to a goal
            // inside the zoom limits, so it can always be reached.
            let target = normalize(g.position) * min(max(length(g.position), Self.minDistance), Self.maxDistance)
            let f = 1 - pow(1 - 0.06, frames)
            let p = position + (target - position) * f
            let len = length(position) + (length(target) - length(position)) * f
            set(position: normalize(p) * len)
            deltaTheta = 0
            deltaPhi = 0
            if !target.x.isFinite || distance(position, target) < 0.03 {
                goal = nil
                if g.thenAutoRotate { autoRotate = true }
            }
        } else {
            if autoRotate { deltaTheta -= 2 * .pi / 60 / 60 * Self.autoRotateSpeed * frames }
            let keep = pow(1 - Self.damping, frames)
            theta += deltaTheta * (1 - keep)
            phi += deltaPhi * (1 - keep)
            deltaTheta *= keep
            deltaPhi *= keep
        }
        // Not quite over a pole, where "up" stops meaning anything.
        phi = min(max(phi, 0.01), .pi - 0.01)
    }

    var view: simd_float4x4 {
        let eye = position
        let f = normalize(-eye)
        let s = normalize(cross(f, SIMD3(0, 1, 0)))
        let u = cross(s, f)
        return simd_float4x4(columns: (
            SIMD4(Float(s.x), Float(u.x), Float(-f.x), 0),
            SIMD4(Float(s.y), Float(u.y), Float(-f.y), 0),
            SIMD4(Float(s.z), Float(u.z), Float(-f.z), 0),
            SIMD4(Float(-dot(s, eye)), Float(-dot(u, eye)), Float(dot(f, eye)), 1)
        ))
    }

    /// Perspective, Metal's 0…1 depth, near 0.01 and far 100 like the page.
    static func projection(aspect: Double) -> simd_float4x4 {
        let near = 0.01, far = 100.0
        let y = 1 / tan(fovY / 2), x = y / aspect, z = far / (near - far)
        return simd_float4x4(columns: (
            SIMD4(Float(x), 0, 0, 0),
            SIMD4(0, Float(y), 0, 0),
            SIMD4(0, 0, Float(z), -1),
            SIMD4(0, 0, Float(z * near), 0)
        ))
    }
}
