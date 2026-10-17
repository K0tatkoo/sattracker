import Foundation

/// Two-Line-Element sets from Celestrak, with the same fallbacks as the
/// Android app's TleRepository.kt: a cache younger than 3 hours, then the
/// network, then any older cache, then the snapshot bundled with the page —
/// per group, never a generic one, so a category never shows satellites that
/// don't belong to it. `source` tells the page which one it got.
actor TleRepository {
    struct Result: Sendable {
        let text: String
        let source: String
    }

    private static let maxAge: TimeInterval = 3 * 60 * 60
    /// Never hand the page more than this many satellites (Starlink is 1.8 MB).
    private static let maxSats = 400

    private let bundled: URL
    private let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 90
        config.httpAdditionalHeaders = ["User-Agent": "OrbitSatTracker/1.0 (iOS)"]
        return URLSession(configuration: config)
    }()

    /// `bundled` is the page's `tle/` folder.
    init(bundled: URL) { self.bundled = bundled }

    func tle(for group: String) async -> Result {
        let name = group.replacingOccurrences(of: "[^A-Za-z0-9_-]", with: "_", options: .regularExpression)
        let cache = cacheDir.appendingPathComponent("tle_\(name).txt")

        if let age = Self.age(of: cache), age < Self.maxAge, let text = Self.read(cache) {
            return Result(text: Self.cap(text), source: "cache")
        }
        if let text = await download(name), Self.looksLikeTle(text) {
            try? text.write(to: cache, atomically: true, encoding: .utf8)
            return Result(text: Self.cap(text), source: "live")
        }
        if let text = Self.read(cache) {
            return Result(text: Self.cap(text), source: "cache")
        }
        if let text = Self.read(bundled.appendingPathComponent("\(name).txt")) {
            return Result(text: Self.cap(text), source: "offline")
        }
        return Result(text: "", source: "none")
    }

    private func download(_ group: String) async -> String? {
        var url = URLComponents(string: "https://celestrak.org/NORAD/elements/gp.php")!
        url.queryItems = [URLQueryItem(name: "GROUP", value: group), URLQueryItem(name: "FORMAT", value: "tle")]
        for _ in 0..<2 {
            if let (data, response) = try? await session.data(from: url.url!),
               (response as? HTTPURLResponse)?.statusCode == 200,
               let text = String(data: data, encoding: .utf8), !text.isEmpty {
                return text
            }
        }
        return nil
    }

    private static func read(_ url: URL) -> String? {
        guard let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty else { return nil }
        return text
    }

    private static func age(of url: URL) -> TimeInterval? {
        guard let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        else { return nil }
        return Date().timeIntervalSince(modified)
    }

    private static func cap(_ text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        return lines.count <= maxSats * 3 ? text : lines.prefix(maxSats * 3).joined(separator: "\n")
    }

    private static func looksLikeTle(_ text: String) -> Bool {
        var line1 = false, line2 = false
        for line in text.split(separator: "\n") where line.count > 60 {
            if line.hasPrefix("1 ") { line1 = true } else if line.hasPrefix("2 ") { line2 = true }
            if line1 && line2 { return true }
        }
        return false
    }
}
