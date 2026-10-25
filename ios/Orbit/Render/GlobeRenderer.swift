import MetalKit
import OrbitCore
import simd

/// The globe: the Android page's three.js scene, drawn with Metal. Everything
/// the page drew is here in the same order and the same colours — the raised
/// Earth on the surface colour, its graticule, the atmosphere and the stars on
/// the dark theme, fixed-size satellite dots, the selection ring, the selected
/// satellite's orbit and the "you are here" dot. (The GNSS beams and glows are
/// Android only: iOS tells an app nothing about the satellites it hears.)
@MainActor
final class GlobeRenderer: NSObject, MTKViewDelegate {
    // The Swift twin of `Frame` in Shaders.metal.
    struct FrameUniforms {
        var viewProj: simd_float4x4
        var view: simd_float4x4
        var proj: simd_float4x4
        var viewport: SIMD2<Float>
        var pxPerPt: Float
        var halfHeight: Float
        var lampDir: SIMD3<Float>
        var ambient: Float
        var lamp: Float
        var time: Float
        var plinthScale: Float
    }

    struct Sprite {
        var x, y, z: Float
        var size: Float
        var r, g, b, a: Float
        var shape: UInt32
        var sizing: UInt32

        init(_ p: SIMD3<Float>, size: Float, color: RGB, alpha: Float, shape: Shape, sizing: Sizing = .points) {
            x = p.x; y = p.y; z = p.z
            self.size = size
            r = Float(color.r); g = Float(color.g); b = Float(color.b); a = alpha
            self.shape = shape.rawValue
            self.sizing = sizing.rawValue
        }
    }

    enum Shape: UInt32 { case soft = 0, solid, ring, glow }
    enum Sizing: UInt32 { case points = 0, attenuated, world }

    struct Segment {
        var ax, ay, az, bx, by, bz: Float
        var ar, ag, ab, aa, br, bg, bb, ba: Float

        init(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ ca: SIMD4<Float>, _ cb: SIMD4<Float>) {
            ax = a.x; ay = a.y; az = a.z; bx = b.x; by = b.y; bz = b.z
            ar = ca.x; ag = ca.y; ab = ca.z; aa = ca.w
            br = cb.x; bg = cb.y; bb = cb.z; ba = cb.w
        }
    }

    private let model: AppModel
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let earthPSO, atmospherePSO, plinthPSO: MTLRenderPipelineState
    private let spritePSO, spriteAddPSO, linePSO, lineAddPSO: MTLRenderPipelineState
    private let depthWrite, depthTest, depthNone: MTLDepthStencilState
    private let sampler: MTLSamplerState
    private let earthVertices, earthIndices, graticule, stars, nebulae: MTLBuffer
    private let earthIndexCount, graticuleCount, starCount, nebulaCount: Int

    private static let maxSprites = 4000 + 8
    private static let trailSegments = 120
    private static let inFlight = 3
    private var spriteBuffers: [MTLBuffer] = []
    private var trailBuffers: [MTLBuffer] = []
    private var frameIndex = 0
    private let semaphore = DispatchSemaphore(value: GlobeRenderer.inFlight)

    private var earthTextures: [Bool: MTLTexture] = [:]
    var dark = true
    var camera = OrbitCamera()
    private var lastTime = CACurrentMediaTime()
    /// The aspect the camera's distance was last fitted to.
    private var fittedAspect: Double?
    /// Where the card covers the globe; the Earth moves into what is left.
    var cardSpace: CardPlacement?
    /// How far up the Earth is moved for the card, points.
    private var shiftPt = SIMD2<Double>(0, 0)
    private let startTime = CACurrentMediaTime()

    /// Kept from the last frame, for picking.
    private var viewProj = matrix_identity_float4x4
    private var viewSizePt = CGSize(width: 1, height: 1)

    private var trail: [Segment] = []
    private var trailNorad: Int?
    private var trailTime = 0.0

