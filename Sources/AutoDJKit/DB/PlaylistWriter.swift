// Copyright 2026 BitWise Media Group Ltd
// SPDX-License-Identifier: MIT

import Foundation

/// A playlist `createPlaylist` inserted.
public struct NewPlaylist: Sendable {
    public var id: String
    public var parentID: String
    public var name: String
    public var created: Date
    public var tracks: Int
}

/// Creates playlists in master.db and mirrors them into masterPlaylists6.xml (port of
/// internal/db/playlist.go, ADR 0016).
public enum PlaylistWriter {
    /// The file next to master.db where Rekordbox 6/7 mirrors the playlist tree.
    public static let playlistXML = "masterPlaylists6.xml"

    /// Adds a plain playlist called name holding contentIDs in order (duplicates kept), at the
    /// end of the root or of the folder called folder. It refuses a name that is already taken
    /// and content IDs that aren't in the library. Like the cue writes it leaves usn and
    /// agentRegistry alone.
    public static func create(_ db: SQLite, name: String, folder: String, contentIDs: [String]) throws -> NewPlaylist {
        if try db.queryRow("select count(*) from djmdPlaylist where rb_local_deleted=0 and Name=?", name)!.int(0) > 0 {
            throw AutoDJError("playlist already exists: '\(name)'")
        }
        var parent = "root"
        if !folder.isEmpty {
            guard
                let r = try db.queryRow(
                    "select ID from djmdPlaylist where rb_local_deleted=0 and Attribute=1 and Name=?", folder)
            else { throw AutoDJError("no playlist folder called '\(folder)'") }
            parent = r.string(0)
        }
        for cid in contentIDs
        where try db.queryRow("select count(*) from djmdContent where rb_local_deleted=0 and ID=?", cid)!.int(0) == 0 {
            throw AutoDJError("track \(cid) is not in the library")
        }
        let seq = try db.queryRow(
            "select coalesce(max(Seq), 0) from djmdPlaylist where rb_local_deleted=0 and ParentID=?", parent)!.int(0)
        let id = try CueWriter.IDSource(db, "djmdPlaylist").next()
        let created = Date()
        let ts = SafeWrite.stamp(created)
        try db.exec(
            """
            insert into djmdPlaylist (ID, Seq, Name, ImagePath, Attribute, ParentID, SmartList, UUID,
              rb_data_status, rb_local_data_status, rb_local_deleted, rb_local_synced, usn, rb_local_usn,
              created_at, updated_at) values (?, ?, ?, NULL, 0, ?, NULL, ?, 0, 0, 0, 0, NULL, NULL, ?, ?)
            """, id, seq + 1, name, parent, CueWriter.newUUID(), ts, ts)
        for (i, cid) in contentIDs.enumerated() {
            try db.exec(
                """
                insert into djmdSongPlaylist (ID, PlaylistID, ContentID, TrackNo, UUID, rb_data_status,
                  rb_local_data_status, rb_local_deleted, rb_local_synced, usn, rb_local_usn, created_at, updated_at)
                  values (?, ?, ?, ?, ?, 0, 0, 0, 0, NULL, NULL, ?, ?)
                """, CueWriter.newUUID(), id, cid, i + 1, CueWriter.newUUID(), ts, ts)
        }
        return NewPlaylist(id: id, parentID: parent, name: name, created: created, tracks: contentIDs.count)
    }

    /// A djmdPlaylist ID as masterPlaylists6.xml writes it: upper-case hex, root "0".
    static func xmlID(_ id: String) throws -> String {
        if id == "root" || id.isEmpty { return "0" }
        guard let n = UInt64(id) else { throw AutoDJError("playlist ID \"\(id)\" is not a number") }
        return String(n, radix: 16, uppercase: true)
    }

    /// masterPlaylists6.xml with a NODE for p appended to PLAYLISTS, in the file's own line
    /// endings and indentation.
    public static func addNode(_ doc: Data, _ p: NewPlaylist) throws -> Data {
        // bytes, not Characters: Swift reads "\r\n" as one Character, so a search for "\n" misses it
        let d = Array(doc)
        let id = try xmlID(p.id)
        let parent = try xmlID(p.parentID)
        func find(_ s: String, backwards: Bool = false, before: Int? = nil) -> Int? {
            let n = Array(s.utf8)
            let hi = (before ?? d.count) - n.count
            if hi < 0 { return nil }
            let range = backwards ? Array(stride(from: hi, through: 0, by: -1)) : Array(0...hi)
            return range.first { Array(d[$0..<$0 + n.count]) == n }
        }
        if find("<NODE Id=\"\(id)\"") != nil { throw AutoDJError("a node with Id \(id) is already there") }
        guard let end = find("</PLAYLISTS>", backwards: true) else { throw AutoDJError("no </PLAYLISTS> element") }
        let lineStart = (d[..<end].lastIndex(of: UInt8(ascii: "\n")) ?? -1) + 1
        let nl = find("\r\n") != nil ? "\r\n" : "\n"
        var indent = "    "
        if let i = find("<NODE ") {
            let ls = (d[..<i].lastIndex(of: UInt8(ascii: "\n")) ?? -1) + 1
            indent = String(decoding: d[ls..<i], as: UTF8.self)
        }
        let ms = Int64((p.created.timeIntervalSince1970 * 1000).rounded(.down))
        let node =
            "\(indent)<NODE Id=\"\(id)\" ParentId=\"\(parent)\" Attribute=\"0\" Timestamp=\"\(ms)\" Lib_Type=\"0\" CheckType=\"0\"/>\(nl)"
        return Data(d[..<lineStart] + Array(node.utf8) + d[lineStart...])
    }

    /// Creates the playlist through `write` (SafeWrite, or a test double), adding its node to masterPlaylists6.xml in the same
    /// step when that file exists.
    public static func write(
        masterDB: String, backupDir: String, name: String, folder: String, contentIDs: [String],
        write: (ApplyFunc, [Sidecar]) throws -> Stats
    ) throws -> Stats {
        nonisolated(unsafe) var created: NewPlaylist?
        let fn: ApplyFunc = { db in
            let p = try create(db, name: name, folder: folder, contentIDs: contentIDs)
            created = p
            return Stats([("playlist", .string(p.name)), ("playlist_id", .string(p.id)), ("tracks", .int(p.tracks))])
        }
        var sides: [Sidecar] = []
        let xml = ((masterDB as NSString).deletingLastPathComponent as NSString).appendingPathComponent(playlistXML)
        if FileManager.default.fileExists(atPath: xml) {
            sides.append(Sidecar(path: xml) { old in try addNode(old, created!) })
        }
        return try write(fn, sides)
    }

    /// `write` through SafeWrite on masterDB.
    public static func safeWrite(
        masterDB: String, backupDir: String, name: String, folder: String, contentIDs: [String]
    ) throws -> Stats {
        try write(masterDB: masterDB, backupDir: backupDir, name: name, folder: folder, contentIDs: contentIDs) {
            fn, sides in try SafeWrite.write(masterDB, backupDir: backupDir, fn, sidecars: sides)
        }
    }
}
