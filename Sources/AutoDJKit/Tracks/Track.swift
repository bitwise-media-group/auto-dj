// Copyright 2026 BitWise Media Group Ltd
// SPDX-License-Identifier: MIT

import Foundation

/// Everything the rules know about one track: beat grid, phrases, per-beat audio features and
/// existing cues (port of internal/tracks).
public struct Track: Sendable, Identifiable {
    public var id: String
    public var title: String
    public var rating = 0
    /// Rekordbox's key name ("Am", "F#"), "" when unknown.
    public var key = ""
    /// djmdContent.Commnt.
    public var comment = ""
    /// Mixed In Key's `EnergyLevel` tag (1-10) from the audio file, nil without one (`EnergyTags`).
    public var mikEnergy: Int?
    public var path = ""
    public var bpm = 0.0
    /// djmdContent.Length (s), 0 when unknown.
    public var length = 0.0
    public var beats: [Double] = []
    public var bnum: [Int] = []
    public var phrases: [Phrase] = []
    public var mood = 0
    public var cues: [Cue] = []
    public var category = ""
    /// The audio file exists here (streaming tracks have none).
    public var local = false
    /// Per-beat features (`Features` columns); nil without audio analysis.
    public var fb: [[Double]]? {
        didSet {
            bass = fb.map { fb in Track.normLevel(fb.map { $0[0] }) }
            loudEnd = fb.flatMap(Track.loudEnd)
        }
    }
    /// `normLevel` of the sub-bass column and `loudEnd`, kept with fb: transitions read them
    /// many times.
    public private(set) var bass: [Double]?
    public private(set) var loudEnd: Int?

    /// The last beat (1-based) within 20 dB of the track's loud parts, nil when none is.
    static func loudEnd(_ fb: [[Double]]) -> Int? {
        let tot = fb.map { log10($0[0] + $0[1] + $0[2] + $0[3] + 1e-9) }
        let thr = Num.percentile(tot, 90) - 2.0
        return tot.lastIndex(where: { $0 > thr }).map { $0 + 1 }
    }

    /// The normalised sub-bass level per beat (`normLevel(col(0))`).
    public var bassLevel: [Double] { bass ?? Track.normLevel(col(0)) }
    /// Per-beat vocal confidence (0...1, `Vocals.perBeat`), nil when not analysed.
    public var vocals: [Double]?

    public init(id: String, title: String) {
        self.id = id
        self.title = title
    }

    /// Whether the track has audio features (the rules fall back to phrases).
    public var hasFB: Bool { fb != nil }

    /// Feature column j of fb.
    public func col(_ j: Int) -> [Double] { (fb ?? []).map { $0[j] } }

    /// Loads every track whose category is in want and that has Rekordbox analysis.
    public static func build(_ paths: Paths, _ want: [String], log: (String) -> Void = { _ in })
        throws -> [Track]
    {
        let (rows, cues): ([TrackRow], [String: [Cue]])
        do {
            let rb = try RekordboxDB.readCopy(paths.masterDB)
            (rows, cues) = try rb.sql.loadTracksAndCues()
        }
        let auto = try Ledger.load(paths.ledger)
        let tags = EnergyTags.cached(paths.energyTags)
        let wanted = Set(want)
        var out: [Track] = []
        for r in rows {
            let cs = cues[r.id] ?? []
            let cat = Category.classify(rating: r.rating, cues: cs, auto: auto.contains(r.id))
            if !wanted.contains(cat) || r.analysisDataPath.isEmpty { continue }
            let a: Analysis
            do {
                a = try Analysis.load(shareDir: paths.shareDir, analysisDataPath: r.analysisDataPath)
            } catch is Analysis.NotFound {
                continue
            } catch {
                log("  skipped \(r.title): \(error)")
                continue
            }
            if a.beats.isEmpty { continue }
            let fp = Config.mapPath(r.folderPath)
            var t = Track(id: r.id, title: r.title)
            t.rating = r.rating
            t.key = r.key
            t.comment = r.comment
            t.mikEnergy = tags[fp]
            t.path = fp
            t.bpm = r.bpm
            t.length = r.length
            t.beats = a.beats
            t.bnum = a.bnum
            t.phrases = a.phrases
            t.mood = a.mood
            t.cues = cs
            t.category = cat
            if !fp.isEmpty {
                t.local = FileManager.default.fileExists(atPath: fp)
                t.fb = try Features.perBeat(
                    featureDir: paths.featureDir, audioPath: fp, beats: t.beats, bpm: t.bpm)
                t.vocals = try Vocals.perBeat(featureDir: paths.featureDir, audioPath: fp, beats: t.beats, bpm: t.bpm)
            }
            out.append(t)
        }
        return out
    }

    /// The 1-based beat nearest sec (np.argmin(abs(beats - sec)) + 1).
    public static func beatOf(_ beats: [Double], _ sec: Double) -> Int {
        var best = 0
        for (i, b) in beats.enumerated() where abs(b - sec) < abs(beats[best] - sec) { best = i }
        return best + 1
    }

    /// Log-energy normalised so the track's loudest 5% sits at ~1.0, silence at 0.
    public static func normLevel(_ band: [Double]) -> [Double] {
        let x = band.map { log10($0 + 1e-9) }
        let p = Num.percentile(x, 95)
        return x.map { Num.clip(($0 - p) + 1, 0, 1.5) }
    }

    /// "Don't Wake Up (Original Mix)" -> "dont wake up": no mix names, no feat., no leading
    /// "the".
    public static func titleStem(_ s: String) -> String {
        var x = s.lowercased()
        x = x.replacing(/\(.*?\)|\[.*?\]/, with: " ")
        x = String(x.unicodeScalars.prefix(featIndex(x)))
        x = x.replacingOccurrences(of: "'", with: "").replacingOccurrences(of: "\u{2019}", with: "")
        x = x.replacing(/[^a-z0-9 ]+/, with: " ")
        x = Config.strip(x)
        if x.hasPrefix("the ") { x.removeFirst(4) }
        return Config.strip(x.replacing(/\s+/, with: " "))
    }

    /// Where Python's re.split(r"\bfeat\.?\b|\bft\.?\b", x)[0] ends, in scalars: the first
    /// "feat" or "ft" with a word boundary on both sides (Unicode letters, numbers and '_').
    static func featIndex(_ x: String) -> Int {
        let r = Array(x.unicodeScalars)
        func isWord(_ c: Unicode.Scalar) -> Bool { c == "_" || Text.isLetter(c) || Text.isNumber(c) }
        for i in r.indices where i == 0 || !isWord(r[i - 1]) {
            for w in ["feat", "ft"] {
                let wu = Array(w.unicodeScalars)
                let n = wu.count
                if i + n <= r.count, Array(r[i..<i + n]) == wu, i + n == r.count || !isWord(r[i + n]) {
                    return i
                }
            }
        }
        return r.count
    }
}
