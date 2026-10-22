import SwiftUI
import OrbitCore

extension Color {
    init(_ rgb: RGB, opacity: Double = 1) {
        self.init(.sRGB, red: rgb.r, green: rgb.g, blue: rgb.b, opacity: opacity)
    }

    /// A satellite category's colour in the current light/dark appearance.
    static func category(_ id: String, dark: Bool) -> Color {
        Color(Palette.of(dark: dark).color(for: id))
    }
}

extension Palette {
    static func of(_ scheme: ColorScheme) -> Palette { .of(dark: scheme == .dark) }
}

/// Orbit's mark, the ringed planet: the shape tools/launcher-icon.py writes
/// into OrbitMarkGeometry, filled in the foreground colour and centred in its
/// frame on the 24-unit grid, the way the page's SVG symbol sits.
struct OrbitMark: View {
    var body: some View {
        Canvas { ctx, size in
            let k = min(size.width, size.height) / 24
            ctx.translateBy(x: (size.width - 24 * k) / 2, y: (size.height - 24 * k) / 2)
            ctx.scaleBy(x: k, y: k)
            var path = Path()
            for outline in OrbitMarkGeometry.outlines {
                path.addLines(outline.map { CGPoint(x: $0.0, y: $0.1) })
                path.closeSubpath()
            }
            ctx.fill(path, with: .foreground, style: FillStyle(eoFill: true))
        }
        .accessibilityHidden(true)
    }
}

/// Compass points, for "rises in the SW".
enum Compass {
    static func point(_ azimuthDeg: Double) -> String {
        let names = ["N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE", "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW"]
        let a = azimuthDeg.truncatingRemainder(dividingBy: 360)
        return names[Int(((a < 0 ? a + 360 : a) / 22.5).rounded()) % 16]
    }
}
