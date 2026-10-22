import Foundation
import OrbitCore

/// Two-Line-Element sets from Celestrak, with the same fallbacks as the
/// Android app's TleRepository.kt: a cache younger than 3 hours, then the
/// network, then any older cache, then the snapshot bundled with the app —
/// per group, never a generic one, so a category never shows satellites that
/// don't belong to it. `source` says which one it got.
///
/// The cache sits in the App Group, so the widget reads what the app fetched
/// (and the other way round).
actor TleRepository {
    enum Source: String, Sendable {
        case cache, live, offline, none
    }

    struct Result: Sendable {
        let text: String
        let source: Source
    }

    private static let maxAge: TimeInterval = 3 * 60 * 60
    /// Never keep more than this many satellites of a group (Starlink is 1.8 MB).
    private static let maxSats = 400

    private let cacheDir: URL
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 90
        config.httpAdditionalHeaders = ["User-Agent": "OrbitSatTracker/2.0 (iOS)"]
        return URLSession(configuration: config)
    }()

    init() {
        let shared = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: SharedStore.appGroup)?
            .appendingPathComponent("Library/Caches", isDirectory: true)
        let dir = shared ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        cacheDir = dir
    }

    /// A whole Celestrak group (GROUP=…).
    func tle(for group: String) async -> Result {
        let name = group.replacingOccurrences(of: "[^A-Za-z0-9_-]", with: "_", options: .regularExpression)
        let cache = cacheDir.appendingPathComponent("tle_\(name).txt")

        if let age = Self.age(of: cache), age < Self.maxAge, let text = Self.read(cache) {
            return Result(text: Self.cap(text), source: .cache)
        }
        if let text = await download(["GROUP": group]), TLE.looksLikeTle(text) {
            try? text.write(to: cache, atomically: true, encoding: .utf8)
            return Result(text: Self.cap(text), source: .live)
        }
        if let text = Self.read(cache) {
            return Result(text: Self.cap(text), source: .cache)
        }
        if let bundled = Bundle.main.url(forResource: "tle", withExtension: nil),
           let text = Self.read(bundled.appendingPathComponent("\(name).txt"))
        {
            return Result(text: Self.cap(text), source: .offline)
        }
        return Result(text: "", source: .none)
    }

    /// The newest elements of one satellite by its catalogue number, or nil
    /// when Celestrak cannot be reached or does not know it.
    func satellite(norad: Int) async -> TleEntry? {
        guard let text = await download(["CATNR": String(norad)]) else { return nil }
        return TLE.parse(text, cap: 1).first
    }

    /// Celestrak's own search: every satellite whose name contains `query`,
    /// or the one with that catalogue number. Nil when it cannot be reached.
    func search(_ query: String) async -> [TleEntry]? {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        let params = Int(q) != nil ? ["CATNR": q] : ["NAME": q]
        guard let text = await download(params) else { return nil }
        return TLE.parse(text, cap: 60)
    }

    /// Celestrak answers an unknown name with a plain-text sentence and a 200,
    /// so anything that holds no element set counts as "nothing found".
    private func download(_ params: [String: String]) async -> String? {
        var url = URLComponents(string: "https://celestrak.org/NORAD/elements/gp.php")!
        url.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) } + [URLQueryItem(name: "FORMAT", value: "tle")]
        for _ in 0..<2 {
            if let (data, response) = try? await session.data(from: url.url!),
               (response as? HTTPURLResponse)?.statusCode == 200,
               let text = String(data: data, encoding: .utf8)
            {
                return TLE.looksLikeTle(text) ? text : ""
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

    // Celestrak ends its lines with \r\n, and Swift counts "\r\n" as ONE
    // Character, so splitting on "\n" finds no lines at all. isNewline matches it.
    private static func cap(_ text: String) -> String {
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        return lines.count <= maxSats * 3 ? text : lines.prefix(maxSats * 3).joined(separator: "\n")
    }
}
