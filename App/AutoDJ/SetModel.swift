// Copyright 2026 BitWise Media Group Ltd
// SPDX-License-Identifier: MIT

import AutoDJKit
import Foundation
import Observation

/// One set being built: the playlist's tracks in the order being tried, the plan for that
/// order (replanned on every edit), and the previews rendering for it. A draft is a set built
/// around picked tracks (ADR 0021) that isn't a playlist yet: its tracks can be re-rolled or
/// removed, and it's saved as a playlist before its cues can be written.
@MainActor @Observable
final class SetModel {
    let app: AppModel
    let player: Player
    let playlist: String

    private(set) var loading = true
    static let bpmRange = 60.0...200.0
    private(set) var library: SetLibrary?
    /// The tracks in the order being tried (`no` is the playlist's own track number).
    var tracks: [PlaylistTrack] = []
    private(set) var result: SetResult?
    private(set) var plan: PreviewPlan?
    /// The previews' fixed tempo (0: each track at its own). Kept within `bpmRange`: a stray
    /// value (1 or 12 while typing 125) would stretch every track tenfold, a render that takes
    /// minutes and gigabytes.
    var bpm = 128.0 {
        didSet {
            if bpm != 0 && !Self.bpmRange.contains(bpm) {
                bpm = min(max(bpm, Self.bpmRange.lowerBound), Self.bpmRange.upperBound)
            }
            if bpm != oldValue { Task { await replan() } }
        }
    }
    var selection: Int?  // a track's `no`
    /// The timeline's zoom (seconds shown, 0 for the whole set), scroll and follow, kept while
    /// another section is shown (not observed: the timeline owns the live values).
    @ObservationIgnored var timelineView = (span: 0.0, t0: 0.0, follow: true)

    // render state
    private(set) var trackProgress: [Int: Double] = [:]  // by mix track number (1-based position)
    private(set) var pairProgress: [Int: Double] = [:]  // by transition index
    private(set) var clips: [Int: (file: String, frames: Int)] = [:]
    /// Segments and clips that couldn't be rendered, and why.
    private(set) var trackErrors: [Int: String] = [:]
    private(set) var pairErrors: [Int: String] = [:]
    private(set) var mixChunks: [MixChunk] = []
    private(set) var mixDone = false
    /// Each mix segment's waveform, by track number, as it renders.
    private(set) var waves: [Int: Waveform] = [:]
    /// The loud level of each band across the set's waveforms, so they share one scale.
    private(set) var waveRef: (low: Float, mid: Float, high: Float) = (0.05, 0.05, 0.05)
    /// Every kept cue of every track in the mix, at its mix seconds.
    private(set) var marks: [MixMark] = []
    /// Each track's beats at their mix seconds (bar: the first beat of a bar), by track number.
    private(set) var grid: [Int: [GridBeat]] = [:]
    private(set) var rendering = false
    private(set) var lastWrite: String?

    @ObservationIgnored private var renderTask: Task<Void, Never>?
    @ObservationIgnored private var planTask: Task<Void, Never>?
    @ObservationIgnored let renderer: SetRenderer

    /// A library that isn't in master.db (the demo): nothing can be written.
    let preloaded: SetLibrary?
    var writable: Bool { preloaded == nil && draft == nil }

    /// How a draft was built, and the tracks taken out of it since (never added back).
    struct Draft {
        var options: SetBuilder.Options
        /// The playlist the added tracks come from (nil: the whole library), and its tracks.
        var poolName: String?
        var pool: Set<String>?
        var rejected: Set<String> = []
        var result: SetBuilder.Result?
    }

    private(set) var draft: Draft?

    init(app: AppModel, player: Player, playlist: String, renderer: SetRenderer, library: SetLibrary? = nil) {
        self.app = app
        self.player = player
        self.playlist = playlist
        self.renderer = renderer
        preloaded = library
    }

    /// A draft built around options.picks, previewed at the set tempo.
    init(app: AppModel, player: Player, draft: Draft, renderer: SetRenderer) {
        self.app = app
        self.player = player
        self.playlist = "Draft set"
        self.renderer = renderer
        preloaded = nil
        self.draft = draft
        if let b = draft.options.bpm {
            bpm = min(max((b * 10).rounded() / 10, Self.bpmRange.lowerBound), Self.bpmRange.upperBound)
        }
    }

    /// Each track's energy (yours, else Mixed In Key's), by playlist number.
    func energy(for no: Int) -> Energy.Level? { record(for: no).flatMap(Energy.level) }

