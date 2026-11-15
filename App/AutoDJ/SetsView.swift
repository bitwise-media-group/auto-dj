// Copyright 2026 BitWise Media Group Ltd
// SPDX-License-Identifier: MIT

import AppKit
import AutoDJKit
import SwiftUI

/// Builds a set from a playlist: reorder by drag, key clashes per pair, the plan for the
/// current order, transition clips that become playable as they render, the full-set
/// timeline with its rendered edge, and Write / Export.
struct SetsView: View {
    @Environment(AppModel.self) private var app
    @Environment(Player.self) private var player
    @State private var picked: String?
    @State private var model: SetModel?
    @State private var confirmWrite = false
    @State private var reorderOnWrite = true
    @State private var exportFormat = ExportFormat.m4a
    let renderer: SetRenderer

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let model {
                if model.loading {
                    ProgressView("Loading \(model.playlist)…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    SetEditor(model: model)
                }
            } else {
                ContentUnavailableView(
                    "Pick a playlist", systemImage: "music.note.list",
                    description: Text("Choose a playlist or intelligent playlist to plan a set.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onChange(of: picked) { _, name in
            player.stop()
            guard let name else { return model = nil }
            let m = SetModel(app: app, player: player, playlist: name, renderer: renderer)
            model = m
            Task { await m.load() }
        }
        .confirmationDialog("Write the set's cues to Rekordbox?", isPresented: $confirmWrite) {
            Button("Write") { Task { await model?.write(reorder: reorderOnWrite && !(model?.intelligent ?? true)) } }
        } message: {
            Text(
                "master.db is backed up to _cue_work first. E/G hot cues, transition markers and memory-cue renames are written"
                    + (reorderOnWrite && !(model?.intelligent ?? true) ? ", and the playlist order saved." : "."))
        }
    }

    private var header: some View {
        HStack {
            Picker("Playlist", selection: $picked) {
                Text("—").tag(String?.none)
                let normal = app.playlists.filter { !$0.intelligent }
                let smart = app.playlists.filter(\.intelligent)
                Section("Playlists") { ForEach(normal, id: \.name) { Text($0.name).tag(Optional($0.name)) } }
                if !smart.isEmpty {
                    Section("Intelligent playlists") {
                        ForEach(smart, id: \.name) { Text($0.name).tag(Optional($0.name)) }
                    }
                }
            }
            .frame(maxWidth: 320)
            if let model {
                Divider().frame(height: 18)
                BPMControl(model: model)
                Spacer()
                if model.rendering { ProgressView().controlSize(.small) }
                Toggle("Save order", isOn: $reorderOnWrite).disabled(model.intelligent)
                    .help(
                        model.intelligent
                            ? "Rekordbox orders an intelligent playlist itself" : "Also save this order to the playlist"
                    )
                Button("Write…") { confirmWrite = true }
                    .disabled(app.rekordboxRunning || model.result == nil)
                    .help(app.rekordboxRunning ? "Quit Rekordbox to write" : "Write the set's cues to master.db")
                Picker("", selection: $exportFormat) {
                    ForEach(ExportFormat.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .frame(width: 70)
                Button("Export…") { export(model) }.disabled(model.plan == nil)
            } else {
                Spacer()
            }
        }
        .padding(10)
    }

    private func export(_ m: SetModel) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let format = exportFormat
        Task {
            if let page = await m.export(to: url.path, format: format) {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: page)])
            }
        }
    }
}

/// Fixed tempo (key kept) or beat-matched at each track's own tempo.
struct BPMControl: View {
    @Bindable var model: SetModel
    @State private var fixed = true
    @State private var value = 128.0

    var body: some View {
        HStack(spacing: 6) {
            Toggle("Fixed tempo", isOn: $fixed).toggleStyle(.checkbox)
            TextField("BPM", value: $value, format: .number.precision(.fractionLength(0...1)))
                .frame(width: 56).disabled(!fixed)
                .onSubmit { model.bpm = fixed ? value : 0 }
            Stepper("", value: $value, in: 60...200, step: 1).labelsHidden().disabled(!fixed)
        }
        .onAppear {
            fixed = model.bpm > 0
            value = model.bpm > 0 ? model.bpm : 128
        }
        .onChange(of: fixed) { _, f in model.bpm = f ? value : 0 }
        .onChange(of: value) { _, v in if fixed { model.bpm = v } }
    }
}

