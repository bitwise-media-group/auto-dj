// Copyright 2026 BitWise Media Group Ltd
// SPDX-License-Identifier: MIT

@preconcurrency import AVFoundation
import Foundation

/// Cuts a set recording into one tagged AAC (.m4a) file per track at the cuts the alignment
/// planned, and writes a cue sheet and a tracklist for the whole recording (port of
/// internal/mixexport, docs/decisions/0017-split-recordings-by-alignment.md).
///
/// The recording is read once and split at exact samples, so the files join back up into the
/// recording with nothing lost or doubled; each file is checked to play exactly its samples
/// (its priming and padding are trimmed by the container, which is what gapless players read).
/// Each file keeps the track's own tags (title, artist, composer, genre, label as grouping,
/// comment); the album is the set, its album artist the DJ, and every file carries the set's
/// cover.
public enum MixExport {
    /// A recording's format.
    public struct Audio: Sendable, Equatable {
        public var sampleRate: Int
        public var channels: Int
        public var samples: Int64
    }

    /// The recording's sample rate, channels and length in samples.
    public static func probe(_ path: String) throws -> Audio {
        let f = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        let a = Audio(
            sampleRate: Int(f.fileFormat.sampleRate), channels: Int(f.fileFormat.channelCount), samples: f.length)
        if a.sampleRate <= 0 || a.channels <= 0 || a.samples <= 0 {
            throw AutoDJError("\(path): can't read the audio format")
        }
        return a
    }

    /// What the export needs beyond the alignment.
    public struct Options: Sendable {
        public var recording: String
        public var outDir: String
        /// The set's name.
        public var album: String
        /// The album artist.
        public var dj: String
        /// yyyy-mm-dd (or yyyy).
        public var date: String
        /// The cover (jpg or png), "" for none.
        public var art: String
        /// Bits per second.
        public var bitrate = 256_000

        public init(recording: String, outDir: String, album: String, dj: String, date: String, art: String) {
            (self.recording, self.outDir, self.album, self.dj, self.date, self.art) =
                (recording, outDir, album, dj, date, art)
        }
    }

    /// One exported file.
    public struct ExportTrack: Sendable, Equatable {
        public var segment: AlignmentFile.Segment
        public var n: Int
        public var tags: Tags
        /// Its path.
        public var file: String

        public var start: Int64 {
            get { segment.start }
            set { segment.start = newValue }
        }
        public var end: Int64 {
            get { segment.end }
            set { segment.end = newValue }
        }
        public var entry: MixAlign.Entry { segment.entry }

        /// The track's artist, "Unknown Artist" when the library has none.
        public var artist: String { orUnknown(tags.artist, "Unknown Artist") }
        /// The track's title from the library, else the history's.
        public var title: String { orUnknown(tags.title, orUnknown(entry.title, "Unknown Title")) }
    }

    /// s with its runs of white space collapsed, or def when s is blank.
    static func orUnknown(_ s: String, _ def: String) -> String {
        let t = s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return t.isEmpty ? def : t
    }

    /// Names the files for the alignment's kept tracks (nothing is written).
    public static func plan(_ f: AlignmentFile, tags: [String: Tags], outDir: String) throws -> [ExportTrack] {
        try f.segments().enumerated().map { i, s in
            var t = ExportTrack(segment: s, n: i + 1, tags: tags[s.entry.id] ?? Tags(), file: "")
            t.file = (outDir as NSString).appendingPathComponent(
                Text.fileName(String(format: "%02d - %@ - %@", t.n, t.artist, t.title)) + ".m4a")
            return t
        }
    }

    /// The level below which the start and end of a recording count as silent (dBFS).
    public static let silence = -60.0

