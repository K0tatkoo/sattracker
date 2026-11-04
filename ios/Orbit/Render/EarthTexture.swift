import CoreGraphics
import ImageIO
import Metal

/// The bundled Earth (the Android page's lib/earth-dark.jpg, used in place) is
/// a greyscale map: land ~0, deep ocean ~12-17, shelves ~25-30 (of 255), with
/// soft coasts a couple of map pixels wide. Rather than tint it — which can
/// only ever make it darker — the shader repaints it in the theme's own land /
/// ocean colours (`earthFragment`), keeping the shelf gradient. On the light
/// theme that turns it into a light globe with the continents still readable.
///
/// It reaches the GPU still grey, and is coloured only after the GPU has
/// blended neighbouring map pixels: the coast is then drawn where the blended
/// grey crosses the land/ocean line, a smooth curve between map pixels even
/// close up. Painted into colours first (as it was), a close-up showed the map
/// pixels themselves as a blurred staircase along every coast.
enum EarthTexture {
    static func make(device: MTLDevice, queue: MTLCommandQueue) -> MTLTexture? {
        guard let url = Bundle.main.url(forResource: "earth-dark", withExtension: "jpg"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        let w = image.width, h = image.height
        // Drawn in the image's own colour space, so the grey levels arrive as
        // they are in the file (a conversion would bend the dark end, which is
        // exactly where the shader's land/ocean line sits).
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

        // One grey channel: the JPEG's three (equal but for its noise), averaged.
        var grey = [UInt8](repeating: 0, count: w * h)
        pixels.withUnsafeBufferPointer { p in
            grey.withUnsafeMutableBufferPointer { g in
                for i in 0..<(w * h) {
                    g[i] = UInt8((Int(p[i * 4]) + Int(p[i * 4 + 1]) + Int(p[i * 4 + 2])) / 3)
                }
            }
        }

        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: w, height: h, mipmapped: true)
        desc.usage = .shaderRead
        guard let tex = device.makeTexture(descriptor: desc) else { return nil }
        grey.withUnsafeBytes {
            tex.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: w)
        }
        if let cmd = queue.makeCommandBuffer(), let blit = cmd.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: tex)
            blit.endEncoding()
            cmd.commit()
        }
        return tex
    }
}
