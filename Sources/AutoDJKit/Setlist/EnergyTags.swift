// Copyright 2026 BitWise Media Group Ltd
// SPDX-License-Identifier: MIT

import AVFoundation
import Foundation

/// Mixed In Key's energy level (1-10) from the `EnergyLevel` tag it writes into the audio file
/// (an ID3 TXXX frame, or an iTunes-style atom), cached by file path, size and modification time
/// so only new or re-tagged files are opened again (ADR 0021).
public enum EnergyTags {
    struct Entry: Codable, Equatable {
        var size: Int
        var mtime: Double
        var level: Int?
    }

    /// The file's size and modification time, nil when it isn't there.
    static func stamp(_ path: String) -> (size: Int, mtime: Double)? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: path),
            let size = (a[.size] as? NSNumber)?.intValue, let m = a[.modificationDate] as? Date
        else { return nil }
        return (size, m.timeIntervalSince1970)
    }

    static func loadCache(_ file: String) -> [String: Entry] {
        (try? JSONFile.read([String: Entry].self, from: file)) ?? [:]
    }

    /// The cached level of every file whose size and modification time still match.
    public static func cached(_ file: String) -> [String: Int] {
        var out: [String: Int] = [:]
        for (p, e) in loadCache(file) {
            guard let lv = e.level, let s = stamp(p), s.size == e.size, s.mtime == e.mtime else { continue }
            out[p] = lv
        }
        return out
    }

    /// Reads the tag of every file in audioPaths that is new or changed since it was cached, and
    /// saves the cache. Returns how many files were read.
    @discardableResult
    public static func refresh(_ audioPaths: [String], cache file: String) async throws -> Int {
        var cache = loadCache(file)
        var todo: [(String, Int, Double)] = []
        for p in Set(audioPaths) where !p.isEmpty {
            guard let s = stamp(p) else { continue }
            if let e = cache[p], e.size == s.size, e.mtime == s.mtime { continue }
            todo.append((p, s.size, s.mtime))
        }
        if todo.isEmpty { return 0 }
        let read = await withTaskGroup(of: (String, Int, Double, Int?).self) { g in
            var it = todo.makeIterator()
            var out: [(String, Int, Double, Int?)] = []
            func add() {
                guard let (p, size, mtime) = it.next() else { return }
                g.addTask { (p, size, mtime, await level(p)) }
            }
            for _ in 0..<8 { add() }
            for await r in g {
                out.append(r)
                add()
            }
            return out
        }
        for (p, size, mtime, lv) in read { cache[p] = Entry(size: size, mtime: mtime, level: lv) }
        try JSONFile.write(cache, to: file)
        return read.count
    }

    /// Reads the cache for the library's tracks: their audio paths from master.db.
    @discardableResult
    public static func refresh(_ paths: Paths) async throws -> Int {
        let rows: [TrackRow]
        do {
            let rb = try RekordboxDB.readCopy(paths.masterDB)
            rows = try rb.sql.loadTracksAndCues().0
        }
        return try await refresh(rows.map { Config.mapPath($0.folderPath) }, cache: paths.energyTags)
    }

    /// The `EnergyLevel` tag of the file at path (1-10), nil without one.
    public static func level(_ path: String) async -> Int? {
        let a = AVURLAsset(url: URL(fileURLWithPath: path))
        guard let formats = try? await a.load(.availableMetadataFormats) else { return nil }
        for f in formats {
            guard let items = try? await a.loadMetadata(for: f) else { continue }
            for it in items {
                let extra = (try? await it.load(.extraAttributes)) ?? [:]
                let info = extra[AVMetadataExtraAttributeKey(rawValue: "info")] as? String
                let key = it.identifier?.rawValue ?? ""
                guard info?.caseInsensitiveCompare("EnergyLevel") == .orderedSame || key.hasSuffix("/EnergyLevel")
                else { continue }
                if let s = try? await it.load(.stringValue),
                    let n = Int(s.trimmingCharacters(in: .whitespaces)), (1...10).contains(n)
                {
                    return n
                }
            }
        }
        return nil
    }
}
