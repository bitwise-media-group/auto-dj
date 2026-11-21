// Copyright 2026 BitWise Media Group Ltd
// SPDX-License-Identifier: MIT

import AppKit
import AutoDJKit
import SwiftUI

/// Builds a set from a playlist: reorder by drag, key clashes per pair, the plan for the
/// current order, transition clips that become playable as they render, the full-set
/// timeline with its rendered edge, and Write / Export.
/// The Sets section's open playlist and set, owned by the window rather than the view.
@MainActor @Observable
final class SetsState {
    var picked: String?
    var model: SetModel?
    var reorderOnWrite = true
    var exportFormat = ExportFormat.m4a
}

struct SetsView: View {
    @Environment(AppModel.self) private var app
    @Environment(Player.self) private var player
    /// Kept by the window, so the open set survives switching to another section and back.
    @Bindable var state: SetsState
    @State private var confirmWrite = false
    let renderer: SetRenderer

    private var model: SetModel? { state.model }
    private var reorderOnWrite: Bool { state.reorderOnWrite }

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
        .onChange(of: state.picked) { _, name in
            player.stop()
            guard let name else { return state.model = nil }
            let m = SetModel(app: app, player: player, playlist: name, renderer: renderer)
            state.model = m
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
            Picker("Playlist", selection: $state.picked) {
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
                Toggle("Save order", isOn: $state.reorderOnWrite).disabled(model.intelligent)
                    .help(
                        model.intelligent
                            ? "Rekordbox orders an intelligent playlist itself" : "Also save this order to the playlist"
                    )
                Button("Write…") { confirmWrite = true }
                    .disabled(app.rekordboxRunning || model.result == nil)
                    .help(app.rekordboxRunning ? "Quit Rekordbox to write" : "Write the set's cues to master.db")
                Picker("", selection: $state.exportFormat) {
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
        let format = state.exportFormat
        Task {
            if let page = await m.export(to: url.path, format: format) {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: page)])
            }
        }
    }
}

/// Fixed tempo (key kept) or beat-matched at each track's own tempo.
/// The previews' tempo. Every change re-renders the whole set, so the field applies only when
/// submitted (Return or leaving it) and the stepper once clicking stops, both within 60-200 BPM.
struct BPMControl: View {
    @Bindable var model: SetModel
    @State private var fixed = true
    @State private var value = 128.0
    @State private var text = "128"
    @FocusState private var editing: Bool

    var body: some View {
        HStack(spacing: 6) {
            Toggle("Fixed tempo", isOn: $fixed).toggleStyle(.checkbox)
            TextField("BPM", text: $text)
                .frame(width: 56).disabled(!fixed)
                .focused($editing)
                .onSubmit(commit)
                .onChange(of: editing) { _, e in if !e { commit() } }
            Stepper("", value: $value, in: SetModel.bpmRange, step: 1).labelsHidden().disabled(!fixed)
        }
        .onAppear {
            fixed = model.bpm > 0
            value = model.bpm > 0 ? model.bpm : 128
            text = Self.format(value)
        }
        .onChange(of: fixed) { _, f in model.bpm = f ? value : 0 }
        .onChange(of: value) { _, v in if !editing { text = Self.format(v) } }
        // apply the stepper's value once it settles, not on every click
        .task(id: value) {
            try? await Task.sleep(for: .milliseconds(400))
            if !Task.isCancelled, fixed, value != model.bpm { model.bpm = value }
        }
    }

    /// Applies the typed tempo, clamped (and resets the field when it isn't a number).
    func commit() {
        guard let v = Double(text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")) else {
            text = Self.format(value)
            return
        }
        value = min(max((v * 10).rounded() / 10, SetModel.bpmRange.lowerBound), SetModel.bpmRange.upperBound)
        text = Self.format(value)
        if fixed { model.bpm = value }
    }

    static func format(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)
    }
}

struct SetEditor: View {
    @Bindable var model: SetModel

