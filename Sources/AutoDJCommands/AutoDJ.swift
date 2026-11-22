// Copyright 2026 BitWise Media Group Ltd
// SPDX-License-Identifier: MIT

import ArgumentParser
import AutoDJKit
import Foundation

/// The `auto-dj` command line. The SwiftPM `auto-dj` executable and the copy embedded in AutoDJ.app
/// (`Contents/MacOS/auto-dj`) both run it from `Sources/AutoDJCLI/AutoDJCLI.swift`.
public struct AutoDJ: AsyncParsableCommand {
    public init() {}

    public static let configuration = CommandConfiguration(
        commandName: "auto-dj",
        abstract: "Place hot cues and memory cues on Rekordbox tracks and prepare sets",
        discussion: """
            Typical run (Rekordbox may stay open until apply):
                auto-dj status
                auto-dj features            # decode audio once, cached
                auto-dj evaluate            # how well the rules match your hand-cued tracks
                auto-dj plan                # -> <work>/plan.json
                auto-dj review              # -> <work>/review.html
                auto-dj apply --write       # quit Rekordbox first; backs up master.db
                auto-dj set "Dark Mode"     # key check + set cues (E/G + BASS SWAP) for a playlist
                auto-dj build-set --pick "Jolene" --pick "Levels"   # a set around picked tracks

            After a gig (plug the USB in so Rekordbox imports the history):
                auto-dj history             # the play histories
                auto-dj recording "HISTORY 2026-11-07" REC001.WAV --dj "Name" --art cover.jpg

            See it all on a generated demo set, no Rekordbox needed:
                auto-dj demo
            """,
        subcommands: [
            Status.self, FeaturesCmd.self, EvaluateCmd.self, PlanCmd.self, ReviewCmd.self, ApplyCmd.self,
            CueSyncCmd.self, SetCmd.self, BuildCmd.self,
            HistoryCmd.self, RecordingCmd.self, DemoCmd.self,
        ]
    )
}

/// The flags every command takes.
struct Globals: ParsableArguments {
    @Option(name: .customLong("rb-dir"), help: "folder holding master.db and share/")
    var rbDir = Config.defaultRBDir

    @Option(name: .customLong("work-dir"), help: "cache + plan output folder")
    var workDir = Config.defaultWorkDir

    var paths: Paths {
        Paths(rbDir: Config.expandUser(rbDir), workDir: Config.expandUser(workDir))
    }
}

/// Counts strings, most common first, ties in first-seen order.
struct Counter {
    var keys: [String] = []
    var n: [String: Int] = [:]

    mutating func add(_ k: String) {
        if n[k] == nil { keys.append(k) }
        n[k, default: 0] += 1
    }

    var mostCommon: [String] {
        keys.enumerated().sorted { a, b in
            n[a.element]! != n[b.element]! ? n[a.element]! > n[b.element]! : a.offset < b.offset
        }.map(\.element)
    }
}

func printErr(_ s: String) {
    FileHandle.standardError.write(Data((s + "\n").utf8))
}

let allCategories = ["mik", "nohot", "manual", "auto", "other"]
