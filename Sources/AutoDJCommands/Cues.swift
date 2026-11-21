// Copyright 2026 BitWise Media Group Ltd
// SPDX-License-Identifier: MIT

import ArgumentParser
import AutoDJKit
import Foundation

struct EvaluateCmd: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "evaluate", abstract: "score the rules against your rated tracks")
    @OptionGroup var g: Globals
    @Flag(name: .shortAndLong, help: "show each track's cues (yours / the rules')") var verbose = false

    func run() throws {
        let ts = try Track.build(g.paths, ["manual"], log: printErr)
        print(Evaluate.format(Evaluate.score(ts, .default, verbose: verbose)))
    }
}

struct PlanCmd: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "plan", abstract: "plan cues for MIK / CUE(Auto) / no-hot-cue tracks")
    @OptionGroup var g: Globals
    @Option(
        parsing: .upToNextOption,
        help: "mik (Energy N / CUE(Auto) cues) | nohot (no hot cues) | auto (re-cue tracks this tool cued before)")
    var categories = ["mik", "nohot"]
    @Option(help: "plan file (default <work>/plan.json)") var out: String?

    func run() throws {
        let p = g.paths
        let cs = splitList(categories).map(Category.alias)
        let ts = try Track.build(p, cs, log: printErr)
        let pl = CuePlan.make(ts, cs, .default)
        let dest = out ?? (p.workDir as NSString).appendingPathComponent("plan.json")
        try CuePlan.save(pl, to: dest)
        print(CuePlan.summary(pl))
        print("plan written to \(dest)")
    }
}

struct ReviewCmd: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "review", abstract: "render the HTML review page for the current plan")
    @OptionGroup var g: Globals
    @Option(help: "plan file (default <work>/plan.json)") var plan: String?
    @Option(help: "page (default <work>/review.html)") var out: String?

    func run() throws {
        let p = g.paths
        let pl = try CuePlan.load(plan ?? (p.workDir as NSString).appendingPathComponent("plan.json"))
        let ts = try Track.build(p, allCategories, log: printErr)
        let page = try Review.render(ts, pl, to: out ?? (p.workDir as NSString).appendingPathComponent("review.html"))
        print("review page: \(page)")
    }
}

struct ApplyCmd: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "apply", abstract: "apply the plan: dry run, or --write with Rekordbox quit")
    @OptionGroup var g: Globals
    @Option(help: "plan file (default <work>/plan.json)") var plan: String?
    @Option(parsing: .upToNextOption, help: "limit to titles containing any of these strings") var only: [String] = []
    @Flag(help: "actually write (default is a dry run)") var write = false

    func run() throws {
        let p = g.paths
        var pl = try CuePlan.load(plan ?? (p.workDir as NSString).appendingPathComponent("plan.json"))
        if !only.isEmpty {
            pl = pl.filter { x in only.contains { x.title.lowercased().contains($0.lowercased()) } }
        }
        print("\(pl.count) tracks in plan")
        let auto = try Ledger.load(p.ledger)
        let rows = CuePlan.toDB(pl)
        let fn: ApplyFunc = { db in try CueWriter.applyPlan(db, rows, autoIDs: auto) }
        if !write {
            print("DRY RUN (nothing written):", try SafeWrite.dryRun(p.masterDB, fn))
            print("Re-run with --write once Rekordbox is quit.")
            return
        }
        let stats = try SafeWrite.write(p.masterDB, backupDir: p.backupDir, fn)
        let skipped = Set(stats.list("skipped"))
        try Ledger.add(p.ledger, pl.filter { !skipped.contains($0.title) }.map(\.id))
        print(stats)
    }
}

/// Splits comma-separated list values ("mik,nohot" as well as "mik nohot").
func splitList(_ v: [String]) -> [String] {
    v.flatMap { $0.split(separator: ",").map(String.init) }
}
