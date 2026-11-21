// Copyright 2026 BitWise Media Group Ltd
// SPDX-License-Identifier: MIT

import AppKit
import AutoDJKit
import Observation
import SwiftUI

/// Splitting one gig recording by its play history: align, review and edit the cuts, export
/// tagged tracks, write the playlist and the transitions played (ADR 0016, 0017).
@MainActor @Observable
final class RecordingModel {
    let app: AppModel
    let history: History
    private(set) var session: Recording.Session?
    var recording: String?
    /// The alignment under review; edits are saved to alignment.json.
    var file: AlignmentFile?
    private(set) var busy: String?
    private(set) var log: [String] = []
    private(set) var exported: [MixExport.ExportTrack] = []
    var dj = UserDefaults.standard.string(forKey: "dj") ?? "" {
        didSet { UserDefaults.standard.set(dj, forKey: "dj") }
    }
    var art = UserDefaults.standard.string(forKey: "art") ?? "" {
        didSet { UserDefaults.standard.set(art, forKey: "art") }
    }
    var album = ""
    var date = ""
    var trim = true
    var playlistName = ""

    init(app: AppModel, history: History) {
        self.app = app
        self.history = history
        playlistName = history.name
    }

    var outDir: String? { session?.defaultOut(app.paths) }
    var alignPath: String? { outDir.map { ($0 as NSString).appendingPathComponent("alignment.json") } }

    func note(_ s: String) { log.append(s) }

    /// Loads the history and, when it was aligned before, its alignment.json.
    func load() async {
        let p = app.paths
        let name = history.name
        busy = "Loading \(name)…"
        session = await app.run { try Recording.load(p, history: name) }
        if let path = alignPath, let f = try? AlignmentFile.load(path) {
            file = f
            recording = f.recording
        }
        busy = nil
    }

    func align(realign: Bool) async {
        guard let s = session, let wav = recording, let path = alignPath else { return }
        let p = app.paths
        busy = "Aligning…"
        log = []
        let sink = LogSink()
        let poll = Task { [weak self] in
            while !Task.isCancelled {
                for l in sink.take() { self?.note(l) }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        file = await app.run {
            try await Recording.alignment(p, s, recording: wav, path: path, realign: realign) { sink.add($0) }
        }
        poll.cancel()
        for l in sink.take() { note(l) }
        busy = nil
    }

    /// Saves the reviewed cuts.
    func save() {
        guard let f = file, let path = alignPath else { return }
        do { try f.save(path) } catch { app.error = "\(error)" }
    }

    func export() async {
        guard let f = file, let s = session, let wav = recording, let out = outDir else { return }
        save()
        var o = Recording.ExportOptions(dj: dj, art: art)
        (o.album, o.date, o.noTrim) = (album, date, !trim)
        busy = "Exporting…"
        let sink = LogSink()
        let poll = Task { [weak self] in
            while !Task.isCancelled {
                for l in sink.take() { self?.note(l) }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        let opts = o
        if let (ts, sheets) = await app.run({
            try await Recording.export(f, s, recording: wav, out: out, opts) { sink.add($0) }
        }) {
            exported = ts
            note(
                "cue sheet and tracklist: " + sheets.map { ($0 as NSString).lastPathComponent }.joined(separator: ", "))
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: ts.first?.file ?? out)])
        }
        poll.cancel()
        for l in sink.take() { note(l) }
        busy = nil
    }

    func write() async {
        guard app.canWrite(), let s = session, let f = file, let out = outDir else { return }
        let p = app.paths
        let (name, folder) = (playlistName, "")
        let ts = exported.isEmpty ? (try? MixExport.plan(f, tags: s.tags, outDir: out)) ?? [] : exported
        busy = "Writing…"
        if let st = await app.run({ try Recording.write(p, s, ts, playlist: name, folder: folder) }) {
            note(st.description)
            await app.refresh()
        }
        busy = nil
    }
}

/// Collects progress lines from background work.
final class LogSink: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    func add(_ s: String) {
        lock.lock()
        lines.append(s)
        lock.unlock()
    }

    func take() -> [String] {
        lock.lock()
        defer {
            lines = []
            lock.unlock()
        }
        return lines
    }
}

/// The Histories section's open history (and its recording, alignment and edits), owned by
/// the window so it survives switching sections.
@MainActor @Observable
final class HistoriesState {
    var selection: String?
    var model: RecordingModel?
}

/// The play histories; pick one to see its tracks and split a recording of it.
struct HistoriesView: View {
    @Environment(AppModel.self) private var app
    @Bindable var state: HistoriesState

