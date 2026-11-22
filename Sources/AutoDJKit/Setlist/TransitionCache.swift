// Copyright 2026 BitWise Media Group Ltd
// SPDX-License-Identifier: MIT

import Foundation

/// The transition cache: every E/G pair seen in the library or written by `set`, so a pair
/// can be restored when the two tracks meet again in another playlist (a track has only one E
/// and one G, so sets overwrite each other). Port of internal/pairs.
///
/// File: <backup dir>/transitions.json  {"pairs": {"<out_id>><in_id>": entry}}
public struct TransitionCache: Codable, Sendable {
    /// An entry's earlier values.
    public struct History: Codable, Sendable, Equatable {
        public var gMS: Int?
        public var eMS: Int?
        public var bassSwapMS: Int?
        public var source: String
        public var updated: String

        enum CodingKeys: String, CodingKey {
            case gMS = "g_ms", eMS = "e_ms", bassSwapMS = "bass_swap_ms", source, updated
        }
    }

    /// One A -> B transition: G on A, E and BASS SWAP on B (milliseconds).
    public struct Entry: Codable, Sendable, Equatable {
        public var outID = ""
        public var outTitle = ""
        public var inID = ""
        public var inTitle = ""
        public var gMS: Int?
        public var eMS: Int?
        public var bassSwapMS: Int?
        public var source = ""
        public var updated = ""
        public var history: [History] = []

        public init() {}

        enum CodingKeys: String, CodingKey {
            case outID = "out_id", outTitle = "out_title", inID = "in_id", inTitle = "in_title"
            case gMS = "g_ms", eMS = "e_ms", bassSwapMS = "bass_swap_ms", source, updated, history
        }

        public init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            outID = try c.decode(String.self, forKey: .outID)
            outTitle = try c.decodeIfPresent(String.self, forKey: .outTitle) ?? ""
            inID = try c.decode(String.self, forKey: .inID)
            inTitle = try c.decodeIfPresent(String.self, forKey: .inTitle) ?? ""
            gMS = try c.decodeIfPresent(Int.self, forKey: .gMS)
            eMS = try c.decodeIfPresent(Int.self, forKey: .eMS)
            bassSwapMS = try c.decodeIfPresent(Int.self, forKey: .bassSwapMS)
            source = try c.decodeIfPresent(String.self, forKey: .source) ?? ""
            updated = try c.decodeIfPresent(String.self, forKey: .updated) ?? ""
            history = try c.decodeIfPresent([History].self, forKey: .history) ?? []
        }
    }

    public var pairs: [String: Entry] = [:]

    public init() {}

    /// The cache at path (empty when the file doesn't exist).
    public static func load(_ path: String) throws -> TransitionCache {
        guard FileManager.default.fileExists(atPath: path) else { return TransitionCache() }
        return try JSONFile.read(TransitionCache.self, from: path)
    }

    public func save(_ path: String) throws { try JSONFile.write(self, to: path) }

    /// The pair's key in the cache.
    public static func key(_ outID: String, _ inID: String) -> String { outID + ">" + inID }

    public func get(_ outID: String, _ inID: String) -> Entry? { pairs[Self.key(outID, inID)] }

    /// Sets g_ms / e_ms / bass_swap_ms for a pair (nil = leave as is); changed values (by more
    /// than 20 ms) push the old entry to history.
    public mutating func record(
        outID: String, outTitle: String, inID: String, inTitle: String, source: String,
        gMS: Int? = nil, eMS: Int? = nil, bassSwapMS: Int? = nil
    ) {
        let k = Self.key(outID, inID)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        let now = f.string(from: Date())
        var cur =
            pairs[k]
            ?? {
                var e = Entry()
                (e.outID, e.outTitle, e.inID, e.inTitle, e.source, e.updated) = (
                    outID, outTitle, inID, inTitle, source, now
                )
                return e
            }()
        func changed(_ old: Int?, _ new: Int?) -> Bool {
            guard let new else { return false }
            return old == nil || abs(old! - new) > 20
        }
        let ch = [changed(cur.gMS, gMS), changed(cur.eMS, eMS), changed(cur.bassSwapMS, bassSwapMS)]
        let olds = [cur.gMS, cur.eMS, cur.bassSwapMS]
        if !ch.contains(true) {
            pairs[k] = cur
            return
        }
        if zip(ch, olds).contains(where: { $0 && $1 != nil }) {
            cur.history.append(
                History(
                    gMS: cur.gMS, eMS: cur.eMS, bassSwapMS: cur.bassSwapMS, source: cur.source, updated: cur.updated))
        }
        if ch[0] { cur.gMS = gMS }
        if ch[1] { cur.eMS = eMS }
        if ch[2] { cur.bassSwapMS = bassSwapMS }
        cur.source = source
        cur.updated = now
        pairs[k] = cur
    }

    /// Records every E/G cue in the library that names another track; returns the number of
    /// pairs touched.
    @discardableResult
    public mutating func harvest(_ recs: [Track], _ r: TitleResolver) -> Int {
        var n = 0
        for t in recs {
            for cue in t.cues where cue.kind == 6 || cue.kind == 8 {
                guard let other = r.resolve(cue.name), other != t.id else { continue }
                let ms = Num.round(cue.t * 1000)
                if cue.kind == 6 {  // E on this track: other -> this
                    record(
                        outID: other, outTitle: r.title(other), inID: t.id, inTitle: r.title(t.id), source: "library",
                        eMS: ms)
                } else {  // G on this track: this -> other
                    record(
                        outID: t.id, outTitle: r.title(t.id), inID: other, inTitle: r.title(other), source: "library",
                        gMS: ms)
                }
                n += 1
            }
        }
        return n
    }
}

