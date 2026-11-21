// Copyright 2026 BitWise Media Group Ltd
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import AutoDJKit

/// Playlists, intelligent playlists, histories, tags and playlist creation on small plain
/// databases holding the Rekordbox tables they read (ported from internal/db).
@Suite struct SmartListTests {
    static let schema = """
        create table djmdContent (ID varchar(255) primary key, Title varchar(255), ArtistID varchar(255),
          AlbumID varchar(255), GenreID varchar(255), BPM integer, Length integer, Commnt text, Rating integer,
          ReleaseYear integer, RemixerID varchar(255), LabelID varchar(255), OrgArtistID varchar(255), KeyID varchar(255),
          StockDate varchar(255), ColorID varchar(255), DJPlayCount integer, FileNameL varchar(255),
          ComposerID varchar(255), Subtitle varchar(255), ReleaseDate varchar(255), DateCreated varchar(255),
          rb_local_deleted integer, created_at datetime);
        create table djmdArtist (ID varchar(255) primary key, Name varchar(255));
        create table djmdAlbum (ID varchar(255) primary key, Name varchar(255), AlbumArtistID varchar(255));
        create table djmdGenre (ID varchar(255) primary key, Name varchar(255));
        create table djmdLabel (ID varchar(255) primary key, Name varchar(255));
        create table djmdKey (ID varchar(255) primary key, ScaleName varchar(255));
        create table djmdSongMyTag (ID varchar(255) primary key, MyTagID varchar(255), ContentID varchar(255),
          rb_local_deleted integer);
        create table djmdPlaylist (ID varchar(255) primary key, Seq integer, Name varchar(255), Attribute integer,
          SmartList text, rb_local_deleted integer);
        create table djmdSongPlaylist (ID varchar(255) primary key, PlaylistID varchar(255), ContentID varchar(255),
          TrackNo integer, rb_local_deleted integer);
        insert into djmdArtist values ('a1', 'Bicep'), ('a2', 'Fred again..'), ('a3', 'Ben_Böhmer');
        insert into djmdAlbum values ('al1', 'Isles', 'a1');
        insert into djmdGenre values ('g1', 'Deep House'), ('g2', 'Techno');
        insert into djmdLabel values ('l1', 'Ninja Tune');
        insert into djmdKey values ('k1', 'Am'), ('k2', 'Fm');
        insert into djmdContent values
          ('1', 'Glue', 'a1', 'al1', 'g1', 12200, 269, '8A - Energy 6', 0, 2017, null, 'l1', null, 'k1',
           '2026-09-03', '0', 0, 'Glue.aiff', null, 'Original', '2017-08-01', '2026-08-31', 0, '2026-09-03 10:00:00'),
          ('2', 'Delilah', 'a2', null, 'g1', 12800, 251, null, 3, 2022, 'a3', null, null, 'k2',
           '2026-10-20', '5', 4, 'Delilah.aiff', null, 'Extended', '', '2026-10-19', 0, '2026-10-20 10:00:00'),
          ('3', 'Beyond Beliefs', 'a3', null, 'g2', 12450, 412, '4A', 5, 2023, null, null, 'a1', null,
           '2026-10-30', null, 12, 'Beyond.mp3', 'a2', null, null, null, 0, '2026-10-30 10:00:00'),
          ('4', 'Deleted', 'a1', null, 'g1', 12800, 300, null, 0, 2026, null, null, null, 'k1',
           '2026-10-31', '0', 0, 'Gone.aiff', null, null, null, null, 1, '2026-10-31 10:00:00');
        insert into djmdSongMyTag values ('t1', '2589317697', '2', 0), ('t2', '1470147897', '3', 0),
          ('t3', '1470147897', '1', 1);
        insert into djmdPlaylist values
          ('f1', 1, 'Sets', 1, null, 0),
          ('p1', 2, 'Melodic Dark', 0, null, 0),
          ('p5', 6, 'Old', 0, null, 1);
        insert into djmdSongPlaylist values ('s1', 'p1', '3', 2, 0), ('s2', 'p1', '1', 1, 0), ('s3', 'p1', '2', 3, 1);
        """