    private var model: RecordingModel? { state.model }

    var body: some View {
        HSplitView {
            List(app.histories, id: \.name, selection: $state.selection) { h in
                VStack(alignment: .leading) {
                    Text(h.name)
                    Text("\(h.tracks) tracks · \(h.created)").font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(minWidth: 190, idealWidth: 220, maxWidth: 260, maxHeight: .infinity)
            if let model {
                RecordingView(model: model).frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Text("Select a history").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: state.selection) { _, name in
            guard let name, let h = app.histories.first(where: { $0.name == name }) else { return state.model = nil }
            let m = RecordingModel(app: app, history: h)
            state.model = m
            Task { await m.load() }
        }
    }
}

struct RecordingView: View {
    @Bindable var model: RecordingModel
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading) {
                    Text(model.history.name).font(.title3.bold())
                    Text("\(model.history.tracks) tracks · \(model.history.created)").foregroundStyle(.secondary)
                }
                Spacer()
                if let b = model.busy {
                    ProgressView().controlSize(.small)
                    Text(b).foregroundStyle(.secondary)
                }
            }
            // the recording's strip on top, like the waveform in DJ software
            if model.file != nil { CutTimeline(model: model).frame(height: 54) }
            HStack {
                Button("Choose Recording…") { chooseRecording() }
                Text(model.recording.map { ($0 as NSString).lastPathComponent } ?? "no recording chosen")
                    .foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Button(model.file == nil ? "Align" : "Realign") {
                    Task { await model.align(realign: model.file != nil) }
                }
                .disabled(model.recording == nil || model.busy != nil || model.session == nil)
                .help("Realign keeps the cuts you edited by hand")
            }
            if model.file != nil {
                CutTable(model: model)
                ExportForm(model: model)
            } else if let s = model.session {
                TrackTable(
                    "history",
                    rows: s.rows.map { r in
                        let t = s.tags[r.track.id]
                        return TrackRowData(
                            id: "\(r.track.no)", no: r.track.no, title: r.track.title, artist: t?.artist ?? "",
                            year: t?.year ?? 0, genre: t?.genre ?? "", bpm: r.track.bpm, key: r.track.key,
                            status: app.library.status(r.track.id))
                    }, numbered: true)
            } else {
                ProgressView("Loading the history…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if !model.log.isEmpty {
                ScrollView {
                    Text(model.log.joined(separator: "\n")).font(.caption.monospaced()).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 90)
            }
        }
        .padding()
        // Fill the pane and keep the content at its top, whatever has loaded so far.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func chooseRecording() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url { model.recording = url.path }
    }
}

/// The recording as a strip: each kept track from its cut to the next, coloured by status.
struct CutTimeline: View {
    let model: RecordingModel

    var body: some View {
        Canvas { ctx, size in
            guard let f = model.file, let segs = try? f.segments() else { return }
            let total = Double(max(f.samples, 1))
            for (k, s) in segs.enumerated() {
                let x0 = CGFloat(Double(s.start) / total) * size.width
                let x1 = CGFloat(Double(s.end) / total) * size.width
                let r = CGRect(x: x0, y: 4, width: max(x1 - x0 - 1, 1), height: size.height - 8)
                let c: Color =
                    s.entry.status == MixAlign.ok ? .green : s.entry.status == MixAlign.lowConf ? .orange : .gray
                ctx.fill(Path(roundedRect: r, cornerRadius: 3), with: .color(c.opacity(k % 2 == 0 ? 0.35 : 0.5)))
                var clip = ctx
                clip.clip(to: Path(r.insetBy(dx: 3, dy: 0)))
                clip.draw(
                    Text("\(s.entry.no)").font(.caption2), at: CGPoint(x: r.minX + 4, y: r.midY), anchor: .leading)
            }
        }
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 4))
    }
}

/// The alignment for review: edit a cut to move it, clear it to leave the track out, give a
/// no-audio track a cut to put it in.
struct CutTable: View {
    @Bindable var model: RecordingModel

