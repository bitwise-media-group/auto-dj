// Copyright 2026 BitWise Media Group Ltd
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import AutoDJKit

/// Reading cues off a USB device's analysis files and comparing them with the collection
/// (`usb-check`, ADR 0024).
@Suite struct USBCheckTests {
    typealias C = USBDevice.Cue

    static func be32(_ v: Int) -> [UInt8] { [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: v >> $0) } }
    static func be16(_ v: Int) -> [UInt8] { [8, 0].map { UInt8(truncatingIfNeeded: v >> $0) } }
    static func utf16(_ s: String) -> [UInt8] { (s.utf16 + [0]).flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] } }

    /// A .EXT as Rekordbox writes it: PMAI header, PPTH, then a PCO2 list per kind (hot, memory).
    static func ext(path: String, cues: [C]) -> [UInt8] {
        func tag(_ type: String, _ lenHeader: Int, _ body: [UInt8]) -> [UInt8] {
            Array(type.utf8) + be32(lenHeader) + be32(12 + body.count) + body
        }
        func pcp2(_ c: C) -> [UInt8] {
            let hot = c.slot.isEmpty ? 0 : Int(c.slot.unicodeScalars.first!.value) - 64
            let name = utf16(c.name)
            var e = [UInt8](repeating: 0, count: 44 + name.count + 4)
            e.replaceSubrange(0..<4, with: Array("PCP2".utf8))
            e.replaceSubrange(4..<8, with: be32(16))
            e.replaceSubrange(8..<12, with: be32(e.count))
            e.replaceSubrange(12..<16, with: be32(hot))
            e[16] = 1
            e.replaceSubrange(20..<24, with: be32(c.ms))
            e.replaceSubrange(40..<44, with: be32(name.count))
            e.replaceSubrange(44..<44 + name.count, with: name)
            return e
        }
        let p = utf16(path)
        var tags = tag("PPTH", 16, be32(p.count) + p)
        for hot in [true, false] {
            let list = cues.filter { $0.slot.isEmpty != hot }
            tags += tag("PCO2", 20, be32(hot ? 1 : 0) + be16(list.count) + [0, 0] + list.flatMap(pcp2))
        }
        return Array("PMAI".utf8) + be32(28) + be32(28 + tags.count) + [UInt8](repeating: 0, count: 16) + tags
    }

    @Test func readsPathAndCuesFromAnEXT() throws {
        let cues = [
            C(slot: "A", ms: 29779, name: "IN"), C(slot: "G", ms: 327_453, name: "PANTERAS"),
            C(slot: "", ms: 11, name: "START"), C(slot: "", ms: 29779, name: "BASS SWAP IN"),
        ]
        let (path, got) = try USBDevice.parse(Self.ext(path: "/Contents/Astre/Loleatta (Original M.aiff", cues: cues))
        #expect(path == "/Contents/Astre/Loleatta (Original M.aiff")
        #expect(got == cues)
        #expect(throws: (any Error).self) { try USBDevice.parse(Array("JUNK".utf8)) }
    }

    @Test func differences() {
        let lib = [
            C(slot: "A", ms: 1000, name: "IN"), C(slot: "E", ms: 500, name: "LOLEATTA"),
            C(slot: "G", ms: 9000, name: "PANTERAS"), C(slot: "D", ms: 8000, name: "OUT"),
            // three memory cues on one beat: the device keeps one
            C(slot: "", ms: 2000, name: "BASS SWAP IN"), C(slot: "", ms: 2001, name: "DROP"),
            C(slot: "", ms: 2000, name: "BASS SWAP"), C(slot: "", ms: 5000, name: "BASS SWAP OUT"),
        ]
        var dev = lib.filter { $0.name != "DROP" && $0.name != "BASS SWAP" }
        #expect(USBDevice.differences(device: dev, library: lib).isEmpty)
        dev = [
            C(slot: "A", ms: 1003, name: "IN"),  // within 5 ms
            C(slot: "D", ms: 7000, name: "OUT"), C(slot: "G", ms: 9000, name: "OLD SET"),
            C(slot: "H", ms: 9500, name: "EMERGENCY"),
            C(slot: "", ms: 2000, name: "DROP"), C(slot: "", ms: 4000, name: "BASS SWAP OUT"),
        ]
        #expect(
            USBDevice.differences(device: dev, library: lib) == [
                "D: OUT at 0:07 on the device, 0:08 in Rekordbox",
                "E: missing on the device (LOLEATTA @ 0:00)",
                "G: OLD SET on the device, PANTERAS in Rekordbox",
                "H: only on the device (EMERGENCY @ 0:09)",
                "memory cues missing on the device: BASS SWAP OUT",
                "memory cues only on the device: BASS SWAP OUT",
            ])
        #expect(
            USBDevice.differences(device: [], library: [C(slot: "F", ms: 0, name: "")]) == [
                "F: missing on the device (unnamed @ 0:00)"
            ])
    }

    @Test func matchesShortenedFileNamesAndNamesThePlaylistsToResync() {
        func track(_ id: String, _ file: String, _ cues: [C]) -> USBDevice.Track {
            USBDevice.Track(id: id, title: "T\(id)", path: "/Users/dj/Music/" + file, cues: cues)
        }
        let g = [C(slot: "G", ms: 9000, name: "NEXT")]
        let lib = [
            track("1", "Celic - Circuit (Original Mix)_PN.aiff", g), track("2", "Tiësto - Voicemail (Remix).aiff", g),
            track("3", "Same.aiff", []), track("4", "Same (Extended).aiff", []),
        ]
        let at = Date(timeIntervalSince1970: 0)
        let exported = [
            USBDevice.Exported(
                file: "a", path: "/Contents/Celic/Circuit/Celic - Circuit (Original M.aiff", cues: g, written: at),
            // decomposed é, as an HFS+ device may store it; the device lacks G
            USBDevice.Exported(
                file: "b", path: "/Contents/Tiesto/Tie\u{0300}sto - Voicemail (Remix).aiff", cues: [], written: at),
            USBDevice.Exported(file: "c", path: "/Contents/x/Same.aiff", cues: [], written: at),  // exact name wins
            USBDevice.Exported(file: "d", path: "/Contents/x/Gone.aiff", cues: [], written: at),
        ]
        // Tiësto's name on the device is decomposed but not the same letter: it doesn't match
        let r = USBDevice.check(
            volume: "/Volumes/PRIMARY", exported: exported, library: lib,
            playlists: (["10": "Jazz Hands", "11": "Other"], ["1": ["10"], "2": ["10", "11"]]), synced: ["10"])
        #expect(r.exported == 4 && r.current == 2)
        #expect(r.unmatched == ["/Contents/Tiesto/Tie\u{0300}sto - Voicemail (Remix).aiff", "/Contents/x/Gone.aiff"])
        #expect(r.synced == ["Jazz Hands"])
        let fixed = USBDevice.Exported(
            file: "b", path: "/Contents/Tiesto/Tie\u{0308}sto - Voicemail (Remix).aiff", cues: [], written: at)
        let r2 = USBDevice.check(
            volume: "/Volumes/PRIMARY", exported: [fixed], library: lib,
            playlists: (["10": "Jazz Hands", "11": "Other"], ["2": ["10", "11"]]), synced: ["10"])
        #expect(r2.stale.map(\.title) == ["T2"] && r2.stale[0].playlists == ["Jazz Hands"])
        #expect(
            USBDevice.format(r2).last?.contains("right-click \"Jazz Hands\" in Rekordbox, Export Playlist > PRIMARY")
                == true)
    }

    @Test func syncedPlaylistsFromTheDevicesSyncFile() throws {
        let dir = try tempDir()
        try FileManager.default.createDirectory(atPath: dir + "/rekordbox", withIntermediateDirectories: true)
        try """
        <?xml version="1.0" encoding="UTF-8"?>\r
        <Sync DBID="1" AutomaticSync="1" AllPlaylists="0" IncludeCue="1" ForcedSync="0" Timestamp="0">\r
          <Playlists>\r
            <NODE Id="0" ParentId="0" Attribute="1" Lib_Type="0" Dev_ID="0" Timestamp="0" CheckType="2"/>\r
            <NODE Id="D1DDA4D9" ParentId="0" Attribute="0" Lib_Type="0" Dev_ID="1" Timestamp="1" CheckType="1"/>\r
          </Playlists>\r
        </Sync>
        """.write(toFile: dir + "/rekordbox/playlists3.sync", atomically: true, encoding: .utf8)
        #expect(USBDevice.syncedPlaylistIDs(dir) == ["3520963801"])
    }
}