    static func node(_ logic: String, _ conds: String...) -> String {
        "<NODE Id=\"1\" LogicalOperator=\"\(logic)\" AutomaticUpdate=\"0\">\(conds.joined())</NODE>"
    }

    static func cond(_ prop: String, _ op: String, _ unit: String, _ left: String, _ right: String) -> String {
        "<CONDITION PropertyName=\"\(prop)\" Operator=\"\(op)\" ValueUnit=\"\(unit)\" ValueLeft=\"\(left)\" "
            + "ValueRight=\"\(right)\"/>"
    }

    static let today: Date = {
        var c = DateComponents()
        (c.year, c.month, c.day) = (2026, 11, 1)
        return Calendar(identifier: .gregorian).date(from: c)!
    }()

    func library() throws -> SQLite {
        let d = try SQLite(path: try tempDir() + "/m.db")
        try d.execScript(Self.schema)
        for (id, name, src) in [
            ("p2", "Never Played", Self.node("1", Self.cond("counter", "1", "", "", ""))),
            ("p3", "Played", Self.node("1", Self.cond("counter", "2", "", "", ""))),
            ("p4", "Broken", Self.node("1", Self.cond("vibe", "1", "", "x", ""))),
        ] {
            try d.exec("insert into djmdPlaylist values (?, ?, ?, 4, ?, 0)", id, Int(id.dropFirst())!, name, src)
        }
        return d
    }

    func matches(_ d: SQLite, _ src: String) throws -> [String] {
        let (w, args) = try SmartList.whereClause(src, today: Self.today)
        return try d.query(
            "select c.ID from djmdContent c where c.rb_local_deleted=0 and (\(w)) order by c.ID", args: args
        ).map { $0.string(0) }
    }