    var body: some View {
        if let f = model.file {
            Table(f.tracks.indices.map { IndexedEntry(id: $0) }) {
                TableColumn("#") { Text("\(f.tracks[$0.id].no)").monospacedDigit() }.width(28)
                TableColumn("Title") { Text(f.tracks[$0.id].title).lineLimit(1) }.width(min: 120, ideal: 220)
                TableColumn("Status") { e in
                    let st = f.tracks[e.id].status
                    Text(st).foregroundStyle(st == MixAlign.ok ? .green : st == MixAlign.lowConf ? .orange : .secondary)
                }
                .width(100)
                TableColumn("Conf.") { Text(String(format: "%.2f", f.tracks[$0.id].confidence)).monospacedDigit() }
                    .width(44)
                TableColumn("Cut") { e in
                    TextField(
                        "—",
                        text: Binding(
                            get: { model.file?.tracks[e.id].cut ?? "" },
                            set: { model.file?.tracks[e.id].cut = $0 })
                    )
                    .monospacedDigit()
                    .onSubmit { model.save() }
                    .foregroundStyle(f.tracks[e.id].edited(sampleRate: f.sampleRate) ? .blue : .primary)
                }
                .width(110)
                TableColumn("Notes") { e in
                    Text(f.tracks[e.id].notes.joined(separator: "; ")).foregroundStyle(.secondary).lineLimit(2)
                        .help(f.tracks[e.id].notes.joined(separator: "\n"))
                }
            }
        }
    }
}

struct IndexedEntry: Identifiable {
    let id: Int
}

/// The tags and cover the files get; export, then write the playlist.
struct ExportForm: View {
    @Bindable var model: RecordingModel
    @Environment(AppModel.self) private var app

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
            GridRow {
                TextField("DJ", text: $model.dj)
                TextField("Album", text: $model.album, prompt: Text(model.history.name))
                TextField("Date", text: $model.date, prompt: Text(model.history.date)).frame(width: 110)
            }
            GridRow {
                HStack {
                    Button("Cover…") { chooseArt() }
                    Text(model.art.isEmpty ? "no cover" : (model.art as NSString).lastPathComponent)
                        .foregroundStyle(.secondary).lineLimit(1)
                }
                Toggle("Trim silence", isOn: $model.trim)
                Button("Export Tracks") { Task { await model.export() } }
                    .disabled(model.dj.isEmpty || model.art.isEmpty || model.busy != nil)
            }
            GridRow {
                TextField("Playlist", text: $model.playlistName).gridCellColumns(2)
                Button("Write Playlist…") { Task { await model.write() } }
                    .disabled(app.rekordboxRunning || model.busy != nil || model.playlistName.isEmpty)
                    .help("Create the playlist and save the transitions played (Rekordbox quit)")
            }
        }
    }

    private func chooseArt() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.jpeg, .png]
        if panel.runModal() == .OK, let url = panel.url { model.art = url.path }
    }
}

/// The generated demo set as a set you can reorder, play and export (no Rekordbox needed).
struct DemoView: View {
    @Environment(AppModel.self) private var app
    @Environment(Player.self) private var player
    @State private var model: SetModel?
    @State private var progress: String?
    let renderer: SetRenderer

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Demo set").font(.headline)
                Text("ten generated house tracks, cued by the rules").foregroundStyle(.secondary)
                Spacer()
                if let model {
                    BPMControl(model: model)
                    Button("Export…") { export(model) }.disabled(model.plan == nil)
                } else if let progress {
                    ProgressView().controlSize(.small)
                    Text(progress).foregroundStyle(.secondary)
                } else {
                    Button("Generate Demo") { generate() }
                }
            }
            .padding(10)
            Divider()
            if let model, !model.loading {
                SetEditor(model: model)
            } else {
                ContentUnavailableView(
                    "No Rekordbox needed", systemImage: "waveform",
                    description: Text(
                        "Renders ten original tracks, analyses them, plans their cues and opens them as a set.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func generate() {
        let dir = (app.paths.workDir as NSString).appendingPathComponent("demo/tracks")
        progress = "Rendering…"
        let sink = LogSink()
        Task {
            let poll = Task {
                while !Task.isCancelled {
                    if let l = sink.take().last { progress = l }
                    try? await Task.sleep(for: .milliseconds(200))
                }
            }
            let lib = await app.run { try await Demo.library(tracksDir: dir) { sink.add($0) } }
            poll.cancel()
            progress = nil
            guard let (recs, _) = lib else { return }
            let library = SetLibrary(
                playlist: Playlist(name: Demo.playlist, intelligent: false, tracks: Demo.order), recs: recs,
                cache: TransitionCache())
            let m = SetModel(app: app, player: player, playlist: Demo.playlist, renderer: renderer, library: library)
            model = m
            await m.load()
        }
    }

    private func export(_ m: SetModel) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            if let page = await m.export(to: url.path, format: .m4a) {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: page)])
            }
        }
    }
}
