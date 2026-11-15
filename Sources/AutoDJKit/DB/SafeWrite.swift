// Copyright 2026 BitWise Media Group Ltd
// SPDX-License-Identifier: MIT

import Foundation

/// A write's outcome: an ordered set of counters and lists, printed as JSON.
public final class Stats: CustomStringConvertible, @unchecked Sendable {
    public enum Value: Equatable, Sendable {
        case int(Int)
        case string(String)
        case list([String])
    }

    public private(set) var keys: [String] = []
    public private(set) var values: [String: Value] = [:]

    public init(_ kv: [(String, Value)] = []) {
        for (k, v) in kv { set(k, v) }
    }

    public func set(_ k: String, _ v: Value) {
        if values[k] == nil { keys.append(k) }
        values[k] = v
    }

    public func add(_ k: String, _ n: Int) {
        if case .int(let v) = values[k] { set(k, .int(v + n)) } else { set(k, .int(n)) }
    }

    public func append(_ k: String, _ v: String) {
        if case .list(let l) = values[k] { set(k, .list(l + [v])) } else { set(k, .list([v])) }
    }

    public func int(_ k: String) -> Int {
        if case .int(let v) = values[k] { return v }
        return 0
    }

    public func list(_ k: String) -> [String] {
        if case .list(let v) = values[k] { return v }
        return []
    }

    public func update(_ o: Stats) {
        for k in o.keys { set(k, o.values[k]!) }
    }

    /// Indented JSON, keys in insertion order.
    public var description: String {
        func q(_ s: String) -> String {
            let e = JSONEncoder()
            e.outputFormatting = .withoutEscapingSlashes
            return String(decoding: (try? e.encode(s)) ?? Data("\"\"".utf8), as: UTF8.self)
        }
        let body = keys.map { k -> String in
            let v: String
            switch values[k]! {
            case .int(let n): v = String(n)
            case .string(let s): v = q(s)
            case .list(let l): v = l.isEmpty ? "[]" : "[\n" + l.map { "  " + q($0) }.joined(separator: ",\n") + "\n ]"
            }
            return " " + q(k) + ": " + v
        }
        return "{\n" + body.joined(separator: ",\n") + "\n}"
    }
}

/// Writes into the open working copy inside one transaction.
public typealias ApplyFunc = (SQLite) throws -> Stats

/// A file Rekordbox keeps in step with master.db (masterPlaylists6.xml), replaced together
/// with it: `update` gets the file's current bytes after the write has run and returns the
/// new ones.
public struct Sidecar {
    public var path: String
    public var update: (Data) throws -> Data

    public init(path: String, update: @escaping (Data) throws -> Data) {
        self.path = path
        self.update = update
    }
}

/// The safe master.db write (port of internal/db/write.go): back up, apply to a decrypted
/// copy, re-encrypt with the original salt, decrypt that again and check it, then swap it in
/// unless master.db changed meanwhile.
public enum SafeWrite {
    /// djmdCue / djmdSongPlaylist's timestamp format: UTC with milliseconds.
    static func stamp(_ d: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f.string(from: d) + " +00:00"
    }

