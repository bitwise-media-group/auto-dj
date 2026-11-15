// Copyright 2026 BitWise Media Group Ltd
// SPDX-License-Identifier: MIT

import AutoDJKit
import Foundation
import Observation

/// One set being built: the playlist's tracks in the order being tried, the plan for that
/// order (replanned on every edit), and the previews rendering for it.
@MainActor @Observable
final class SetModel {
    let app: AppModel
    let player: Player
    let playlist: String

    private(set) var loading = true
    private(set) var library: SetLibrary?
    /// The tracks in the order being tried (`no` is the playlist's own track number).
    var tracks: [PlaylistTrack] = []
    private(set) var result: SetResult?
    private(set) var plan: PreviewPlan?
    var bpm = 128.0 {
        didSet { if bpm != oldValue { Task { await replan() } } }
    }
    var selection: Int?  // a track's `no`

    // render state
    private(set) var trackProgress: [Int: Double] = [:]  // by mix track number (1-based position)
    private(set) var pairProgress: [Int: Double] = [:]  // by transition index
    private(set) var clips: [Int: (file: String, frames: Int)] = [:]
    /// Segments and clips that couldn't be rendered, and why.
    private(set) var trackErrors: [Int: String] = [:]
    private(set) var pairErrors: [Int: String] = [:]
    private(set) var mixChunks: [MixChunk] = []
    private(set) var mixDone = false
    private(set) var rendering = false
    private(set) var lastWrite: String?

    @ObservationIgnored private var renderTask: Task<Void, Never>?
    @ObservationIgnored private var planTask: Task<Void, Never>?
    @ObservationIgnored let renderer: SetRenderer

    /// A library that isn't in master.db (the demo): nothing can be written.
    let preloaded: SetLibrary?
    var writable: Bool { preloaded == nil }

    init(app: AppModel, player: Player, playlist: String, renderer: SetRenderer, library: SetLibrary? = nil) {
        self.app = app
        self.player = player
        self.playlist = playlist
        self.renderer = renderer
        preloaded = library
    }

    var intelligent: Bool { library?.playlist.intelligent ?? false }

    /// The playlist's own order.
    var original: [PlaylistTrack] { library?.playlist.tracks ?? [] }

    var reordered: Bool { tracks.map(\.no) != original.map(\.no) }

    /// Seconds of the mix rendered contiguously from the start.
    var renderedSeconds: Double {
        var end = 0
        for c in mixChunks.sorted(by: { $0.index < $1.index }) where c.start == end { end = c.start + c.frames }
        return Double(end) / Mix.sampleRate
    }

    func load() async {
        let p = app.paths
        let name = playlist
        loading = true
        if let preloaded {
            library = preloaded
        } else {
            library = await app.run { try SetLibrary.load(p, playlist: name) }
        }
        tracks = library?.playlist.tracks ?? []
        loading = false
        await replan()
    }

    /// Plans the set for the current order and restarts the previews (segments that didn't
    /// change come straight from the render cache).
    func replan() async {
        guard let lib = library else { return }
        planTask?.cancel()
        let (order, bpm, name) = (tracks, bpm, playlist)
        let task = Task { [weak self] in
            let r = await Task.detached(priority: .userInitiated) { () -> (SetResult, PreviewPlan)? in
                guard let res = try? SetRun.plan(name, order, lib.recs, lib.cache, order: .playlist, freeStart: false)
                else {
                    return nil
                }
                return (res, PreviewPlan(res, bpm: bpm))
            }.value
            guard let self, !Task.isCancelled, let (res, plan) = r else { return }
            self.result = res
            self.plan = plan
            self.startRender(plan)
        }
        planTask = task
        await task.value
    }

    func move(from: IndexSet, to: Int) {
        tracks.move(fromOffsets: from, toOffset: to)
        Task { await replan() }
    }

    /// Applies the suggested order (fewest key clashes, least change); freeStart lets it
    /// change the first track.
    func useSuggested(freeStart: Bool) {
        let items = tracks.map { Keys.Item(key: $0.key, bpm: $0.bpm) }
        let (order, _) = Keys.suggestOrder(items, keepFirst: !freeStart)
        if order == Array(tracks.indices) { return }
        tracks = order.map { tracks[$0] }
        Task { await replan() }
    }

    func resetOrder() {
        tracks = original
        Task { await replan() }
    }

    private func startRender(_ plan: PreviewPlan) {
        renderTask?.cancel()
        trackProgress = [:]
        pairProgress = [:]
        clips = [:]
        trackErrors = [:]
        pairErrors = [:]
        mixChunks = []
        mixDone = false
        player.resetMix()
        rendering = true
        let renderer = self.renderer
        renderTask = Task { [weak self] in
            do {
                for try await ev in renderer.render(plan) {
                    guard let self, !Task.isCancelled else { return }
                    self.handle(ev)
                }
            } catch is CancellationError {
            } catch {
                self?.app.error = "rendering the previews: \(error)"
            }
            self?.rendering = false
        }
    }

    private func handle(_ ev: RenderEvent) {
        switch ev {
        case .track(let n, let p): trackProgress[n] = max(trackProgress[n] ?? 0, p)
        case .pair(let i, let p): pairProgress[i] = max(pairProgress[i] ?? 0, p)
        case .pairReady(let i, let file, let frames):
            pairProgress[i] = 1
            clips[i] = (file, frames)
        case .mixChunk(let c):
            mixChunks.append(c)
            player.addChunk(c)
        case .mixDone: mixDone = true
        case .trackFailed(let n, let e): trackErrors[n] = e
        case .pairFailed(let i, let e): pairErrors[i] = e
        }
    }

    func action(for no: Int) -> SetAction? {
        guard let r = result, let i = r.order.firstIndex(where: { $0.no == no }) else { return nil }
        return r.actions[i]
    }

    func record(for no: Int) -> Track? {
        tracks.first { $0.no == no }.flatMap { library?.recs[$0.id] }
    }

    /// Writes the set's cues (and the order, when reorder) to master.db.
    func write(reorder: Bool) async {
        guard writable, app.canWrite(), let planned = result else { return }
        let p = app.paths
        let stats = await app.run { () -> (String, SetResult) in
            var res = planned
            let st = try SetRun.write(p, &res, reorder: reorder)
            return (st.description, res)
        }
        if let (s, r) = stats {
            lastWrite = s
            library?.cache = r.cache
            await load()
        }
    }

    /// Exports the bundle (index.html, set.json, clips, mix) into dir, waiting for the
    /// render to finish first.
    func export(to dir: String, format: ExportFormat) async -> String? {
        while rendering { try? await Task.sleep(for: .milliseconds(200)) }
        guard let plan else { return nil }
        let clipFiles = clips.mapValues(\.file)
        let chunks = mixChunks.sorted { $0.index < $1.index }.map(\.file)
        let out = (dir as NSString).appendingPathComponent(Text.slug(playlist))
        return await app.run {
            try PreviewExport.write(plan, clips: clipFiles, mixChunks: chunks, to: out, format: format)
        }
    }

    func cancelRender() {
        renderTask?.cancel()
        rendering = false
    }
}
