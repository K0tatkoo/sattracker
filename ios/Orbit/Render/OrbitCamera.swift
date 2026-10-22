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
    }

    mutating func update(dt: Double) {
        let frames = min(max(dt, 0), 0.25) * 60
        if let g = goal {
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
