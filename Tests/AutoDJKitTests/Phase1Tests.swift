// Copyright 2026 BitWise Media Group Ltd
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import AutoDJKit

@Suite struct NumTests {
    @Test func percentileAndMean() {
        let y = (0..<257).map { sin(Double($0)) * 3.7 }  // np.sin(np.arange(257)) * 3.7
        #expect(abs(Num.percentile(y, 95) - 3.652542774941139) < 1e-12)
        #expect(abs(Num.percentile(y, 90) - 3.4981252708182433) < 1e-12)
        #expect(abs(Num.percentile(Array(y.prefix(10)), 50) - 1.023491212608004) < 1e-12)
        #expect(abs(Num.mean(y) - 0.0065082293479743905) < 1e-12)
    }

    @Test func hann() {
        for (a, b) in zip(Num.hann(5), [0, 0.5, 1, 0.5, 0]) { #expect(abs(a - b) < 1e-16) }
        let p = Num.hannPeriodic(4)
        #expect(p.count == 4 && p[0] == 0 && abs(p[2] - 1) < 1e-16)
    }

    @Test func rounding() {
        #expect(Num.round(1.5) == 2 && Num.round(2.5) == 2 && Num.round(-0.5) == 0 && Num.round(2.6) == 3)
        #expect(Num.roundTo(2.675, 2) == 2.67 && Num.roundTo(0.125, 2) == 0.12 && Num.roundTo(1.25, 1) == 1.2)
    }

    @Test func argFirst() {
        let a: [Double] = [3, 1, 1, 5, 5]
        #expect(Num.argmin(a) == 1 && Num.argmax(a) == 3 && Num.argmin([]) == -1)
        #expect(Num.minBy([4, 2, 7, 2], <) == 2)
    }
}

@Suite struct TextTests {
    @Test func slug() {
        let cases = [
            "Melodic Dark": "melodic-dark", "  Dark Mode (Live) 2026! ": "dark-mode-live-2026",
            "Café/Nuit": "café-nuit", "auto-dj demo": "auto-dj-demo", "../..": "set", "": "set",
        ]
        for (i, w) in cases { #expect(Text.slug(i) == w) }
    }

    @Test func fileName() {
        let cases = [
            "Voicemail  (Tiësto Remix)": "Voicemail (Tiësto Remix)",
            "AC/DC: Back in Black?": "AC_DC_ Back in Black_", "..hidden. ": "hidden", "": "_",
            "Tie\u{301}sto": "Tiésto", "tab\there\nnewline": "tab here newline",
            "a\"b<c>d|e*f\\g": "a_b_c_d_e_f_g",
        ]
        for (i, w) in cases { #expect(Text.fileName(i) == w, "\(i)") }
        #expect(Text.fileName(String(repeating: "é", count: 150)).utf8.count <= 200)
    }
}

@Suite struct ConfigTests {
    @Test func renameTo() {
        let cases: [(String, Bool, String)] = [
            ("Cut-Out RES", false, "CUT OUT"), ("CUT-IN DRACUL", false, "CUT IN"),
            ("cut-out", false, "CUT OUT"), ("LONG CUT-OUT RES", false, "CUT OUT"),
            ("JUMP TO DROP", false, "JUMP"), ("JUMP TO DROP", true, "JUMP"),
            ("JUMP", false, ""), ("jump", true, ""), ("JUMPER", true, ""), ("OUT", true, ""),
            ("CUT OUT", false, ""), ("Low Pass", false, "FILTER"), ("CUT-OUTRO", false, ""),
            ("CUT-OUT", true, ""), ("Filter Out Out", false, "FILTER OUT"),
            ("FILTER OUT IN", false, "FILTER IN"),
        ]
        for (n, hot, w) in cases { #expect(Config.renameTo(n, hot: hot) == w, "\(n) hot=\(hot)") }
    }

    @Test func memoryColors() {
        #expect(Config.memoryColorOrder.count == Config.memoryColor.count)
        for n in Config.memoryColorOrder { #expect(Config.memoryColor[n] != nil) }
    }

    @Test func mapPath() throws {
        let dir = try tempDir()
        let f = dir + "/contents_123/artist/album/track.aiff"
        try FileManager.default.createDirectory(
            atPath: (f as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data().write(to: URL(fileURLWithPath: f))
        let (oldCloud, oldMap) = (Config.cloudDirs, Config.pathMap)
        defer { (Config.cloudDirs, Config.pathMap) = (oldCloud, oldMap) }
        Config.cloudDirs = [dir + "/missing", dir]
        Config.pathMap = []
        #expect(Config.mapPath("/contents_123/artist/album/track.aiff") == f)
        #expect(Config.mapPath("/contents_123/artist/album/gone.aiff") == "/contents_123/artist/album/gone.aiff")
        Config.pathMap = Config.parsePathMap("/Users/me/Music=/mnt/Music;bad;/Volumes/USB=/mnt/usb")
        #expect(Config.mapPath("/Volumes/USB/a.mp3") == "/mnt/usb/a.mp3")
    }
}

/// sqlcipher-fixture.db was written by sqlcipher3 (SQLCipher 4.12, defaults) with key 'test':
/// table t(id, name) holding 300 rows 'row 0000 xxx…'.
@Suite struct SQLCipherTests {
    let db = fixture("sqlcipher-fixture.db")

    func countRows(_ path: String) throws -> (Int, String) {
        let s = try SQLite(path: path)
        #expect(try s.queryRow("pragma integrity_check")?.string(0) == "ok")
        let r = try s.queryRow("select count(*), (select name from t where id=1) from t")!
        return (r.int(0), r.string(1))
    }

    @Test func rekordboxKey() throws {
        #expect(try SQLCipher.rekordboxKey().hasPrefix("402fd"))
        #expect(try SQLCipher.b85decode("Xk~0{Zy<MXa%^NF") == Array("hello world!".utf8))
        #expect(try SQLCipher.b85decode("VPaz") == Array("abc".utf8))
    }

    @Test func decrypt() throws {
        let plain = try tempDir() + "/plain.db"
        try SQLCipher.decrypt(src: db, dst: plain, key: "test")
        let (n, first) = try countRows(plain)
        #expect(n == 300 && first == "row 0000 " + String(repeating: "x", count: 40))
    }

    @Test func wrongKey() throws {
        #expect(throws: SQLCipher.Failure.hmac(page: 1)) {
            try SQLCipher.decrypt(src: db, dst: try tempDir() + "/x.db", key: "wrong")
        }
    }

    @Test func roundTripSameIVs() throws {
        let d = try tempDir()
        try SQLCipher.decrypt(src: db, dst: d + "/plain.db", key: "test")
        try SQLCipher.encrypt(
            src: d + "/plain.db", dst: d + "/again.db", key: "test", salt: try SQLCipher.readSalt(db),
            iv: try SQLCipher.pageIVs(db))
        #expect(FileManager.default.contents(atPath: db) == FileManager.default.contents(atPath: d + "/again.db"))
    }

    @Test func roundTripFreshIVs() throws {
        let d = try tempDir()
        try SQLCipher.decrypt(src: db, dst: d + "/plain.db", key: "test")
        try SQLCipher.encrypt(src: d + "/plain.db", dst: d + "/enc.db", key: "test", salt: try SQLCipher.readSalt(db))
        let a = FileManager.default.contents(atPath: db)!
        let b = FileManager.default.contents(atPath: d + "/enc.db")!
        #expect(a != b && a.prefix(16) == b.prefix(16))
        try SQLCipher.decrypt(src: d + "/enc.db", dst: d + "/back.db", key: "test")
        #expect(try countRows(d + "/back.db").0 == 300)
    }

    @Test func rejectsWrongLayout() throws {
        let d = try tempDir()
        try SQLite(path: d + "/p.db").exec("create table x(a)")
        #expect(throws: (any Error).self) {
            try SQLCipher.encrypt(src: d + "/p.db", dst: d + "/e.db", key: "k", salt: [UInt8](repeating: 0, count: 16))
        }
    }
}

@Suite struct ANLZTests {
    struct Want: Decodable {
        let beats: [Double]
        let bnum: [Int]
        let phrases: [[Phrase0]]
        let mood: Int
        enum Phrase0: Decodable {
            case n(Int), s(String)
            init(from d: Decoder) throws {
                let c = try d.singleValueContainer()
                if let i = try? c.decode(Int.self) { self = .n(i) } else { self = .s(try c.decode(String.self)) }
            }
        }
    }

    @Test func matchesPyrekordbox() throws {
        let w = try JSONFile.read(Want.self, from: fixture("anlz/want.json"))
        let a = try Analysis.load(shareDir: fixture("anlz"), analysisDataPath: "/PIONEER/USBANLZ/fix/ANLZ0000.DAT")
        #expect(a.beats == w.beats && a.bnum == w.bnum && a.mood == w.mood)
        #expect(a.phrases.count == w.phrases.count)
        for (p, q) in zip(a.phrases, w.phrases) {
            if case .n(let b) = q[0], case .s(let l) = q[1] { #expect(p.beat == b && p.label == l) }
        }
    }

    @Test func maskedAndPlain() throws {
        let ext = Array(FileManager.default.contents(atPath: fixture("anlz/PIONEER/USBANLZ/fix/ANLZ0000.EXT"))!)
        let tag = try #require(try Analysis.findTag(ext, "PSSI"))
        var toggled = Array(tag)
        let n = toggled[17]
        for x in 0..<(toggled.count - 18) { toggled[18 + x] ^= Analysis.xorMask[x % 19] &+ n }
        var a = Analysis()
        var b = Analysis()
        try Analysis.parsePSSI(tag, &a)
        try Analysis.parsePSSI(toggled[...], &b)
        #expect(a == b && (1...3).contains(a.mood) && !a.phrases.isEmpty)
    }

    @Test func missingDAT() {
        #expect(throws: Analysis.NotFound.self) {
            try Analysis.load(shareDir: fixture("anlz"), analysisDataPath: "/nope/ANLZ0000.DAT")
        }
    }
}

@Suite struct TrackTests {
    @Test func titleStem() {
        let cases = [
            "Don't Wake Up (Original Mix)": "dont wake up", "The Lost Hawk (Original Mix)": "lost hawk",
            "Café Feat. Zoë (Remix)": "caf", "Rêverie ft. Ödön": "r verie",
            "Señorita (Extended) [Label]": "se orita", "Éfeat Song": "feat song", "Leftfield": "leftfield",
            "Lift Off feat Someone": "lift off", "Daft Funk": "daft funk", "Über ft": "ber",
            "Naïveft x": "na veft x", "Ftäler": "ft ler", "Søft Touch": "s ft touch",
            "Mädchen feat.Ünder": "m dchen", "  The   Thing  ": "thing", "Theory of X": "theory of x",
            "": "", "2ft Under": "2ft under", "Árbol_ft": "rbol ft",
        ]
        for (i, w) in cases { #expect(Track.titleStem(i) == w, "\(i)") }
    }

    @Test func normLevel() {
        let lv = Track.normLevel((1...100).map(Double.init))
        #expect(lv[99] > 1.022 && lv[99] < 1.023 && lv[0] == 0)
    }
}

@Suite struct FeatureTests {
    @Test func chunkedMatchesOneShot() throws {
        var g = SystemRandomNumberGenerator()
        let y = (0..<20000).map { i in Float(sin(Double(i) * 0.07) + 0.3 * Double.random(in: -1...1, using: &g)) }
        let whole = try Features.frameFeatures(y)
        let e = Features.Extractor()
        var i = 0
        while i < y.count {
            e.push(Array(y[i..<min(i + 777, y.count)]))
            i += 777
        }
        #expect(e.finish() == whole)
        #expect(whole.count == 1 + (y.count - Features.nfft) / Features.hop)
    }

    @Test func sineLandsInItsBand() throws {
        // a 60 Hz tone: nearly all power in column 0 (30-120 Hz)
        let y = (0..<22050).map { Float(sin(2 * Double.pi * 60 * Double($0) / Features.sr)) }
        let F = try Features.frameFeatures(y)
        let r = F.row(10)
        #expect(r[r.startIndex] > 100 * r[r.startIndex + 2])
        // unscaled rfft (numpy's): a full-scale Hann-windowed sine has band energy (N/4)^2 * 1.5
        #expect(abs(r[r.startIndex].squareRoot() - 313.5) < 5)
    }

    @Test func cacheRoundTrip() throws {
        let F = Features.Frames(data: (0..<60).map(Float.init))
        let p = try tempDir() + "/x.f32.lzfse"
        try Features.save(p, F)
        #expect(try Features.load(p) == F)
        #expect(try Features.load(p + ".missing") == nil)
    }
}
