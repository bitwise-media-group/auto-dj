// Copyright 2026 BitWise Media Group Ltd
// SPDX-License-Identifier: MIT

import Foundation

/// A hot cue to write.
public struct PlanHot: Sendable, Equatable {
    public var kind: Int
    public var name: String
    public var ms: Int
    /// EMERGENCY loop length in beats (0: `Config.emergencyLoopBeats`).
    public var loop = 0
    public var outMS = 0
}

/// A memory cue to write.
public struct PlanMem: Sendable, Equatable {
    public var name: String
    public var ms: Int
}

/// One track of a cue plan to write.
public struct PlanTrack: Sendable, Equatable {
    public var id: String
    public var title: String
    public var hot: [PlanHot]
    public var mem: [PlanMem]
}

/// An E or G hot cue `set` writes.
public struct SetSlot: Sendable, Equatable, Codable {
    public enum Status: String, Sendable, Codable { case new, replace, clear, existing }
    public var name: String
    public var beat: Int
    public var status: Status

    public init(name: String, beat: Int, status: Status) {
        self.name = name
        self.beat = beat
        self.status = status
    }
}

/// A memory cue `set` writes or removes.
public struct SetMarker: Sendable, Equatable, Codable, Hashable {
    public enum Status: String, Sendable, Codable { case new, rename, existing }
    public var name: String
    public var beat: Int
    public var status: Status

    public init(name: String, beat: Int, status: Status) {
        self.name = name
        self.beat = beat
        self.status = status
    }
}

/// What `set --write` changes on one track.
public struct SetCues: Sendable, Equatable {
    public var id: String
    public var title: String
    public var e: SetSlot?
    public var g: SetSlot?
    public var markers: [SetMarker] = []
    public var remove: [SetMarker] = []

    public init(id: String, title: String) {
        self.id = id
        self.title = title
    }
}

/// Writes cues into an open (decrypted) master.db copy (port of internal/db/apply.go).
public enum CueWriter {
    /// The cue names this tool writes (replaced when it re-cues a track).
    public static let ours: Set<String> = ["IN", "BRIDGE", "DROP", "OUT", "EMERGENCY", "START", "BASS SWAP"]

    struct CueInfo {
        var id: String
        var kind: Int
        var comment: String
        var inMS: Int
        var active = false
    }

    static func trackCues(_ db: SQLite, _ contentID: String, _ extra: String = "") throws -> [CueInfo] {
        try db.query(
            "select ID, Kind, Comment, InMsec, coalesce(ActiveLoop,0) from djmdCue where ContentID=? "
                + "and rb_local_deleted=0" + extra, contentID
        ).map {
            CueInfo(id: $0.string(0), kind: $0.int(1), comment: $0.string(2), inMS: $0.int(3), active: $0.int(4) == 1)
        }
    }

    /// The track's UUID (NULL when it has none) and rating; nil when the track is gone.
    static func content(_ db: SQLite, _ id: String) throws -> (uuid: SQLValue, rating: Int)? {
        guard let r = try db.queryRow("select UUID, coalesce(Rating,0) from djmdContent where ID=?", id) else {
            return nil
        }
        return (r[0], r.int(1))
    }

    /// Hands out unused random numeric IDs for a table (1 ..< 2^32, deleted rows included).
    final class IDSource {
        var used: Set<String>

        init(_ db: SQLite, _ table: String) throws {
            used = Set(try db.query("select ID from \(table)").map { $0.string(0) })
        }

        func next() -> String {
            while true {
                let id = String(UInt32.random(in: 1...UInt32.max))
                if used.insert(id).inserted { return id }
            }
        }
    }

    /// One djmdCue insert; nil is NULL.
    struct CueRow {
        var content = ""
        var contentUUID: SQLValue = .null
        var inMS: Int
        var outMS: Int
        var kind: Int
        var color: Int
        var comment: String
        var cti: Int?
        var al: Int?
        var bls: Int?
        var cms: Int?
    }

