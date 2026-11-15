// Copyright 2026 BitWise Media Group Ltd
// SPDX-License-Identifier: MIT

import AutoDJKit
import SwiftUI

/// Status counts, the Rekordbox indicator, and feature analysis with per-track progress.
struct LibraryView: View {
    @Environment(AppModel.self) private var app
    @State private var files: [String] = []
    @State private var progress: [Int: Double] = [:]
    @State private var status: [Int: Features.Status] = [:]
    @State private var task: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                RekordboxBadge()
                Spacer()
                Button("Refresh") { Task { await app.refresh() } }
            }
            if let s = app.status {
                Text("\(s.tracks) tracks").font(.title2)
                HStack(spacing: 16) {
                    ForEach(s.categories, id: \.0) { c in
                        VStack {
                            Text("\(c.1)").font(.title3.monospacedDigit()); Text(c.0).foregroundStyle(.secondary)
                        }
                    }
                }
                Text("Feature cache: \(app.paths.featureDir) (\(s.featureFiles) files)").font(.caption).foregroundStyle(
                    .secondary)
            }
            Divider()
            HStack {
                Text("Audio features").font(.headline)
                Spacer()
                if task != nil {
                    Button("Cancel") {
                        task?.cancel(); task = nil
                    }
                } else {
                    Button("Analyse features") { analyse() }
                }
            }
            if !files.isEmpty {
                let done = status.count
                ProgressView(value: Double(done), total: Double(files.count)) {
                    Text("\(done) of \(files.count) tracks")
                }
                List(files.indices, id: \.self) { i in
                    HStack {
                        Text((files[i] as NSString).lastPathComponent).lineLimit(1)
                        Spacer()
                        switch status[i] {
                        case .cached?: Text("cached").foregroundStyle(.secondary)
                        case .ok?: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        case .error(let e)?: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red).help(e)
                        case nil: ProgressView(value: progress[i] ?? 0).frame(width: 120)
                        }
                    }
                }
            }
            Spacer()
        }
        .padding()
    }

    private func analyse() {
        let p = app.paths
        task = Task {
            guard
                let paths = await app.run({ () -> [String] in
                    let rb = try RekordboxDB.readCopy(p.masterDB)
                    let (tr, _) = try rb.sql.loadTracksAndCues()
                    return tr.compactMap { r in
                        let fp = Config.mapPath(r.folderPath)
                        return !r.folderPath.isEmpty && FileManager.default.fileExists(atPath: fp) ? fp : nil
                    }
                })
            else { return task = nil }
            files = paths
            progress = [:]
            status = [:]
            let sink = ProgressSink()
            let poll = Task {
                while !Task.isCancelled {
                    let (p, s) = sink.take()
                    for (i, v) in p { progress[i] = v }
                    for (i, v) in s { status[i] = v }
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
            _ = await app.run {
                try await Features.extractMany(
                    paths, featureDir: p.featureDir, workers: ProcessInfo.processInfo.activeProcessorCount,
                    onProgress: { sink.progress($0, $1) }, onDone: { sink.done($0, $1) })
            }
            poll.cancel()
            let (pp, s) = sink.take()
            for (i, v) in pp { progress[i] = v }
            for (i, v) in s { status[i] = v }
            task = nil
            await app.refresh()
        }
    }
}

/// Collects progress from worker threads for the UI to pick up.
final class ProgressSink: @unchecked Sendable {
    private let lock = NSLock()
    private var p: [Int: Double] = [:]
    private var s: [Int: Features.Status] = [:]

    func progress(_ i: Int, _ v: Double) {
        lock.lock()
        p[i] = v
        lock.unlock()
    }

    func done(_ i: Int, _ st: Features.Status) {
        lock.lock()
        s[i] = st
        lock.unlock()
    }

    func take() -> ([Int: Double], [Int: Features.Status]) {
        lock.lock()
        defer {
            p = [:]
            s = [:]
            lock.unlock()
        }
        return (p, s)
    }
}

struct RekordboxBadge: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Label(
            app.rekordboxRunning ? "Rekordbox is running: writes are off" : "Rekordbox is not running",
            systemImage: app.rekordboxRunning ? "lock.fill" : "lock.open"
        )
        .foregroundStyle(app.rekordboxRunning ? .orange : .secondary)
    }
}