    static func localStamp(_ d: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: d)
    }

    /// Copies master.db to backupDir/master.before-cues.<timestamp>.db and checks the copy.
    public static func backup(_ masterDB: String, _ backupDir: String) throws -> String {
        try FileManager.default.createDirectory(atPath: backupDir, withIntermediateDirectories: true)
        let dest = (backupDir as NSString).appendingPathComponent(
            "master.before-cues.\(localStamp()).db")
        try copyFile(masterDB, dest)
        guard FileManager.default.contents(atPath: masterDB) == FileManager.default.contents(atPath: dest)
        else { throw AutoDJError("backup verification failed") }
        return dest
    }

    /// Copies src to dst (fsynced), keeping its mode and modification time.
    static func copyFile(_ src: String, _ dst: String) throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: src))
        let attrs = try FileManager.default.attributesOfItem(atPath: src)
        try SQLCipher.writeSync(dst, data)
        var keep: [FileAttributeKey: Any] = [:]
        keep[.posixPermissions] = attrs[.posixPermissions]
        keep[.modificationDate] = attrs[.modificationDate]
        try FileManager.default.setAttributes(keep, ofItemAtPath: dst)
    }

    static func integrityCheck(_ db: SQLite) throws {
        let ok = try db.queryRow("pragma integrity_check")?.string(0) ?? ""
        if ok != "ok" { throw AutoDJError("integrity check failed after writing: \(ok)") }
    }

    /// Runs fn in one transaction on the plain database at path, checks integrity and folds
    /// the WAL back in.
    static func applyPlain(_ path: String, _ fn: ApplyFunc) throws -> Stats {
        let db = try SQLite(path: path)
        let stats = try db.transaction { try fn(db) }
        try integrityCheck(db)
        try db.query("pragma wal_checkpoint(TRUNCATE)")
        return stats
    }

    /// Applies fn to a throwaway decrypted copy of masterDB and returns the stats.
    public static func dryRun(_ masterDB: String, _ fn: ApplyFunc) throws -> Stats {
        let dir = try makeTempDir("auto-dj-dry-")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        return try applyPlain(try RekordboxDB.decrypt(masterDB, into: dir), fn)
    }

    /// Backs up master.db, applies fn to a decrypted copy, re-encrypts it, checks it and swaps
    /// it in. Sidecars are backed up and replaced with it: if one can't be written, master.db and
    /// the sidecars already written are put back.
    public static func write(
        _ masterDB: String, backupDir: String, _ fn: ApplyFunc, sidecars: [Sidecar] = [],
        key: String? = nil, guard check: (String) throws -> Void = Rekordbox.assertSafeToWrite
    ) throws -> Stats {
        let key = try key ?? SQLCipher.rekordboxKey()
        try check(masterDB)
        let before = try mtime(masterDB)
        let bak = try backup(masterDB, backupDir)
        let dir = try makeTempDir("auto-dj-write-")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let plain = (dir as NSString).appendingPathComponent("master.db")
        do {
            try SQLCipher.decrypt(src: masterDB, dst: plain, key: key)
        } catch {
            throw AutoDJError("decrypting \(masterDB): \(error)")
        }
        let stats = try applyPlain(plain, fn)
        if let w = try? FileManager.default.attributesOfItem(atPath: plain + "-wal"),
            ((w[.size] as? NSNumber)?.intValue ?? 0) > 0
        {
            throw AutoDJError("working copy left un-checkpointed WAL data; aborting before replace")
        }
        let salt = try SQLCipher.readSalt(masterDB)
        let enc = (dir as NSString).appendingPathComponent("master.enc.db")
        try SQLCipher.encrypt(src: plain, dst: enc, key: key, salt: salt)
        let checkPath = (dir as NSString).appendingPathComponent("check.db")
        do {
            try SQLCipher.decrypt(src: enc, dst: checkPath, key: key)
        } catch {
            throw AutoDJError("re-encrypted copy does not decrypt: \(error)")
        }
        do {
            try integrityCheck(try SQLite(path: checkPath))
        } catch {
            throw AutoDJError("re-encrypted copy: \(error)")
        }
        let staged = try stage(sidecars, backupDir)
        guard (try? mtime(masterDB)) == before else {
            throw AutoDJError("master.db changed while writing; nothing was replaced")
        }
        try swapIn(enc, masterDB, bak, staged)
        stats.set("backup", .string(bak))
        for s in staged { stats.append("sidecar_backups", s.backup) }
        return stats
    }

    static func mtime(_ p: String) throws -> Date {
        try FileManager.default.attributesOfItem(atPath: p)[.modificationDate] as? Date ?? .distantPast
    }

    struct Staged {
        var path: String
        var backup: String
        var old: Data
        var new: Data
    }

    /// Each sidecar's new contents, its old ones backed up, before anything is replaced.
    static func stage(_ sides: [Sidecar], _ backupDir: String) throws -> [Staged] {
        if !sides.isEmpty {
            try FileManager.default.createDirectory(atPath: backupDir, withIntermediateDirectories: true)
        }
        return try sides.map { s in
            let old = try Data(contentsOf: URL(fileURLWithPath: s.path))
            let new: Data
            do { new = try s.update(old) } catch {
                throw AutoDJError("\((s.path as NSString).lastPathComponent): \(error)")
            }
            let base = (s.path as NSString).lastPathComponent as NSString
            let ext = base.pathExtension.isEmpty ? "" : "." + base.pathExtension
            let bak = (backupDir as NSString).appendingPathComponent(
                "\(base.deletingPathExtension).before-cues.\(localStamp())\(ext)")
            try copyFile(s.path, bak)
            return Staged(path: s.path, backup: bak, old: old, new: new)
        }
    }

    /// Replaces master.db with enc, then each sidecar; if a sidecar can't be written, master.db
    /// goes back to its backup and the sidecars written so far to their old bytes.
    static func swapIn(_ enc: String, _ masterDB: String, _ bak: String, _ staged: [Staged]) throws {
        try replaceContents(enc, masterDB)
        for (i, s) in staged.enumerated() {
            do {
                try writeKeepingMode(s.path, s.new)
            } catch {
                var restoreErrors: [Error] = []
                do { try replaceContents(bak, masterDB) } catch { restoreErrors.append(error) }
                for done in staged[..<i] {
                    do { try writeKeepingMode(done.path, done.old) } catch { restoreErrors.append(error) }
                }
                if !restoreErrors.isEmpty {
                    throw AutoDJError("writing \(s.path): \(error); restoring the backups failed too: \(restoreErrors)")
                }
                throw AutoDJError("writing \(s.path): \(error) (master.db restored, nothing changed)")
            }
        }
    }

    /// Replaces path with data through a temporary file in the same folder, keeping its mode.
    static func writeKeepingMode(_ path: String, _ data: Data) throws {
        let mode = (try? FileManager.default.attributesOfItem(atPath: path))?[.posixPermissions]
        let tmp = path + ".auto-dj.tmp"
        try data.write(to: URL(fileURLWithPath: tmp))
        if let mode { try? FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: tmp) }
        if rename(tmp, path) != 0 {
            try? FileManager.default.removeItem(atPath: tmp)
            throw AutoDJError("can't replace \(path)")
        }
    }

    /// Overwrites dst with src's bytes in place (dst keeps its mode).
    static func replaceContents(_ src: String, _ dst: String) throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: src))
        let fd = open(dst, O_WRONLY | O_TRUNC)
        if fd < 0 { throw AutoDJError("can't open \(dst) for writing") }
        defer { close(fd) }
        try data.withUnsafeBytes { b in
            var done = 0
            while done < b.count {
                let n = Darwin.write(fd, b.baseAddress! + done, b.count - done)
                if n <= 0 { throw AutoDJError("writing \(dst) failed") }
                done += n
            }
        }
        if fsync(fd) != 0 { throw AutoDJError("syncing \(dst) failed") }
    }
}
