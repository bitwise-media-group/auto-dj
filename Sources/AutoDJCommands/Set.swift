// Copyright 2026 BitWise Media Group Ltd
// SPDX-License-Identifier: MIT

import ArgumentParser
import AutoDJKit
import Foundation

struct SetCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set", abstract: "set-specific E/G cues + BASS SWAP for a playlist (omit it to list playlists)",
        discussion: """
            Key check, suggested order, then set-specific E / G hot cues and BASS SWAP / FILTER / CUT / SYNC
            transition markers for a playlist or intelligent playlist. Without a playlist, lists the playlists.
            """)
    @OptionGroup var g: Globals
    @Argument var playlist: String?
    @Option(help: "'suggested' or a comma-separated track-number order, e.g. 1,3,2,4") var order = ""
    @Flag(help: "let the suggested order change the first track") var freeStart = false
    @Flag(help: "with --write: also save the order to the playlist (not an intelligent playlist)") var reorder = false
    @Option(
        help: "render transition previews, the full-set mix and a set-list page into DIR/<set name> (default <work>)")
    var previewDir: String?
    @Flag(help: "skip the previews") var noPreview = false
    @Flag(help: "skip the full-set mix") var noMix = false
    @Option(help: "play the previews at this fixed tempo, key kept (0: each track at its own tempo)") var bpm = 128.0
    @Option(help: "audio format of the previews: m4a or wav") var format = "m4a"
    @Option(help: "set plan file (default <work>/set-plan.json)") var out: String?
    @Flag(help: "write the cues (Rekordbox quit)") var write = false

    func run() async throws {
        let p = g.paths
        guard let playlist else {
            let rb = try RekordboxDB.readCopy(p.masterDB)
            let pls = try rb.sql.listPlaylists()
            print("playlists:", pls.filter { !$0.intelligent }.map(\.name).joined(separator: ", "))
            let smart = pls.filter(\.intelligent).map(\.name)
            if !smart.isEmpty { print("intelligent playlists:", smart.joined(separator: ", ")) }
            return
        }
        var res: SetResult
        do {
            res = try SetRun.run(p, playlist: playlist, order: try SetOrder(order), freeStart: freeStart, log: printErr)
        } catch let e as SetError {
            printErr(e.description)
            throw ExitCode.failure
        }
        if reorder && res.intelligent {
            printErr(
                "'\(playlist)' is an intelligent playlist: Rekordbox orders it, so --reorder can't save the order. "
                    + "Drop --reorder, or copy the tracks to a normal playlist.")
            throw ExitCode.failure
        }
        print(res.report)
        let dest = out ?? (p.workDir as NSString).appendingPathComponent("set-plan.json")
        try JSONFile.write(
            SetRun.PlanFile(playlist: playlist, order: res.order.map(\.id), actions: res.actions), to: dest)
        print("\nset plan written to \(dest)")
        if !noPreview {
            let dir = (Config.expandUser(previewDir ?? p.workDir) as NSString).appendingPathComponent(
                Text.slug(playlist))
            let page = try await previewBundle(res, dir: dir, mix: !noMix, bpm: bpm, format: format, paths: p)
            print("set-list page with transition previews: \(page)")
        }
        if !write {
            print("Dry run. Re-run with --write (Rekordbox quit) to add the new cues.")
            return
        }
        print(try SetRun.write(p, &res, reorder: reorder))
    }
}

struct HistoryCmd: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "history", abstract: "list the play histories, or one history's tracks (omit it to list them)",
        discussion: """
            Lists the play histories Rekordbox imported from the CDJs' USB, oldest first, or one history's
            tracks in play order with the time Rekordbox wrote each row (the import, not the play: the
            recording command times the tracks from the audio).
            """)
    @OptionGroup var g: Globals
    @Argument var name: String?

    func run() throws {
        let rb = try RekordboxDB.readCopy(g.paths.masterDB)
        guard let name else {
            for h in try rb.sql.listHistories() {
                print("\(Text.padRight(h.name, 28)) \(h.created)  \(Text.padLeft(String(h.tracks), 3)) tracks")
            }
            return
        }
        let (h, rows) = try rb.sql.loadHistory(name)
        print("\(h.name) (created \(h.created)): \(rows.count) tracks")
        for r in rows {
            print(
                "  \(Text.padLeft(String(r.track.no), 2)). \(r.created)  \(Text.padLeft(r.track.key.isEmpty ? "?" : r.track.key, 4))  "
                    + r.track.title)
        }
    }
}
