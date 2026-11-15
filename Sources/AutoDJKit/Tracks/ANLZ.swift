// Copyright 2026 BitWise Media Group Ltd
// SPDX-License-Identifier: MIT

import Foundation

/// A Rekordbox phrase start: 1-based beat and normalised label (Intro / Up / Down / Chorus /
/// Outro).
public struct Phrase: Sendable, Equatable, Codable {
    public var beat: Int
    public var label: String

    public init(beat: Int, label: String) {
        self.beat = beat
        self.label = label
    }
}

/// Reads Rekordbox analysis files (ANLZ0000.DAT / .EXT): the beat grid (PQTZ) and the phrases
/// (PSSI) (port of internal/anlz).
///
/// Phrase analysis must be enabled in Rekordbox (Preferences > Analysis > Phrase) for PSSI to
/// exist. The tag walker is lenient: it reads the two tags it needs and skips every other one
/// unparsed, so header changes in tags we never use can't break a load.
public struct Analysis: Sendable, Equatable {
    /// Beat times (s); index i is beat i+1.
    public var beats: [Double] = []
    /// Beat-in-bar number (1..4).
    public var bnum: [Int] = []
    public var phrases: [Phrase] = []
    /// 0 without phrase analysis.
    public var mood = 0

    public init() {}

    /// PSSI's mood (1 = high, 2 = mid, 3 = low) and phrase kind to a label.
    static let moodLabels: [Int: [Int: String]] = [
        1: [1: "Intro", 2: "Up", 3: "Down", 5: "Chorus", 6: "Outro"],
        2: [
            1: "Intro", 2: "Verse1", 3: "Verse2", 4: "Verse3", 5: "Verse4", 6: "Verse5", 7: "Verse6",
            8: "Bridge", 9: "Chorus", 10: "Outro",
        ],
        3: [
            1: "Intro", 2: "Verse1", 3: "Verse1", 4: "Verse1", 5: "Verse2", 6: "Verse2", 7: "Verse2",
            8: "Bridge", 9: "Chorus", 10: "Outro",
        ],
    ]

    /// Collapses mid/low-mood labels onto the high-mood vocabulary the rules use.
    static let normalise = [
        "Verse1": "Up", "Verse2": "Up", "Verse3": "Up", "Verse4": "Up", "Verse5": "Up", "Verse6": "Up",
        "Bridge": "Down",
    ]

    /// Garbles PSSI in the files Rekordbox 6+ writes: every byte from offset 18 of the tag is
    /// XORed with mask[i % 19] + len_entries.
    static let xorMask: [UInt8] = [
        0xCB, 0xE1, 0xEE, 0xFA, 0xE5, 0xEE, 0xAD, 0xEE, 0xE9, 0xD2,
        0xE9, 0xEB, 0xE1, 0xE9, 0xF3, 0xE8, 0xE9, 0xF4, 0xE1,
    ]

    public struct FormatError: Error, CustomStringConvertible {
        public let description: String
    }

    /// A missing .DAT.
    public struct NotFound: Error {}

    /// Reads the beat grid from the .DAT and the phrases from the .EXT (if present) of
    /// djmdContent.AnalysisDataPath under shareDir.
    public static func load(shareDir: String, analysisDataPath: String) throws -> Analysis {
        let p = shareDir + analysisDataPath
        let base = (p as NSString).deletingPathExtension
        guard let dat = FileManager.default.contents(atPath: base + ".DAT") else { throw NotFound() }
        var a = Analysis()
        guard let pq = try findTag(Array(dat), "PQTZ") else {
            throw FormatError(description: "\(base).DAT: no beat grid (PQTZ): anlz: malformed analysis file")
        }
        do { try parsePQTZ(pq, &a) } catch { throw FormatError(description: "\(base).DAT: \(error)") }
        guard let ext = FileManager.default.contents(atPath: base + ".EXT") else { return a }
        do {
            if let ps = try findTag(Array(ext), "PSSI") { try parsePSSI(ps, &a) }
        } catch {
            throw FormatError(description: "\(base).EXT: \(error)")
        }
        return a
    }

    static let malformed = FormatError(description: "anlz: malformed analysis file")

    static func be32(_ d: ArraySlice<UInt8>, _ i: Int) -> Int {
        let s = d.startIndex + i
        return Int(d[s]) << 24 | Int(d[s + 1]) << 16 | Int(d[s + 2]) << 8 | Int(d[s + 3])
    }

    static func be16(_ d: ArraySlice<UInt8>, _ i: Int) -> Int {
        let s = d.startIndex + i
        return Int(d[s]) << 8 | Int(d[s + 1])
    }

    /// The first tag of the given type (header included), or nil.
    static func findTag(_ data: [UInt8], _ typ: String) throws -> ArraySlice<UInt8>? {
        let d = data[...]
        guard data.count >= 12, Array(data[0..<4]) == Array("PMAI".utf8) else { throw malformed }
        let lenHeader = be32(d, 4)
        let lenFile = min(be32(d, 8), data.count)
        let t = Array(typ.utf8)
        var i = lenHeader
        while i < lenFile {
            if i + 12 > data.count { throw malformed }
            let lenTag = be32(d, i + 8)
            if lenTag < 12 || i + lenTag > data.count { throw malformed }
            if Array(data[i..<i + 4]) == t { return data[i..<i + lenTag] }
            i += lenTag
        }
        return nil
    }

    /// 12-byte tag header, 4 unknown bytes, 0x80000, entry count, then 8-byte entries
    /// (beat-in-bar u16, tempo u16, time in ms u32).
    static func parsePQTZ(_ tag: ArraySlice<UInt8>, _ a: inout Analysis) throws {
        if tag.count < 24 { throw malformed }
        let n = be32(tag, 20)
        if 24 + 8 * n > tag.count { throw malformed }
        a.beats = (0..<n).map { Double(be32(tag, 24 + 8 * $0 + 4)) / 1000 }
        a.bnum = (0..<n).map { be16(tag, 24 + 8 * $0) }
    }

    /// 12-byte tag header, entry size (24), entry count u16 at 16, mood u16 at 18, ..., then
    /// 24-byte entries from offset 32 (index u16, beat u16, kind u16, ...).
    static func parsePSSI(_ tagIn: ArraySlice<UInt8>, _ a: inout Analysis) throws {
        var tag = Array(tagIn)[...]
        if tag.count < 32 { throw malformed }
        let nEntries = be16(tag, 16)
        let mood = be16(tag, 18)
        if mood < 1 || mood > 3 {  // garbled
            for x in 0..<(tag.count - 18) {
                tag[18 + x] ^= xorMask[x % xorMask.count] &+ UInt8(truncatingIfNeeded: nEntries)
            }
        }
        if 32 + 24 * nEntries > tag.count { throw malformed }
        a.mood = be16(tag, 18)
        a.phrases = (0..<nEntries).map { i in
            let kind = be16(tag, 32 + 24 * i + 4)
            var lab = moodLabels[a.mood]?[kind] ?? String(kind)
            if let n = normalise[lab] { lab = n }
            return Phrase(beat: be16(tag, 32 + 24 * i + 2), label: lab)
        }
    }
}
