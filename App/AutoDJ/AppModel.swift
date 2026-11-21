// Copyright 2026 BitWise Media Group Ltd
// SPDX-License-Identifier: MIT

import AppKit
import AutoDJKit
import Foundation
import Observation

/// The app's shared state: where the library is, whether Rekordbox is running, the library's
/// status, and the last error.
@MainActor @Observable
final class AppModel {
    var rbDir: String {
        didSet { UserDefaults.standard.set(rbDir, forKey: "rbDir") }
    }
    var workDir: String {
        didSet { UserDefaults.standard.set(workDir, forKey: "workDir") }
    }

    /// Rekordbox is running: every write is disabled.
    private(set) var rekordboxRunning = Rekordbox.isRunning()
    var error: String?

    private(set) var status: LibraryStatus?
    private(set) var playlists: [Playlist] = []
    private(set) var histories: [History] = []
    /// Every track and its feature analysis (kept here so it outlives the Library view).
    let library = LibraryModel()
    /// Tracks' waveforms, decoded as the timelines need them.
    let waves = WaveCache()

    struct LibraryStatus {
        var tracks: Int
        var categories: [(String, Int)]
        var featureFiles: Int
    }

    var paths: Paths { Paths(rbDir: Config.expandUser(rbDir), workDir: Config.expandUser(workDir)) }

    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init() {
        rbDir = UserDefaults.standard.string(forKey: "rbDir") ?? Config.defaultRBDir
        workDir = UserDefaults.standard.string(forKey: "workDir") ?? Config.defaultWorkDir
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(
                nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.rekordboxRunning = Rekordbox.isRunning() }
                })
        }
    }

    /// Runs work off the main actor, reporting a failure in the error banner.
    func run<T: Sendable>(_ work: @Sendable @escaping () async throws -> T) async -> T? {
        do {
            return try await Task.detached(priority: .userInitiated) { try await work() }.value
        } catch is CancellationError {
            return nil
        } catch {
            self.error = "\(error)"
            return nil
        }
    }

    /// Rereads the library's status, playlists and histories.
    func refresh() async {
        let p = paths
        library.loading = true
        defer { library.loading = false }
        let r = await run { () -> (LibraryStatus, [Playlist], [History], [LibraryTrack]) in
            let rb = try RekordboxDB.readCopy(p.masterDB)
            let (tr, cues) = try rb.sql.loadTracksAndCues()
            let auto = try Ledger.load(p.ledger)
            var counts: [String: Int] = [:]
            var order: [String] = []
            for r in tr {
                let c = Category.classify(rating: r.rating, cues: cues[r.id] ?? [], auto: auto.contains(r.id))
                if counts[c] == nil { order.append(c) }
                counts[c, default: 0] += 1
            }
            let files = ((try? FileManager.default.contentsOfDirectory(atPath: p.featureDir)) ?? [])
                .filter { $0.hasSuffix(".f32.lzfse") }.count
            let cats = order.map { ($0, counts[$0]!) }.sorted { $0.1 > $1.1 }
            return (
                LibraryStatus(tracks: tr.count, categories: cats, featureFiles: files), try rb.sql.listPlaylists(),
                try rb.sql.listHistories(), try Library.tracks(rb.sql, featureDir: p.featureDir)
            )
        }
        if let r {
            (status, playlists, histories) = (r.0, r.1, r.2)
            library.tracks = r.3
        }
        rekordboxRunning = Rekordbox.isRunning()
    }

    /// Rechecks Rekordbox right before a write (the notifications can lag).
    func canWrite() -> Bool {
        rekordboxRunning = Rekordbox.isRunning()
        if rekordboxRunning { error = "Rekordbox is running. Quit it fully before writing." }
        return !rekordboxRunning
    }
}

/// The library's tracks, and analysing the features of those that need it, with per-track
/// progress.
@MainActor @Observable
final class LibraryModel {
    var tracks: [LibraryTrack] = [] {
        didSet { index = Dictionary(tracks.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a }) }
    }
    /// Reading the library.
    var loading = false
    private(set) var index: [String: Int] = [:]
    /// While analysing: each running track's progress, by ID.
    private(set) var progress: [String: Double] = [:]
    /// The tracks whose analysis failed, and why.
    private(set) var failed: [String: String] = [:]
    private(set) var task: Task<Void, Never>?

    var missing: [LibraryTrack] { tracks.filter { $0.analysis == .missing && failed[$0.id] == nil } }

    func status(_ id: String) -> TrackStatus {
        if let p = progress[id] { return .analysing(p) }
        if let e = failed[id] { return .failed(e) }
        return index[id].map { TrackStatus(tracks[$0].analysis) } ?? .unknown
    }

    /// Caches the features of every track that needs them.
    func analyse(_ app: AppModel) {
        let todo = tracks.filter { $0.analysis == .missing }
        guard task == nil, !todo.isEmpty else { return }
        let ids = todo.map(\.id)
        let paths = todo.map(\.path)
        let dir = app.paths.featureDir
        failed = [:]
        task = Task {
            let sink = ProgressSink()
            let poll = Task {
                while !Task.isCancelled {
                    take(sink, ids)
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
            _ = await app.run {
                try await Features.extractMany(
                    paths, featureDir: dir, workers: ProcessInfo.processInfo.activeProcessorCount,
                    onProgress: { sink.progress($0, $1) }, onDone: { sink.done($0, $1) })
            }
            poll.cancel()
            take(sink, ids)
            progress = [:]
            task = nil
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        progress = [:]
    }

    private func take(_ sink: ProgressSink, _ ids: [String]) {
        let (p, s) = sink.take()
        for (i, v) in p { progress[ids[i]] = v }
        for (i, st) in s {
            let id = ids[i]
            progress[id] = nil
            switch st {
            case .ok, .cached: if let k = index[id] { tracks[k].analysis = .analysed }
            case .error(let e): failed[id] = e
            }
        }
    }
}
