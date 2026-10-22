import Foundation

/// One satellite's name and two-line element set, as Celestrak sends them.
public struct TleEntry: Sendable, Hashable, Codable {
    public var name: String
    public var line1: String
    public var line2: String

    public init(name: String, line1: String, line2: String) {
        self.name = name
        self.line1 = line1
        self.line2 = line2
    }

    /// The NORAD catalogue number, read as the page reads it.
    public var norad: Int? { Satrec.noradId(line2: line2) }

    /// The orbit, ready to propagate; nil for lines too short to be a TLE.
    public var satrec: Satrec? { Satrec(line1: line1, line2: line2) }

    /// When these elements were measured.
    public var epoch: Date? { satrec.map { Julian.date($0.jdsatepoch) } }
}

public enum TLE {
    /// Reads a Celestrak TLE file the way the page's ingestTle does: three
    /// lines a satellite, and when a line 1 or 2 is not where it should be,
    /// step on one line and try again. At most `cap` satellites.
    ///
    /// Celestrak ends its lines with "\r\n", and Swift counts "\r\n" as ONE
    /// Character, so splitting on "\n" finds no lines at all; isNewline
    /// matches it.
    public static func parse(_ text: String, cap: Int = .max) -> [TleEntry] {
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        var out: [TleEntry] = []
        var i = 0
        while i + 2 < lines.count && out.count < cap {
            let name = lines[i].trimmingCharacters(in: .whitespaces)
            let l1 = lines[i + 1], l2 = lines[i + 2]
            if l1.first != "1" || l2.first != "2" {
                i += 1          // resync: the page's `i -= 2; continue` with its `i += 3`
                continue
            }
            out.append(TleEntry(name: name, line1: l1, line2: l2))
            i += 3
        }
        return out
    }

    /// Does this text hold at least one element set? (A Celestrak error page
    /// or an empty answer does not.)
    public static func looksLikeTle(_ text: String) -> Bool {
        var line1 = false, line2 = false
        for line in text.split(whereSeparator: \.isNewline) where line.count > 60 {
            if line.hasPrefix("1 ") { line1 = true } else if line.hasPrefix("2 ") { line2 = true }
            if line1 && line2 { return true }
        }
        return false
    }
}