    @Test func smartWhere() throws {
        let d = try library()
        let n = Self.node
        let c = Self.cond
        let cases: [(String, String, [String])] = [
            ("never played", n("1", c("counter", "1", "", "", "")), ["1"]),
            ("played", n("1", c("counter", "2", "", "", "")), ["2", "3"]),
            ("unrated", n("1", c("rating", "1", "", "", "")), ["1"]),
            ("rated 3+", n("1", c("rating", "3", "", "2", "")), ["2", "3"]),
            ("after 2019", n("1", c("year", "3", "", "2019", "")), ["2", "3"]),
            ("bpm range", n("1", c("bpm", "5", "", "122", "125")), ["1", "3"]),
            ("bpm decimal", n("1", c("bpm", "1", "", "124.5", "")), ["3"]),
            ("bpm under", n("1", c("bpm", "4", "", "128", "")), ["1", "3"]),
            ("duration", n("1", c("duration", "3", "", "300", "")), ["3"]),
            ("artist is, any case", n("1", c("artist", "1", "", "BICEP", "")), ["1"]),
            ("artist is not", n("1", c("artist", "2", "", "bicep", "")), ["2", "3"]),
            ("artist contains literal _", n("1", c("artist", "8", "", "n_b", "")), ["3"]),
            ("artist contains no wildcard", n("1", c("artist", "8", "", "e_", "")), []),
            ("genre contains", n("1", c("genre", "8", "", "house", "")), ["1", "2"]),
            ("genre does not contain", n("1", c("genre", "9", "", "house", "")), ["3"]),
            ("name starts with", n("1", c("name", "10", "", "de", "")), ["2"]),
            ("file ends with", n("1", c("fileName", "11", "", ".AIFF", "")), ["1", "2"]),
            ("comments empty", n("1", c("comments", "1", "", "", "")), ["2"]),
            ("key", n("1", c("key", "1", "", "Am", "")), ["1"]),
            ("album artist", n("1", c("albumArtist", "1", "", "Bicep", "")), ["1"]),
            ("album", n("1", c("album", "8", "", "isl", "")), ["1"]),
            ("label", n("1", c("label", "1", "", "ninja tune", "")), ["1"]),
            ("remixer", n("1", c("remixedBy", "1", "", "Ben_Böhmer", "")), ["2"]),
            ("original artist", n("1", c("originalArtist", "1", "", "Bicep", "")), ["3"]),
            ("producer", n("1", c("producer", "8", "", "fred", "")), ["3"]),
            ("mix name", n("1", c("mixName", "1", "", "extended", "")), ["2"]),
            ("colour", n("1", c("grouping", "1", "", "5", "")), ["2"]),
            ("no colour", n("1", c("grouping", "1", "", "", "")), ["1", "3"]),
            ("my tag", n("1", c("myTag", "8", "", "1470147897", "")), ["3"]),
            ("my tag, signed", n("1", c("myTag", "1", "", "-1705649599", "")), ["2"]),
            ("not my tag", n("1", c("myTag", "9", "", "1470147897", "")), ["1", "2"]),
            ("added on", n("1", c("stockDate", "1", "", "2026-10-20", "")), ["2"]),
            ("added after", n("1", c("stockDate", "3", "", "2026-10-01", "")), ["2", "3"]),
            ("added in range", n("1", c("stockDate", "5", "", "2026-09-01", "2026-10-20")), ["1", "2"]),
            ("added in last 14 days", n("1", c("stockDate", "6", "1", "14", "")), ["2", "3"]),
            ("added in last month", n("1", c("stockDate", "6", "2", "1", "")), ["2", "3"]),
            ("not added in last 5 days", n("1", c("stockDate", "7", "day", "5", "")), ["1", "2"]),
            ("released before", n("1", c("dateReleased", "4", "", "2020-01-01", "")), ["1"]),
            ("no release date", n("1", c("dateReleased", "1", "", "", "")), ["2", "3"]),
            ("created", n("1", c("dateCreated", "3", "", "2026-09-01", "")), ["2"]),
            ("all", n("1", c("genre", "8", "", "house", ""), c("rating", "3", "", "0", "")), ["2"]),
            ("any", n("2", c("genre", "1", "", "techno", ""), c("rating", "1", "", "0", "")), ["1", "3"]),
        ]
        for (name, src, want) in cases { #expect(try matches(d, src) == want, "\(name)") }
    }

    @Test func smartWhereRefuses() {
        let n = Self.node
        let c = Self.cond
        for src in [
            "not xml", n("3", c("rating", "1", "", "", "")), n("1"), n("1", c("vibe", "1", "", "x", "")),
            n("1", c("rating", "8", "", "3", "")), n("1", c("artist", "3", "", "a", "")),
            n("1", c("bpm", "1", "", "fast", "")), n("1", c("bpm", "5", "", "120", "fast")),
            n("1", c("stockDate", "1", "", "1/9/2026", "")), n("1", c("stockDate", "5", "", "2026-09-01", "")),
            n("1", c("stockDate", "6", "3", "2", "")), n("1", c("myTag", "8", "", "Techno", "")),
            n("1", c("grouping", "8", "", "5", "")),
        ] {
            #expect(throws: (any Error).self, "\(src)") { try SmartList.whereClause(src, today: Self.today) }
        }
    }

    @Test func loadPlaylist() throws {
        let d = try library()
        var pl = try d.loadPlaylist("Melodic Dark", today: Self.today)
        #expect(
            !pl.intelligent
                && pl.tracks == [
                    PlaylistTrack(no: 1, id: "1", title: "Glue", bpm: 122, key: "Am"),
                    PlaylistTrack(no: 2, id: "3", title: "Beyond Beliefs", bpm: 124.5, key: ""),
                ])
        pl = try d.loadPlaylist("Played", today: Self.today)
        #expect(
            pl.intelligent
                && pl.tracks == [
                    PlaylistTrack(no: 1, id: "2", title: "Delilah", bpm: 128, key: "Fm"),
                    PlaylistTrack(no: 2, id: "3", title: "Beyond Beliefs", bpm: 124.5, key: ""),
                ])
        for (name, msg) in [
            ("Sets", "is a folder"), ("Old", "no playlist called"), ("Missing", "no playlist called"),
            ("Broken", "intelligent playlist 'Broken': condition vibe 1"),
        ] {
            do {
                _ = try d.loadPlaylist(name, today: Self.today)
                Issue.record("\(name) loaded")
            } catch {
                #expect("\(error)".contains(msg), "\(name): \(error)")
            }
        }
    }

    @Test func listPlaylists() throws {
        let got = try library().listPlaylists().map { "\($0.name):\($0.intelligent)" }
        #expect(got == ["Melodic Dark:false", "Never Played:true", "Played:true", "Broken:true"])
    }
}