struct SetEditor: View {
    @Bindable var model: SetModel

    var body: some View {
        VSplitView {
            HSplitView {
                TrackList(model: model).frame(minWidth: 360, idealWidth: 460)
                TransitionList(model: model).frame(minWidth: 300, idealWidth: 360)
                Inspector(model: model).frame(minWidth: 280, idealWidth: 340)
            }
            .frame(minHeight: 300)
            MixTimelineView(model: model).frame(minHeight: 150, idealHeight: 190)
        }
    }
}

/// The tracks in play order, reorderable by drag, with the key move into each.
struct TrackList: View {
    @Bindable var model: SetModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(model.tracks.count) tracks").font(.headline)
                if let r = model.result, r.clashes > 0 {
                    Label(
                        "\(r.clashes) key clash\(r.clashes == 1 ? "" : "es")",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(.orange)
                }
                Spacer()
                Menu("Order") {
                    Button("Suggested order") { model.useSuggested(freeStart: false) }
                    Button("Suggested order, any first track") { model.useSuggested(freeStart: true) }
                    Divider()
                    Button("Playlist order") { model.resetOrder() }.disabled(!model.reordered)
                }
                .fixedSize()
                .help("Fewest key clashes, changing your order as little as possible")
            }
            .padding(8)
            List(selection: $model.selection) {
                ForEach(Array(model.tracks.enumerated()), id: \.element.no) { i, t in
                    TrackRowView(model: model, index: i, track: t).tag(t.no)
                }
                .onMove { model.move(from: $0, to: $1) }
            }
        }
    }
}

struct TrackRowView: View {
    let model: SetModel
    let index: Int
    let track: PlaylistTrack

    var body: some View {
        HStack(spacing: 8) {
            Text("\(index + 1)").monospacedDigit().foregroundStyle(.secondary).frame(width: 24, alignment: .trailing)
            KeyBadge(key: track.key, move: index > 0 ? Keys.move(model.tracks[index - 1].key, track.key) : nil)
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title).lineLimit(1)
                HStack(spacing: 6) {
                    Text(String(format: "%.1f BPM", track.bpm)).font(.caption).foregroundStyle(.secondary)
                    if let a = model.action(for: track.no), !a.warnings.isEmpty {
                        Label("\(a.warnings.count)", systemImage: "exclamationmark.circle").font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }
            Spacer()
            let n = index + 1
            if let e = model.trackErrors[n] {
                Image(systemName: "exclamationmark.octagon.fill").foregroundStyle(.red).help(e)
            } else if let p = model.trackProgress[n], p < 1 {
                ProgressView(value: p).progressViewStyle(.circular).controlSize(.small)
            } else if model.trackProgress[n] == 1 {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).help("Rendered")
            }
        }
    }
}

/// The track's key, coloured by the move from the previous track.
struct KeyBadge: View {
    let key: String
    let move: Keys.Move?

    var body: some View {
        let camelot = Camelot(key).map(\.description) ?? "?"
        Text(camelot)
            .font(.caption.monospacedDigit().bold())
            .frame(width: 34)
            .padding(.vertical, 2)
            .background(color.opacity(0.25), in: RoundedRectangle(cornerRadius: 4))
            .help(move.map { "\(key.isEmpty ? "?" : key): \($0.desc)" } ?? (key.isEmpty ? "key unknown" : key))
    }

    var color: Color {
        guard let move else { return .gray }
        if !move.ok { return .red }
        return move.cost == 0 ? .green : .yellow
    }
}

