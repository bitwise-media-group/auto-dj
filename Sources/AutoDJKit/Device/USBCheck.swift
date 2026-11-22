// Copyright 2026 BitWise Media Group Ltd
// SPDX-License-Identifier: MIT

import Foundation

/// A USB device Rekordbox exported to, and whether the cues on it are still the collection's
/// (ADR 0024). Rekordbox's Sync Manager doesn't refresh the cues of a track that's already on a
/// device: only edits made with the device plugged in, or exporting the playlist again
/// (right-click > Export Playlist, replace), get there. `check` finds the tracks whose cues on a device differ from
/// master.db, and the synced playlists that hold them.
public enum USBDevice {
    /// A cue as a device holds it: hot cue slot "A"..."H", or "" for a memory cue.
    public struct Cue: Sendable, Equatable, Hashable {
        public var slot: String
        public var ms: Int
        public var name: String

        public init(slot: String, ms: Int, name: String) {
            (self.slot, self.ms, self.name) = (slot, ms, name)
        }
    }

    /// One track's analysis file on a device: the audio path it names and its cues.
    public struct Exported: Sendable, Equatable {
        /// The .EXT file.
        public var file: String
        /// The audio file's path on the device (PPTH), e.g. "/Contents/Artist/Album/Title.aiff".
        public var path: String
        public var cues: [Cue]
        /// When Rekordbox last wrote the file.
        public var written: Date

        public init(file: String, path: String, cues: [Cue], written: Date) {
            (self.file, self.path, self.cues, self.written) = (file, path, cues, written)
        }
    }

    /// A collection track to compare: its ID, title, audio path and cues from master.db.
    public struct Track: Sendable {
        public var id: String
        public var title: String
        public var path: String
        public var cues: [Cue]
    }

    /// A track whose cues on the device differ from master.db.
    public struct Stale: Sendable, Equatable {
        public var id: String
        public var title: String
        public var written: Date
        public var differences: [String]
        /// The synced playlists (else all playlists) that hold it.
        public var playlists: [String]
    }

    public struct Report: Sendable {
        public var volume: String
        public var exported = 0
        public var current = 0
        public var stale: [Stale] = []
        /// Device paths that match no collection track, or more than one.
        public var unmatched: [String] = []
        /// The playlists Sync Manager keeps in step with the device.
        public var synced: [String] = []
    }

    // ---------------------------------------------------------------- the device

    /// The export folder on a volume: `.PIONEER` (Rekordbox 7) or `PIONEER`, nil when there's none.
    public static func pioneerDir(_ volume: String) -> String? {
        for d in [".PIONEER", "PIONEER"] {
            let p = (volume as NSString).appendingPathComponent(d)
            if FileManager.default.fileExists(atPath: (p as NSString).appendingPathComponent("USBANLZ")) { return p }
        }
        return nil
    }

    /// The mounted volumes with a Rekordbox export.
    public static func volumes() -> [String] {
        let vs = (try? FileManager.default.contentsOfDirectory(atPath: "/Volumes")) ?? []
        return vs.sorted().map { "/Volumes/" + $0 }.filter { pioneerDir($0) != nil }
    }

    /// Every track's .EXT analysis file under the device's USBANLZ.
    public static func exported(_ pioneerDir: String) throws -> [Exported] {
        let root = (pioneerDir as NSString).appendingPathComponent("USBANLZ")
        guard let walk = FileManager.default.enumerator(atPath: root) else { return [] }
        var out: [Exported] = []
        for case let rel as String in walk where rel.hasSuffix(".EXT") {
            let f = (root as NSString).appendingPathComponent(rel)
            guard let data = FileManager.default.contents(atPath: f) else { continue }
            let written = (try? FileManager.default.attributesOfItem(atPath: f))?[.modificationDate] as? Date
            let (path, cues) = try parse(Array(data))
            out.append(Exported(file: f, path: path, cues: cues, written: written ?? .distantPast))
        }
        return out.sorted { $0.path < $1.path }
    }

    /// The synced playlists' IDs from the device's `playlists3.sync` (Sync Manager's file: hex
    /// djmdPlaylist IDs).
    public static func syncedPlaylistIDs(_ pioneerDir: String) -> [String] {
        let f = (pioneerDir as NSString).appendingPathComponent("rekordbox/playlists3.sync")
        guard let s = try? String(contentsOfFile: f, encoding: .utf8) else { return [] }
        return s.matches(of: /<NODE Id="([0-9A-Fa-f]+)"[^>]*Attribute="0"/).compactMap {
            UInt64($0.1, radix: 16).map(String.init)
        }
    }

    // ---------------------------------------------------------------- ANLZ cue tags

