// Copyright 2026 BitWise Media Group Ltd
// SPDX-License-Identifier: MIT

import ArgumentParser
import AutoDJKit
import Foundation

struct BuildCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "build-set", abstract: "build a set around picked tracks (key, tempo, vocals, energy arc)",
        discussion: """
            Fills a set around the picked tracks with tracks from the library (or one playlist): harmonic
            keys, tempos near the set tempo, transitions without vocal overlaps, and energy (your rating,
            else Mixed In Key's EnergyLevel tag, halved) following an arc. With --write (Rekordbox quit) it
            saves the set as a playlist; then `auto-dj set "<name>"` previews and cues it.

                auto-dj build-set --pick "Jolene" --pick "Levels" --tracks 16 --arc peak
            """)
    @OptionGroup var g: Globals
    @Option(name: .customLong("pick"), help: "a track to build around: its content ID or part of its title (repeat)")
    var picks: [String] = []
    @Option(help: "tracks in the set, picks included") var tracks = 16
    @Option(help: "energy arc: \(SetBuilder.Arc.allCases.map(\.rawValue).joined(separator: ", "))") var arc = "peak"
    @Flag(help: "keep the picks in the order given (else placed along the arc by energy)") var keepOrder = false
    @Flag(help: "the first pick opens the set") var opener = false
    @Flag(help: "the last pick closes the set") var closer = false
    @Option(help: "set tempo (default: the picks' median BPM)") var bpm: Double?
    @Option(help: "how far a track's tempo may be from the set tempo, in percent") var tempoRange = 6.0
    @Option(help: "only add tracks from this playlist (default: the whole library)") var from: String?
    @Option(help: "with --write: the playlist to create") var name: String?
    @Option(help: "with --write: the folder to create it in") var folder = ""
    @Flag(help: "save the set as a new playlist (Rekordbox quit)") var write = false

    func run() async throws {
        let p = g.paths
        guard let shape = SetBuilder.Arc(rawValue: arc) else {
            throw ValidationError("--arc must be one of \(SetBuilder.Arc.allCases.map(\.rawValue))")
        }
        if picks.isEmpty { throw ValidationError("pick at least one track with --pick") }
        if write && (name ?? "").isEmpty { throw ValidationError("--write needs --name") }
        try await EnergyTags.refresh(p)
        let (recs, cache) = try SetLibrary.loadAll(p, log: printErr)
        var o = SetBuilder.Options(picks: try picks.map { try resolve($0, recs) }, length: tracks)
        o.arc = shape
        (o.keepOrder, o.opener, o.closer, o.bpm, o.tempoRange) = (keepOrder, opener, closer, bpm, tempoRange / 100)
        if let from {
            o.pool = Set(try RekordboxDB.readCopy(p.masterDB).sql.loadPlaylist(from).tracks.map(\.id))
        }
        let res: SetBuilder.Result
        do {
            res = try SetBuilder.build(o, recs, cache)
        } catch let e as SetBuilder.BuildError {
            printErr(e.description)
            throw ExitCode.failure
        }
        print(SetBuilder.report(res).joined(separator: "\n"))
        if res.slots.count < tracks {
            print("Only \(res.slots.count) of \(tracks) tracks: the pool has too few tracks in range.")
        }
        guard write, let name else {
            print("Dry run. Re-run with --write --name \"<playlist>\" (Rekordbox quit) to save it as a playlist.")
            return
        }
        print(
            try PlaylistWriter.safeWrite(p, name: name, folder: folder, contentIDs: res.slots.map(\.id), recs: recs))
        print("Saved. Next: auto-dj set \"\(name)\"")
    }

    /// A content ID, else the one track whose title contains s (case-insensitive).
    func resolve(_ s: String, _ recs: [String: Track]) throws -> String {
        if recs[s] != nil { return s }
        let hits = recs.values.filter { $0.title.localizedCaseInsensitiveContains(s) }.sorted { $0.title < $1.title }
        if hits.count == 1 { return hits[0].id }
        if hits.isEmpty { throw ValidationError("no track matches \"\(s)\"") }
        throw ValidationError(
            "\"\(s)\" matches \(hits.count) tracks: "
                + hits.prefix(6).map { "\($0.title) (\($0.id))" }.joined(separator: ", "))
    }
}
