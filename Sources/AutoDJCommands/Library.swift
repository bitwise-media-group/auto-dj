// Copyright 2026 BitWise Media Group Ltd
// SPDX-License-Identifier: MIT

import ArgumentParser
import AutoDJKit
import Foundation

struct Status: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "tracks per state; is Rekordbox running?")
    @OptionGroup var g: Globals

    func run() throws {
        let p = g.paths
        let rb = try RekordboxDB.readCopy(p.masterDB)
        let (tr, cues) = try rb.sql.loadTracksAndCues()
        let auto = try Ledger.load(p.ledger)
        var c = Counter()
        for r in tr {
            c.add(Category.classify(rating: r.rating, cues: cues[r.id] ?? [], auto: auto.contains(r.id)))
        }
        let parts = c.mostCommon.map { "\($0)=\(c.n[$0]!)" }
        let n =
            ((try? FileManager.default.contentsOfDirectory(atPath: p.featureDir)) ?? [])
            .filter { $0.hasSuffix(".f32.lzfse") }.count
        print("master.db: \(p.masterDB)")
        print("tracks: \(tr.count)  \(parts.joined(separator: "  "))")
        print("Rekordbox running: \(Rekordbox.isRunning() ? "True" : "False")")
        print("feature cache: \(p.featureDir) (\(n) files)")
    }
}

struct FeaturesCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "features", abstract: "decode audio once (cached in the work dir)")
    @OptionGroup var g: Globals

    @Option(parsing: .upToNextOption, help: "track categories to decode")
    var categories = ["manual", "mik", "nohot", "auto", "other"]

    @Option(help: "parallel decodes")
    var workers = ProcessInfo.processInfo.activeProcessorCount

    func run() async throws {
        let p = g.paths
        let (tr, cues): ([TrackRow], [String: [Cue]])
        do {
            let rb = try RekordboxDB.readCopy(p.masterDB)
            (tr, cues) = try rb.sql.loadTracksAndCues()
        }
        let want = Set(categories.flatMap { $0.split(separator: ",").map { Category.alias(String($0)) } })
        let auto = try Ledger.load(p.ledger)
        var files: [String] = []
        for r in tr where !r.folderPath.isEmpty {
            let fp = Config.mapPath(r.folderPath)
            guard FileManager.default.fileExists(atPath: fp) else { continue }
            if want.contains(
                Category.classify(rating: r.rating, cues: cues[r.id] ?? [], auto: auto.contains(r.id)))
            {
                files.append(fp)
            }
        }
        let tags = try await EnergyTags.refresh(files, cache: p.energyTags)
        if tags > 0 { print("read Mixed In Key's energy tag from \(tags) file(s)") }
        let res = try await Features.extractMany(files, featureDir: p.featureDir, workers: workers)
        var n = Counter()
        for (f, r) in zip(files, res) {
            n.add(r.label)
            if case .error(let e) = r { printErr("  \((f as NSString).lastPathComponent): error: \(e)") }
        }
        let parts = n.keys.map { "\($0) \(n.n[$0]!)" }
        print("\(files.count) files: \(parts.joined(separator: ", "))")
    }
}