    /// Reads the recording's frames [from, to) in chunks, at its own rate and channels; body
    /// gets each chunk's first frame index and the chunk, and returns false to stop.
    static func read(_ path: String, from: Int64, to: Int64, _ body: (Int64, AVAudioPCMBuffer) throws -> Bool) throws {
        if to <= from { return }
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        file.framePosition = from
        let cap: AVAudioFrameCount = 1 << 16
        guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: cap) else { return }
        var pos = from
        while pos < to {
            try file.read(into: buf, frameCount: AVAudioFrameCount(min(Int64(cap), to - pos)))
            if buf.frameLength == 0 { break }
            if try !body(pos, buf) { return }
            pos += Int64(buf.frameLength)
        }
    }

    /// Moves the first track's start to where the recording's sound begins and the last
    /// track's end to where it stops (the recorder usually runs a moment before the music
    /// starts and after it ends), keeping 10 ms before the sound so the first attack is whole.
    public static func trimSilence(_ f: AlignmentFile, _ ts: inout [ExportTrack], recording: String) throws {
        guard !ts.isEmpty else { return }
        let thr = Float(pow(10, silence / 20))
        func loud(_ b: AVAudioPCMBuffer, _ i: Int) -> Bool {
            (0..<Int(b.format.channelCount)).contains { abs(b.floatChannelData![$0][i]) > thr }
        }
        var lead: Int64 = -1
        try read(recording, from: ts[0].start, to: ts[0].end) { pos, b in
            for i in 0..<Int(b.frameLength) where loud(b, i) {
                lead = pos + Int64(i)
                return false
            }
            return true
        }
        if lead >= 0 { ts[0].start = max(ts[0].start, lead - Int64(f.sampleRate) / 100) }
        var end: Int64 = -1
        let last = ts.count - 1
        try read(recording, from: ts[last].start, to: ts[last].end) { pos, b in
            for i in stride(from: Int(b.frameLength) - 1, through: 0, by: -1) where loud(b, i) {
                end = pos + Int64(i) + 1
                break
            }
            return true
        }
        if end > ts[last].start { ts[last].end = end }
    }

    /// Writes the planned files: each track's samples are read from the recording, encoded as
    /// AAC, then tagged (with the cover) by a passthrough remux; every file is checked to play
    /// exactly its samples.
    public static func export(
        _ f: AlignmentFile, _ ts: [ExportTrack], _ opt: Options, progress: (Int) -> Void = { _ in }
    ) async throws {
        try FileManager.default.createDirectory(atPath: opt.outDir, withIntermediateDirectories: true)
        let art = opt.art.isEmpty ? nil : try Data(contentsOf: URL(fileURLWithPath: opt.art))
        for (k, t) in ts.enumerated() {
            let raw = t.file + ".part.m4a"
            try? FileManager.default.removeItem(atPath: raw)
            try encode(
                opt.recording, t.start, t.end, to: raw, sampleRate: f.sampleRate, channels: f.channels,
                bitrate: opt.bitrate)
            try await tag(raw, to: t.file, items: metadata(t, of: ts.count, opt, art: art))
            try? FileManager.default.removeItem(atPath: raw)
            let got = try AVAudioFile(forReading: URL(fileURLWithPath: t.file)).length
            if got != t.end - t.start {
                throw AutoDJError(
                    "\((t.file as NSString).lastPathComponent) plays \(got) samples, want \(t.end - t.start): it won't be "
                        + "gapless")
            }
            progress(k + 1)
        }
    }

    /// Encodes frames [from, to) of the recording to AAC at path.
    static func encode(
        _ recording: String, _ from: Int64, _ to: Int64, to path: String, sampleRate: Int, channels: Int, bitrate: Int
    ) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: Double(sampleRate), AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: bitrate, AVEncoderAudioQualityKey: AVAudioQuality.max.rawValue,
        ]
        let out = try AVAudioFile(
            forWriting: URL(fileURLWithPath: path), settings: settings, commonFormat: .pcmFormatFloat32,
            interleaved: false)
        var n: Int64 = 0
        try read(recording, from: from, to: to) { _, b in
            try out.write(from: b)
            n += Int64(b.frameLength)
            return true
        }
        if n != to - from {
            throw AutoDJError("\(recording): the recording ended \(to - from - n) samples early")
        }
    }

    /// The tags of track t of n (and the cover).
    static func metadata(_ t: ExportTrack, of n: Int, _ opt: Options, art: Data?) -> [AVMetadataItem] {
        func item(_ id: AVMetadataIdentifier, _ v: (NSCopying & NSObjectProtocol)?, type: String? = nil)
            -> AVMetadataItem?
        {
            guard let v else { return nil }
            if let s = v as? String, s.isEmpty { return nil }
            let m = AVMutableMetadataItem()
            m.identifier = id
            m.value = v
            if let type { m.dataType = type }
            return m
        }
        func pair(_ a: Int, _ b: Int) -> NSData {
            // trkn / disk: reserved, index, total, reserved (big-endian 16-bit)
            let bytes: [UInt8] = [0, 0, UInt8(a >> 8), UInt8(a & 0xFF), UInt8(b >> 8), UInt8(b & 0xFF), 0, 0]
            return Data(bytes) as NSData
        }
        let g = t.tags
        let items: [AVMetadataItem?] = [
            item(.iTunesMetadataSongName, t.title as NSString),
            item(.iTunesMetadataArtist, t.artist as NSString),
            item(.iTunesMetadataComposer, g.composer as NSString),
            item(.iTunesMetadataAlbum, opt.album as NSString),
            item(.iTunesMetadataAlbumArtist, opt.dj as NSString),
            item(.iTunesMetadataUserGenre, g.genre as NSString),
            item(.iTunesMetadataReleaseDate, opt.date as NSString),
            item(.iTunesMetadataTrackNumber, pair(t.n, n), type: kCMMetadataBaseDataType_RawData as String),
            item(.iTunesMetadataDiscNumber, pair(1, 1), type: kCMMetadataBaseDataType_RawData as String),
            item(.iTunesMetadataUserComment, g.comment as NSString),
            item(.iTunesMetadataGrouping, g.label as NSString),
            art.flatMap { a in
                let png = a.starts(with: [0x89, 0x50, 0x4E, 0x47])
                return item(
                    .iTunesMetadataCoverArt, a as NSData,
                    type: (png ? kCMMetadataBaseDataType_PNG : kCMMetadataBaseDataType_JPEG) as String)
            },
        ]
        return items.compactMap { $0 }
    }

    /// Copies the audio of src into dst (passthrough: the encoded audio and its gapless info are
    /// kept) with the given tags.
    static func tag(_ src: String, to dst: String, items: [AVMetadataItem]) async throws {
        try? FileManager.default.removeItem(atPath: dst)
        let asset = AVURLAsset(url: URL(fileURLWithPath: src))
        guard let s = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw AutoDJError("can't tag \(dst)")
        }
        s.metadata = items
        s.shouldOptimizeForNetworkUse = true
        try await s.export(to: URL(fileURLWithPath: dst), as: .m4a)
    }

    // ---------------------------------------------------------------- cue sheet, tracklist

    /// Samples as a cue sheet's mm:ss:ff (75 frames a second; minutes may pass 99).
    static func cueTime(_ samples: Int64, _ sampleRate: Int) -> String {
        let fr = samples * 75 / Int64(sampleRate)
        return String(format: "%02d:%02d:%02d", fr / 75 / 60, fr / 75 % 60, fr % 75)
    }

    static func cueQuote(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "'") + "\"" }

    /// The cue sheet for the whole recording: one track per file, indexed at its cut.
    public static func cueSheet(_ f: AlignmentFile, _ ts: [ExportTrack], _ opt: Options) -> String {
        var b = ""
        if !opt.date.isEmpty { b += "REM DATE \(opt.date)\n" }
        b += "PERFORMER \(cueQuote(opt.dj))\nTITLE \(cueQuote(opt.album))\n"
        b += "FILE \(cueQuote((opt.recording as NSString).lastPathComponent)) WAVE\n"
        for t in ts {
            b += String(format: "  TRACK %02d AUDIO\n", t.n)
            b += "    TITLE \(cueQuote(t.title))\n    PERFORMER \(cueQuote(t.artist))\n"
            if !t.tags.composer.isEmpty { b += "    SONGWRITER \(cueQuote(t.tags.composer))\n" }
            b += "    INDEX 01 \(cueTime(t.start, f.sampleRate))\n"
        }
        return b
    }

    /// Samples as h:mm:ss (whole seconds, rounded down).
    static func hms(_ samples: Int64, _ sampleRate: Int) -> String {
        let s = samples / Int64(sampleRate)
        return String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
    }

    /// One line of tracklist.json.
    public struct TracklistEntry: Codable, Sendable, Equatable {
        public var n: Int
        public var start: String
        public var artist: String
        public var title: String
        public var id: String
        public var file: String
        public var status: String
        public var duration: String
    }

    /// The timestamped tracklist (text) and its JSON form.
    public static func tracklist(_ f: AlignmentFile, _ ts: [ExportTrack]) -> (String, [TracklistEntry]) {
        var b = ""
        var out: [TracklistEntry] = []
        for t in ts {
            b += "\(hms(t.start, f.sampleRate))  \(t.artist) – \(t.title)\n"
            out.append(
                TracklistEntry(
                    n: t.n, start: hms(t.start, f.sampleRate), artist: t.artist, title: t.title, id: t.entry.id,
                    file: (t.file as NSString).lastPathComponent, status: t.entry.status,
                    duration: MixAlign.formatTime(Double(t.end - t.start) / Double(f.sampleRate))))
        }
        return (b, out)
    }

    /// Writes <album>.cue, tracklist.txt and tracklist.json into the output folder; returns
    /// their paths.
    public static func writeSheets(_ f: AlignmentFile, _ ts: [ExportTrack], _ opt: Options) throws -> [String] {
        try FileManager.default.createDirectory(atPath: opt.outDir, withIntermediateDirectories: true)
        let cue = (opt.outDir as NSString).appendingPathComponent(Text.fileName(opt.album) + ".cue")
        let (txt, js) = tracklist(f, ts)
        try Data(cueSheet(f, ts, opt).utf8).write(to: URL(fileURLWithPath: cue))
        let tl = (opt.outDir as NSString).appendingPathComponent("tracklist.txt")
        try Data(txt.utf8).write(to: URL(fileURLWithPath: tl))
        let tj = (opt.outDir as NSString).appendingPathComponent("tracklist.json")
        try JSONFile.write(js, to: tj)
        return [cue, tl, tj]
    }
}