    /// The audio path (PPTH) and cues (PCO2: hot cues and memory cues, with names) of a .EXT.
    ///
    /// PPTH: 12-byte header, path length u32 at 12, UTF-16BE path from 16. PCO2: 12-byte header,
    /// list type u32 at 12 (0 memory, 1 hot), cue count u16 at 16, then PCP2 entries from the
    /// tag's header length: entry length u32 at 8, hot cue number u32 at 12 (0 memory, 1 = A),
    /// time in ms u32 at 20, comment length u32 at 40, UTF-16BE comment from 44.
    static func parse(_ data: [UInt8]) throws -> (String, [Cue]) {
        let d = data[...]
        guard data.count >= 12, Array(data[0..<4]) == Array("PMAI".utf8) else { throw Analysis.malformed }
        var path = ""
        var cues: [Cue] = []
        var i = Analysis.be32(d, 4)
        let end = min(Analysis.be32(d, 8), data.count)
        while i + 12 <= end {
            let lenHeader = Analysis.be32(d, i + 4)
            let lenTag = Analysis.be32(d, i + 8)
            guard lenTag >= 12, i + lenTag <= data.count else { throw Analysis.malformed }
            let tag = data[i..<i + lenTag]
            switch String(decoding: data[i..<i + 4], as: UTF8.self) {
            case "PPTH" where lenTag >= 16:
                let n = Analysis.be32(tag, 12)
                path = utf16(tag, 16, n)
            case "PCO2" where lenTag >= 18:
                var o = lenHeader
                for _ in 0..<Analysis.be16(tag, 16) {
                    guard o + 44 <= lenTag else { throw Analysis.malformed }
                    let lenEntry = Analysis.be32(tag, o + 8)
                    let hot = Analysis.be32(tag, o + 12)
                    let n = Analysis.be32(tag, o + 40)
                    guard lenEntry >= 44, o + lenEntry <= lenTag, 44 + n <= lenEntry else { throw Analysis.malformed }
                    let slot = (1...8).contains(hot) ? String("ABCDEFGH".dropFirst(hot - 1).prefix(1)) : ""
                    cues.append(Cue(slot: slot, ms: Analysis.be32(tag, o + 20), name: utf16(tag, o + 44, n)))
                    o += lenEntry
                }
            default: break
            }
            i += lenTag
        }
        return (path, cues)
    }

    /// n bytes of UTF-16BE from offset o, without the trailing NUL.
    static func utf16(_ d: ArraySlice<UInt8>, _ o: Int, _ n: Int) -> String {
        let s = d.startIndex + o
        let units = stride(from: 0, to: n - 1, by: 2).map { UInt16(d[s + $0]) << 8 | UInt16(d[s + $0 + 1]) }
        return String(decoding: units, as: UTF16.self).trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
    }

    // ---------------------------------------------------------------- comparing

    /// The collection's live tracks with their cues, as a device would hold them.
    public static func library(_ db: SQLite) throws -> [Track] {
        let slots = Dictionary(uniqueKeysWithValues: Config.kind.filter { $0.key != "MEM" }.map { ($0.value, $0.key) })
        var cues: [String: [Cue]] = [:]
        for r in try db.query(
            "select ContentID, Kind, InMsec, coalesce(Comment, '') from djmdCue where rb_local_deleted=0")
        {
            let kind = r.int(1)
            guard kind == 0 || slots[kind] != nil else { continue }
            cues[r.string(0), default: []].append(Cue(slot: slots[kind] ?? "", ms: r.int(2), name: r.string(3)))
        }
        return try db.query("select ID, Title, FolderPath from djmdContent where rb_local_deleted=0").map {
            Track(id: $0.string(0), title: $0.string(1), path: $0.string(2), cues: cues[$0.string(0)] ?? [])
        }
    }

    /// The playlists (by ID) holding each track.
    public static func playlists(_ db: SQLite) throws -> (names: [String: String], byTrack: [String: [String]]) {
        var names: [String: String] = [:]
        for r in try db.query("select ID, Name from djmdPlaylist where rb_local_deleted=0") {
            names[r.string(0)] = r.string(1)
        }
        var byTrack: [String: [String]] = [:]
        for r in try db.query("select ContentID, PlaylistID from djmdSongPlaylist where rb_local_deleted=0") {
            byTrack[r.string(0), default: []].append(r.string(1))
        }
        return (names, byTrack)
    }

    /// File names compared the way Rekordbox shortens them on a device: canonical Unicode,
    /// case-insensitive, the device's name a prefix of the collection's (same extension).
    static func key(_ path: String) -> (stem: String, ext: String) {
        let base = ((path as NSString).lastPathComponent).precomposedStringWithCanonicalMapping.lowercased()
        return ((base as NSString).deletingPathExtension, (base as NSString).pathExtension)
    }

    /// The collection track a device file is, or nil when none or several match.
    static func match(_ e: Exported, _ index: [String: [Track]]) -> Track? {
        let k = key(e.path)
        guard !k.stem.isEmpty else { return nil }
        let hits = (index[k.ext] ?? []).filter { key($0.path).stem.hasPrefix(k.stem) }
        if hits.count == 1 { return hits[0] }
        return hits.first { key($0.path).stem == k.stem }  // an exact name wins among several
    }