    init?(view: MTKView, model: AppModel) {
        guard let device = view.device ?? MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary()
        else { return nil }
        self.model = model
        self.device = device
        self.queue = queue

        func pipeline(_ vertex: String, _ fragment: String, blend: Blend?) -> MTLRenderPipelineState? {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: vertex)
            d.fragmentFunction = library.makeFunction(name: fragment)
            d.rasterSampleCount = view.sampleCount
            d.depthAttachmentPixelFormat = view.depthStencilPixelFormat
            let c = d.colorAttachments[0]!
            c.pixelFormat = view.colorPixelFormat
            if let blend {
                c.isBlendingEnabled = true
                c.sourceRGBBlendFactor = .sourceAlpha
                c.destinationRGBBlendFactor = blend == .additive ? .one : .oneMinusSourceAlpha
                c.sourceAlphaBlendFactor = .one
                c.destinationAlphaBlendFactor = blend == .additive ? .one : .oneMinusSourceAlpha
            }
            return try? device.makeRenderPipelineState(descriptor: d)
        }
        guard let earthPSO = pipeline("earthVertex", "earthFragment", blend: nil),
              let atmospherePSO = pipeline("earthVertex", "atmosphereFragment", blend: .additive),
              let plinthPSO = pipeline("plinthVertex", "plinthFragment", blend: .normal),
              let spritePSO = pipeline("spriteVertex", "spriteFragment", blend: .normal),
              let spriteAddPSO = pipeline("spriteVertex", "spriteFragment", blend: .additive),
              let linePSO = pipeline("lineVertex", "lineFragment", blend: .normal),
              let lineAddPSO = pipeline("lineVertex", "lineFragment", blend: .additive)
        else { return nil }
        self.earthPSO = earthPSO
        self.atmospherePSO = atmospherePSO
        self.plinthPSO = plinthPSO
        self.spritePSO = spritePSO
        self.spriteAddPSO = spriteAddPSO
        self.linePSO = linePSO
        self.lineAddPSO = lineAddPSO

        func depth(_ compare: MTLCompareFunction, write: Bool) -> MTLDepthStencilState {
            let d = MTLDepthStencilDescriptor()
            d.depthCompareFunction = compare
            d.isDepthWriteEnabled = write
            return device.makeDepthStencilState(descriptor: d)!
        }
        depthWrite = depth(.less, write: true)
        depthTest = depth(.less, write: false)
        depthNone = depth(.always, write: false)

        let s = MTLSamplerDescriptor()
        s.minFilter = .linear
        s.magFilter = .linear
        s.mipFilter = .linear
        s.maxAnisotropy = 4
        s.sAddressMode = .repeat
        s.tAddressMode = .clampToEdge
        sampler = device.makeSamplerState(descriptor: s)!

