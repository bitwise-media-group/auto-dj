// Copyright 2026 BitWise Media Group Ltd
// SPDX-License-Identifier: MIT

import AutoDJKit
import SwiftUI

/// Building a set around picked tracks (ADR 0021): the Library's picks bar, the options sheet,
/// and saving the draft as a playlist.

/// Plays a library track from its DROP hot cue (else a minute in), or pauses it.
@MainActor
func preview(_ t: LibraryTrack, _ player: Player) {
    if player.source == .track(t.id) {
        player.toggle()
    } else if !t.path.isEmpty, FileManager.default.fileExists(atPath: t.path) {
        player.playTrack(t.id, file: t.path, from: t.drop ?? 60)
    }
}

/// The picked tracks, each playable and removable, and the button that builds a set.
struct PicksBar: View {
    @Environment(AppModel.self) private var app
    @Environment(Player.self) private var player
    @Bindable var state: SetsState
    @State private var building = false
    let openSets: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Label("Picks", systemImage: "pin.fill").font(.headline)
            if state.picks.isEmpty {
                Text("Select a track and press Return (or Pick) to build a set around it; Space previews it.")
                    .foregroundStyle(.secondary)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(state.picks, id: \.self) { id in
                        if let t = app.library.index[id].map({ app.library.tracks[$0] }) { chip(t) }
                    }
                }
            }
            Spacer(minLength: 0)
            if !state.picks.isEmpty {
                Button("Clear") { state.picks = [] }
            }
            Button("Build Set…") { building = true }
                .keyboardShortcut("b", modifiers: [.command])
                .disabled(state.picks.isEmpty)
        }
        .sheet(isPresented: $building) {
            BuildSheet(state: state) { d in
                state.pendingDraft = d
                openSets()
            }
        }
    }

    func chip(_ t: LibraryTrack) -> some View {
        let playing = player.source == .track(t.id) && player.playing
        return HStack(spacing: 6) {
            Button {
                preview(t, player)
            } label: {
                Image(systemName: playing ? "pause.fill" : "play.fill")
            }
            .buttonStyle(.borderless)
            .help("Preview from the drop")
            Text(t.title).lineLimit(1).frame(maxWidth: 200, alignment: .leading)
            if let e = t.energy { Text(e.label).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
            Button {
                state.picks.removeAll { $0 == t.id }
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.quaternary, in: Capsule())
    }
}

/// The options for building a set around the picks.
struct BuildSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Bindable var state: SetsState
    let build: (SetModel.Draft) -> Void

    @State private var tracks = 16
    @State private var arc = SetBuilder.Arc.peak
    @State private var keepOrder = false
    @State private var opener = false
    @State private var closer = false
    @State private var bpm = ""
    @State private var range = 6.0
    @State private var pool: String?

    var picked: [LibraryTrack] { state.picks.compactMap { app.library.index[$0].map { app.library.tracks[$0] } } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Build a Set Around \(picked.count) Pick\(picked.count == 1 ? "" : "s")").font(.title3.bold())
            List {
                ForEach(picked) { t in
                    HStack {
                        Text(t.title).lineLimit(1)
                        Spacer()
                        Text(Camelot(t.key)?.description ?? "?").monospacedDigit().foregroundStyle(.secondary)
                        Text(String(format: "%.1f", t.bpm)).monospacedDigit().foregroundStyle(.secondary)
                        EnergyChip(energy: t.energy).environment(\.colorScheme, .dark)
                    }
                }
                .onMove { state.picks.move(fromOffsets: $0, toOffset: $1) }
            }
            .frame(height: min(CGFloat(picked.count) * 28 + 12, 170))
            Form {
                Picker("Energy arc", selection: $arc) {
                    Text("Build up").tag(SetBuilder.Arc.build)
                    Text("Peak").tag(SetBuilder.Arc.peak)
                    Text("Flat").tag(SetBuilder.Arc.flat)
                }
                .pickerStyle(.segmented)
                Stepper("\(tracks) tracks", value: $tracks, in: max(picked.count, 2)...80)
                Toggle("Keep my order (drag the picks above)", isOn: $keepOrder)
                    .help("Otherwise the picks are placed along the arc by energy")
                Toggle("First pick opens the set", isOn: $opener)
                Toggle("Last pick closes the set", isOn: $closer)
                TextField("Set tempo (BPM)", text: $bpm)
                Stepper(String(format: "Tempo range ±%.0f%%", range), value: $range, in: 2...12, step: 1)
                Picker("Add tracks from", selection: $pool) {
                    Text("The whole library").tag(String?.none)
                    ForEach(app.playlists, id: \.name) { Text($0.name).tag(Optional($0.name)) }
                }
            }
            .formStyle(.grouped)
            HStack {
                Text("Energy is your rating, else Mixed In Key's level halved (~).").font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Build") {
                    var o = SetBuilder.Options(picks: state.picks, length: max(tracks, state.picks.count))
                    (o.arc, o.keepOrder, o.opener, o.closer, o.tempoRange) = (
                        arc, keepOrder, opener, closer, range / 100
                    )
                    o.bpm = Double(bpm.replacingOccurrences(of: ",", with: ".")) ?? defaultBPM
                    build(SetModel.Draft(options: o, poolName: pool))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(state.picks.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear { bpm = BPMControl.format(defaultBPM) }
    }

    /// The picks' median tempo.
    var defaultBPM: Double {
        let bs = picked.map(\.bpm).filter { $0 > 0 }.sorted()
        guard !bs.isEmpty else { return 128 }
        let m = bs.count % 2 == 1 ? bs[bs.count / 2] : (bs[bs.count / 2 - 1] + bs[bs.count / 2]) / 2
        return (m * 10).rounded() / 10
    }
}

/// Names the playlist a draft is saved as.
struct SaveDraftSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let model: SetModel
    let saved: (String) -> Void
    @State private var name = ""
    @State private var busy = false

    var taken: Bool { app.playlists.contains { $0.name == name } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Save as Playlist").font(.title3.bold())
            TextField("Playlist name", text: $name).textFieldStyle(.roundedBorder)
            if taken { Text("A playlist with that name exists.").font(.caption).foregroundStyle(.orange) }
            Text("master.db is backed up to _cue_work first. Then plan and write the set's cues as for any playlist.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    busy = true
                    Task {
                        let ok = await model.saveAsPlaylist(name)
                        busy = false
                        if ok {
                            dismiss()
                            saved(name)
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || taken || busy)
            }
        }
        .padding(20)
        .frame(width: 400)
    }
}
