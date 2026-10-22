/// An sRGB colour, 0…1 a channel.
public struct RGB: Sendable, Hashable {
    public var r: Double
    public var g: Double
    public var b: Double

    public init(_ hex: UInt32) {
        r = Double((hex >> 16) & 0xff) / 255
        g = Double((hex >> 8) & 0xff) / 255
        b = Double(hex & 0xff) / 255
    }

    public init(r: Double, g: Double, b: Double) {
        self.r = r
        self.g = g
        self.b = b
    }

    public var simd: SIMD3<Float> { SIMD3(Float(r), Float(g), Float(b)) }
}

/// Orbit's colours: the page's styles.css tokens, value for value, which are
/// the store's and the other apps' (Palette.kt). The satellite colours are one
/// list for the globe, the chips, the card and the widget, so a colour can
/// never mean one thing in one place and another elsewhere. The dark set is
/// bright to glow on the slate; the light set is the same hues taken dark
/// enough to hold up on a light-grey globe.
public struct Palette: Sendable {
    public let isDark: Bool
    public let bg: RGB
    public let bgDeep: RGB
    /// The two neumorphic shadows: away from the light, and facing it.
    public let dark: RGB
    public let light: RGB
    public let text: RGB
    public let textDim: RGB
    public let textFaint: RGB
    public let accent: RGB
    public let accent2: RGB
    /// Filled controls: one flat violet, never a gradient.
    public let accentFill: RGB
    public let good: RGB
    public let warn: RGB
    public let bad: RGB
    /// Text on a filled satellite-colour tag.
    public let tagInk: RGB
    /// The Earth repainted: land, deep ocean, continental shelf.
    public let land: RGB
    public let deep: RGB
    public let shelf: RGB
    let categories: [String: RGB]

    public func color(for categoryId: String) -> RGB {
        categories[categoryId] ?? categories["unknown"]!
    }

    public static func of(dark: Bool) -> Palette { dark ? .dark : .light }

    public static let dark = Palette(
        isDark: true,
        bg: RGB(0x22252c), bgDeep: RGB(0x1b1e24), dark: RGB(0x171920), light: RGB(0x2d313a),
        text: RGB(0xeef1f7), textDim: RGB(0xa3abbd), textFaint: RGB(0x737b8c),
        accent: RGB(0x9b7cff), accent2: RGB(0x34e3ff), accentFill: RGB(0x6a45ff),
        good: RGB(0x4ade80), warn: RGB(0xf5c451), bad: RGB(0xff6b6b), tagInk: RGB(0x14161b),
        land: RGB(0x191b21), deep: RGB(0x2e2e41), shelf: RGB(0x3d385a),
        categories: [
            "stations": RGB(0xffffff), "gps": RGB(0x38e1ff), "glonass": RGB(0xff7b7b),
            "galileo": RGB(0x8affc1), "beidou": RGB(0xffcb5b), "starlink": RGB(0xb58bff),
            "weather": RGB(0x5bd0ff), "science": RGB(0xff9edb), "unknown": RGB(0x93a7c4),
            "pinned": RGB(0x93a7c4),
        ]
    )

    public static let light = Palette(
        isDark: false,
        bg: RGB(0xe7eaf1), bgDeep: RGB(0xdde1ea), dark: RGB(0xc1c6d1), light: RGB(0xffffff),
        text: RGB(0x1c2029), textDim: RGB(0x545c6c), textFaint: RGB(0x7b8394),
        accent: RGB(0x5f43e8), accent2: RGB(0x0a9fbd), accentFill: RGB(0x5734db),
        good: RGB(0x17914d), warn: RGB(0xa06f04), bad: RGB(0xcf3535), tagInk: RGB(0xffffff),
        land: RGB(0xf1f3f7), deep: RGB(0xb8bed6), shelf: RGB(0xccd1e3),
        categories: [
            "stations": RGB(0x2a2f3a), "gps": RGB(0x0a93b8), "glonass": RGB(0xd23f3f),
            "galileo": RGB(0x13935a), "beidou": RGB(0xb07400), "starlink": RGB(0x6a4fe0),
            "weather": RGB(0x1f74c4), "science": RGB(0xc0418f), "unknown": RGB(0x66708a),
            "pinned": RGB(0x66708a),
        ]
    )
}