/// Choose categories, plan, review the plan per track, dry run, apply.
struct CuePlanView: View {
    @Environment(AppModel.self) private var app
    @State private var categories: Set<String> = ["mik", "nohot"]
    @State private var tracks: [Track] = []
    @State private var plan: [CuePlan.Item] = []
    @State private var selection: CuePlan.Item.ID?
    @State private var filter = ""
    @State private var sort = [KeyPathComparator(\CuePlan.Item.title)]
    @State private var dryRun: String?
    @State private var confirm = false
    @State private var busy = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                ForEach(["mik", "nohot", "auto"], id: \.self) { c in
                    Toggle(
                        c,
                        isOn: Binding(
                            get: { categories.contains(c) },
                            set: { if $0 { categories.insert(c) } else { categories.remove(c) } })
                    )
                    .toggleStyle(.checkbox)
                }
                Button("Plan") { makePlan() }.disabled(categories.isEmpty || busy)
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                TextField("Filter", text: $filter).frame(width: 180)
                Button("Dry run") { runDry() }.disabled(plan.isEmpty || busy)
                Button("Apply…") { confirm = true }.disabled(plan.isEmpty || busy || app.rekordboxRunning)
            }
            .padding(10)
            if !plan.isEmpty {
                Text(CuePlan.summary(plan).replacingOccurrences(of: "\n", with: " · ")).font(.caption).foregroundStyle(
                    .secondary
                )
                .padding(.bottom, 4)
            }
            HSplitView {
                Table(shown, selection: $selection, sortOrder: $sort) {
                    TableColumn("Title", value: \.title).width(min: 200, ideal: 300)
                    TableColumn("BPM", value: \.bpm) { Text(String(format: "%.1f", $0.bpm)) }.width(50)
                    TableColumn("IN") { Text(beat($0, "IN")) }.width(44)
                    TableColumn("BRIDGE") { Text(beat($0, "BRIDGE")) }.width(54)
                    TableColumn("DROP") { Text(beat($0, "DROP")) }.width(48)
                    TableColumn("OUT") { Text(beat($0, "OUT")) }.width(44)
                    TableColumn("EMERG.") { Text(beat($0, "EMERGENCY")) }.width(54)
                    TableColumn("Memory") { x in
                        Text(x.mem.map { "\($0.name) \($0.beat)" }.joined(separator: ", ")).lineLimit(1)
                    }
                    TableColumn("Flags") { x in Text(x.flags.joined(separator: ", ")).foregroundStyle(.orange) }
                }
                .onChange(of: sort) { _, s in plan.sort(using: s) }
                .frame(minWidth: 600)
                CueDetail(item: plan.first { $0.id == selection }, track: tracks.first { $0.id == selection })
                    .frame(minWidth: 320)
            }
            if let dryRun {
                Text(dryRun).font(.caption.monospaced()).textSelection(.enabled).padding(8).frame(
                    maxWidth: .infinity, alignment: .leading)
            }
        }
        .confirmationDialog("Write \(plan.count) tracks' cues to Rekordbox?", isPresented: $confirm) {
            Button("Apply") { apply() }
        } message: {
            Text("master.db is backed up to _cue_work first. Rated tracks and hot cues E/F/G are never touched.")
        }
    }

    var shown: [CuePlan.Item] {
        filter.isEmpty ? plan : plan.filter { $0.title.localizedCaseInsensitiveContains(filter) }
    }

    func beat(_ x: CuePlan.Item, _ n: String) -> String { x.hot.first { $0.name == n }.map { String($0.beat) } ?? "–" }

    func makePlan() {
        busy = true
        let p = app.paths
        let cats = Array(categories)
        Task {
            if let (ts, pl) = await app.run({ () -> ([Track], [CuePlan.Item]) in
                let ts = try Track.build(p, cats)
                let pl = CuePlan.make(ts, cats, .default)
                try CuePlan.save(pl, to: (p.workDir as NSString).appendingPathComponent("plan.json"))
                return (ts, pl)
            }) {
                (tracks, plan) = (ts, pl.sorted(using: sort))
            }
            busy = false
        }
    }

    func runDry() {
        busy = true
        let p = app.paths
        let rows = CuePlan.toDB(plan)
        Task {
            dryRun = await app.run {
                let auto = try Ledger.load(p.ledger)
                return "DRY RUN (nothing written): "
                    + (try SafeWrite.dryRun(p.masterDB) { try CueWriter.applyPlan($0, rows, autoIDs: auto) })
                    .description
            }
            busy = false
        }
    }

    func apply() {
        guard app.canWrite() else { return }
        busy = true
        let p = app.paths
        let pl = plan
        Task {
            dryRun = await app.run {
                let auto = try Ledger.load(p.ledger)
                let st = try SafeWrite.write(p.masterDB, backupDir: p.backupDir) {
                    try CueWriter.applyPlan($0, CuePlan.toDB(pl), autoIDs: auto)
                }
                let skipped = Set(st.list("skipped"))
                try Ledger.add(p.ledger, pl.filter { !skipped.contains($0.title) }.map(\.id))
                return st.description
            }
            busy = false
            await app.refresh()
        }
    }
}

/// One track's planned cues on its energy strip (bass and mids), with the phrases.
struct CueDetail: View {
    let item: CuePlan.Item?
    let track: Track?