    var body: some View {
        // the timeline on top, like the waveforms on a CDJ or in Rekordbox
        VSplitView {
            MixTimelineView(model: model).frame(minHeight: 270, idealHeight: 320, maxHeight: 400)
            HSplitView {
                TrackList(model: model).frame(minWidth: 360, idealWidth: 460)
                TransitionList(model: model).frame(minWidth: 300, idealWidth: 360)
                Inspector(model: model).frame(minWidth: 280, idealWidth: 340)
            }
            .frame(minHeight: 300, maxHeight: .infinity)
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

    /// The selected track's place in the play order.
    var selected: Int? { model.selection.flatMap { no in model.tracks.firstIndex { $0.no == no } } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Transitions").font(.headline).padding(8)
            ScrollViewReader { proxy in
                List {
                    if let plan = model.plan {
                        ForEach(plan.pairs, id: \.i) { p in
                            row(p).listRowBackground(role(p).map { _ in Color.accentColor.opacity(0.16) })
                        }
                    }
                }
                .onChange(of: selected) { _, k in
                    // bring the selected track's transitions into view
                    guard let k, let plan = model.plan else { return }
                    let ids = plan.pairs.map(\.i).filter { $0 == k - 1 || $0 == k }
                    if let first = ids.first { withAnimation { proxy.scrollTo(first, anchor: .top) } }
                }
            }
        }
    }

    /// Whether p mixes into the selected track or out of it.
    func role(_ p: PairPreview) -> String? {
        guard let k = selected else { return nil }
        return p.i == k - 1 ? "IN" : p.i == k ? "OUT" : nil
    }

    func row(_ p: PairPreview) -> some View {
        let a = model.tracks[p.i]
        let b = model.tracks[p.i + 1]
        let r = role(p)
        // the incoming track's plan holds the transition's warnings
        let inc = model.plan.flatMap { p.i + 1 < $0.actions.count ? $0.actions[p.i + 1] : nil }
        return HStack {
            VStack(alignment: .leading) {
                HStack(spacing: 6) {
                    Text("\(p.i + 1) → \(p.i + 2)").font(.caption).foregroundStyle(.secondary)
                    if let inc, let n = inc.vocalOverlap {
                        Label("VOCALS \(n / 4) BARS", systemImage: "music.mic")
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.orange.opacity(0.16), in: Capsule())
                            .help(
                                inc.warnings.first { $0.hasPrefix("vocal overlap") }
                                    ?? "Both tracks' vocals play during this transition")
                    }
                    if let r {
                        Text(r)
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .tracking(0.4)
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.18), in: Capsule())
                            .help(r == "IN" ? "Mixes into the selected track" : "Mixes out of the selected track")
                    }
                }
                Text("\(a.title)").lineLimit(1).fontWeight(r == "OUT" ? .semibold : .regular)
                Text("→ \(b.title)").lineLimit(1).foregroundStyle(r == "IN" ? .primary : .secondary)
                    .fontWeight(r == "IN" ? .semibold : .regular)
            }
            Spacer()
            control(p)
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

/// The selected track's set decisions, laid out like a deck's cue lists: its hot cues as pads
/// (E / G as the set plans them), its memory cues as arrows (with the set's markers and the
/// stale ones the write removes), then the bass swap, exit and warnings.
struct Inspector: View {
    let model: SetModel