/// Maps hand-typed cue names ('RAJ', 'LOST HAWK') to track IDs.
public struct TitleResolver: Sendable {
    let titles: [(id: String, title: String)]
    let stems: [String]
    let byID: [String: String]

    /// Indexes the library's titles (in table order, which breaks ties).
    public init(_ titles: [(id: String, title: String)]) {
        self.titles = titles
        stems = titles.map { Track.titleStem($0.title) }
        byID = Dictionary(titles.map { ($0.id, $0.title) }, uniquingKeysWith: { a, _ in a })
    }

    public func title(_ id: String) -> String { byID[id] ?? "" }

    /// The ID of the track the cue name means, or nil.
    public func resolve(_ name: String) -> String? {
        let n = Track.titleStem(name)
        if n.unicodeScalars.count < 3 || n == "start" { return nil }
        var best: String?
        var bestR = 0.0
        for (i, t) in titles.enumerated() {
            let q = stems[i] == n ? 1.0 : SequenceMatcher.ratio(n, stems[i])
            if q > bestR { (best, bestR) = (t.id, q) }
        }
        return bestR >= 0.75 ? best : nil
    }
}

/// Python's difflib.SequenceMatcher(None, a, b).ratio() over characters (no junk; the
/// autojunk heuristic only applies to sequences of 200+ items, longer than any title).
public enum SequenceMatcher {
    public static func ratio(_ a: String, _ b: String) -> Double {
        let x = Array(a.unicodeScalars)
        let y = Array(b.unicodeScalars)
        if x.isEmpty && y.isEmpty { return 1 }
        var b2j: [Unicode.Scalar: [Int]] = [:]
        for (j, c) in y.enumerated() { b2j[c, default: []].append(j) }
        func longest(_ alo: Int, _ ahi: Int, _ blo: Int, _ bhi: Int) -> (Int, Int, Int) {
            var (bi, bj, bs) = (alo, blo, 0)
            var j2len: [Int: Int] = [:]
            for i in alo..<ahi {
                var next: [Int: Int] = [:]
                for j in b2j[x[i]] ?? [] {
                    if j < blo { continue }
                    if j >= bhi { break }
                    let k = (j2len[j - 1] ?? 0) + 1
                    next[j] = k
                    if k > bs { (bi, bj, bs) = (i - k + 1, j - k + 1, k) }
                }
                j2len = next
            }
            return (bi, bj, bs)
        }
        var matched = 0
        var queue = [(0, x.count, 0, y.count)]
        while let (alo, ahi, blo, bhi) = queue.popLast() {
            let (i, j, k) = longest(alo, ahi, blo, bhi)
            if k == 0 { continue }
            matched += k
            if alo < i && blo < j { queue.append((alo, i, blo, j)) }
            if i + k < ahi && j + k < bhi { queue.append((i + k, ahi, j + k, bhi)) }
        }
        return 2 * Double(matched) / Double(x.count + y.count)
    }
}