@Suite struct HistoryTests {
    static let schema = """
        create table djmdContent (ID varchar(255) primary key, Title varchar(255), ArtistID varchar(255),
          AlbumID varchar(255), GenreID varchar(255), BPM integer, Commnt varchar(255), ReleaseYear integer,
          RemixerID varchar(255), LabelID varchar(255), OrgArtistID varchar(255), KeyID varchar(255),
          ComposerID varchar(255), FolderPath varchar(255), rb_local_deleted integer default 0);
        create table djmdArtist (ID varchar(255) primary key, Name varchar(255));
        create table djmdAlbum (ID varchar(255) primary key, Name varchar(255), AlbumArtistID varchar(255));
        create table djmdGenre (ID varchar(255) primary key, Name varchar(255));
        create table djmdLabel (ID varchar(255) primary key, Name varchar(255));
        create table djmdKey (ID varchar(255) primary key, ScaleName varchar(255));
        create table djmdHistory (ID varchar(255) primary key, Seq integer, Name varchar(255), Attribute integer,
          ParentID varchar(255), DateCreated varchar(255), rb_local_deleted integer default 0);
        create table djmdSongHistory (ID varchar(255) primary key, HistoryID varchar(255), ContentID varchar(255),
          TrackNo integer, rb_local_deleted integer default 0, created_at datetime);
        create table djmdPlaylist (ID varchar(255) primary key, Seq integer, Name varchar(255), ImagePath varchar(255),
          Attribute integer, ParentID varchar(255), SmartList text, UUID varchar(255), rb_data_status integer default 0,
          rb_local_data_status integer default 0, rb_local_deleted tinyint(1) default 0, rb_local_synced tinyint(1) default 0,
          usn bigint, rb_local_usn bigint, created_at datetime not null, updated_at datetime not null);
        create table djmdSongPlaylist (ID varchar(255) primary key, PlaylistID varchar(255), ContentID varchar(255),
          TrackNo integer, UUID varchar(255), rb_data_status integer default 0, rb_local_data_status integer default 0,
          rb_local_deleted tinyint(1) default 0, rb_local_synced tinyint(1) default 0, usn bigint, rb_local_usn bigint,
          created_at datetime not null, updated_at datetime not null);
        insert into djmdArtist values ('a1', 'Oxia'), ('a2', 'Giorgio Moroder'), ('a3', 'DJ Deavon');
        insert into djmdAlbum values ('al1', 'Domino', 'a3');
        insert into djmdGenre values ('g1', 'Techno');
        insert into djmdLabel values ('l1', 'Kompakt');
        insert into djmdKey values ('k1', 'Am');
        insert into djmdContent (ID, Title, ArtistID, AlbumID, GenreID, BPM, Commnt, ReleaseYear, LabelID, KeyID, ComposerID,
          FolderPath) values
          ('10', 'Domino (Original Mix)', 'a1', 'al1', 'g1', 12800, '8A', 2003, 'l1', 'k1', 'a2', '/m/domino.aiff'),
          ('11', 'Second', 'a1', null, null, 12600, null, null, null, null, null, '/m/second.aiff'),
          ('12', 'Third', null, null, null, 12400, null, null, null, null, null, '/m/third.aiff');
        insert into djmdHistory values ('2026', 1, '2026', 1, 'root', '2026-11-01 22:21:19', 0),
          ('h1', 1, 'HISTORY 2026-11-07', 0, '2026', '2026-11-07 19:58:27', 0),
          ('h0', 2, 'HISTORY 2026-11-01', 0, '2026', '2026-11-01 22:21:19', 0);
        insert into djmdSongHistory values ('s1', 'h1', '12', 2, 0, '2026-11-07 19:58:27.406 +00:00'),
          ('s2', 'h1', '10', 1, 0, '2026-11-07 19:58:27.406 +00:00'),
          ('s3', 'h1', '12', 3, 0, '2026-11-07 19:58:27.407 +00:00'),
          ('s4', 'h1', '11', 4, 1, '2026-11-07 19:58:27.407 +00:00');
        insert into djmdPlaylist (ID, Seq, Name, Attribute, ParentID, created_at, updated_at) values
          ('200000', 1, 'Dark Mode', 0, 'root', 'x', 'x'), ('300', 2, 'Gigs', 1, 'root', 'x', 'x'),
          ('301', 1, 'Old Gig', 0, '300', 'x', 'x');
        """

