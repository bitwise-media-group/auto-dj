// Copyright 2026 BitWise Media Group Ltd
// SPDX-License-Identifier: MIT

import Foundation

/// Splits a set recording by its play history (port of internal/cli/recording.go, ADR 0016,
/// ADR 0017): align the history's tracks with the recording, review alignment.json, export one
/// tagged .m4a per track with a cue sheet and tracklist, and with write save the transitions
/// played to the transition cache and create a playlist from the tracks.
public enum Recording {
    /// A history and what the recording workflow needs from the library.
    public struct Session: Sendable {
        public var history: History
        public var rows: [HistoryTrack]
        public var tags: [String: Tags]
        public var recs: [String: Track]

        /// The default output folder: <work>/recordings/<history>.
        public func defaultOut(_ paths: Paths) -> String {
            ((paths.workDir as NSString).appendingPathComponent("recordings") as NSString)
                .appendingPathComponent(Text.slug(history.name))
        }
    }

    /// Loads the history, its tracks' tags and every analysed track.
    public static func load(_ paths: Paths, history name: String, log: (String) -> Void = { _ in }) throws -> Session {
        let rb = try RekordboxDB.readCopy(paths.masterDB)
        let (h, rows) = try rb.sql.loadHistory(name)
        let tags = try rb.sql.loadTags(rows.map(\.track.id))
        let all = try Track.build(paths, ["manual", "auto", "mik", "nohot", "other"], log: log)
        return Session(
            history: h, rows: rows, tags: tags,
            recs: Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }))
    }

    /// The existing alignment.json, or a fresh alignment of the history against the recording
    /// (written to path). A realignment keeps the cuts edited by hand.
    public static func alignment(
        _ paths: Paths, _ s: Session, recording wav: String, path: String, realign: Bool,
        progress: @Sendable (String) -> Void = { _ in }
    ) async throws -> AlignmentFile {
        let old = try AlignmentFile.load(path)
        if let old, !realign {
            if old.recording != wav {
                throw AutoDJError("\(path) aligns \(old.recording), not \(wav): pass --realign or another --out")
            }
            progress("reusing \(path) (--realign to align again)")
            return old
        }
        let audio = try MixExport.probe(wav)
        progress("decoding the recording (\(MixAlign.formatTime(Double(audio.samples) / Double(audio.sampleRate))))")
        let recF = try Features.recordingFrames(featureDir: paths.featureDir, path: wav)
        func local(_ id: String) -> String? {
            let fp = Config.mapPath(s.tags[id]?.folderPath ?? "")
            return !fp.isEmpty && FileManager.default.fileExists(atPath: fp) ? fp : nil
        }
        let files = s.rows.compactMap { local($0.track.id) }
        progress("decoding \(files.count) tracks (cached in \(paths.featureDir))")
        _ = try await Features.extractMany(files, featureDir: paths.featureDir, workers: 4)
        var inputs: [MixAlign.Input] = []
        for r in s.rows {
            var frames: Features.Frames?
            if let fp = local(r.track.id) {
                do {
                    frames = try Features.frames(featureDir: paths.featureDir, audioPath: fp)
                } catch {
                    progress("  \(r.track.title): \(error)")
                }
            }
            inputs.append(
                MixAlign.Input(
                    no: r.track.no, id: r.track.id, title: r.track.title, rec: s.recs[r.track.id], frames: frames))
        }
        progress("aligning \(inputs.count) tracks")
        var f = AlignmentFile(
            history: s.history.name, date: s.history.date, recording: wav, sampleRate: audio.sampleRate,
            channels: audio.channels, samples: audio.samples,
            tracks: MixAlign.align(
                recF, inputs, sampleRate: audio.sampleRate, samples: audio.samples, progress: progress))
        if let old {
            let n = f.keepEdits(from: old)
            if n > 0 { progress("kept \(n) hand-edited cut(s) from the earlier alignment") }
        }
        try f.save(path)
        return f
    }

    /// The per-track table: cut, status, confidence, title, notes.
    public static func report(_ f: AlignmentFile) -> String {
        var b = "\(f.history): \(f.tracks.count) tracks, recording \(f.duration)\n\n"
        b += "  \(Text.padLeft("no", 3))  \(Text.padRight("cut", 12))  \(Text.padRight("status", 14))  "
        b += "\(Text.padLeft("conf", 5))  title\n"
        for e in f.tracks {
            var cut = e.cut.isEmpty ? "-" : e.cut
            if !e.cut.isEmpty && e.edited(sampleRate: f.sampleRate) { cut += "*" }
            b += "  \(Text.padLeft(String(e.no), 3))  \(Text.padRight(cut, 12))  \(Text.padRight(e.status, 14))  "
            b += "\(Text.padLeft(String(format: "%.2f", e.confidence), 5))  \(e.title)\n"
            for n in e.notes { b += "  \(Text.padLeft("", 3))  \(Text.padRight("", 12))  ! \(n)\n" }
        }
        b += "\n(* = cut edited by hand)\n"
        return b
    }

    /// What an export writes.
    public struct ExportOptions: Sendable {
        public var dj: String
        public var art: String
        /// Album name ("" for the history's).
        public var album = ""
        /// Release date ("" for the history's).
        public var date = ""
        /// Keep the silence before the first track and after the last one.
        public var noTrim = false

        public init(dj: String, art: String) {
            self.dj = dj
            self.art = art
        }
    }

    /// Plans the files and, unless only planning, trims the silence, encodes them and writes the
    /// cue sheet and tracklist. Returns the tracks and the sheets written.
    public static func export(
        _ f: AlignmentFile, _ s: Session, recording wav: String, out: String, _ o: ExportOptions?,
        progress: @Sendable (String) -> Void = { _ in }
    ) async throws -> ([MixExport.ExportTrack], [String]) {
        var ts: [MixExport.ExportTrack]
        do {
            ts = try MixExport.plan(f, tags: s.tags, outDir: out)
        } catch {
            throw AutoDJError("alignment.json: \(error)")
        }
        guard let o else { return (ts, []) }
        if !o.noTrim { try MixExport.trimSilence(f, &ts, recording: wav) }
        if !FileManager.default.fileExists(atPath: o.art) { throw AutoDJError("--art: no such file: \(o.art)") }
        let opt = MixExport.Options(
            recording: wav, outDir: out, album: o.album.isEmpty ? s.history.name : o.album, dj: o.dj,
            date: o.date.isEmpty ? s.history.date : o.date, art: o.art)
        progress("encoding \(ts.count) tracks (Apple AAC, 256 kb/s) into \(out)")
        let total = ts.count
        try await MixExport.export(f, ts, opt) { progress("encoded \($0) of \(total)") }
        return (ts, try MixExport.writeSheets(f, ts, opt))
    }

    /// Creates the playlist from the exported tracks (master.db through SafeWrite, with
    /// masterPlaylists6.xml, and the cue template on its tracks missing it) and saves the
    /// transitions played to the transition cache.
    public static func write(
        _ paths: Paths, _ s: Session, _ ts: [MixExport.ExportTrack], playlist: String, folder: String
    ) throws -> Stats {
        let stats = try PlaylistWriter.safeWrite(
            paths, name: playlist, folder: folder, contentIDs: ts.map(\.entry.id), recs: s.recs)
        var cache = try TransitionCache.load(paths.transitions)
        var n = 0
        for i in ts.indices.dropFirst() {
            let a = ts[i - 1]
            let b = ts[i]
            guard let tr = b.entry.transition, tr.fromID == a.entry.id, a.entry.status == MixAlign.ok,
                b.entry.status == MixAlign.ok, let ra = s.recs[a.entry.id], let rb = s.recs[b.entry.id]
            else { continue }
            func ms(_ t: Track, _ beat: Int) -> Int { Num.round(t.beats[min(max(beat, 1), t.beats.count) - 1] * 1000) }
            cache.record(
                outID: a.entry.id, outTitle: a.tags.title, inID: b.entry.id, inTitle: b.tags.title,
                source: "recording:" + s.history.name, gMS: ms(ra, tr.g), eMS: ms(rb, tr.e),
                bassSwapMS: ms(rb, tr.bassSwap))
            n += 1
        }
        try cache.save(paths.transitions)
        stats.set("transitions_recorded", .int(n))
        stats.set("transition_cache", .string(paths.transitions))
        return stats
    }
}