    static let insertCue = """
        insert into djmdCue (ID,ContentID,InMsec,InFrame,InMpegFrame,InMpegAbs,OutMsec,
          OutFrame,OutMpegFrame,OutMpegAbs,Kind,Color,ColorTableIndex,ActiveLoop,Comment,BeatLoopSize,
          CueMicrosec,InPointSeekInfo,OutPointSeekInfo,ContentUUID,UUID,rb_data_status,
          rb_local_data_status,rb_local_deleted,rb_local_synced,usn,rb_local_usn,created_at,updated_at)
          values (?,?,?,?,0,0,?,?,0,0,?,?,?,?,?,?,?,NULL,NULL,?,?,0,0,0,0,NULL,NULL,?,?)
        """

    /// Milliseconds to the 150-per-second frame index Rekordbox stores.
    static func frames(_ ms: Int) -> Int { Int(Double(ms * 150) / 1000) }

    static func newUUID() -> String { UUID().uuidString.lowercased() }

    static func insert(_ db: SQLite, _ ids: IDSource, _ c: CueRow, _ ts: String) throws {
        try db.exec(
            insertCue, ids.next(), c.content, c.inMS, frames(c.inMS), c.outMS, c.outMS > 0 ? frames(c.outMS) : 0,
            c.kind,
            c.color, c.cti, c.al, c.comment, c.bls, c.cms, c.contentUUID, newUUID(), ts, ts)
    }

    // ---------------------------------------------------------------- cue plans

    /// Writes a cue plan.
    ///
    /// Target tracks: every hot cue must be replaceable (Energy N / CUE(Auto) / START hot cue)
    /// or the track is skipped. Generated cues are deleted; memory cues the user named are kept
    /// and never duplicated. Tracks this tool cued before (autoIDs, still unrated): only cues
    /// with our names are replaced, so any E/F/G notes the user added survive a re-run.
    /// EMERGENCY is written as an active loop unless a cue that stays already is one.
    public static func applyPlan(_ db: SQLite, _ plan: [PlanTrack], autoIDs: Set<String>) throws -> Stats {
        let ids = try IDSource(db, "djmdCue")
        let ts = SafeWrite.stamp()
        let stats = Stats([
            ("updated", .int(0)), ("skipped", .list([])), ("removed", .int(0)), ("added", .int(0)),
            ("content_cues", .int(0)),
        ])
        var touched: [String] = []
        for x in plan {
            let c = try content(db, x.id)
            let cur = try trackCues(db, x.id)
            let rerun = c != nil && autoIDs.contains(x.id) && c!.rating == 0
            guard let c, let doomed = planDoomed(x, cur, rerun: rerun) else {
                stats.append("skipped", x.title)
                continue
            }
            var kept: [CueInfo] = []  // memory cues the user named themselves stay
            var activeLoop = false  // a cue that stays is already the track's active loop
            for q in cur {
                let gone = doomed.contains(q.id)
                if !gone, q.kind == 0 { kept.append(q) }
                activeLoop = activeLoop || (!gone && q.active)
                if gone { try db.exec("delete from djmdCue where ID=?", q.id) }
            }
            stats.add("removed", doomed.count)
            func ins(_ r: CueRow) throws {
                var r = r
                r.content = x.id
                r.contentUUID = c.uuid
                try insert(db, ids, r, ts)
                stats.add("added", 1)
            }
            for h in x.hot { try ins(hotRow(h, active: !activeLoop)) }
            for m in x.mem where !kept.contains(where: { $0.comment == m.name && abs($0.inMS - m.ms) <= 500 }) {
                try ins(
                    CueRow(
                        inMS: m.ms, outMS: -1, kind: Config.kind["MEM"]!, color: Config.memoryColor[m.name] ?? 0,
                        comment: m.name))
            }
            stats.add("updated", 1)
            touched.append(x.id)
        }
        stats.add("content_cues", try ContentCue.sync(db, touched, ts: ts))
        return stats
    }