    var body: some View {
        if let item, let track {
            VStack(alignment: .leading, spacing: 8) {
                Text(item.title).font(.headline)
                let nb = max(track.beats.count, 1)
                let lo = track.hasFB ? Track.normLevel(track.col(0)) : []
                let md = track.hasFB ? Track.normLevel(track.col(2)) : []
                Canvas { ctx, size in
                    let x = { (b: Int) in CGFloat(b - 1) / CGFloat(nb) * size.width }
                    let h = size.height
                    for (i, v) in lo.enumerated() {
                        let r = CGRect(
                            x: x(i + 1), y: h * 0.5 * (1 - CGFloat(min(v, 1))), width: max(size.width / CGFloat(nb), 1),
                            height: h * 0.5 * CGFloat(min(v, 1)))
                        ctx.fill(Path(r), with: .color(.blue.opacity(0.5)))
                    }
                    for (i, v) in md.enumerated() {
                        let r = CGRect(
                            x: x(i + 1), y: h * 0.5, width: max(size.width / CGFloat(nb), 1),
                            height: h * 0.5 * CGFloat(min(v, 1)))
                        ctx.fill(Path(r), with: .color(.teal.opacity(0.4)))
                    }
                    for p in track.phrases {
                        var l = Path()
                        l.move(to: CGPoint(x: x(p.beat), y: 0))
                        l.addLine(to: CGPoint(x: x(p.beat), y: h))
                        ctx.stroke(l, with: .color(.secondary.opacity(0.4)), lineWidth: 0.5)
                    }
                    for c in item.hot {
                        var l = Path()
                        l.move(to: CGPoint(x: x(c.beat), y: 0))
                        l.addLine(to: CGPoint(x: x(c.beat), y: h))
                        ctx.stroke(l, with: .color(.red), lineWidth: 1.5)
                        ctx.draw(
                            Text(c.name).font(.caption2).foregroundStyle(.red), at: CGPoint(x: x(c.beat) + 2, y: 2),
                            anchor: .topLeading)
                    }
                    for c in item.mem {
                        ctx.fill(
                            Path(ellipseIn: CGRect(x: x(c.beat) - 3, y: h - 8, width: 6, height: 6)),
                            with: .color(.orange))
                    }
                }
                .frame(height: 140)
                .background(.quaternary.opacity(0.3))
                Grid(alignment: .leading) {
                    ForEach(item.hot, id: \.self) { c in
                        GridRow {
                            Text("\(c.slot) \(c.name)"); Text("beat \(c.beat)");
                            Text(SetRun.minSec(Double(c.ms) / 1000))
                        }
                    }
                    ForEach(item.mem, id: \.self) { c in
                        GridRow {
                            Text("MEM \(c.name)"); Text("beat \(c.beat)"); Text(SetRun.minSec(Double(c.ms) / 1000))
                        }
                    }
                }
                .font(.callout.monospacedDigit())
                Spacer()
            }
            .padding(10)
        } else {
            Text("Select a track").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// The ADR 0003 accuracy tables against your rated tracks.
struct EvaluateView: View {
    @Environment(AppModel.self) private var app
    @State private var report: Evaluate.Report?
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("How well the rules match your hand-cued tracks").font(.headline)
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button("Evaluate") { run() }.disabled(busy)
            }
            if let r = report {
                Grid(alignment: .trailing, horizontalSpacing: 18, verticalSpacing: 6) {
                    GridRow {
                        Text("cue").gridColumnAlignment(.leading); Text("n"); Text("exact"); Text("≤16"); Text("≤32");
                        Text("none")
                    }
                    .font(.caption.bold())
                    ForEach(Evaluate.names, id: \.name) { n in
                        let c = r.cues[n.name] ?? Evaluate.CueScore()
                        GridRow {
                            Text(n.name); Text("\(c.n)"); Text("\(c.exact)"); Text("\(c.within16)");
                            Text("\(c.within32)"); Text("\(c.missing)")
                        }
                        .monospacedDigit()
                    }
                }
                Text("Memory DROP: hit \(r.dropHit), missed \(r.dropMissed), extra \(r.dropExtra)")
                Text("BASS SWAP: n \(r.bassSwapN), exact \(r.bassSwapExact), ≤16 \(r.bassSwapWithin16)")
                if !r.rows.isEmpty {
                    Table(r.rows.enumerated().map { IndexedRow(id: $0, row: $1) }) {
                        TableColumn("Track") { Text($0.row.title) }
                        TableColumn("Cues (yours / the rules')") {
                            Text($0.row.cells.joined(separator: "  ")).monospaced()
                        }
                    }
                }
            }
            Spacer()
        }
        .padding()
    }

    func run() {
        busy = true
        let p = app.paths
        Task {
            report = await app.run { Evaluate.score(try Track.build(p, ["manual"]), .default, verbose: true) }
            busy = false
        }
    }
}

/// A table row with a stable identity (titles can repeat).
struct IndexedRow: Identifiable {
    let id: Int
    let row: Evaluate.Row
}
