// Copyright 2026 BitWise Media Group Ltd
// SPDX-License-Identifier: MIT

import Darwin
import Foundation

/// Reads and writes Rekordbox's master.db (port of internal/db).
///
/// Safety model:
///   - Reads always happen on a decrypted temporary copy of master.db, never the live file.
///   - Writes happen on a decrypted copy too; the original is backed up and only replaced once
///     the re-encrypted copy has been decrypted again and integrity-checked (`SafeWrite`).
///   - Writing is refused while Rekordbox is running (it keeps master.db open and would
///     overwrite our changes on quit) or while a -wal/-shm sidecar exists.
public final class RekordboxDB: @unchecked Sendable {
    /// The connection to the copy. It owns the copy: the folder goes when the connection is
    /// closed, so `readCopy(...).sql.query(...)` is safe even after this object is released.
    public let sql: SQLite

    init(sql: SQLite) { self.sql = sql }

    /// A decrypted throwaway copy of masterDB (removed when its connection is released).
    public static func readCopy(_ masterDB: String) throws -> RekordboxDB {
        let dir = try makeTempDir("auto-dj-read-")
        do {
            let plain = try decrypt(masterDB, into: dir)
            let sql = try SQLite(path: plain)
            sql.onClose = { try? FileManager.default.removeItem(atPath: dir) }
            return RekordboxDB(sql: sql)
        } catch {
            try? FileManager.default.removeItem(atPath: dir)
            throw error
        }
    }

    /// Decrypts master into dir/master.db.
    static func decrypt(_ master: String, into dir: String) throws -> String {
        let key = try SQLCipher.rekordboxKey()
        let plain = (dir as NSString).appendingPathComponent("master.db")
        do {
            try SQLCipher.decrypt(src: master, dst: plain, key: key)
        } catch {
            throw AutoDJError("decrypting \(master): \(error)")
        }
        return plain
    }
}

/// A plain error message (printed as is).
public struct AutoDJError: Error, CustomStringConvertible, LocalizedError {
    public let description: String
    public init(_ s: String) { description = s }
    public var errorDescription: String? { description }
}

/// A fresh folder under $TMPDIR (else the user's temporary directory).
public func makeTempDir(_ prefix: String) throws -> String {
    let env = ProcessInfo.processInfo.environment["TMPDIR"] ?? ""
    let base = env.isEmpty ? NSTemporaryDirectory() : env
    let path = (base as NSString).appendingPathComponent(prefix + UUID().uuidString.prefix(8))
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    return path
}

// MARK: - safety checks

