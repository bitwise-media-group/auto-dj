// Copyright 2026 BitWise Media Group Ltd
// SPDX-License-Identifier: MIT

import AutoDJKit
import SwiftUI

/// Every track in Rekordbox with its tags, key and whether its audio features are cached;
/// the tracks that need analysing are flagged and analysed in one go.
struct LibraryView: View {
    @Environment(AppModel.self) private var app
    @State private var filter = ""
    @State private var needsOnly = false

    var body: some View {
        let lib = app.library
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                Text("Library").font(.title2.bold())
                if let s = app.status {
                    Text("\(s.tracks) tracks").foregroundStyle(.secondary)
                    ForEach(s.categories, id: \.0) { c in
                        Text("\(c.0) \(c.1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if lib.loading { ProgressView().controlSize(.small) }
                Button("Refresh") { Task { await app.refresh() } }.disabled(lib.loading)
            }
            HStack(spacing: 10) {
                AnalysisSummary(needsOnly: $needsOnly)
                Spacer()
                TextField("Filter title, artist, genre", text: $filter)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
            }
            if lib.tracks.isEmpty {
                Group {
                    if lib.loading {
                        ProgressView("Reading the Rekordbox library…")
                    } else {
                        Text("No tracks: check the Rekordbox folder in Settings").foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                TrackTable("library", rows: rows)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task { if lib.tracks.isEmpty && !lib.loading { await app.refresh() } }
    }

    var rows: [TrackRowData] {
        let lib = app.library
        return lib.tracks.compactMap { t in
            let st = lib.status(t.id)
            if needsOnly, st == .analysed || st == .noAudio { return nil }
            if !filter.isEmpty,
                ![t.title, t.artist, t.genre].contains(where: { $0.localizedCaseInsensitiveContains(filter) })
            {
                return nil
            }
            return TrackRowData(
                id: t.id, title: t.title, artist: t.artist, year: t.year, genre: t.genre, bpm: t.bpm, key: t.key,
                status: st)
        }
    }
}

/// How many tracks are analysed, the ones that need it (click to show only those) and the
/// button that analyses them.
struct AnalysisSummary: View {
    @Environment(AppModel.self) private var app
    @Binding var needsOnly: Bool

    var body: some View {
        let lib = app.library
        let todo = lib.missing.count
        let done = lib.tracks.filter { $0.analysis == .analysed }.count
        let noAudio = lib.tracks.filter { $0.analysis == .noAudio }.count
        HStack(spacing: 10) {
            Label("\(done) analysed", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.secondary)
            if todo > 0 || lib.task != nil {
                Toggle(isOn: $needsOnly) {
                    Label("\(todo) need analysis", systemImage: "exclamationmark.triangle.fill")
                }
                .toggleStyle(.button)
                .tint(Deck.mid)
                .foregroundStyle(Deck.mid)
                .help("Show only the tracks whose features aren't cached")
            }
            if noAudio > 0 {
                Label("\(noAudio) without audio", systemImage: "speaker.slash.fill").foregroundStyle(.secondary)
                    .help("Rekordbox lists them, but their audio files aren't on this machine")
            }
            if lib.task != nil {
                ProgressView().controlSize(.small)
                Button("Cancel") { lib.cancel() }
            } else if todo > 0 {
                Button("Analyse \(todo) track\(todo == 1 ? "" : "s")") { lib.analyse(app) }
                    .buttonStyle(.borderedProminent)
                    .tint(Deck.low)
            }
        }
        .font(.callout)
        .help("Feature cache: \(app.paths.featureDir)")
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

/// The Cue plan section's state, owned by the window so it survives switching sections.
@MainActor @Observable
final class CuePlanState {
    var categories: Set<String> = ["mik", "nohot"]
    var tracks: [Track] = []
    var plan: [CuePlan.Item] = []
    var selection: String?
    var filter = ""
    var dryRun: String?
}

/// Choose categories, plan, review each track's planned cues on its waveform, dry run, apply.
struct CuePlanView: View {
    @Environment(AppModel.self) private var app
    @Bindable var state: CuePlanState
    @State private var confirm = false
    @State private var busy = false

    var body: some View {
        VSplitView {
            TrackTimelineView(title: item?.title ?? "", track: track, marks: marks)
                .frame(maxWidth: .infinity, minHeight: 160, idealHeight: 220, maxHeight: 260)
            VStack(spacing: 8) {
                toolbar
                if !state.plan.isEmpty {
                    Text(CuePlan.summary(state.plan).replacingOccurrences(of: "\n", with: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if state.plan.isEmpty {
                    ContentUnavailableView(
                        busy ? "Planning…" : "No plan yet", systemImage: "flag",
                        description: Text("Pick which tracks to cue above and press Plan."))
                } else {
                    TrackTable(
                        "plan", rows: rows, available: [.track, .artist, .tempo, .key, .cues, .memory, .flags],
                        selection: $state.selection)
                }
                if let dryRun = state.dryRun {
                    Text(dryRun).font(.caption.monospaced()).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 200, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .confirmationDialog("Write \(state.plan.count) tracks' cues to Rekordbox?", isPresented: $confirm) {
            Button("Apply") { apply() }
        } message: {
            Text("master.db is backed up to _cue_work first. Rated tracks and hot cues E/F/G are never touched.")
        }
    }

    /// The track categories a plan can cue (`Category.classify`): label and what it means.
    static let categories: [(key: String, label: String, help: String)] = [
        (
            "mik", "Only generated cues",
            "Unrated tracks whose only cues are generated: Mixed In Key's Energy N, Rekordbox's CUE(Auto), maybe a START hot cue. They're replaced."
        ),
        (
            "nohot", "No hot cues",
            "Unrated tracks without hot cues (no cues, or memory cues only). Memory cues you named yourself are kept."
        ),
        (
            "auto", "Cued by auto-dj, unrated",
            "Tracks auto-dj cued before that you haven't rated yet: planning them again replaces the cues it wrote."
        ),
    ]

    var toolbar: some View {
        HStack(spacing: 14) {
            Text("Cue tracks with").foregroundStyle(.secondary)
            ForEach(Self.categories, id: \.key) { c in
                let n = app.status?.categories.first { $0.0 == c.key }?.1 ?? 0
                Toggle(
                    isOn: Binding(
                        get: { state.categories.contains(c.key) },
                        set: { if $0 { state.categories.insert(c.key) } else { state.categories.remove(c.key) } })
                ) {
                    Text(c.label) + Text(" \(n)").foregroundStyle(.secondary).monospacedDigit()
                }
                .toggleStyle(.checkbox)
                .help(c.help)
            }
            Button("Plan") { makePlan() }
                .buttonStyle(.borderedProminent)
                .disabled(state.categories.isEmpty || busy)
            if busy { ProgressView().controlSize(.small) }
            Spacer()
            TextField("Filter title, artist", text: $state.filter).textFieldStyle(.roundedBorder)
                .frame(maxWidth: 220)
            Button("Dry run") { runDry() }.disabled(state.plan.isEmpty || busy)
            Button("Apply…") { confirm = true }.disabled(state.plan.isEmpty || busy || app.rekordboxRunning)
        }
    }

    var item: CuePlan.Item? { state.plan.first { $0.id == state.selection } }
    var track: Track? { state.tracks.first { $0.id == state.selection } }
    var marks: [CueMark] {
        guard let item, let track else { return [] }
        return CueMarks.planned(track, item)
    }

    var rows: [TrackRowData] {
        let lib = app.library
        return state.plan.compactMap { x in
            let t = lib.index[x.id].map { lib.tracks[$0] }
            if !state.filter.isEmpty,
                ![x.title, t?.artist ?? ""].contains(where: { $0.localizedCaseInsensitiveContains(state.filter) })
            {
                return nil
            }
            var r = TrackRowData(id: x.id, title: x.title, artist: t?.artist ?? "", bpm: x.bpm, key: t?.key ?? "")
            r.hot = x.hot.map(\.slot)
            r.memory = x.mem.map { Config.memoryColor[Config.norm($0.name)] }
            r.flags = x.flags
            return r
        }
    }

    func makePlan() {
        busy = true
        let p = app.paths
        let cats = Array(state.categories)
        Task {
            if let (ts, pl) = await app.run({ () -> ([Track], [CuePlan.Item]) in
                let ts = try Track.build(p, cats)
                let pl = CuePlan.make(ts, cats, .default)
                try CuePlan.save(pl, to: (p.workDir as NSString).appendingPathComponent("plan.json"))
                return (ts, pl)
            }) {
                (state.tracks, state.plan) = (ts, pl)
                if state.selection == nil || !pl.contains(where: { $0.id == state.selection }) {
                    state.selection = pl.first?.id
                }
            }
            busy = false
        }
    }

    func runDry() {
        busy = true
        let p = app.paths
        let rows = CuePlan.toDB(state.plan)
        Task {
            state.dryRun = await app.run {
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
        let pl = state.plan
        Task {
            state.dryRun = await app.run {
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
