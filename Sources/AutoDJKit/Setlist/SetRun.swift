// Copyright 2026 BitWise Media Group Ltd
// SPDX-License-Identifier: MIT

import Foundation

/// How to order a set.
public enum SetOrder: Sendable, Equatable {
    /// The playlist's own order.
    case playlist
    /// The suggested order (fewest key clashes, least change).
    case suggested
    /// Track numbers (1-based) in play order.
    case numbers([Int])

    /// Parses "", "suggested" or a comma-separated track-number list (1,3,2,...).
    public init(_ spec: String) throws {
        let s = spec.trimmingCharacters(in: .whitespaces)
        if s.isEmpty {
            self = .playlist
        } else if s == "suggested" {
            self = .suggested
        } else {
            self = .numbers(
                try s.split(separator: ",", omittingEmptySubsequences: false).map { v in
                    guard let n = Int(v.trimmingCharacters(in: .whitespaces)) else {
                        throw SetError.order("\"\(v)\" is not a track number")
                    }
                    return n
                })
        }
    }
}

public enum SetError: Error, CustomStringConvertible {
    case order(String)

    public var description: String {
        switch self {
        case .order(let s):
            "order must list every track number exactly once" + (s.isEmpty ? "" : ": " + s)
        }
    }
}

/// A planned set.
public struct SetResult: Sendable {
    public var playlist: String
    public var report: String
    /// The tracks in play order.
    public var order: [PlaylistTrack]
    public var actions: [SetAction]
    public var recs: [String: Track]
    public var clashes: Int
    /// The key check of each pair of neighbours in `order`.
    public var keyChecks: [Keys.Check]
    /// The suggested order (indices into the order the plan started from) and its key cost.
    public var suggested: [Int]
    public var suggestedCost: Int
    public var cache: TransitionCache
    /// An intelligent playlist: Rekordbox picks and orders its tracks, so the order can't be
    /// saved to it.
    public var intelligent = false
}

/// What a set needs from the library, loaded once and replanned on every edit.
public struct SetLibrary: Sendable {
    public var playlist: Playlist
    public var recs: [String: Track]
    public var cache: TransitionCache

    public init(playlist: Playlist, recs: [String: Track], cache: TransitionCache) {
        (self.playlist, self.recs, self.cache) = (playlist, recs, cache)
    }

    /// Loads a playlist, every analysed track and the transition cache, and records every E/G
    /// pair in the library before anything changes.
    public static func load(_ paths: Paths, playlist name: String, log: (String) -> Void = { _ in }) throws
        -> SetLibrary
    {
        let (pl, titles): (Playlist, [(id: String, title: String)])
        do {
            let rb = try RekordboxDB.readCopy(paths.masterDB)
            pl = try rb.sql.loadPlaylist(name)
            titles = try rb.sql.titles()
        }
        let all = try Track.build(paths, ["manual", "auto", "mik", "nohot", "other"], log: log)
        var cache = try TransitionCache.load(paths.transitions)
        cache.harvest(all, TitleResolver(titles))
        try cache.save(paths.transitions)
        return SetLibrary(
            playlist: pl, recs: Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }), cache: cache)
    }
}

/// Key check, suggested order and set cues for a playlist (port of internal/setlist/run.go).
public enum SetRun {
    /// Loads a playlist, checks keys, suggests an order and plans the set cues.
    public static func run(
        _ paths: Paths, playlist: String, order: SetOrder, freeStart: Bool, log: (String) -> Void = { _ in }
    )
        throws -> SetResult
    {
        let lib = try SetLibrary.load(paths, playlist: playlist, log: log)
        if case .numbers(let n) = order { _ = try pick(lib.playlist.tracks, n) }  // checked before planning
        var res = try plan(playlist, lib.playlist.tracks, lib.recs, lib.cache, order: order, freeStart: freeStart)
        res.intelligent = lib.playlist.intelligent
        return res
    }

    /// `run` without the library: the key check, suggested order and set cues for the tracks in
    /// order, with recs holding every track's record. The app, the CLI and the demo share it.
    public static func plan(
        _ playlist: String, _ tracks: [PlaylistTrack], _ recs: [String: Track], _ cache: TransitionCache,
        order spec: SetOrder, freeStart: Bool
    ) throws -> SetResult {
        var order = tracks
        if case .numbers(let n) = spec { order = try pick(tracks, n) }
        let checks = Keys.checkOrder(order)
        var lines = keyReport(playlist, order, checks)
        let clashes = checks.filter { !$0.move.ok }.count
        let (suggested, cost) = Keys.suggestOrder(
            order.map { Keys.Item(key: $0.key, bpm: $0.bpm) }, keepFirst: !freeStart)
        if clashes > 0 {
            lines += ["", "\(clashes) key clash(es). Suggested order (key cost \(cost)):"]
            for (n, k) in suggested.enumerated() {
                lines.append(
                    "  \(Text.padLeft(String(n + 1), 2)). \(Text.padLeft(orQ(order[k].key), 4))  \(order[k].title)")
            }
            lines.append("Plan with order 'suggested' (or a list like 1,3,2,...) once you agree.")
        }
        if spec == .suggested { order = suggested.map { order[$0] } }
        let acts = SetPlanner.plan(order, recs, cache)
        lines += [
            "",
            "Set cues (beat @ m:ss; existing = kept as is, new = empty slot, replace = slot overwritten (old cue saved "
                + "in the transition cache), clear = removed from the last track):",
        ]
        for a in acts { lines += reportTrack(a, recs[a.id]) }
        return SetResult(
            playlist: playlist, report: lines.joined(separator: "\n"), order: order, actions: acts, recs: recs,
            clashes: clashes, keyChecks: Keys.checkOrder(order), suggested: suggested, suggestedCost: cost, cache: cache
        )
    }