/// Each transition: its clip's progress, then a play button.
struct TransitionList: View {
    let model: SetModel
    @Environment(Player.self) private var player

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Transitions").font(.headline).padding(8)
            List {
                if let plan = model.plan {
                    ForEach(plan.pairs, id: \.i) { p in
                        HStack {
                            let a = model.tracks[p.i]
                            let b = model.tracks[p.i + 1]
                            VStack(alignment: .leading) {
                                Text("\(p.i + 1) → \(p.i + 2)").font(.caption).foregroundStyle(.secondary)
                                Text("\(a.title)").lineLimit(1)
                                Text("→ \(b.title)").lineLimit(1).foregroundStyle(.secondary)
                            }
                            Spacer()
                            control(p)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    func control(_ p: PairPreview) -> some View {
        if let reason = p.reason {
            Image(systemName: "speaker.slash").foregroundStyle(.secondary).help(reason)
        } else if let e = model.pairErrors[p.i] {
            Image(systemName: "exclamationmark.octagon.fill").foregroundStyle(.red).help(e)
        } else if let c = model.clips[p.i] {
            let on = player.source == .clip(p.i) && player.playing
            Button {
                if on { player.pause() } else { player.playClip(p.i, file: c.file, frames: c.frames) }
            } label: {
                Image(systemName: on ? "pause.circle.fill" : "play.circle.fill").font(.title2)
            }
            .buttonStyle(.borderless)
        } else {
            ProgressView(value: model.pairProgress[p.i] ?? 0).progressViewStyle(.circular).controlSize(.small)
        }
    }
}

/// The selected track's set decisions: E / G, bass swap and why, exit, markers, warnings.
struct Inspector: View {
    let model: SetModel

    var body: some View {
        ScrollView {
            if let no = model.selection, let a = model.action(for: no), let t = model.record(for: no) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(a.title).font(.headline)
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                        slot("E", a.e, t)
                        slot("G", a.g, t)
                        if let bs = a.bassSwap {
                            GridRow {
                                Text("BASS SWAP").foregroundStyle(.secondary)
                                if let b = bs.beat {
                                    Text("beat \(b) @ \(at(t, b))  \(bs.why)")
                                } else {
                                    Text("none: \(bs.why)")
                                }
                            }
                        }
                        if let ex = a.exit {
                            GridRow {
                                Text("Exit").foregroundStyle(.secondary)
                                Text(
                                    "\(ex.name) at beat \(ex.a) @ \(at(t, ex.a)) (\(ex.side == "out" ? "own cue" : "from the next track"))"
                                )
                            }
                        }
                        if a.sync {
                            GridRow {
                                Text("SYNC").foregroundStyle(.secondary); Text("instant mashup: in at full volume")
                            }
                        }
                    }
                    if !a.markers.isEmpty {
                        Text("Markers").font(.subheadline.bold())
                        ForEach(a.markers, id: \.self) { m in
                            Text("\(m.name)  beat \(m.beat) @ \(at(t, m.beat))  \(m.status.rawValue)").font(
                                .callout.monospaced())
                        }
                    }
                    if !a.remove.isEmpty {
                        Text("Removed on write").font(.subheadline.bold())
                        ForEach(a.remove, id: \.beat) { r in Text("\(r.name) @ beat \(r.beat): \(r.why)").font(.callout)
                        }
                    }
                    if !a.warnings.isEmpty {
                        Text("Warnings").font(.subheadline.bold())
                        ForEach(a.warnings, id: \.self) { w in
                            Label(w, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
                        }
                    }
                    if let w = model.lastWrite {
                        Text("Last write").font(.subheadline.bold())
                        Text(w).font(.caption.monospaced()).textSelection(.enabled)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("Select a track").foregroundStyle(.secondary).padding()
            }
        }
    }

    func at(_ t: Track, _ b: Int) -> String { SetRun.minSec(beatTime(t, b)) }

    @ViewBuilder
    func slot(_ name: String, _ s: Slot?, _ t: Track) -> some View {
        if let s {
            GridRow {
                Text(name).foregroundStyle(.secondary)
                Text(
                    "\(s.name)  beat \(s.beat) @ \(at(t, s.beat))  \(s.status.rawValue)"
                        + (s.status == .replace ? s.old.map { " (was '\($0.name)')" } ?? "" : ""))
            }
        }
    }
}
