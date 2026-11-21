// Copyright 2026 BitWise Media Group Ltd
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import AutoDJKit

/// The safe write and the cue writers on the SQLCipher fixture (key 'test', table t(id, name)
/// holding 300 rows) and on a plain database holding the tables the writers touch.
@Suite struct WriteTests {
    func copyFixture() throws -> (String, String) {
        let dir = try tempDir()
        let master = dir + "/rekordbox/master.db"
        try FileManager.default.createDirectory(atPath: dir + "/rekordbox", withIntermediateDirectories: true)
        try SafeWrite.copyFile(fixture("sqlcipher-fixture.db"), master)
        return (master, dir + "/_cue_work")
    }

    func countT(_ master: String) throws -> Int {
        let plain = try tempDir() + "/p.db"
        try SQLCipher.decrypt(src: master, dst: plain, key: "test")
        return try SQLite(path: plain).queryRow("select count(*) from t")!.int(0)
    }

    let noGuard: (String) throws -> Void = { _ in }

    @Test func safeWrite() throws {
        let (master, backups) = try copyFixture()
        let orig = FileManager.default.contents(atPath: master)!
        let st = try SafeWrite.write(
            master, backupDir: backups,
            { db in
                try db.exec("insert into t (name) values ('new')")
                return Stats([("added", .int(1))])
            }, key: "test", guard: noGuard)
        #expect(try countT(master) == 301)
        let now = FileManager.default.contents(atPath: master)!
        #expect(now.prefix(16) == orig.prefix(16))  // the salt is kept
        guard case .string(let bak) = st.values["backup"] else {
            Issue.record("no backup")
            return
        }
        #expect(FileManager.default.contents(atPath: bak) == orig)
        #expect(st.description == "{\n \"added\": 1,\n \"backup\": \"\(bak)\"\n}")
    }