    /// Reorders the tracks by 1-based track numbers.
    public static func pick(_ order: [PlaylistTrack], _ numbers: [Int]) throws -> [PlaylistTrack] {
        let idx = numbers.map { $0 - 1 }
        guard idx.count == order.count, idx.sorted() == Array(0..<order.count) else { throw SetError.order("") }
        return idx.map { order[$0] }
    }

    static func orQ(_ s: String) -> String { s.isEmpty ? "?" : s }

    static func keyReport(_ playlist: String, _ order: [PlaylistTrack], _ checks: [Keys.Check]) -> [String] {
        var lines = [
            "\(playlist): \(order.count) tracks", "",
            "Key check (Mixed In Key chart: same / Camelot +-1 / relative; energy boosts +-1 and +-2 semitones):",
        ]
        for k in checks {
            let a = order[k.i]
            let b = order[k.j]
            lines.append(
                "  \(k.move.ok ? "ok" : "XX")  \(Text.padLeft(orQ(a.key), 4)) -> \(Text.padRight(orQ(b.key), 4)) "
                    + "\(Text.padRight(Text.truncate(a.title, 34), 34)) -> \(Text.padRight(Text.truncate(b.title, 34), 34)) "
                    + k.move.desc)
        }
        return lines
    }

    /// Seconds as m:ss.
    public static func minSec(_ sec: Double) -> String {
        let m = Int((sec / 60).rounded(.down))
        let s = Int(sec - Double(m) * 60)
        return String(format: "%d:%02d", m, s)
    }

    /// Beat b's position as m:ss.
    static func at(_ t: Track, _ b: Int) -> String { minSec(t.beats[min(max(b, 1), t.beats.count) - 1]) }

    static func reportTrack(_ x: SetAction, _ t: Track?) -> [String] {
        var lines = ["  " + x.title]
        guard let t else { return lines }
        for (name, v) in [("E", x.e), ("G", x.g)] {
            guard let v else { continue }
            let was = v.status == .replace ? v.old.map { " (was '\($0.name)' @ beat \($0.beat))" } ?? "" : ""
            lines.append(
                "     \(name) \(Text.padRight(v.name, 22)) beat \(Text.padLeft(String(v.beat), 4)) @ \(at(t, v.beat))  "
                    + "\(v.status.rawValue)\(was)")
        }
        let bs = x.bassSwap
        if let bs, bs.beat == nil { lines.append("     BASS SWAP IN: none: " + bs.why) }
        for m in x.markers {
            let why =
                m.name == "BASS SWAP IN" && bs != nil && bs!.why != "new" && bs!.why != "existing"
                ? " (\(bs!.why))" : ""
            lines.append(
                "     \(Text.padRight(m.name, 24)) beat \(Text.padLeft(String(m.beat), 4)) @ \(at(t, m.beat))  "
                    + "\(m.status.rawValue)\(why)")
        }
        if let ex = x.exit {
            let src = ex.side == "out" ? "own cue" : "from the next track's cue"
            lines.append("     leaves the mix: \(ex.name) at beat \(ex.a) @ \(at(t, ex.a)) (\(src))")
        }
        for w in x.warnings { lines.append("     ! " + w) }
        return lines
    }

    /// Remembers this set's pairs after a write (G on track i, E + BASS SWAP on track i+1).
    public static func recordWritten(_ res: inout SetResult) {
        func ms(_ r: Track, _ x: Int) -> Int { Num.round(r.beats[min(max(x, 1), r.beats.count) - 1] * 1000) }
        for i in 0..<max(res.order.count - 1, 0) {
            let a = res.actions[i]
            let b = res.actions[i + 1]
            guard let t = res.recs[res.order[i].id], let u = res.recs[res.order[i + 1].id], let g = a.g, let e = b.e
            else {
                continue
            }
            res.cache.record(
                outID: res.order[i].id, outTitle: res.order[i].title, inID: res.order[i + 1].id,
                inTitle: res.order[i + 1].title, source: "set:" + res.playlist, gMS: ms(t, g.beat), eMS: ms(u, e.beat),
                bassSwapMS: b.bassSwap?.beat.map { ms(u, $0) })
        }
    }

    /// The set-plan file (`set --out`).
    public struct PlanFile: Codable, Sendable {
        public var playlist: String
        public var order: [String]
        public var actions: [SetAction]

        public init(playlist: String, order: [String], actions: [SetAction]) {
            self.playlist = playlist
            self.order = order
            self.actions = actions
        }
    }

    /// Writes the set's cues (and, with reorder, the playlist order) to master.db.
    public static func write(_ paths: Paths, _ res: inout SetResult, reorder: Bool) throws -> Stats {
        let beats = res.recs.mapValues(\.beats)
        let acts = SetPlanner.toDB(res.actions)
        let ids = res.order.map(\.id)
        let playlist = res.playlist
        let stats = try SafeWrite.write(paths.masterDB, backupDir: paths.backupDir) { db in
            let st = try CueWriter.applySet(db, acts, beats: beats)
            if reorder { st.update(try CueWriter.reorderPlaylist(db, playlist, ids)) }
            return st
        }
        recordWritten(&res)
        try res.cache.save(paths.transitions)
        stats.set("transition_cache", .string(paths.transitions))
        return stats
    }
}
