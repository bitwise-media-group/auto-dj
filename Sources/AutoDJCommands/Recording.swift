// Copyright 2026 BitWise Media Group Ltd
// SPDX-License-Identifier: MIT

import AppKit
import ArgumentParser
import AutoDJKit
import Foundation

struct RecordingCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "recording", abstract: "split a set recording into tagged AAC tracks by its play history",
        discussion: """
            Lines the history's tracks up against the recording by their sound (the history gives the order,
            the audio the timing), cuts where each incoming track takes the bass over (snapped to its phrase
            start) and writes, into --out: alignment.json (review and edit it, then re-run), one .m4a per track
            (the track's tags, the set as album, the DJ as album artist, --art as cover), a cue sheet and a
            tracklist. With --write (Rekordbox quit) it also saves the transitions played to the transition
            cache and creates a playlist from the tracks, for `auto-dj set`.
            """)
    @OptionGroup var g: Globals
    @Argument(help: "the play history (auto-dj history lists them)") var history: String
    @Argument(help: "the recording (WAV, AIFF, …)") var recording: String
    @Option(help: "the DJ: album artist of every file (required to export)") var dj = ""
    @Option(help: "the set's cover, jpg or png (required to export)") var art = ""
    @Option(help: "album name (default: the history's name)") var album = ""
    @Option(help: "release date, YYYY-MM-DD (default: the history's date)") var date = ""
    @Option(help: "output folder (default <work>/recordings/<history>)") var out: String?
    @Flag(help: "align again instead of reusing alignment.json (hand-edited cuts are kept)") var realign = false
    @Flag(help: "only align and report (no audio files)") var noExport = false
    @Flag(help: "keep the silence before the first track and after the last one") var noTrim = false
    @Flag(help: "also save the transitions to the cache and create the playlist (Rekordbox quit)") var write = false
    @Option(help: "with --write: the playlist's name (default: the history's name)") var playlist = ""
    @Option(help: "with --write: put the playlist in this playlist folder") var folder = ""

    func run() async throws {
        if !noExport && (dj.isEmpty || art.isEmpty) {
            printErr("--dj and --art are required to export (or pass --no-export)")
            throw ExitCode.failure
        }
        let p = g.paths
        let wav = URL(fileURLWithPath: Config.expandUser(recording)).standardizedFileURL.path
        let s = try Recording.load(p, history: history, log: printErr)
        let outDir = out.map(Config.expandUser) ?? s.defaultOut(p)
        let alignPath = (outDir as NSString).appendingPathComponent("alignment.json")
        let f = try await Recording.alignment(p, s, recording: wav, path: alignPath, realign: realign) { print($0) }
        print(Recording.report(f), terminator: "")
        print("\nalignment: \(alignPath)")
        var opts: Recording.ExportOptions?
        if !noExport {
            var o = Recording.ExportOptions(dj: dj, art: Config.expandUser(art))
            (o.album, o.date, o.noTrim) = (album, date, noTrim)
            opts = o
        }
        let (ts, sheets) = try await Recording.export(f, s, recording: wav, out: outDir, opts) { print($0) }
        if !sheets.isEmpty { print("cue sheet and tracklist: \(sheets.joined(separator: ", "))") }
        if !write {
            print(
                "Review alignment.json, then re-run with --write (Rekordbox quit) to save the transitions and create "
                    + "the playlist.")
            return
        }
        print(try Recording.write(p, s, ts, playlist: playlist.isEmpty ? s.history.name : playlist, folder: folder))
    }
}

struct DemoCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "demo", abstract: "render the demo set, cue it, plan the set and open its preview",
        discussion: """
            Renders ten original house tracks (24-bit AIFF, free to use) and runs the whole pipeline on them
            without Rekordbox: features, cue plan, key check, suggested order, set cues and the set-list
            preview, which it then opens. The generator supplies the beat grid and phrases Rekordbox would.
            DIR defaults to <work>/demo; the tracks go in DIR/tracks unless --tracks says otherwise.
            """)
    @OptionGroup var g: Globals
    @Argument var dir: String?
    @Option(help: "where to write the AIFF files (default DIR/tracks)") var tracks: String?
    @Option(help: "play the preview at this fixed tempo, key kept (0: each track at its own tempo)") var bpm = 128.0
    @Option(help: "audio format of the preview: m4a or wav") var format = "m4a"
    @Flag(help: "don't open the preview page") var noOpen = false

    func run() async throws {
        let p = g.paths
        let d = dir.map(Config.expandUser) ?? (p.workDir as NSString).appendingPathComponent("demo")
        let td = tracks.map(Config.expandUser) ?? (d as NSString).appendingPathComponent("tracks")
        guard let fmt = ExportFormat(rawValue: format) else { throw ValidationError("--format must be m4a or wav") }
        print("rendering \(Demo.tracks.count) tracks into \(td)")
        let res = try await Demo.walkthrough(
            tracksDir: td, outDir: d, bpm: bpm, renderer: SetRenderer(cacheDir: p.renderDir), format: fmt
        ) { printErr("  " + $0) }
        print("\n$ auto-dj features\n\(res.features)\n\n$ auto-dj plan\n\(res.plan)\n")
        print("$ auto-dj set \"\(Demo.playlist)\"\n\(res.setCheck)\n")
        print("$ auto-dj set \"\(Demo.playlist)\" --order suggested\n\(res.setSuggested)\n")
        print("set-list page with transition previews: \(res.page)")
        if !noOpen { NSWorkspace.shared.open(URL(fileURLWithPath: res.page)) }
    }
}