    @Test func safeWriteLeavesMasterOnFailure() throws {
        let (master, backups) = try copyFixture()
        let orig = FileManager.default.contents(atPath: master)!
        #expect(throws: AutoDJError.self) {
            try SafeWrite.write(master, backupDir: backups, { _ in Stats() }, key: "test") { _ in
                throw AutoDJError("rekordbox is running")
            }
        }
        #expect(throws: AutoDJError.self) {
            try SafeWrite.write(
                master, backupDir: backups,
                { db in
                    try db.exec("delete from t")
                    throw AutoDJError("boom")
                }, key: "test", guard: noGuard)
        }
        #expect(throws: (any Error).self) {
            try SafeWrite.write(master, backupDir: backups, { _ in Stats() }, key: "wrong", guard: noGuard)
        }
        #expect(FileManager.default.contents(atPath: master) == orig)
    }

    static let schema = """
        create table djmdContent (ID varchar(255) primary key, UUID varchar(255), Rating integer, rb_local_deleted integer);
        create table djmdCue (ID varchar(255) primary key, ContentID varchar(255), InMsec integer, InFrame integer,
          InMpegFrame integer, InMpegAbs integer, OutMsec integer, OutFrame integer, OutMpegFrame integer, OutMpegAbs integer,
          Kind integer, Color integer, ColorTableIndex integer, ActiveLoop integer, Comment varchar(255), BeatLoopSize integer,
          CueMicrosec integer, InPointSeekInfo varchar(255), OutPointSeekInfo varchar(255), ContentUUID varchar(255),
          UUID varchar(255), rb_data_status integer, rb_local_data_status integer, rb_local_deleted integer,
          rb_local_synced integer, usn bigint, rb_local_usn bigint, created_at datetime, updated_at datetime);
        create table djmdPlaylist (ID varchar(255) primary key, Name varchar(255), rb_local_deleted integer);
        create table djmdSongPlaylist (ID varchar(255) primary key, PlaylistID varchar(255), ContentID varchar(255),
          TrackNo integer, rb_local_deleted integer, updated_at datetime);
        insert into djmdContent values ('10', 'uuid-10', 0, 0), ('11', 'uuid-11', 0, 0), ('12', 'uuid-12', 3, 0);
        insert into djmdPlaylist values ('p1', 'Set', 0);
        insert into djmdSongPlaylist values ('s1', 'p1', '10', 1, 0, null), ('s2', 'p1', '11', 2, 0, null);
        """

    static func cueSQL(_ id: String, _ content: String, _ kind: Int, _ ms: Int, _ name: String, _ color: Int) -> String
    {
        "insert into djmdCue (ID, ContentID, Kind, InMsec, Comment, Color, rb_local_deleted) values "
            + "('\(id)', '\(content)', \(kind), \(ms), '\(name)', \(color), 0);"
    }

    func db(_ extra: String) throws -> SQLite {
        let d = try SQLite(path: try tempDir() + "/m.db")
        try d.execScript(Self.schema + extra)
        return d
    }

    struct Row: Equatable {
        var kind = 0, inMsec = 0, inFrame = 0, outMsec = 0, outFrame = 0, color = 0
        var comment = ""
        var cti: Int?
        var al: Int?
        var bls: Int?
        var contentUUID: String?
    }

    func cues(_ d: SQLite, _ content: String) throws -> [Row] {
        try d.query(
            """
            select Kind, InMsec, coalesce(InFrame,0), coalesce(OutMsec,0), coalesce(OutFrame,0), Color, Comment,
              ColorTableIndex, ActiveLoop, BeatLoopSize, ContentUUID from djmdCue where ContentID=? order by InMsec, Kind
            """, content
        ).map {
            Row(
                kind: $0.int(0), inMsec: $0.int(1), inFrame: $0.int(2), outMsec: $0.int(3), outFrame: $0.int(4),
                color: $0.int(5), comment: $0.string(6), cti: $0.optInt(7), al: $0.optInt(8), bls: $0.optInt(9),
                contentUUID: $0.isNull(10) ? nil : $0.string(10))
        }
    }

    @Test func applyPlan() throws {
        let c = Self.cueSQL
        let d = try db(
            c("1", "10", 1, 1000, "Energy 5", -1) + c("2", "10", 0, 64000, "DROP", 4)
                + c("3", "10", 0, 2000, "CUE(Auto)", 0)
                + c("4", "11", 1, 1000, "Energy 5", -1) + c("5", "11", 6, 9000, "ARIA", -1))  // 11: a hand-made E
        let plan = [
            PlanTrack(
                id: "10", title: "Ten",
                hot: [
                    PlanHot(kind: 1, name: "IN", ms: 15000),
                    PlanHot(kind: 9, name: "EMERGENCY", ms: 200_000, loop: 32, outMS: 215_000),
                ],
                mem: [PlanMem(name: "START", ms: 0), PlanMem(name: "DROP", ms: 64200)]),
            PlanTrack(id: "11", title: "Eleven", hot: [PlanHot(kind: 1, name: "IN", ms: 15000)], mem: []),
            PlanTrack(id: "99", title: "Gone", hot: [], mem: []),
        ]
        let st = try d.transaction { try CueWriter.applyPlan(d, plan, autoIDs: []) }
        #expect(st.int("updated") == 1 && st.int("removed") == 2 && st.int("added") == 3)
        #expect(st.list("skipped") == ["Eleven", "Gone"])
        let u = "uuid-10"
        #expect(
            try cues(d, "10") == [
                Row(kind: 0, inMsec: 0, outMsec: -1, color: 1, comment: "START", contentUUID: u),
                Row(kind: 1, inMsec: 15000, inFrame: 2250, outMsec: -1, color: -1, comment: "IN", contentUUID: u),
                Row(kind: 0, inMsec: 64000, color: 4, comment: "DROP"),  // the user's own DROP: kept, not duplicated
                Row(
                    kind: 9, inMsec: 200_000, inFrame: 30000, outMsec: 215_000, outFrame: 32250, color: 255,
                    comment: "EMERGENCY",
                    cti: 0, al: 1, bls: 2_097_153, contentUUID: u),
            ])
        #expect(try cues(d, "11").count == 2)
    }

    @Test func applyPlanRerun() throws {
        let c = Self.cueSQL
        let d = try db(
            c("1", "10", 1, 1000, "IN", -1) + c("2", "10", 6, 5000, "ARIA", -1) + c("3", "10", 0, 0, "START", 1))
        let plan = [
            PlanTrack(
                id: "10", title: "Ten", hot: [PlanHot(kind: 1, name: "IN", ms: 33000)],
                mem: [PlanMem(name: "START", ms: 0)])
        ]
        let st = try d.transaction { try CueWriter.applyPlan(d, plan, autoIDs: ["10"]) }
        #expect(st.int("updated") == 1 && st.int("removed") == 2)
        let got = try cues(d, "10")  // ARIA (the user's E) survives; IN moved; START re-added once
        #expect(got.count == 3 && got[2].comment == "IN" && got[2].inMsec == 33000 && got[1].comment == "ARIA")
    }

    @Test func applyPlanActiveLoop() throws {
        let c = Self.cueSQL
        let d = try db(
            c("1", "10", 1, 1000, "Energy 5", -1) + c("2", "10", 0, 9000, "LOOP", 0) + c("3", "11", 1, 1000, "IN", -1)
                + c("4", "11", 8, 9000, "RUN", -1) + c("5", "12", 9, 200_000, "EMERGENCY", 255)
                + "update djmdCue set ActiveLoop=1 where ID in ('2', '4', '5');"
                + "update djmdContent set Rating=0 where ID='12';")
        let em = PlanHot(kind: 9, name: "EMERGENCY", ms: 200_000, loop: 32, outMS: 215_000)
        let plan = ["10", "11", "12"].map {
            PlanTrack(id: $0, title: $0, hot: [PlanHot(kind: 1, name: "IN", ms: 15000), em], mem: [])
        }
        let st = try d.transaction { try CueWriter.applyPlan(d, plan, autoIDs: ["11", "12"]) }
        #expect(st.int("updated") == 3)
        for (id, want) in [("10", 0), ("11", 0), ("12", 1)] {
            #expect(try cues(d, id).first { $0.comment == "EMERGENCY" }?.al == want, "track \(id)")
        }
    }

    static let contentCueTable = """
        create table contentCue (ID varchar(255) primary key, ContentID varchar(255), Cues text, rb_cue_count integer,
          UUID varchar(255), rb_data_status integer default 0, rb_local_data_status integer default 0,
          rb_local_deleted tinyint(1) default 0, rb_local_synced tinyint(1) default 0, usn bigint, rb_local_usn bigint,
          created_at datetime not null, updated_at datetime not null);
        """

    @Test func contentCueFollowsTheWrite() throws {
        let c = Self.cueSQL
        let d = try db(
            Self.contentCueTable + c("1", "10", 1, 1000, "Energy 5", -1) + c("2", "10", 0, 9000, "MY SPOT", 0)
                + c("3", "11", 1, 1000, "Energy 3", -1)
                + "update djmdCue set created_at='2026-10-10 00:44:16.500 +00:00', updated_at=created_at, ContentUUID='uuid-10' where ID='2';"
                // track 10's copy still holds its generated cue; track 11 has none
                + "insert into contentCue (ID, ContentID, Cues, rb_cue_count, UUID, created_at, updated_at) values "
                + "('uuid-10', '10', '[{\"ID\":\"1\",\"Comment\":\"Energy 5\"}]', 1, 'u', 'x', 'x');")
        #expect(try ContentCue.stale(d).sorted() == ["10", "11"])
        let em = PlanHot(kind: 9, name: "EMERGENCY", ms: 200_000, loop: 32, outMS: 215_000)
        let plan = ["10", "11"].map {
            PlanTrack(id: $0, title: $0, hot: [PlanHot(kind: 1, name: "IN", ms: 15000), em], mem: [])
        }
        let st = try d.transaction { try CueWriter.applyPlan(d, plan, autoIDs: []) }
        #expect(st.int("content_cues") == 2)
        #expect(try ContentCue.stale(d).isEmpty)
        let r = try #require(try d.queryRow("select Cues, rb_cue_count, ID from contentCue where ContentID='10'"))
        let cues = try #require(try JSONSerialization.jsonObject(with: Data(r.string(0).utf8)) as? [[String: Any]])
        #expect(r.int(1) == 3 && cues.count == 3)  // MY SPOT kept, IN and EMERGENCY added
        let spot = try #require(cues.first { $0["Comment"] as? String == "MY SPOT" })
        #expect(spot["ID"] as? String == "2" && spot["Kind"] as? Int == 0 && spot["InMsec"] as? Int == 9000)
        #expect(spot["ActiveLoop"] == nil && spot["created_at"] as? String == "2026-10-10T00:44:16.500+00:00")
        let loop = try #require(cues.first { $0["Comment"] as? String == "EMERGENCY" })
        #expect(loop["ActiveLoop"] as? Int == 1 && loop["BeatLoopSize"] as? Int == (32 << 16) + 1)
        #expect(loop["OutMsec"] as? Int == 215_000 && loop["ContentUUID"] as? String == "uuid-10")
        #expect(r.string(0).hasPrefix("[{\"ID\":") && !r.string(0).contains("\": ") && !r.string(0).contains(", \""))
        // track 11 had no copy: one is added, keyed by the track's UUID
        #expect(
            try d.queryRow("select ID, rb_cue_count from contentCue where ContentID='11'").map {
                ($0.string(0), $0.int(1))
            } ?? ("", 0) == ("uuid-11", 2))
        // a second write changes nothing that's already in step
        #expect(try ContentCue.sync(d, ["10", "11"], ts: "t") == 0)
    }

    @Test func contentCueJSONText() {
        #expect(ContentCue.quote("A \"B\" \\ é/") == "\"A \\\"B\\\" \\\\ é/\"")
        #expect(ContentCue.iso("2026-11-15 21:18:32.984 +00:00") == "2026-11-15T21:18:32.984+00:00")
    }

    @Test func applySetAndReorder() throws {
        let c = Self.cueSQL
        let d = try db(
            c("1", "10", 0, 1000, "Low Pass", 7) + c("2", "10", 7, 2000, "JUMP TO DROP", -1)
                + c("3", "10", 0, 3000, "BASS SWAP", 1)
                + c("4", "10", 0, 9000, "CUT OUT", 6) + c("5", "10", 8, 4000, "OLD", -1))
        var a = SetCues(id: "10", title: "Ten")
        a.e = SetSlot(name: "START", beat: 1, status: .new)
        a.g = SetSlot(name: "ELEVEN", beat: 6, status: .replace)
        a.markers = [
            SetMarker(name: "BASS SWAP OUT", beat: 4, status: .rename),
            SetMarker(name: "FILTER OUT", beat: 8, status: .new),
        ]
        a.remove = [SetMarker(name: "CUT OUT", beat: 10, status: .existing)]
        try d.transaction {
            let st = try CueWriter.applySet(d, [a], beats: ["10": [0, 1, 2, 3, 4, 5, 6, 7, 8, 9]])
            #expect(
                st.description
                    == "{\n \"hot_cues\": 2,\n \"markers\": 1,\n \"removed\": 2,\n \"renamed\": 3,\n \"recoloured\": 1,\n \"skipped\": [],\n \"content_cues\": 0\n}"
            )
            _ = try CueWriter.reorderPlaylist(d, "Set", ["11", "10"])
            #expect(throws: AutoDJError.self) { try CueWriter.reorderPlaylist(d, "Set", ["10"]) }
        }
        #expect(
            try cues(d, "10").map(\.comment) == ["START", "FILTER", "JUMP", "BASS SWAP OUT", "ELEVEN", "FILTER OUT"])
        #expect(try d.queryRow("select ContentID from djmdSongPlaylist order by TrackNo limit 1")?.string(0) == "11")
    }
}
