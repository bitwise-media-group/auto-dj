// Copyright 2026 BitWise Media Group Ltd
// SPDX-License-Identifier: MIT

import AutoDJKit
import Foundation

/// Renders the set's previews in parallel and writes the bundle (set-list page, clips, full
/// mix), with a progress line on stderr.
func previewBundle(_ res: SetResult, dir: String, mix: Bool, bpm: Double, format: String, paths: Paths) async throws
    -> String
{
    guard let fmt = ExportFormat(rawValue: format) else {
        throw AutoDJError("--format must be one of: \(ExportFormat.allCases.map(\.rawValue).joined(separator: ", "))")
    }
    let plan = PreviewPlan(res, bpm: bpm)
    let renderer = SetRenderer(cacheDir: paths.renderDir)
    let total = plan.pairs.filter { $0.clip != nil }.count + (mix ? plan.mix.filter { !$0.missing }.count : 0)
    let done = Counter()
    let t0 = Date()
    let page = try await PreviewExport.build(plan, renderer: renderer, to: dir, mix: mix, format: fmt) { ev in
        switch ev {
        case .trackFailed(let n, let e):
            FileHandle.standardError.write(Data("\n  ! track \(n) left silent in the mix: \(e)\n".utf8))
        case .pairFailed(let i, let e):
            FileHandle.standardError.write(Data("\n  ! no clip for transition \(i + 1): \(e)\n".utf8))
        case .pairReady, .mixChunk:
            let n = done.next()
            FileHandle.standardError.write(Data("\r  rendered \(n)/\(total)".utf8))
        default: break
        }
    }
    FileHandle.standardError.write(
        Data(String(format: "\r  rendered %d/%d in %.1f s\n", total, total, Date().timeIntervalSince(t0)).utf8))
    return page

    final class Counter: @unchecked Sendable {
        let lock = NSLock()
        var n = 0
        func next() -> Int {
            lock.lock()
            defer { lock.unlock() }
            n += 1
            return n
        }
    }
}