public enum Rekordbox {
    /// Whether Rekordbox is running: any process whose executable path contains
    /// "rekordbox.app/Contents/MacOS" (case-insensitive), like the Go version's pgrep. When the
    /// process list can't be read, assume it is running rather than allow a write.
    public static func isRunning() -> Bool {
        let n = proc_listallpids(nil, 0)
        if n <= 0 { return true }
        var pids = [pid_t](repeating: 0, count: Int(n) + 64)
        let got = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        if got <= 0 { return true }
        var buf = [CChar](repeating: 0, count: Int(4 * MAXPATHLEN))
        // without the paths of other processes (e.g. in a sandbox) we can't tell
        if proc_pidpath(1, &buf, UInt32(buf.count)) <= 0 { return true }
        for pid in pids.prefix(Int(got)) where pid > 0 {
            let len = proc_pidpath(pid, &buf, UInt32(buf.count))
            if len <= 0 { continue }
            let path = String(decoding: buf.prefix(Int(len)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
                .lowercased()
            if path.contains("rekordbox.app/contents/macos") { return true }
        }
        return false
    }

    /// Refuses while Rekordbox runs or master.db has a -wal / -shm sidecar.
    public static func assertSafeToWrite(_ masterDB: String) throws {
        if isRunning() {
            throw AutoDJError("rekordbox is running. Quit it fully before writing cues")
        }
        let dir = (masterDB as NSString).deletingLastPathComponent
        for side in ["master.db-wal", "master.db-shm"]
        where FileManager.default.fileExists(atPath: (dir as NSString).appendingPathComponent(side)) {
            throw AutoDJError("\(side) exists, so Rekordbox may still have the database open")
        }
    }
}

// MARK: - track selection

/// One djmdCue row.
public struct Cue: Sendable, Equatable, Codable {
    /// 0 memory cue, 1.. hot cue slots (see `Config.kind`).
    public var kind: Int
    /// InMsec / 1000.
    public var t: Double
    /// OutMsec / 1000, 0 when the cue has no end.
    public var out: Double = 0
    /// Comment ("" when NULL).
    public var name: String
    public var activeLoop: Int?
    public var beatLoopSize: Int?

    public init(
        kind: Int, t: Double, out: Double = 0, name: String, activeLoop: Int? = nil,
        beatLoopSize: Int? = nil
    ) {
        self.kind = kind
        self.t = t
        self.out = out
        self.name = name
        self.activeLoop = activeLoop
        self.beatLoopSize = beatLoopSize
    }
}

/// One djmdContent row.
public struct TrackRow: Sendable {
    public var id: String
    public var title: String
    public var rating: Int
    public var folderPath: String
    /// BPM / 100.
    public var bpm: Double
    /// Seconds, 0 when unknown.
    public var length: Double
    public var analysisDataPath: String
    public var uuid: String
}

extension SQLite {
    /// Every track and its cues (by content ID, in InMsec order).
    public func loadTracksAndCues() throws -> ([TrackRow], [String: [Cue]]) {
        let tracks = try query(
            """
            select ID, Title, coalesce(Rating,0), FolderPath, BPM, Length,
                   AnalysisDataPath, UUID from djmdContent where rb_local_deleted=0
            """
        ).map { r in
            TrackRow(
                id: r.string(0), title: r.string(1), rating: r.int(2), folderPath: r.string(3),
                bpm: r.double(4) / 100, length: r.double(5), analysisDataPath: r.string(6),
                uuid: r.string(7))
        }
        var by: [String: [Cue]] = [:]
        for r in try query(
            """
            select ContentID, Kind, InMsec, OutMsec, Comment, ActiveLoop, BeatLoopSize
            from djmdCue where rb_local_deleted=0 order by InMsec
            """)
        {
            var c = Cue(
                kind: r.int(1), t: Double(r.int(2)) / 1000, name: r.string(4), activeLoop: r.optInt(5),
                beatLoopSize: r.optInt(6))
            if let o = r.optInt(3), o > 0 { c.out = Double(o) / 1000 }
            by[r.string(0), default: []].append(c)
        }
        return (tracks, by)
    }

    /// Every track's ID and title in table order.
    public func titles() throws -> [(id: String, title: String)] {
        try query("select ID, Title from djmdContent where rb_local_deleted=0").map {
            ($0.string(0), $0.string(1))
        }
    }
}

public enum Category {
    /// Old category names and the current ones.
    public static let aliases = ["uncued": "nohot"]

    /// Resolves a category alias.
    public static func alias(_ c: String) -> String { aliases[c] ?? c }

    /// Cues generated by software that we replace: Mixed In Key 'Energy N', Rekordbox
    /// 'CUE(Auto)'.
    public static func isAutoCue(_ name: String) -> Bool {
        let n = Config.norm(name)
        return n.hasPrefix("ENERGY") || n == "CUE(AUTO)"
    }

    /// Cues we are allowed to delete on a target track.
    public static func replaceable(_ name: String, kind: Int) -> Bool {
        isAutoCue(name) || (name == "START" && kind == 1)
    }

    /// Sorts a track:
    ///
    ///     manual - rated, or has the user's own IN/DROP/OUT hot cues (training data)
    ///     auto   - unrated and cued by this tool (listed in the ledger); not training data
    ///     mik    - only generated cues (Mixed In Key 'Energy N', Rekordbox 'CUE(Auto)'),
    ///              plus an optional START hot cue
    ///     nohot  - no hot cues at all (no cues, or memory cues only); any memory cues the
    ///              user named themselves are kept when the track is cued
    ///     other  - anything else (left alone)
    ///
    /// Rating an 'auto' track (after checking/fixing it) promotes it to 'manual'.
    public static func classify(rating: Int, cues: [Cue], auto: Bool) -> String {
        if rating > 0 { return "manual" }
        if auto { return "auto" }
        var hot = Set<String>()
        var anyHot = false
        var anyAutoHot = false
        var allReplaceable = true
        for c in cues {
            if c.kind > 0 {
                hot.insert(c.name)
                anyHot = true
                if isAutoCue(c.name) { anyAutoHot = true }
            }
            if !replaceable(c.name, kind: c.kind) { allReplaceable = false }
        }
        if hot.contains("IN"), hot.contains("DROP"), hot.contains("OUT") { return "manual" }
        if anyAutoHot, allReplaceable { return "mik" }
        if !anyHot { return "nohot" }
        return "other"
    }
}

// MARK: - ledger

public enum Ledger {
    struct File: Codable {
        var trackIDs: [String]
        enum CodingKeys: String, CodingKey { case trackIDs = "track_ids" }
    }

    /// The IDs of tracks this tool has cued (so they are not mistaken for hand-cued tracks).
    public static func load(_ path: String) throws -> Set<String> {
        guard FileManager.default.fileExists(atPath: path) else { return [] }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        do {
            return Set(try JSONDecoder().decode(File.self, from: data).trackIDs)
        } catch {
            throw AutoDJError("\(path): \(error)")
        }
    }

    /// Records ids as cued by this tool.
    public static func add(_ path: String, _ ids: [String]) throws {
        let all = try load(path).union(ids).sorted()
        try JSONFile.write(File(trackIDs: all), to: path)
    }
}

// MARK: - playlists

/// A playlist, or an intelligent playlist whose tracks Rekordbox picks by its conditions. An
/// intelligent playlist has no order of its own, so it can't be reordered.
public struct Playlist: Sendable {
    public var name: String
    public var intelligent: Bool
    /// Only from `loadPlaylist`.
    public var tracks: [PlaylistTrack] = []

    public init(name: String, intelligent: Bool, tracks: [PlaylistTrack] = []) {
        (self.name, self.intelligent, self.tracks) = (name, intelligent, tracks)
    }
}

/// One track of a playlist.
public struct PlaylistTrack: Sendable, Codable, Equatable {
    public var no: Int
    public var id: String
    public var title: String
    public var bpm: Double
    /// "" when unknown.
    public var key: String

    public init(no: Int, id: String, title: String, bpm: Double, key: String) {
        self.no = no
        self.id = id
        self.title = title
        self.bpm = bpm
        self.key = key
    }
}

/// djmdPlaylist.Attribute values.
enum PlaylistAttr {
    static let folder = 1
    static let intelligent = 4
}

/// No playlist has the requested name.
public struct NoPlaylist: Error, CustomStringConvertible {
    public let description: String
}

extension SQLite {
    /// The playlists and intelligent playlists (folders excluded), without their tracks.
    public func listPlaylists() throws -> [Playlist] {
        try query(
            "select Name, coalesce(Attribute,0) from djmdPlaylist where rb_local_deleted=0 "
                + "and coalesce(Attribute,0) <> ? order by Seq", PlaylistAttr.folder
        ).map { Playlist(name: $0.string(0), intelligent: $0.int(1) == PlaylistAttr.intelligent) }
    }

    /// The playlist's tracks in TrackNo order. An intelligent playlist's tracks are the
    /// collection's matches, in the order they were added, numbered from 1.
    public func loadPlaylist(_ name: String, today: Date = Date()) throws -> Playlist {
        guard
            let row = try queryRow(
                "select ID, coalesce(Attribute,0), SmartList from djmdPlaylist "
                    + "where rb_local_deleted=0 and Name=? order by coalesce(Attribute,0) = ?", name,
                PlaylistAttr.folder)
        else {
            throw NoPlaylist(description: "no such playlist: no playlist called '\(name)'")
        }
        let pid = row.string(0)
        let attr = row.int(1)
        let cols = "c.ID, c.Title, c.BPM, (select ScaleName from djmdKey where ID = c.KeyID)"
        var q =
            "select sp.TrackNo, \(cols) from djmdSongPlaylist sp join djmdContent c on c.ID = sp.ContentID "
            + "where sp.PlaylistID=? and sp.rb_local_deleted=0 order by sp.TrackNo"
        var args: [SQLBindable] = [pid]
        switch attr {
        case PlaylistAttr.folder:
            throw NoPlaylist(description: "no such playlist: '\(name)' is a folder")
        case PlaylistAttr.intelligent:
            do {
                let (w, a) = try SmartList.whereClause(row.string(2), today: today)
                args = a
                q =
                    "select 0, \(cols) from djmdContent c where c.rb_local_deleted=0 and (\(w)) "
                    + "order by c.created_at, c.ID"
            } catch {
                throw AutoDJError("intelligent playlist '\(name)': \(error)")
            }
        default: break
        }
        var pl = Playlist(name: name, intelligent: attr == PlaylistAttr.intelligent)
        for r in try query(q, args: args) {
            let no = pl.intelligent ? pl.tracks.count + 1 : r.int(0)
            pl.tracks.append(
                PlaylistTrack(
                    no: no, id: r.string(1), title: r.string(2), bpm: r.double(3) / 100, key: r.string(4)))
        }
        return pl
    }
}