    /// How the device's cues differ from the collection's (empty when they're the same): hot
    /// cues by slot, memory cues by position and name, times within 5 ms.
    public static func differences(device: [Cue], library: [Cue]) -> [String] {
        func at(_ ms: Int) -> String { SetRun.minSec(Double(ms) / 1000) }
        func named(_ c: Cue) -> String { c.name.isEmpty ? "unnamed" : c.name }
        var out: [String] = []
        let dh = Dictionary(device.filter { !$0.slot.isEmpty }.map { ($0.slot, $0) }, uniquingKeysWith: { a, _ in a })
        let lh = Dictionary(library.filter { !$0.slot.isEmpty }.map { ($0.slot, $0) }, uniquingKeysWith: { a, _ in a })
        for s in Set(dh.keys).union(lh.keys).sorted() {
            switch (dh[s], lh[s]) {
            case (nil, let l?): out.append("\(s): missing on the device (\(named(l)) @ \(at(l.ms)))")
            case (let d?, nil): out.append("\(s): only on the device (\(named(d)) @ \(at(d.ms)))")
            case (let d?, let l?) where d.name != l.name:
                out.append("\(s): \(named(d)) on the device, \(named(l)) in Rekordbox")
            case (let d?, let l?) where abs(d.ms - l.ms) > 5:
                out.append("\(s): \(named(l)) at \(at(d.ms)) on the device, \(at(l.ms)) in Rekordbox")
            default: break
            }
        }
        // memory cues: Rekordbox exports one per position, so cues within 5 ms of each other
        // count as one point, matched by any of their names
        var dm = device.filter { $0.slot.isEmpty }
        var missing: [String] = []
        var points: [[Cue]] = []
        for l in library.filter({ $0.slot.isEmpty }).sorted(by: { $0.ms < $1.ms }) {
            if let last = points.last?.last, l.ms - last.ms <= 5 {
                points[points.count - 1].append(l)
            } else {
                points.append([l])
            }
        }
        for p in points {
            let names = Set(p.map(\.name))
            if let i = dm.firstIndex(where: { d in names.contains(d.name) && p.contains { abs($0.ms - d.ms) <= 5 } }) {
                dm.remove(at: i)
            } else {
                missing.append(p.map(named).joined(separator: "/"))
            }
        }
        if !missing.isEmpty {
            out.append("memory cues missing on the device: " + missing.sorted().joined(separator: ", "))
        }
        if !dm.isEmpty {
            out.append("memory cues only on the device: " + dm.map(named).sorted().joined(separator: ", "))
        }
        return out
    }

    /// Compares a device's exported tracks with the collection.
    public static func check(
        volume: String, exported: [Exported], library: [Track],
        playlists: (names: [String: String], byTrack: [String: [String]]),
        synced: [String]
    ) -> Report {
        var r = Report(volume: volume)
        r.exported = exported.count
        r.synced = synced.compactMap { playlists.names[$0] }
        let index = Dictionary(grouping: library) { key($0.path).ext }
        for e in exported {
            guard let t = match(e, index) else {
                r.unmatched.append(e.path)
                continue
            }
            let diff = differences(device: e.cues, library: t.cues)
            if diff.isEmpty {
                r.current += 1
                continue
            }
            let holding = playlists.byTrack[t.id] ?? []
            let inSynced = holding.filter { synced.contains($0) }
            r.stale.append(
                Stale(
                    id: t.id, title: t.title, written: e.written, differences: diff,
                    playlists: (inSynced.isEmpty ? holding : inSynced).compactMap { playlists.names[$0] }.sorted()))
        }
        r.stale.sort { $0.title < $1.title }
        return r
    }

    /// Reads a volume's export and compares it with master.db at masterDB.
    public static func check(volume: String, masterDB: String) throws -> Report {
        guard let dir = pioneerDir(volume) else {
            throw AutoDJError("\(volume): no Rekordbox export (no PIONEER folder)")
        }
        let db = try RekordboxDB.readCopy(masterDB).sql
        return check(
            volume: volume, exported: try exported(dir), library: try library(db), playlists: try playlists(db),
            synced: syncedPlaylistIDs(dir))
    }

    /// The report as text.
    public static func format(_ r: Report) -> [String] {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        let name = (r.volume as NSString).lastPathComponent
        var lines = [
            "\(name): \(r.exported) tracks exported, \(r.current) up to date, \(r.stale.count) out of date"
                + (r.unmatched.isEmpty ? "" : ", \(r.unmatched.count) not matched to the collection")
        ]
        if !r.synced.isEmpty { lines.append("synced playlists: " + r.synced.joined(separator: ", ")) }
        for s in r.stale {
            lines.append("")
            lines.append("  \(s.title) (on the device since \(f.string(from: s.written)))")
            for d in s.differences { lines.append("     \(d)") }
        }
        for u in r.unmatched { lines.append("  ? \(u)") }
        let resync = Array(Set(r.stale.flatMap(\.playlists))).sorted()
        if !r.stale.isEmpty {
            lines.append("")
            let which = resync.isEmpty ? "their playlists" : resync.map { "\"\($0)\"" }.joined(separator: ", ")
            lines.append(
                "Sync Manager doesn't update the cues of tracks already on a device. To refresh them, right-click "
                    + "\(which) in Rekordbox, Export Playlist > \(name), and OK to replace it: only the changed tracks "
                    + "are exported again.")
        }
        return lines
    }
}
