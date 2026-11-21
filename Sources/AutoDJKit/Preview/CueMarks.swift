// Copyright 2026 BitWise Media Group Ltd
// SPDX-License-Identifier: MIT

import Foundation

/// One cue as the set editor shows it: a hot cue (its slot letter) or a memory cue, as the
/// track will have it once `set --write` applies the set's decisions.
public struct CueMark: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable, Hashable {
        /// A hot cue in slot "A"..."H".
        case hot(String)
        case memory
    }

    /// What the write does to it.
    public enum Change: String, Sendable {
        case existing, new, replace, rename, clear, remove
    }

    public var kind: Kind
    public var name: String
    /// Source seconds.
    public var t: Double
    /// 1-based beat on the track's grid.
    public var beat: Int
    public var change: Change
    /// The name it had, when the write renames or replaces it.
    public var was: String?
    /// Why the write removes it.
    public var why: String?

    public var id: String { "\(kind)|\(beat)|\(name)|\(change.rawValue)" }

    public var slot: String? {
        if case .hot(let s) = kind { return s }
        return nil
    }

    /// The memory cue colour index (`Config.memoryColor`: 0 pink ... 7 purple), nil when the
    /// set doesn't colour cues with this name.
    public var memoryColor: Int? { Config.memoryColor[Config.norm(name)] }

    /// Whether the cue is still there after the write.
    public var kept: Bool { change != .clear && change != .remove }
}

public enum CueMarks {
    /// The hot cue slot of djmdCue.Kind k ("A"..."H"), nil for a memory cue.
    public static func slot(_ k: Int) -> String? {
        k == 0 ? nil : Config.kind.first { $0.value == k }?.key
    }

    /// The 1-based beat nearest source second s on t's grid.
    public static func beat(_ t: Track, _ s: Double) -> Int {
        let B = t.beats
        guard !B.isEmpty else { return 1 }
        var lo = 0
        var hi = B.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if B[mid] < s { lo = mid + 1 } else { hi = mid }
        }
        if lo > 0 && s - B[lo - 1] < B[lo] - s { lo -= 1 }
        return lo + 1
    }

    /// Every hot and memory cue on t, sorted by time, as the write leaves them under act:
    /// existing cues (renamed as the write renames them), the planned E / G, the set's markers
    /// and the stale memory cues it removes.
    public static func of(_ t: Track, _ act: SetAction?) -> [CueMark] {
        var out: [CueMark] = []
        let markers = act?.markers ?? []
        let removals = act?.remove ?? []
        for c in t.cues {
            let b = beat(t, c.t)
            let to = Config.renameTo(c.name, hot: c.kind > 0)
            let name = to.isEmpty ? Config.strip(c.name) : to
            if let s = slot(c.kind) {
                if (s == "E" && act?.e != nil) || (s == "G" && act?.g != nil) { continue }
                out.append(
                    CueMark(
                        kind: .hot(s), name: name, t: c.t, beat: b, change: to.isEmpty ? .existing : .rename,
                        was: to.isEmpty ? nil : c.name))
                continue
            }
            if markers.contains(where: { $0.beat == b && Config.norm($0.name) == Config.norm(name) }) { continue }
            if let r = removals.first(where: { $0.beat == b && Config.norm($0.name) == Config.norm(c.name) }) {
                out.append(CueMark(kind: .memory, name: name, t: c.t, beat: b, change: .remove, why: r.why))
                continue
            }
            out.append(
                CueMark(
                    kind: .memory, name: name, t: c.t, beat: b, change: to.isEmpty ? .existing : .rename,
                    was: to.isEmpty ? nil : c.name))
        }
        for (s, slot) in [("E", act?.e), ("G", act?.g)] {
            guard let slot, !t.beats.isEmpty else { continue }
            let change: CueMark.Change =
                switch slot.status {
                case .existing: .existing
                case .new: .new
                case .replace: .replace
                case .clear: .clear
                }
            out.append(
                CueMark(
                    kind: .hot(s), name: slot.name, t: beatTime(t, slot.beat), beat: slot.beat, change: change,
                    was: slot.status == .replace ? slot.old?.name : nil))
        }
        for m in markers where !t.beats.isEmpty {
            let change: CueMark.Change =
                switch m.status {
                case .existing: .existing
                case .new: .new
                case .rename: .rename
                }
            out.append(CueMark(kind: .memory, name: m.name, t: beatTime(t, m.beat), beat: m.beat, change: change))
        }
        return out.sorted { ($0.t, $0.slot ?? "~") < ($1.t, $1.slot ?? "~") }
    }

    /// t's hot and memory cues, sorted by time, as applying its cue plan x leaves them
    /// (`CueWriter.applyPlan`): the generated cues it removes (Mixed In Key's "Energy N",
    /// Rekordbox's "CUE(Auto)", a START hot cue, and on a re-run of an unrated auto track the
    /// cues it wrote before), the planned hot cues (replacing what was in their slot), the
    /// memory cues the user named themselves, and the planned memory cues they don't already
    /// cover.
    public static func planned(_ t: Track, _ x: CuePlan.Item) -> [CueMark] {
        let rerun = t.category == "auto" && t.rating == 0
        func doomed(_ c: Cue) -> Bool {
            rerun ? CueWriter.ours.contains(c.name) : Category.replaceable(c.name, kind: c.kind)
        }
        var out: [CueMark] = []
        for c in t.cues {
            let b = beat(t, c.t)
            if doomed(c) {
                let replaced = c.kind > 0 && x.hot.contains { $0.kind == c.kind }
                if !replaced {
                    let why = rerun ? "replaced by the new plan" : "a generated cue"
                    out.append(
                        CueMark(
                            kind: slot(c.kind).map { .hot($0) } ?? .memory, name: c.name, t: c.t, beat: b,
                            change: .remove, why: why))
                }
                continue
            }
            guard c.kind == 0 || !x.hot.contains(where: { $0.kind == c.kind }) else { continue }
            out.append(
                CueMark(
                    kind: slot(c.kind).map { .hot($0) } ?? .memory, name: c.name, t: c.t, beat: b, change: .existing))
        }
        for h in x.hot {
            let old = t.cues.first { $0.kind == h.kind }
            out.append(
                CueMark(
                    kind: .hot(h.slot), name: h.name, t: Double(h.ms) / 1000, beat: h.beat,
                    change: old == nil ? .new : .replace, was: old?.name))
        }
        for m in x.mem {
            let s = Double(m.ms) / 1000
            let kept = t.cues.contains { $0.kind == 0 && !doomed($0) && $0.name == m.name && abs($0.t - s) <= 0.5 }
            if !kept { out.append(CueMark(kind: .memory, name: m.name, t: s, beat: m.beat, change: .new)) }
        }
        return out.sorted { ($0.t, $0.slot ?? "~") < ($1.t, $1.slot ?? "~") }
    }

    /// The mix seconds where source second src plays in s (once per pass through it), within
    /// the time s is in the mix.
    public static func mixTimes(_ s: Seg, _ src: Double) -> [Double] {
        var out: [Double] = []
        var after = 0.0
        while let q = s.route.play(src, after: after) {
            let m = s.clock.out(q)
            if m > s.end + 1e-3 { break }
            if m >= s.start - 1e-3 { out.append(m) }
            after = q + 1e-3
        }
        return out
    }
}
