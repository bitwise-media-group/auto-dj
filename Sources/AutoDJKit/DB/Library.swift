// Copyright 2026 BitWise Media Group Ltd
// SPDX-License-Identifier: MIT

import Foundation

/// One Rekordbox track as the app's library table lists it, and whether its audio features
/// are cached (what the rules, sets and recordings read).
public struct LibraryTrack: Sendable, Equatable, Identifiable {
    public enum Analysis: String, Sendable, Comparable {
        /// Its features and vocal analysis are in the cache.
        case analysed
        /// It has audio, but its features or vocal analysis aren't cached yet.
        case missing
        /// Its audio file isn't there (moved, offline, a streaming track).
        case noAudio

        public static func < (a: Self, b: Self) -> Bool { a.order < b.order }
        var order: Int { [.missing: 0, .noAudio: 1, .analysed: 2][self]! }
    }

    public var id: String
    public var title: String
    public var artist: String
    public var genre: String
    /// Rekordbox's key name ("Am", "F#"), "" when unknown.
    public var key: String
    /// 0 when unknown.
    public var year: Int
    public var bpm: Double
    /// The audio file on this machine ("" when Rekordbox has none).
    public var path: String
    public var analysis: Analysis
    /// Stars (0 unrated).
    public var rating = 0
    /// The track's energy (ADR 0021), nil when neither rated nor tagged by Mixed In Key.
    public var energy: Energy.Level?
    /// Seconds to its DROP hot cue (slot C), where a preview starts; nil without one.
    public var drop: Double?

    public init(
        id: String, title: String, artist: String = "", genre: String = "", key: String = "", year: Int = 0,
        bpm: Double = 0, path: String = "", analysis: Analysis = .missing
    ) {
        (self.id, self.title, self.artist, self.genre, self.key) = (id, title, artist, genre, key)
        (self.year, self.bpm, self.path, self.analysis) = (year, bpm, path, analysis)
    }
}

public enum Library {
    /// Every track with its tags and analysis state. Checking the cache lists featureDir once
    /// and compares file names, so it's quick even for a large library (no file is opened).
    public static func tracks(_ db: SQLite, featureDir: String, energyTags: [String: Int] = [:]) throws
        -> [LibraryTrack]
    {
        let rows = try db.query(
            """
            select c.ID, c.Title, ar.Name, g.Name, k.ScaleName, c.ReleaseYear, c.BPM, c.FolderPath,
                   coalesce(c.Rating, 0), coalesce(c.Commnt, ''),
                   (select min(q.InMsec) from djmdCue q
                     where q.ContentID = c.ID and q.Kind = 3 and q.rb_local_deleted = 0)
              from djmdContent c
              left join djmdArtist ar on ar.ID = c.ArtistID
              left join djmdGenre g on g.ID = c.GenreID
              left join djmdKey k on k.ID = c.KeyID
              where c.rb_local_deleted = 0
            """)
        let cached = self.cached(featureDir)
        return rows.map { r in
            let path = Config.mapPath(r.string(7))
            var t = LibraryTrack(
                id: r.string(0), title: r.string(1), artist: r.string(2), genre: r.string(3), key: r.string(4),
                year: r.int(5), bpm: r.double(6) / 100, path: path,
                analysis: analysis(path, cached: cached))
            t.rating = r.int(8)
            t.energy = Energy.level(rating: t.rating, tag: energyTags[path], comment: r.string(9))
            t.drop = r.optInt(10).map { Double($0) / 1000 }
            return t
        }
    }

    /// The names of the cache files (features and vocals) in featureDir.
    public static func cached(_ featureDir: String) -> Set<String> {
        Set(
            ((try? FileManager.default.contentsOfDirectory(atPath: featureDir)) ?? []).filter {
                $0.hasSuffix(Features.ext) || $0.hasSuffix(Vocals.ext)
            })
    }

    /// Whether path's features are among the cached file names.
    public static func analysis(_ path: String, cached: Set<String>) -> LibraryTrack.Analysis {
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else { return .noAudio }
        let k = Features.key(path)
        return cached.contains(k + Features.ext) && cached.contains(k + Vocals.ext) ? .analysed : .missing
    }
}
