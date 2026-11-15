// Copyright 2026 BitWise Media Group Ltd
// SPDX-License-Identifier: MIT

import Foundation

/// alignment.json: the review step between aligning and exporting (port of
/// internal/mixalign/file.go).
public struct AlignmentFile: Codable, Sendable, Equatable {
    /// The help the file carries for whoever reviews it.
    public static let editNote =
        "Review before exporting. Each track's file starts at its 'cut' (h:mm:ss.sss into the recording) and runs "
        + "to the next kept track's cut. Edit a cut to move it, clear it (\"\") to leave the track out, or give a "
        + "no-audio track a cut to put it in. Re-runs keep this file (and its edits) unless --realign is passed, "
        + "which also keeps cuts edited by hand."

    public var history: String
    public var date: String
    public var recording: String
    public var sampleRate: Int
    public var channels: Int
    public var samples: Int64
    public var duration: String
    public var note = AlignmentFile.editNote
    public var tracks: [MixAlign.Entry]

    enum CodingKeys: String, CodingKey {
        case history, date, recording, sampleRate = "sample_rate", channels, samples, duration, note, tracks
    }

    public init(
        history: String, date: String, recording: String, sampleRate: Int, channels: Int, samples: Int64,
        tracks: [MixAlign.Entry]
    ) {
        (self.history, self.date, self.recording, self.sampleRate, self.channels, self.samples, self.tracks) =
            (history, date, recording, sampleRate, channels, samples, tracks)
        duration = MixAlign.formatTime(Double(samples) / Double(sampleRate))
    }

    public static func load(_ path: String) throws -> AlignmentFile? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        return try JSONFile.read(AlignmentFile.self, from: path)
    }

    public func save(_ path: String) throws {
        var f = self
        f.note = Self.editNote
        try JSONFile.write(f, to: path)
    }

    /// Carries the cuts edited by hand in old over to this fresh alignment (matched by history
    /// position and track); returns how many.
    @discardableResult
    public mutating func keepEdits(from old: AlignmentFile) -> Int {
        var n = 0
        for (i, o) in old.tracks.enumerated()
        where i < tracks.count && tracks[i].id == o.id && o.edited(sampleRate: old.sampleRate) {
            tracks[i].cut = o.cut
            tracks[i].notes.append("cut kept from the earlier alignment (edited by hand)")
            n += 1
        }
        return n
    }

    /// One kept track's stretch of the recording, in samples [start, end).
    public struct Segment: Sendable, Equatable {
        public var entry: MixAlign.Entry
        public var start: Int64
        public var end: Int64
    }

    /// The kept tracks' stretches in order: each runs to the next one's cut, the last to the
    /// end of the recording. Cuts must increase.
    public func segments() throws -> [Segment] {
        var out: [Segment] = []
        for e in tracks where e.kept {
            let s = try e.sample(sampleRate: sampleRate)
            if s < 0 || s >= samples {
                throw AutoDJError("track \(e.no) (\(e.title)): cut \(e.cut) is outside the recording")
            }
            if let last = out.last {
                if s <= last.start {
                    throw AutoDJError(
                        "track \(e.no) (\(e.title)): cut \(e.cut) is not after track \(last.entry.no)'s (\(last.entry.cut))"
                    )
                }
                out[out.count - 1].end = s
            }
            out.append(Segment(entry: e, start: s, end: samples))
        }
        return out
    }
}

extension MixAlign.Entry {
    /// Whether the cut was changed by hand: it no longer says cut_sample (a cleared cut on a
    /// located track counts too).
    public func edited(sampleRate: Int) -> Bool {
        if cut.isEmpty { return located && cutSample > 0 }
        return cut != MixAlign.formatTime(Double(cutSample) / Double(sampleRate))
    }

    /// Where the entry's file starts: the hand-edited cut, else cut_sample.
    public func sample(sampleRate: Int) throws -> Int64 {
        if !edited(sampleRate: sampleRate) { return cutSample }
        do {
            return Int64((try MixAlign.parseTime(cut) * Double(sampleRate)).rounded())
        } catch {
            throw AutoDJError("track \(no) (\(title)): cut: \(error)")
        }
    }
}