    var body: some View {
        ScrollView {
            if let no = model.selection, let a = model.action(for: no), let t = model.record(for: no) {
                let marks = model.cueMarks(for: no)
                VStack(alignment: .leading, spacing: 14) {
                    header(a, t, no)
                    section("HOT CUES") {
                        let hot = marks.filter { $0.slot != nil }.sorted { ($0.slot!, $0.t) < ($1.slot!, $1.t) }
                        if hot.isEmpty { empty("No hot cues") }
                        ForEach(hot) { m in
                            row(m, t) { PadBadge(slot: m.slot!, size: 18, dimmed: !m.kept) }
                        }
                    }
                    section("MEMORY CUES") {
                        let mem = marks.filter { $0.slot == nil }
                        if mem.isEmpty { empty("No memory cues") }
                        ForEach(mem) { m in
                            row(m, t) { MemoryArrow(color: Deck.memory(m.memoryColor), dimmed: !m.kept) }
                        }
                    }
                    mix(a, t)
                    if !a.warnings.isEmpty {
                        section("WARNINGS") {
                            ForEach(a.warnings, id: \.self) { w in
                                Label(w, systemImage: "exclamationmark.triangle.fill").font(.callout)
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                    if let w = model.lastWrite {
                        section("LAST WRITE") {
                            Text(w).font(.caption.monospaced()).textSelection(.enabled)
                        }
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ContentUnavailableView(
                    "Select a track", systemImage: "square.grid.2x2",
                    description: Text("Its hot cues, memory cues and transition appear here."))
            }
        }
    }

    private func header(_ a: SetAction, _ t: Track, _ no: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(a.title).font(.headline).lineLimit(2)
            HStack(spacing: 8) {
                if let i = model.tracks.firstIndex(where: { $0.no == no }) {
                    let pt = model.tracks[i]
                    Text("#\(i + 1)").font(.caption.monospacedDigit().bold()).foregroundStyle(.secondary)
                    KeyBadge(key: pt.key, move: i > 0 ? Keys.move(model.tracks[i - 1].key, pt.key) : nil)
                }
                Text(String(format: "%.1f BPM", t.bpm)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                if t.length > 0 {
                    Text(SetRun.minSec(t.length)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                if a.sync { ChipLabel(text: "SYNC", color: Deck.memory(5)) }
            }
        }
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 10, weight: .bold, design: .rounded)).tracking(1.2)
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func empty(_ s: String) -> some View {
        Text(s).font(.callout).foregroundStyle(.tertiary)
    }

    /// One cue: its pad or arrow, name (and what it was), beat and time, what the write does.
    private func row<I: View>(_ m: CueMark, _ t: Track, @ViewBuilder icon: () -> I) -> some View {
        HStack(alignment: .center, spacing: 8) {
            icon()
            VStack(alignment: .leading, spacing: 1) {
                Text(m.name.isEmpty ? "—" : m.name)
                    .font(.system(.callout, weight: .semibold))
                    .strikethrough(!m.kept)
                    .foregroundStyle(m.kept ? .primary : .secondary)
                    .lineLimit(1).truncationMode(.tail)
                if let was = m.was {
                    Text("was \(was)").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                } else if let why = m.why {
                    Text(why).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            .layoutPriority(1)
            Spacer(minLength: 4)
            ChangeTag(change: m.change)
            VStack(alignment: .trailing, spacing: 0) {
                Text(SetRun.minSec(m.t)).font(.callout.monospacedDigit())
                Text("beat \(m.beat)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
            .frame(minWidth: 52, alignment: .trailing)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.35)))
    }

    @ViewBuilder
    private func mix(_ a: SetAction, _ t: Track) -> some View {
        if a.bassSwap != nil || a.exit != nil {
            section("MIX") {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                    if let bs = a.bassSwap {
                        GridRow(alignment: .firstTextBaseline) {
                            ChipLabel(text: "BASS SWAP", color: Deck.memory(2))
                            if let b = bs.beat {
                                Text("\(at(t, b)) · beat \(b)  ").monospacedDigit()
                                    + Text(bs.why).foregroundStyle(.secondary)
                            } else {
                                Text("none: ").foregroundStyle(.secondary) + Text(bs.why).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if let ex = a.exit {
                        GridRow(alignment: .firstTextBaseline) {
                            ChipLabel(
                                text: ex.name, color: Deck.memory(Config.memoryColor[Config.norm(ex.name)]))
                            Text("\(at(t, ex.a)) · beat \(ex.a)  ").monospacedDigit()
                                + Text(ex.side == "out" ? "its own cue" : "from the next track")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .font(.callout)
            }
        }
    }

    func at(_ t: Track, _ b: Int) -> String { SetRun.minSec(beatTime(t, b)) }
}

/// A coloured label for a mix decision.
struct ChipLabel: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 9.5, weight: .bold, design: .rounded)).tracking(0.5)
            .foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(color, lineWidth: 1.2))
    }
}
