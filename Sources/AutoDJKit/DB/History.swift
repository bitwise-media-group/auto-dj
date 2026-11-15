// Copyright 2026 BitWise Media Group Ltd
// SPDX-License-Identifier: MIT

import Foundation

/// One play history (djmdHistory, Attribute 0; the year / month folders are left out).
/// Rekordbox names imported CDJ histories "HISTORY yyyy-mm-dd (n)".
public struct History: Sendable, Codable, Equatable {
    public var id: String
    public var name: String
    /// DateCreated, "yyyy-mm-dd hh:mm:ss" local time.
    public var created: String
    public var tracks: Int

    /// The history's day (yyyy-mm-dd), "" when unknown.
    public var date: String { created.count >= 10 ? String(created.prefix(10)) : "" }
}

/// One row of a history. `created` is when Rekordbox wrote the row (when the history was
/// imported, not when the track was played), kept for diagnostics only.
public struct HistoryTrack: Sendable, Codable, Equatable {
    public var track: PlaylistTrack
    public var created: String

    enum CodingKeys: String, CodingKey { case no, id, title, bpm, key, created }

    public init(track: PlaylistTrack, created: String) {
        self.track = track
        self.created = created
    }

    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        track = PlaylistTrack(
            no: try c.decode(Int.self, forKey: .no), id: try c.decode(String.self, forKey: .id),
            title: try c.decode(String.self, forKey: .title), bpm: try c.decode(Double.self, forKey: .bpm),
            key: try c.decode(String.self, forKey: .key))
        created = try c.decode(String.self, forKey: .created)
    }

    public func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self)
        try c.encode(track.no, forKey: .no)
        try c.encode(track.id, forKey: .id)
        try c.encode(track.title, forKey: .title)
        try c.encode(track.bpm, forKey: .bpm)
        try c.encode(track.key, forKey: .key)
        try c.encode(created, forKey: .created)
    }
}

/// A track's library metadata, as the recording export writes them.
public struct Tags: Sendable, Codable, Equatable {
    public var id = ""
    public var title = ""
    public var artist = ""
    public var composer = ""
    public var remixer = ""
    public var originalArtist = ""
    public var album = ""
    public var albumArtist = ""
    public var genre = ""
    public var label = ""
    public var key = ""
    public var year = 0
    public var bpm = 0.0
    public var comment = ""
    public var folderPath = ""

    public init() {}

    enum CodingKeys: String, CodingKey {
        case id, title, artist, composer, remixer
        case originalArtist = "original_artist"
        case album
        case albumArtist = "album_artist"
        case genre, label, key, year, bpm, comment
        case folderPath = "folder_path"
    }
}

extension SQLite {
    /// The play histories, oldest first.
    public func listHistories() throws -> [History] {
        try query(
            """
            select h.ID, h.Name, coalesce(h.DateCreated, ''),
              (select count(*) from djmdSongHistory s where s.HistoryID = h.ID and s.rb_local_deleted = 0)
              from djmdHistory h where h.rb_local_deleted = 0 and coalesce(h.Attribute, 0) = 0
              order by h.DateCreated, h.Seq
            """
        ).map { History(id: $0.string(0), name: $0.string(1), created: $0.string(2), tracks: $0.int(3)) }
    }

    /// The history and its tracks in TrackNo order (play order). A track the CDJs loaded twice
    /// appears twice.
    public func loadHistory(_ name: String) throws -> (History, [HistoryTrack]) {
        guard
            let row = try queryRow(
                """
                select ID, coalesce(DateCreated, '') from djmdHistory
                where rb_local_deleted = 0 and coalesce(Attribute, 0) = 0 and Name = ?
                """, name)
        else { throw AutoDJError("no such history: no history called '\(name)'") }
        var h = History(id: row.string(0), name: name, created: row.string(1), tracks: 0)
        let out = try query(
            """
            select sh.TrackNo, c.ID, c.Title, c.BPM, k.ScaleName, sh.created_at
            from djmdSongHistory sh join djmdContent c on c.ID = sh.ContentID
            left join djmdKey k on k.ID = c.KeyID
            where sh.HistoryID = ? and sh.rb_local_deleted = 0 order by sh.TrackNo
            """, h.id
        ).map { r in
            HistoryTrack(
                track: PlaylistTrack(
                    no: r.int(0), id: r.string(1), title: r.string(2), bpm: r.double(3) / 100,
                    key: r.string(4)),
                created: r.string(5))
        }
        h.tracks = out.count
        return (h, out)
    }

    /// The tags of the given tracks by ID (unknown IDs are left out).
    public func loadTags(_ ids: [String]) throws -> [String: Tags] {
        var out: [String: Tags] = [:]
        if ids.isEmpty { return out }
        let q =
            """
            select c.ID, c.Title, ar.Name, co.Name, re.Name, oa.Name, al.Name, aa.Name, g.Name, l.Name,
              k.ScaleName, c.ReleaseYear, c.BPM, c.Commnt, c.FolderPath
              from djmdContent c
              left join djmdArtist ar on ar.ID = c.ArtistID
              left join djmdArtist co on co.ID = c.ComposerID
              left join djmdArtist re on re.ID = c.RemixerID
              left join djmdArtist oa on oa.ID = c.OrgArtistID
              left join djmdAlbum al on al.ID = c.AlbumID
              left join djmdArtist aa on aa.ID = al.AlbumArtistID
              left join djmdGenre g on g.ID = c.GenreID
              left join djmdLabel l on l.ID = c.LabelID
              left join djmdKey k on k.ID = c.KeyID
              where c.ID in (?\(String(repeating: ",?", count: ids.count - 1)))
            """
        for r in try query(q, args: ids) {
            var t = Tags()
            t.id = r.string(0)
            t.title = r.string(1)
            t.artist = r.string(2)
            t.composer = r.string(3)
            t.remixer = r.string(4)
            t.originalArtist = r.string(5)
            t.album = r.string(6)
            t.albumArtist = r.string(7)
            t.genre = r.string(8)
            t.label = r.string(9)
            t.key = r.string(10)
            t.year = r.int(11)
            t.bpm = r.double(12) / 100
            t.comment = r.string(13)
            t.folderPath = r.string(14)
            out[t.id] = t
        }
        return out
    }
}
