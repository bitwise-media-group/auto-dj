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
        let r = await run { () -> (LibraryStatus, [Playlist], [History]) in
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
                try rb.sql.listHistories()
            )
        }
        if let r { (status, playlists, histories) = r }
        rekordboxRunning = Rekordbox.isRunning()
    }

    /// Rechecks Rekordbox right before a write (the notifications can lag).
    func canWrite() -> Bool {
        rekordboxRunning = Rekordbox.isRunning()
        if rekordboxRunning { error = "Rekordbox is running. Quit it fully before writing." }
        return !rekordboxRunning
    }
}