    static let xmlDoc =
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\r\n\r\n<MASTER_PLAYLIST Version=\"3.0.0\" AutomaticSync=\"0\">\r\n"
        + "  <PRODUCT Name=\"rekordbox\" Version=\"7.2.19\" Company=\"Pioneer DJ\"/>\r\n  <PLAYLISTS>\r\n"
        + "    <NODE Id=\"30D40\" ParentId=\"0\" Attribute=\"0\" Timestamp=\"0\" Lib_Type=\"0\" CheckType=\"0\"/>\r\n"
        + "  </PLAYLISTS>\r\n</MASTER_PLAYLIST>\r\n"

    func db(_ dir: String? = nil) throws -> SQLite {
        let d = try SQLite(path: (dir ?? (try tempDir())) + "/master.db")
        try d.execScript(Self.schema)
        return d
    }

    @Test func histories() throws {
        let d = try db()
        let hs = try d.listHistories()
        #expect(hs.count == 2 && hs[0].name == "HISTORY 2026-11-01" && hs[1].tracks == 3)
        let (h, rows) = try d.loadHistory("HISTORY 2026-11-07")
        #expect(rows.map(\.track.id) == ["10", "12", "12"])
        #expect(
            rows[0].track.bpm == 128 && rows[0].track.key == "Am" && !rows[0].created.isEmpty && h.date == "2026-11-07")
        #expect(throws: AutoDJError.self) { try d.loadHistory("2026") }  // a history folder
    }

    @Test func loadTags() throws {
        let tags = try db().loadTags(["10", "11", "99"])
        var want = Tags()
        (want.id, want.title, want.artist, want.composer, want.album, want.albumArtist) =
            ("10", "Domino (Original Mix)", "Oxia", "Giorgio Moroder", "Domino", "DJ Deavon")
        (want.genre, want.label, want.key, want.year, want.bpm, want.comment, want.folderPath) =
            ("Techno", "Kompakt", "Am", 2003, 128, "8A", "/m/domino.aiff")
        #expect(tags.count == 2 && tags["10"] == want && tags["11"]?.artist == "Oxia" && tags["11"]?.genre == "")
    }

    @Test func libraryTracks() throws {
        let dir = try tempDir()
        let d = try db(dir)
        let (a, b) = (dir + "/domino.aiff", dir + "/second.aiff")
        for f in [a, b] { FileManager.default.createFile(atPath: f, contents: Data()) }
        try d.exec("update djmdContent set FolderPath = ? where ID = '10'", a)
        try d.exec("update djmdContent set FolderPath = ? where ID = '11'", b)
        let fd = dir + "/features"
        try FileManager.default.createDirectory(atPath: fd, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: Features.cachePath(featureDir: fd, audioPath: a), contents: Data())
        FileManager.default.createFile(atPath: Vocals.cachePath(featureDir: fd, audioPath: a), contents: Data())
        // features without the vocal analysis: still needs analysing
        FileManager.default.createFile(atPath: Features.cachePath(featureDir: fd, audioPath: b), contents: Data())
        let ts = Dictionary(uniqueKeysWithValues: try Library.tracks(d, featureDir: fd).map { ($0.id, $0) })
        let x = ts["10"]!
        #expect(
            (x.title, x.artist, x.genre, x.key, x.year, x.bpm) == (
                "Domino (Original Mix)", "Oxia", "Techno", "Am", 2003, 128
            ))
        #expect(x.analysis == .analysed && ts["11"]?.analysis == .missing && ts["12"]?.analysis == .noAudio)
        #expect(ts["11"]?.year == 0 && ts["12"]?.artist == "")
        #expect([LibraryTrack.Analysis.analysed, .noAudio, .missing].sorted() == [.missing, .noAudio, .analysed])
    }

    @Test func createPlaylist() throws {
        let d = try db()
        let (p, sub) = try d.transaction {
            (
                try PlaylistWriter.create(d, name: "HISTORY 2026-11-07", folder: "", contentIDs: ["10", "12", "12"]),
                try PlaylistWriter.create(d, name: "In Gigs", folder: "Gigs", contentIDs: ["11"])
            )
        }
        let r = try #require(
            try d.queryRow("select Seq, Attribute, ParentID, UUID, created_at from djmdPlaylist where ID=?", p.id))
        #expect(r.int(0) == 3 && r.int(1) == 0 && r.string(2) == "root" && r.string(3).count == 36)
        #expect(r.string(4).hasSuffix(" +00:00"))
        #expect(try d.queryRow("select Seq from djmdPlaylist where ID=?", sub.id)?.int(0) == 2 && sub.parentID == "300")
        #expect(try d.loadPlaylist("HISTORY 2026-11-07").tracks.map(\.id) == ["10", "12", "12"])
        #expect(
            try d.queryRow("select ID from djmdSongPlaylist where PlaylistID=? and TrackNo=1", p.id)?.string(0).count
                == 36)
    }

    @Test func createPlaylistRefuses() throws {
        let d = try db()
        for (name, folder, ids) in [
            ("Dark Mode", "", ["10"]), ("Gigs", "", ["10"]), ("New", "", ["99"]), ("New", "Nope", ["10"]),
        ] {
            #expect(throws: AutoDJError.self, "\(name)") {
                try PlaylistWriter.create(d, name: name, folder: folder, contentIDs: ids)
            }
        }
    }

    @Test func addPlaylistNode() throws {
        let p = NewPlaylist(
            id: "3885415173", parentID: "root", name: "", created: Date(timeIntervalSince1970: 1_793_572_897.663),
            tracks: 0)
        let got = String(decoding: try PlaylistWriter.addNode(Data(Self.xmlDoc.utf8), p), as: UTF8.self)
        let node =
            "    <NODE Id=\"E796BB05\" ParentId=\"0\" Attribute=\"0\" Timestamp=\"1793572897663\" Lib_Type=\"0\" "
            + "CheckType=\"0\"/>\r\n  </PLAYLISTS>"
        #expect(
            got.contains(node)
                && got.utf8.count == Self.xmlDoc.utf8.count + node.utf8.count - "  </PLAYLISTS>".utf8.count)
        #expect(throws: AutoDJError.self) { try PlaylistWriter.addNode(Data(got.utf8), p) }  // a duplicate Id
        let sub = try PlaylistWriter.addNode(
            Data(Self.xmlDoc.utf8), NewPlaylist(id: "2", parentID: "300", name: "", created: Date(), tracks: 0))
        #expect(String(decoding: sub, as: UTF8.self).contains("<NODE Id=\"2\" ParentId=\"12C\""))
        #expect(throws: AutoDJError.self) { try PlaylistWriter.addNode(Data("<MASTER_PLAYLIST/>".utf8), p) }
    }

    /// The playlist and its masterPlaylists6.xml node are written together.
    @Test func writePlaylistXML() throws {
        let dir = try tempDir()
        let d = try db(dir)
        let xml = dir + "/" + PlaylistWriter.playlistXML
        try Data(Self.xmlDoc.utf8).write(to: URL(fileURLWithPath: xml))
        let st = try PlaylistWriter.write(
            masterDB: dir + "/master.db", backupDir: dir + "/bak", name: "Gig", folder: "", contentIDs: ["10", "11"]
        ) { fn, sides in
            let st = try d.transaction { try fn(d) }
            for s in try SafeWrite.stage(sides, dir + "/bak") { try SafeWrite.writeKeepingMode(s.path, s.new) }
            return st
        }
        guard case .string(let id) = st.values["playlist_id"] else {
            Issue.record("no playlist id")
            return
        }
        let doc = try String(contentsOfFile: xml, encoding: .utf8)
        #expect(doc.contains("<NODE Id=\"\(try PlaylistWriter.xmlID(id))\""))
    }
}
