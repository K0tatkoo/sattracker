import CoreGraphics
import ImageIO
import Metal
import OrbitCore

/// The bundled Earth (the Android page's lib/earth-dark.jpg, used in place) is
/// a greyscale map: land ~0, deep ocean ~12-17, shelves ~25-30 (of 255).
/// Rather than tint it — which can only ever make it darker — it is repainted
/// once per theme into that theme's own land / ocean colours, keeping the
/// shelf gradient. On the light theme that turns it into a light globe with
/// the continents still readable, which a multiplied tint cannot do.
enum EarthTexture {
    static func make(device: MTLDevice, queue: MTLCommandQueue, palette: Palette) -> MTLTexture? {
        guard let url = Bundle.main.url(forResource: "earth-dark", withExtension: "jpg"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        let w = image.width, h = image.height
        // Drawn in the image's own colour space, so the grey levels arrive as
        // they are in the file (a conversion would bend the dark end, which is
        // exactly where the thresholds below sit).
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = pixels.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }

        // Two ramps over the 256 grey levels, so the per-pixel loop is a read.
        let l = palette.land, d = palette.deep, s = palette.shelf
        var lut = [UInt8](repeating: 0, count: 256 * 3)
        for g in 0..<256 {
            let sea = min(1, max(0, (Double(g) - 3) / 6))       // land -> ocean over 3..9
            let t = min(1, max(0, (Double(g) - 11) / 18))       // deep -> shelf over 11..29
            for (k, (lk, dk, sk)) in [(l.r, d.r, s.r), (l.g, d.g, s.g), (l.b, d.b, s.b)].enumerated() {
                let ocean = dk + (sk - dk) * t
                lut[g * 3 + k] = UInt8(min(255, max(0, ((lk + (ocean - lk) * sea) * 255).rounded(.toNearestOrEven))))
            }
        }
        pixels.withUnsafeMutableBufferPointer { p in
            lut.withUnsafeBufferPointer { lut in
                var i = 0
                while i < p.count {
                    let g = (Int(p[i]) + Int(p[i + 1]) + Int(p[i + 2])) / 3
                    p[i] = lut[g * 3]
                    p[i + 1] = lut[g * 3 + 1]
                    p[i + 2] = lut[g * 3 + 2]
                    p[i + 3] = 255
                    i += 4
                }
            }
        }

        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: true)
        desc.usage = .shaderRead
        guard let tex = device.makeTexture(descriptor: desc) else { return nil }
        pixels.withUnsafeBytes {
            tex.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: w * 4)
        }
        if let cmd = queue.makeCommandBuffer(), let blit = cmd.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: tex)
            blit.endEncoding()
            cmd.commit()
        }
        return tex
    }
}
