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

/// Orbit's mark: a planet and one orbit, with a satellite on it — the page's
/// `i-orbit` symbol, drawn on its 24-point grid.
struct OrbitMark: View {
    var lineWidth: CGFloat = 1.75

    var body: some View {
        Canvas { ctx, size in
            let k = min(size.width, size.height) / 24
            ctx.translateBy(x: (size.width - 24 * k) / 2, y: (size.height - 24 * k) / 2)
            ctx.scaleBy(x: k, y: k)
            // In grid units, like the SVG's stroke: it scales with the mark.
            let style = StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
            ctx.stroke(Path(ellipseIn: CGRect(x: 8, y: 8, width: 8, height: 8)), with: .foreground, style: style)
            var orbit = Path(ellipseIn: CGRect(x: 2, y: 7.7, width: 20, height: 8.6))
            orbit = orbit.applying(CGAffineTransform(translationX: -12, y: -12)
                .concatenating(CGAffineTransform(rotationAngle: -26 * .pi / 180))
                .concatenating(CGAffineTransform(translationX: 12, y: 12)))
            ctx.stroke(orbit, with: .foreground, style: style)
            ctx.fill(Path(ellipseIn: CGRect(x: 20.2 - 1.4, y: 7.3 - 1.4, width: 2.8, height: 2.8)), with: .foreground)
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