    /// The cues a plan replaces on a track; nil when the track must be skipped: hand-edited
    /// since planning, or (on a re-run) with the user's own cue in one of our hot cue slots.
    static func planDoomed(_ x: PlanTrack, _ cur: [CueInfo], rerun: Bool) -> Set<String>? {
        let foreign = cur.contains { $0.kind > 0 && !Category.replaceable($0.comment, kind: $0.kind) }
        if !rerun && foreign { return nil }
        let doomed = Set(
            cur.filter {
                (rerun && ours.contains($0.comment)) || (!rerun && Category.replaceable($0.comment, kind: $0.kind))
            }
            .map(\.id))
        if rerun {
            let ourKinds = Set(x.hot.map(\.kind))
            if cur.contains(where: { $0.kind > 0 && !ours.contains($0.comment) && ourKinds.contains($0.kind) }) {
                return nil
            }
        }
        return doomed
    }

    /// A planned hot cue's djmdCue row. EMERGENCY is a loop, active (ActiveLoop 1: it starts
    /// looping when playback reaches it) when active is set: BeatLoopSize packs the loop length
    /// in beats into bits 16+ (32 beats -> 2097153).
    static func hotRow(_ c: PlanHot, active: Bool) -> CueRow {
        if c.name != "EMERGENCY" {
            return CueRow(inMS: c.ms, outMS: -1, kind: c.kind, color: Config.hotColor, comment: c.name)
        }
        let loop = c.loop == 0 ? Config.emergencyLoopBeats : c.loop
        return CueRow(
            inMS: c.ms, outMS: c.outMS, kind: c.kind, color: 255, comment: "EMERGENCY", cti: 0, al: active ? 1 : 0,
            bls: loop << 16 + 1, cms: 0)
    }

    // ---------------------------------------------------------------- sets

    /// Writes E/G hot cues and the transition markers (BASS SWAP / FILTER / CUT ... IN / OUT
    /// memory cues) planned by `SetPlanner`, renames the tracks' cues `Config.renameTo` lists,
    /// recolours the memory cues named in `Config.memoryColor` and deletes the stale ones in
    /// `remove`. beats: track id -> beat-time array (s). E/G marked replace/clear are
    /// overwritten / removed (callers cache them first, see `TransitionCache`); nothing else is
    /// touched.
    public static func applySet(_ db: SQLite, _ actions: [SetCues], beats: [String: [Double]]) throws -> Stats {
        let ids = try IDSource(db, "djmdCue")
        let ts = SafeWrite.stamp()
        let stats = Stats([
            ("hot_cues", .int(0)), ("markers", .int(0)), ("removed", .int(0)), ("renamed", .int(0)),
            ("recoloured", .int(0)), ("skipped", .list([])), ("content_cues", .int(0)),
        ])
        var touched: [String] = []
        for a in actions {
            guard let c = try content(db, a.id) else { continue }
            touched.append(a.id)
            try renameAndRecolour(db, a.id, ts, stats)
            let B = beats[a.id]
            func ms(_ b: Int) -> Int { Num.round(B![min(max(b, 1), B!.count) - 1] * 1000) }
            func ins(_ kind: Int, _ m: Int, _ name: String, _ color: Int) throws {
                try insert(
                    db, ids,
                    CueRow(
                        content: a.id, contentUUID: c.uuid, inMS: m, outMS: -1, kind: kind, color: color, comment: name),
                    ts)
            }
            let hot = try trackCues(db, a.id, " and Kind>0")
            var mem = try trackCues(db, a.id, " and Kind=0").map {
                var m = $0; m.comment = Config.norm(m.comment); return m
            }

            if B != nil {  // remove stale memory cues: the nearest with the name within 500 ms
                for r in a.remove {
                    let at = ms(r.beat)
                    var best = -1
                    for (i, q) in mem.enumerated()
                    where q.comment == r.name && abs(q.inMS - at) <= 500
                        && (best < 0 || abs(q.inMS - at) < abs(mem[best].inMS - at))
                    {
                        best = i
                    }
                    if best < 0 { continue }
                    try db.exec("delete from djmdCue where ID=?", mem[best].id)
                    mem.remove(at: best)
                    stats.add("removed", 1)
                }
            }
            let taken = Set(hot.map(\.kind))
            for (name, v) in [("E", a.e), ("G", a.g)] {
                let kind = Config.kind[name]!
                guard let v, v.status != .existing else { continue }
                if v.status == .new && taken.contains(kind) {
                    stats.append("skipped", "\(a.title): \(name) is no longer empty")
                    continue
                }
                if v.status == .replace || v.status == .clear {  // already in the transition cache
                    let n = try db.exec(
                        "delete from djmdCue where ContentID=? and Kind=? and rb_local_deleted=0", a.id, kind)
                    stats.add("removed", n)
                }
                if v.status == .clear || B == nil { continue }
                try ins(kind, ms(v.beat), v.name, Config.hotColor)
                stats.add("hot_cues", 1)
            }
            guard B != nil else { continue }
            for m in a.markers where m.status != .existing {
                let base = m.name.range(of: " ", options: .backwards).map { String(m.name[..<$0.lowerBound]) } ?? m.name
                // '<base> IN/OUT' at the beat: there already, else a plain '<base>' there renamed, else added
                let at = ms(m.beat)
                func near(_ n: String) -> Int? { mem.firstIndex { $0.comment == n && abs($0.inMS - at) <= 500 } }
                if near(m.name) != nil { continue }
                if let i = near(base) {
                    let old = mem[i]
                    try db.exec(
                        "update djmdCue set Comment=?, Color=?, updated_at=? where ID=?", m.name,
                        Config.memoryColor[m.name] ?? 0, ts,
                        old.id.isEmpty ? nil : old.id)
                    mem.remove(at: i)
                    mem.append(CueInfo(id: old.id, kind: 0, comment: m.name, inMS: old.inMS))
                    stats.add("renamed", 1)
                    continue
                }
                try ins(Config.kind["MEM"]!, at, m.name, Config.memoryColor[m.name] ?? 0)
                mem.append(CueInfo(id: "", kind: 0, comment: m.name, inMS: at))
                stats.add("markers", 1)
            }
        }
        stats.add("content_cues", try ContentCue.sync(db, touched, ts: ts))
        return stats
    }

