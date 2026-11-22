// Copyright 2026 BitWise Media Group Ltd
// SPDX-License-Identifier: MIT

import Foundation

/// A track's energy on the star scale (1-5), for building sets along an energy arc (ADR 0021):
/// the DJ's rating, else Mixed In Key's energy level (its `EnergyLevel` tag, else the comment),
/// halved.
public enum Energy {
    /// Where a track's energy comes from.
    public enum Source: String, Sendable, Codable {
        /// The DJ's star rating.
        case rating
        /// Mixed In Key's energy level (1-10), halved.
        case mik
    }

    public struct Level: Sendable, Equatable, Codable {
        /// 0.5-5.
        public var stars: Double
        public var source: Source

        public init(stars: Double, source: Source) {
            (self.stars, self.source) = (stars, source)
        }

        /// "4" (rated) or "~3.5" (Mixed In Key).
        public var label: String {
            let s = stars == stars.rounded() ? String(Int(stars)) : String(format: "%.1f", stars)
            return source == .rating ? s : "~" + s
        }
    }

    /// Mixed In Key's energy level (1-10) in a comment it wrote: fields joined by " - " with a
    /// Camelot key among them and the energy last ("126 - 10A - 7", "10A - 7"), or "Energy 7".
    /// nil for anything else; the tempo and key are not used.
    public static func mik(_ comment: String) -> Int? {
        let c = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        if let m = c.wholeMatch(of: /(?i)energy\s*(\d{1,2})/), let n = Int(m.1), (1...10).contains(n) { return n }
        let fields = c.split(separator: "-").map { $0.trimmingCharacters(in: .whitespaces) }
        guard fields.count >= 2, let last = fields.last, last.wholeMatch(of: /\d{1,2}/) != nil, let n = Int(last),
            (1...10).contains(n),
            fields.dropLast().contains(where: { $0.uppercased().wholeMatch(of: /(1[0-2]|[1-9])[AB]/) != nil })
        else { return nil }
        return n
    }

    /// The energy from a rating (0 = unrated), Mixed In Key's tag and the comment.
    public static func level(rating: Int, tag: Int? = nil, comment: String) -> Level? {
        if rating > 0 { return Level(stars: Double(min(rating, 5)), source: .rating) }
        return (tag ?? mik(comment)).map { Level(stars: Double($0) / 2, source: .mik) }
    }

    /// Mixed In Key's level for t: its tag, else its comment.
    public static func mik(_ t: Track) -> Int? { t.mikEnergy ?? mik(t.comment) }

    public static func level(_ t: Track) -> Level? { level(rating: t.rating, tag: t.mikEnergy, comment: t.comment) }

    /// How Mixed In Key's halved energy agrees with the DJ's ratings, on tracks that have both.
    public struct Agreement: Sendable {
        public var compared = 0
        /// Within half a star / one star.
        public var half = 0
        public var one = 0
        /// Rated tracks where they differ by 2 stars or more: title, rating, Mixed In Key level.
        public var far: [(title: String, rating: Int, mik: Int)] = []
        /// Mean (Mixed In Key / 2 - rating).
        public var bias = 0.0
    }

    public static func agreement(_ ts: [Track]) -> Agreement {
        var a = Agreement()
        var sum = 0.0
        for t in ts where t.rating > 0 {
            guard let m = mik(t) else { continue }
            let d = Double(m) / 2 - Double(t.rating)
            a.compared += 1
            sum += d
            if abs(d) <= 0.5 { a.half += 1 }
            if abs(d) <= 1 { a.one += 1 }
            if abs(d) >= 2 { a.far.append((t.title, t.rating, m)) }
        }
        if a.compared > 0 { a.bias = sum / Double(a.compared) }
        return a
    }

    /// A report of where the library's energy comes from and how the two sources agree.
    public static func report(_ ts: [Track]) -> [String] {
        let levels = ts.map(level)
        let rated = levels.filter { $0?.source == .rating }.count
        let mikN = levels.filter { $0?.source == .mik }.count
        let none = levels.filter { $0 == nil }
        var lines = [
            "energy: \(ts.count) tracks: \(rated) rated, \(mikN) from Mixed In Key, \(none.count) none"
        ]
        var hist: [String: Int] = [:]
        for t in ts where t.rating > 0 { hist["\(min(t.rating, 5))", default: 0] += 1 }
        lines.append("ratings: " + (1...5).map { "\($0)★ \(hist["\($0)"] ?? 0)" }.joined(separator: "  "))
        var mh = [Int](repeating: 0, count: 11)
        for t in ts { if let m = mik(t) { mh[m] += 1 } }
        lines.append("Mixed In Key levels: " + (1...10).map { "\($0): \(mh[$0])" }.joined(separator: "  "))
        let a = agreement(ts)
        if a.compared > 0 {
            func pc(_ n: Int) -> String { "\(Num.round(Double(n) * 100 / Double(a.compared)))%" }
            lines.append(
                "rated tracks with a Mixed In Key level: \(a.compared); level / 2 within half a star of the rating "
                    + "\(pc(a.half)), within one star \(pc(a.one)); mean difference \(String(format: "%+.2f", a.bias))")
            var cross: [Int: [Int: Int]] = [:]
            for t in ts where t.rating > 0 {
                if let m = mik(t) { cross[m, default: [:]][min(t.rating, 5), default: 0] += 1 }
            }
            lines.append("Mixed In Key level -> your ratings (1★..5★):")
            for m in cross.keys.sorted() {
                let row = (1...5).map { Text.padLeft(String(cross[m]![$0] ?? 0), 3) }.joined()
                lines.append("  \(Text.padLeft(String(m), 2)):\(row)")
            }
            for f in a.far {
                lines.append("  \(f.rating)★ but Mixed In Key \(f.mik) (\(Double(f.mik) / 2)★): \(f.title)")
            }
        }
        let odd = ts.filter { level($0) == nil }
        if !odd.isEmpty {
            lines.append("no energy (\(odd.count): unrated, no EnergyLevel tag or energy in the comment), e.g.:")
            for t in odd.prefix(5) { lines.append("  \(t.title) (\(t.local ? t.path : "no audio file"))") }
        }
        return lines
    }
}