    /// Whether track no is one of the draft's picks.
    func isPick(_ no: Int) -> Bool {
        guard let d = draft, let t = tracks.first(where: { $0.no == no }) else { return false }
        return d.options.picks.contains(t.id)
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
        } else if var d = draft {
            let (opts, poolName, rejected) = (d.options, d.poolName, d.rejected)
            let built = await app.run { () -> (SetLibrary, SetBuilder.Result, Set<String>?) in
                let (recs, cache) = try SetLibrary.loadAll(p)
                var o = opts
                if let pn = poolName {
                    o.pool = Set(try RekordboxDB.readCopy(p.masterDB).sql.loadPlaylist(pn).tracks.map(\.id))
                }
                o.exclude.formUnion(rejected)
                let res = try SetBuilder.build(o, recs, cache)
                let pl = Playlist(name: name, intelligent: false, tracks: res.order)
                return (SetLibrary(playlist: pl, recs: recs, cache: cache), res, o.pool)
            }
            if let (lib, res, pool) = built {
                library = lib
                (d.result, d.pool) = (res, pool)
                draft = d
                if res.slots.count < d.options.length {
                    app.error =
                        "Only \(res.slots.count) of \(d.options.length) tracks fit: too few tracks in the pool are "
                        + "within the tempo range."
                }
            }
        } else {
            library = await app.run { try SetLibrary.load(p, playlist: name) }
        }
        tracks = library?.playlist.tracks ?? []
        loading = false
        await replan()
    }

    /// Builds the draft again from its picks, leaving out every track taken out so far.
    func rebuild() async {
        guard draft != nil else { return }
        player.stop()
        await load()
    }

    /// Swaps track no for the best other track there, keeping every other track in place. The
    /// track taken out isn't added back, so re-rolling again goes down the candidates.
    func reroll(_ no: Int) async {
        guard var d = draft, let lib = library, let i = tracks.firstIndex(where: { $0.no == no }) else { return }
        d.rejected.insert(tracks[i].id)
        draft = d
        var fixed: [Int: String] = [:]
        for (k, t) in tracks.enumerated() where k != i { fixed[k] = t.id }
        let anchors = fixed
        let n = tracks.count
        let bpm = d.options.bpm ?? d.result?.bpm ?? self.bpm
        let (arc, pool, range) = (d.options.arc, d.pool, d.options.tempoRange)
        let exclude = d.rejected.union(d.options.exclude)
        let r = await app.run {
            SetBuilder.refill(
                anchors: anchors, length: n, bpm: bpm, arc: arc, pool: pool, exclude: exclude, tempoRange: range,
                lib.recs, lib.cache)
        }
        guard let r else { return }
        guard r.slots.count == n else {
            app.error = "No other track fits there: every candidate in range is in the set or was taken out."
            return
        }
        let s = r.slots[i]
        let next = (tracks.map(\.no).max() ?? 0) + 1
        tracks[i] = PlaylistTrack(no: next, id: s.id, title: s.title, bpm: s.bpm, key: s.key)
        if selection == no { selection = next }
        await replan()
    }

    /// Takes track no out of the draft (and keeps it out of rebuilds and re-rolls).
    func remove(_ no: Int) {
        guard var d = draft, let i = tracks.firstIndex(where: { $0.no == no }) else { return }
        if !d.options.picks.contains(tracks[i].id) { d.rejected.insert(tracks[i].id) }
        d.options.picks.removeAll { $0 == tracks[i].id }
        draft = d
        tracks.remove(at: i)
        Task { await replan() }
    }

    /// Saves the draft as a new playlist in master.db (Rekordbox quit); true when it was.
    func saveAsPlaylist(_ name: String, folder: String = "") async -> Bool {
        guard draft != nil, app.canWrite() else { return false }
        let p = app.paths
        let ids = tracks.map(\.id)
        let recs = library?.recs ?? [:]
        let st = await app.run {
            try PlaylistWriter.safeWrite(p, name: name, folder: folder, contentIDs: ids, recs: recs)
        }
        guard st != nil else { return false }
        await app.refresh()
        return true
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
            self.marks = Self.marks(plan)
            self.grid = Self.grid(plan)
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
        waves = [:]
        waveRef = (0.05, 0.05, 0.05)
        player.resetMix()
        rendering = true
        let renderer = self.renderer
        renderTask = Task { [weak self] in
            do {
                for try await ev in renderer.render(plan, waveforms: true) {
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
        case .trackWave(let n, let w):
            waves[n] = w
            let l = w.level(0.97)
            waveRef = (max(waveRef.low, l.low), max(waveRef.mid, l.mid), max(waveRef.high, l.high))
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

/// One beat of a track in the mix.
struct GridBeat {
    var at: Double
    var bar: Bool
}

/// A cue in the full-set mix: track n's cue at mix second `at`.
struct MixMark: Identifiable {
    var n: Int
    var mark: CueMark
    var at: Double
    var id: String { "\(n)|\(mark.id)|\(at)" }
}

extension SetModel {
    static func marks(_ plan: PreviewPlan) -> [MixMark] {
        plan.mix.filter { !$0.missing && $0.rec != nil }.flatMap { s in
            CueMarks.of(s.rec!, plan.actions[s.n - 1]).filter(\.kept).flatMap { m in
                CueMarks.mixTimes(s, m.t).map { MixMark(n: s.n, mark: m, at: $0) }
            }
        }
    }

    static func grid(_ plan: PreviewPlan) -> [Int: [GridBeat]] {
        var out: [Int: [GridBeat]] = [:]
        for s in plan.mix where !s.missing {
            guard let t = s.rec else { continue }
            out[s.n] = t.beats.indices.flatMap { k in
                CueMarks.mixTimes(s, t.beats[k]).map { GridBeat(at: $0, bar: k < t.bnum.count && t.bnum[k] == 1) }
            }
            .sorted { $0.at < $1.at }
        }
        return out
    }

    /// Where transition i's clip sits in the mix: the mix second of the clip's start, and its
    /// end (the clip is the same A -> B mix, lined up on A reaching G).
    func clipWindow(_ i: Int) -> (start: Double, end: Double)? {
        guard let plan, i < plan.pairs.count, let clip = plan.pairs[i].clip, let ga = clip.a.gT,
            let mixG = plan.mix.first(where: { $0.n == i + 1 })?.gT
        else { return nil }
        let off = mixG - ga
        let dur = clips[i].map { Double($0.frames) / Mix.sampleRate } ?? clip.b.end
        return (off, off + dur)
    }

    /// The mix second the player is at: the mix's position, or the clip's mapped into the mix.
    var playheadInMix: Double? {
        switch player.source {
        case .mix: return player.position
        case .clip(let i): return clipWindow(i).map { $0.start + player.position }
        case .track, nil: return nil
        }
    }

    /// The cues of the track with playlist number no, as the write leaves them.
    func cueMarks(for no: Int) -> [CueMark] {
        guard let t = record(for: no) else { return [] }
        return CueMarks.of(t, action(for: no))
    }
}