    /// Applies `Config.renameTo` to the track's cues and `Config.memoryColor` to its memory cues.
    static func renameAndRecolour(_ db: SQLite, _ id: String, _ ts: String, _ stats: Stats) throws {
        for r in try db.query(
            "select ID, Comment, Color from djmdCue where ContentID=? and rb_local_deleted=0 and Kind=0", id)
        {
            var key = Config.norm(r.string(1))
            let to = Config.renameTo(key, hot: false)
            if !to.isEmpty {
                key = to
                try db.exec("update djmdCue set Comment=?, updated_at=? where ID=?", to, ts, r.string(0))
                stats.add("renamed", 1)
            }
            if let want = Config.memoryColor[key], r.optInt(2) != want {
                try db.exec("update djmdCue set Color=?, updated_at=? where ID=?", want, ts, r.string(0))
                stats.add("recoloured", 1)
            }
        }
        for c in try trackCues(db, id, " and Kind>0") {
            let to = Config.renameTo(c.comment, hot: true)  // 'JUMP TO DROP' -> 'JUMP'
            if !to.isEmpty {
                try db.exec("update djmdCue set Comment=?, updated_at=? where ID=?", to, ts, c.id)
                stats.add("renamed", 1)
            }
        }
    }

    /// Sets the playlist's track order (djmdSongPlaylist.TrackNo) to contentIDs.
    public static func reorderPlaylist(_ db: SQLite, _ name: String, _ contentIDs: [String]) throws -> Stats {
        let pid = try db.queryRow("select ID from djmdPlaylist where rb_local_deleted=0 and Name=?", name)?.string(0)
        var byContent: [String: String] = [:]
        for r in try db.query(
            "select ID, ContentID from djmdSongPlaylist where PlaylistID=? and rb_local_deleted=0", pid)
        {
            byContent[r.string(1)] = r.string(0)
        }
        guard Set(contentIDs) == Set(byContent.keys) else {
            throw AutoDJError("the playlist changed since the order was planned")
        }
        let ts = SafeWrite.stamp()
        for (n, cid) in contentIDs.enumerated() {
            try db.exec("update djmdSongPlaylist set TrackNo=?, updated_at=? where ID=?", n + 1, ts, byContent[cid])
        }
        return Stats([("reordered", .int(contentIDs.count))])
    }
}