        let mesh = Self.sphere(segments: 96)
        earthVertices = device.makeBuffer(bytes: mesh.vertices, length: mesh.vertices.count * 4)!
        earthIndices = device.makeBuffer(bytes: mesh.indices, length: mesh.indices.count * 2)!
        earthIndexCount = mesh.indices.count
        let grat = Self.graticuleSegments()
        graticule = device.makeBuffer(bytes: grat, length: grat.count * MemoryLayout<Segment>.stride)!
        graticuleCount = grat.count
        let sky = Self.starField()
        stars = device.makeBuffer(bytes: sky.stars, length: sky.stars.count * MemoryLayout<Sprite>.stride)!
        starCount = sky.stars.count
        nebulae = device.makeBuffer(bytes: sky.nebulae, length: sky.nebulae.count * MemoryLayout<Sprite>.stride)!
        nebulaCount = sky.nebulae.count
        for _ in 0..<Self.inFlight {
            spriteBuffers.append(device.makeBuffer(length: Self.maxSprites * MemoryLayout<Sprite>.stride, options: .storageModeShared)!)
            trailBuffers.append(device.makeBuffer(length: Self.trailSegments * MemoryLayout<Segment>.stride, options: .storageModeShared)!)
        }
        super.init()
    }

    private enum Blend { case normal, additive }

    private var palette: Palette { .of(dark: dark) }

    private func earthTexture() -> MTLTexture? {
        if let t = earthTextures[dark] { return t }
        let t = EarthTexture.make(device: device, queue: queue, palette: palette)
        earthTextures[dark] = t
        return t
    }

    // MARK: - Frame

    nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    nonisolated func draw(in view: MTKView) {
        MainActor.assumeIsolated { render(view) }
    }

    private func render(_ view: MTKView) {
        let now = CACurrentMediaTime()
        let dt = now - lastTime
        lastTime = now
        let date = Date()
        let jd = Julian.jday(date)
        let pal = palette
        let store = model.store
        store.propagate(jd: jd)

        // Camera: fitted to the screen, requests from the model, then the
        // controls. When the screen changes shape (turned, an iPad window
        // resized, an iPhone Duo opened or closed) the distance follows, so the
        // Earth fills as much of the new screen as it did of the old.
        if view.drawableSize.width > 0, view.drawableSize.height > 0 {
            let aspect = view.drawableSize.width / view.drawableSize.height
            if let was = fittedAspect {
                if abs(aspect - was) > 0.01 {
                    camera.refit(from: was, to: aspect)
                    fittedAspect = aspect
                }
            } else {
                camera.fit(aspect: aspect)
                fittedAspect = aspect
            }
        }
        if let request = model.cameraRequest {
            model.cameraRequest = nil
            apply(request)
        }
        if model.following, let sat = model.selected, sat.alive {
            camera.goal = .init(position: framing(sat.pos), thenAutoRotate: false)
        }
        camera.update(dt: dt)

        viewSizePt = view.bounds.size
        let drawable = view.drawableSize
        guard drawable.width > 0, drawable.height > 0 else { return }

        // While the card is open the Earth moves into the space it leaves:
        // up between the toolbar and the card, or across beside a side panel,
        // so what you tapped stays in view.
        let top = Double(view.safeAreaInsets.top) + 44
        let target: SIMD2<Double>
        switch cardSpace {
        case .sheet: target = SIMD2(0, max(0, (Double(SatelliteCard.compact) + 8 - top) / 2))
        case .side(let width):
            // A bar down the side (iPhone Duo) narrows what is left too.
            let insets = view.safeAreaInsets
            target = SIMD2((Double(insets.left) + Double(width) + 16 - Double(insets.right)) / 2, 0)
        case .bottom(let height):
            target = SIMD2(0, max(0, (Double(height) + 8 + Double(view.safeAreaInsets.bottom) + 56 - top) / 2))
        case nil: target = .zero
        }
        shiftPt += (target - shiftPt) * (1 - pow(0.82, min(max(dt, 0), 0.25) * 60))
        let shift = simd_float4x4(columns: (SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 1, 0),
                                            SIMD4(Float(2 * shiftPt.x / max(viewSizePt.width, 1)),
                                                  Float(2 * shiftPt.y / max(viewSizePt.height, 1)), 0, 1)))
        let proj = shift * OrbitCamera.projection(aspect: drawable.width / drawable.height)
        let viewM = camera.view
        viewProj = proj * viewM
        let camDist = camera.radius
        let lamp = normalize(SIMD3<Float>(-2.2, 2.4, 4.2))
        var frame = FrameUniforms(
            viewProj: viewProj, view: viewM, proj: proj,
            viewport: SIMD2(Float(drawable.width), Float(drawable.height)),
            pxPerPt: Float(view.contentScaleFactor), halfHeight: Float(drawable.height / 2),
            lampDir: lamp, ambient: dark ? 0.78 : 0.8, lamp: dark ? 0.5 : 0.26,
            time: Float(now - startTime),
            plinthScale: Float(camDist / max(1e-2, (camDist * camDist - 1)).squareRoot())
        )

        // Sprites this frame: the satellites, then the ring and you.
        semaphore.wait()
        frameIndex = (frameIndex + 1) % Self.inFlight
        let spriteBuf = spriteBuffers[frameIndex]
        let sprites = spriteBuf.contents().bindMemory(to: Sprite.self, capacity: Self.maxSprites)
        // Smaller when zoomed out; a dark dot weighs more than a bright one of
        // the same size, so they are a little smaller on the light theme.
        let dotSize = Float(max(7, min(18, 22 - camDist)) * (dark ? 1 : 0.72))
        let dotShape: Shape = dark ? .soft : .solid
        var count = 0
        for s in store.sats where s.alive && count < Self.maxSprites - 2 {
            sprites[count] = Sprite(s.pos, size: dotSize, color: pal.color(for: s.category.id), alpha: 1, shape: dotShape)
            count += 1
        }
        let satCount = count
        // The ring round the selected one, a few points clear of its dot.
        var ringIndex: Int?
        if let sel = model.selected, sel.alive, !hiddenByEarth(SIMD3<Double>(sel.pos)) {
            sprites[count] = Sprite(sel.pos, size: max(20, dotSize + 12), color: pal.accent, alpha: 0.9, shape: .ring)
            ringIndex = count
            count += 1
        }
        // "You are here": one green dot, breathing on the panels' 1.6 s beat.
        var youIndex: Int?
        if let o = model.observer {
            let p = SatStore.sceneVector(latDeg: o.latitudeDeg, lonDeg: o.longitudeDeg, radius: 1.003)
            if !hiddenByEarth(SIMD3<Double>(p), r: 0.999) {
                let b = Float(0.5 + 0.5 * sin((now - startTime) * 3.9))
                sprites[count] = Sprite(p, size: 9.5 + 2 * b, color: pal.good, alpha: 0.5 + 0.5 * b, shape: .solid)
                youIndex = count
                count += 1
            }
        }

        // The selected satellite's orbit, every 0.8 s.
        updateTrail(now: now, date: date, palette: pal)
        let trailBuf = trailBuffers[frameIndex]
        let trailCount = min(trail.count, Self.trailSegments)
        if trailCount > 0 {
            trail.withUnsafeBytes { trailBuf.contents().copyMemory(from: $0.baseAddress!, byteCount: trailCount * MemoryLayout<Segment>.stride) }
        }

        view.clearColor = MTLClearColor(red: pal.bg.r, green: pal.bg.g, blue: pal.bg.b, alpha: 1)
        guard let pass = view.currentRenderPassDescriptor, let drawableTarget = view.currentDrawable,
              let cmd = queue.makeCommandBuffer(), let enc = cmd.makeRenderCommandEncoder(descriptor: pass)
        else {
            semaphore.signal()
            return
        }
        let sem = semaphore
        cmd.addCompletedHandler { _ in sem.signal() }
        enc.setFrontFacing(.counterClockwise)
        enc.setVertexBytes(&frame, length: MemoryLayout<FrameUniforms>.stride, index: 1)
        enc.setFragmentBytes(&frame, length: MemoryLayout<FrameUniforms>.stride, index: 1)

        // The Earth (opaque).
        var one: Float = 1
        enc.setRenderPipelineState(earthPSO)
        enc.setDepthStencilState(depthWrite)
        enc.setCullMode(.back)
        enc.setVertexBuffer(earthVertices, offset: 0, index: 0)
        enc.setVertexBytes(&one, length: 4, index: 2)
        enc.setFragmentTexture(earthTexture(), index: 0)
        enc.setFragmentSamplerState(sampler, index: 0)
        enc.drawIndexedPrimitives(type: .triangle, indexCount: earthIndexCount, indexType: .uint16, indexBuffer: earthIndices, indexBufferOffset: 0)
        enc.setCullMode(.none)

        // Stars and nebulae: the dark theme's backdrop.
        if dark {
            enc.setRenderPipelineState(spritePSO)
            enc.setDepthStencilState(depthTest)
            enc.setVertexBuffer(stars, offset: 0, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: starCount)
            enc.setRenderPipelineState(spriteAddPSO)
            enc.setVertexBuffer(nebulae, offset: 0, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: nebulaCount)
        }

        // The raised globe's shadow pair.
        var plinth = (SIMD4<Float>(pal.dark.simd, dark ? 0.9 : 1), SIMD4<Float>(pal.light.simd, 1))
        enc.setRenderPipelineState(plinthPSO)
        enc.setDepthStencilState(depthTest)
        enc.setFragmentBytes(&plinth, length: MemoryLayout<SIMD4<Float>>.stride * 2, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)

        // You (not depth-tested: a flat dot on a curved surface would lose half
        // of itself near the horizon; hiddenByEarth decided already).
        enc.setVertexBuffer(spriteBuf, offset: 0, index: 0)
        if let i = youIndex {
            enc.setRenderPipelineState(spritePSO)
            enc.setDepthStencilState(depthNone)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: 1, baseInstance: i)
        }

        // The graticule, faint, in the accent.
        var gratTint = SIMD4<Float>(pal.accent.simd, dark ? 0.14 : 0.13)
        var gratWidth: Float = 0.6
        enc.setRenderPipelineState(linePSO)
        enc.setDepthStencilState(depthTest)
        enc.setVertexBuffer(graticule, offset: 0, index: 0)
        enc.setVertexBytes(&gratTint, length: 16, index: 2)
        enc.setVertexBytes(&gratWidth, length: 4, index: 3)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: graticuleCount)

        // The atmosphere: an accent rim, dark theme only (additive light is
        // invisible on a light surface).
        if dark {
            var radius: Float = 1.035
            var color = SIMD4<Float>(pal.accent.simd, 1)
            enc.setRenderPipelineState(atmospherePSO)
            enc.setDepthStencilState(depthTest)
            enc.setCullMode(.front)
            enc.setVertexBuffer(earthVertices, offset: 0, index: 0)
            enc.setVertexBytes(&radius, length: 4, index: 2)
            enc.setFragmentBytes(&color, length: 16, index: 0)
            enc.drawIndexedPrimitives(type: .triangle, indexCount: earthIndexCount, indexType: .uint16, indexBuffer: earthIndices, indexBufferOffset: 0)
            enc.setCullMode(.none)
        }

        // The selected satellite's orbit: glowing on the slate, plain on light.
        if trailCount > 0 {
            var tint = SIMD4<Float>(1, 1, 1, dark ? 0.8 : 0.9)
            var width: Float = 1.2
            enc.setRenderPipelineState(dark ? lineAddPSO : linePSO)
            enc.setDepthStencilState(depthTest)
            enc.setVertexBuffer(trailBuf, offset: 0, index: 0)
            enc.setVertexBytes(&tint, length: 16, index: 2)
            enc.setVertexBytes(&width, length: 4, index: 3)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: trailCount)
        }

        // The satellites, then the ring over its dot.
        enc.setVertexBuffer(spriteBuf, offset: 0, index: 0)
        if satCount > 0 {
            enc.setRenderPipelineState(spritePSO)
            enc.setDepthStencilState(depthTest)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: satCount)
        }
        if let i = ringIndex {
            enc.setRenderPipelineState(spritePSO)
            enc.setDepthStencilState(depthNone)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: 1, baseInstance: i)
        }

        enc.endEncoding()
        cmd.present(drawableTarget)
        cmd.commit()
    }

    // MARK: - Camera

    private func apply(_ request: CameraRequest) {
        switch request {
        case let .face(lat, lon):
            // The page's first-fix swing: you, front and centre, from a little above.
            let n = SIMD3<Double>(SatStore.sceneVector(latDeg: lat, lonDeg: lon, radius: 1))
            var goal = normalize(n) * length(camera.position)
            goal.y += 0.35
            camera.autoRotate = false
            camera.goal = .init(position: goal, thenAutoRotate: true)
        case let .satellite(norad):
            // Never worked out (decayed, say): its position is a placeholder.
            guard let sat = model.store.sat(norad: norad), sat.alive else { return }
            camera.autoRotate = false
            camera.goal = .init(position: framing(sat.pos), thenAutoRotate: false)
        }
    }

    /// Where to look at a satellite from: straight above it, far enough out
    /// that it sits in front of the Earth with room around it.
    private func framing(_ p: SIMD3<Float>) -> SIMD3<Double> {
        let d = SIMD3<Double>(p)
        let r = length(d)
        guard r > 1e-6, r.isFinite else { return camera.position }
        let dist = min(max(camera.radius, r * 1.8, r + 1.2), OrbitCamera.maxDistance)
        return normalize(d) * dist
    }

    func touched() {
        camera.touched()
        model.following = false
    }

    // MARK: - Picking

    /// The page's screen-space pick: the visible dot nearest the finger within
    /// 24 points; dots within 2 points of each other go to the first in the
    /// catalogue (the ISS, not a ship docked to it).
    func pick(at point: CGPoint) -> Int? {
        let radius = 24.0, tie = 2.0
        var best: Int?
        var bestD = Double.infinity
        for s in model.store.sats where s.alive {
            let p = SIMD3<Double>(s.pos)
            guard !hiddenByEarth(p), let scr = toScreen(s.pos) else { continue }
            let d = hypot(scr.x - point.x, scr.y - point.y)
            if d < radius && d < bestD - tie {
                best = s.norad
                bestD = d
            }
        }
        return best
    }

    private func toScreen(_ v: SIMD3<Float>) -> CGPoint? {
        let c = viewProj * SIMD4(v, 1)
        guard c.w > 0 else { return nil }
        let z = c.z / c.w
        guard z >= 0, z <= 1 else { return nil }
        return CGPoint(x: Double((c.x / c.w + 1) / 2) * viewSizePt.width,
                       y: Double((1 - c.y / c.w) / 2) * viewSizePt.height)
    }

    /// Is the straight line from the camera to `v` blocked by the globe? The
    /// same occlusion the depth buffer gives the dots, so what cannot be seen
    /// cannot be tapped through the Earth.
    private func hiddenByEarth(_ v: SIMD3<Double>, r: Double = 1) -> Bool {
        let c = camera.position
        var w = v - c
        let len = length(w)
        guard len > 0 else { return false }
        w /= len
        let b = dot(c, w), q = length_squared(c) - r * r
        let disc = b * b - q
        guard disc > 0 else { return false }
        let t = -b - disc.squareRoot()
        return t > 0 && t < len
    }

    // MARK: - The selected satellite's orbit

    /// One full orbit centred on now, 120 segments, brightest at the satellite
    /// and fading both ways (in alpha, so it fades on the light theme too).
    private func updateTrail(now: Double, date: Date, palette: Palette) {
        guard let sel = model.selected else {
            trail.removeAll()
            trailNorad = nil
            return
        }
        guard sel.norad != trailNorad || now - trailTime > 0.8 else { return }
        trailNorad = sel.norad
        trailTime = now
        trail.removeAll(keepingCapacity: true)
        let period = sel.satrec.periodMinutes
        guard period.isFinite, period > 0 else { return }
        let c = palette.color(for: sel.category.id).simd
        let n = Self.trailSegments
        let base = Julian.jday(date)
        var prev: (SIMD3<Float>, Float)?
        for i in 0...n {
            let tmin = -period * 0.5 + period * Double(i) / Double(n)
            let jd = base + tmin / 1440
            guard let pv = sel.satrec.propagate(jd: jd) else { prev = nil; continue }
            let gd = Coordinates.eciToGeodetic(pv.position, gmst: Julian.gstime(jd))
            let v = SatStore.sceneVector(latDeg: gd.latitudeDeg, lonDeg: gd.longitudeDeg,
                                         radius: 1 + gd.height / SatStore.earthRadiusKm)
            let f = Float(max(0.12, 1 - abs(Double(i) / Double(n) - 0.5) * 2))
            if let (pp, pf) = prev {
                trail.append(Segment(pp, v, SIMD4(c, pf), SIMD4(c, f)))
            }
            prev = (v, f)
        }
    }

    // MARK: - Geometry

    /// A latitude/longitude sphere laid out like three.js's SphereGeometry, so
    /// the equirectangular map lines up with `sceneVector`: Greenwich on +X.
    static func sphere(segments n: Int) -> (vertices: [Float], indices: [UInt16]) {
        var v: [Float] = []
        for i in 0...n {
            let lat = 90 - 180 * Double(i) / Double(n)
            for j in 0...n {
                let lon = -180 + 360 * Double(j) / Double(n)
                let p = SatStore.sceneVector(latDeg: lat, lonDeg: lon, radius: 1)
                v += [p.x, p.y, p.z, Float(Double(j) / Double(n)), Float(Double(i) / Double(n))]
            }
        }
        var idx: [UInt16] = []
        let row = n + 1
        for i in 0..<n {
            for j in 0..<n {
                let a = UInt16(i * row + j), b = UInt16((i + 1) * row + j)
                idx += [a, b, a + 1, a + 1, b, b + 1]
            }
        }
        return (v, idx)
    }

    /// Latitude lines every 30° (±60 and the equator between), meridians every 30°.
    static func graticuleSegments() -> [Segment] {
        var out: [Segment] = []
        let white = SIMD4<Float>(1, 1, 1, 1)
        func add(_ a: SIMD3<Float>, _ b: SIMD3<Float>) { out.append(Segment(a, b, white, white)) }
        for lat in stride(from: -60.0, through: 60, by: 30) {
            for lon in stride(from: -180.0, to: 180, by: 5) {
                add(SatStore.sceneVector(latDeg: lat, lonDeg: lon, radius: 1.001),
                    SatStore.sceneVector(latDeg: lat, lonDeg: lon + 5, radius: 1.001))
            }
        }
        for lon in stride(from: -180.0, to: 180, by: 30) {
            for lat in stride(from: -90.0, to: 90, by: 5) {
                add(SatStore.sceneVector(latDeg: lat, lonDeg: lon, radius: 1.001),
                    SatStore.sceneVector(latDeg: lat + 5, lonDeg: lon, radius: 1.001))
            }
        }
        return out
    }

    /// 1,800 stars between 34 and 74 radii out, in five tints, and three faint
    /// nebula clouds — the page's galaxy backdrop, with a fixed seed.
    static func starField() -> (stars: [Sprite], nebulae: [Sprite]) {
        var rng = SplitMix64(seed: 0x0_2b17)
        let tints: [RGB] = [RGB(r: 1, g: 1, b: 1), RGB(r: 0.75, g: 0.68, b: 1), RGB(r: 1, g: 0.7, b: 0.95),
                            RGB(r: 0.6, g: 0.8, b: 1), RGB(r: 0.85, g: 0.75, b: 1)]
        func onSphere(_ r: Double) -> SIMD3<Float> {
            let t = rng.next() * 2 * .pi, p = acos(2 * rng.next() - 1)
            return SIMD3(Float(r * sin(p) * cos(t)), Float(r * cos(p)), Float(r * sin(p) * sin(t)))
        }
        var stars: [Sprite] = []
        for _ in 0..<1800 {
            let pos = onSphere(34 + rng.next() * 40)
            let c = tints[Int(rng.next() * Double(tints.count)) % tints.count], b = 0.45 + rng.next() * 0.5
            stars.append(Sprite(pos, size: 0.07, color: RGB(r: c.r * b, g: c.g * b, b: c.b * b), alpha: 1,
                                shape: .glow, sizing: .attenuated))
        }
        let nebColors = [RGB(0x6a2cff), RGB(0xb02cff), RGB(0x2c66ff)]
        let nebulae = nebColors.map {
            Sprite(onSphere(45), size: Float(30 + rng.next() * 20), color: $0, alpha: 0.07, shape: .glow, sizing: .world)
        }
        return (stars, nebulae)
    }
}

/// A small seeded generator, so the sky is the same every launch.
struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    /// 0 ..< 1
    mutating func next() -> Double {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Double(z >> 11) / Double(1 << 53)
    }
}
