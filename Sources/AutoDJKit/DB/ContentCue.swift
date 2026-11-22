// Copyright 2026 BitWise Media Group Ltd
// SPDX-License-Identifier: MIT

import Foundation

/// Rekordbox 6+ keeps a second copy of each track's cues in `contentCue` (ADR 0005): `Cues`
/// is a JSON array of the track's live `djmdCue` rows and `rb_cue_count` their number. The
/// players read it (a loop made active only in `djmdCue` never activates), so every cue write
/// rebuilds it from `djmdCue`, the way Rekordbox writes it: the columns below in this order,
/// NULL ones left out, timestamps in ISO form (`2026-10-10T00:44:16.500+00:00`), compact, with
/// nothing escaped beyond what JSON requires.
public enum ContentCue {
    /// The djmdCue columns in the JSON, in Rekordbox's order; true for the text ones.
    static let columns: [(String, Bool)] = [
        ("ID", true), ("ContentID", true), ("ContentUUID", true), ("InMsec", false), ("InFrame", false),
        ("InMpegFrame", false), ("InMpegAbs", false), ("OutMsec", false), ("OutFrame", false),
        ("OutMpegFrame", false), ("OutMpegAbs", false), ("Kind", false), ("Color", false),
        ("ColorTableIndex", false), ("ActiveLoop", false), ("Comment", true), ("BeatLoopSize", false),
        ("CueMicrosec", false), ("UUID", true), ("created_at", true), ("updated_at", true),
    ]

    /// "2026-10-10 00:44:16.500 +00:00" -> "2026-10-10T00:44:16.500+00:00".
    static func iso(_ s: String) -> String {
        guard let m = s.wholeMatch(of: #/(\d{4}-\d\d-\d\d) (\d\d:\d\d:\d\d(?:\.\d+)?) ?([+-]\d\d:\d\d)/#) else {
            return s
        }
        return "\(m.1)T\(m.2)\(m.3)"
    }

    /// s as a JSON string: quotes, backslashes and control characters escaped, the rest as is.
    static func quote(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case _ where u.value < 0x20: out += String(format: "\\u%04x", u.value)
            default: out.unicodeScalars.append(u)
            }
        }
        return out + "\""
    }

    /// The `Cues` JSON and count for content id, from its live djmdCue rows in the order they
    /// were created (Rekordbox's order).
    public static func json(_ db: SQLite, _ id: String) throws -> (json: String, count: Int) {
        let cols = columns.map(\.0).joined(separator: ",")
        let rows = try db.query(
            "select \(cols) from djmdCue where ContentID=? and rb_local_deleted=0 order by created_at, rowid", id)
        let objs: [String] = rows.map { r in
            var fields: [String] = []
            for (i, c) in columns.enumerated() where !r.isNull(i) {
                let v: String
                if c.1 {
                    let s = r.string(i)
                    v = quote(c.0.hasSuffix("_at") ? iso(s) : s)
                } else {
                    v = String(r.int(i))
                }
                fields.append("\"\(c.0)\":" + v)
            }
            return "{" + fields.joined(separator: ",") + "}"
        }
        return ("[" + objs.joined(separator: ",") + "]", rows.count)
    }

    /// Rewrites the contentCue rows of the given tracks from djmdCue (adding the row when a
    /// track with cues has none). ts: the write's timestamp. Returns how many rows changed.
    @discardableResult
    public static func sync(_ db: SQLite, _ ids: some Sequence<String>, ts: String) throws -> Int {
        guard try exists(db) else { return 0 }  // Rekordbox 5 libraries (and test fixtures) don't have it
        var n = 0
        for id in Set(ids) {
            let (js, count) = try json(db, id)
            if let r = try db.queryRow(
                "select ID, Cues, rb_cue_count from contentCue where ContentID=? and rb_local_deleted=0", id)
            {
                if r.string(1) == js && r.int(2) == count { continue }
                try db.exec(
                    "update contentCue set Cues=?, rb_cue_count=?, updated_at=? where ID=?", js, count, ts, r.string(0))
                n += 1
            } else if count > 0, let c = try db.queryRow("select UUID from djmdContent where ID=?", id) {
                try db.exec(
                    """
                    insert into contentCue (ID, ContentID, Cues, rb_cue_count, UUID, rb_data_status,
                      rb_local_data_status, rb_local_deleted, rb_local_synced, usn, rb_local_usn, created_at, updated_at)
                    values (?, ?, ?, ?, ?, 0, 0, 0, 0, NULL, NULL, ?, ?)
                    """, c.string(0), id, js, count, UUID().uuidString.lowercased(), ts, ts)
                n += 1
            }
        }
        return n
    }

    /// The tracks whose contentCue doesn't hold the same cues as djmdCue (compared as JSON
    /// values, so key order and spacing don't count), or that have cues but no contentCue row.
    public static func stale(_ db: SQLite) throws -> [String] {
        guard try exists(db) else { return [] }
        var out: [String] = []
        let have = Dictionary(
            try db.query("select ContentID, Cues from contentCue where rb_local_deleted=0").map {
                ($0.string(0), $0.string(1))
            }, uniquingKeysWith: { a, _ in a })
        for r in try db.query("select distinct ContentID from djmdCue where rb_local_deleted=0") {
            let id = r.string(0)
            guard let cur = have[id] else {
                out.append(id)
                continue
            }
            if try !same(cur, json(db, id).json) { out.append(id) }
        }
        return out
    }

    /// Brings every out-of-step track's contentCue in line (`cue-sync`).
    public static func resync(_ db: SQLite) throws -> Stats {
        let ids = try stale(db)
        let st = Stats([("out_of_step", .int(ids.count)), ("synced", .int(0))])
        st.add("synced", try sync(db, ids, ts: SafeWrite.stamp()))
        return st
    }

    static func exists(_ db: SQLite) throws -> Bool {
        try db.queryRow("select 1 from sqlite_master where type='table' and name='contentCue'") != nil
    }

    /// Whether two Cues JSON arrays hold the same cues, in any order.
    static func same(_ a: String, _ b: String) -> Bool {
        func set(_ s: String) -> NSSet? {
            (try? JSONSerialization.jsonObject(with: Data(s.utf8))).flatMap { $0 as? [NSDictionary] }.map {
                NSSet(array: $0)
            }
        }
        guard let x = set(a), let y = set(b) else { return false }
        return x == y
    }
}
