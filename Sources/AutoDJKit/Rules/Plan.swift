// Copyright 2026 BitWise Media Group Ltd
// SPDX-License-Identifier: MIT

import Foundation

/// Turns rule output into a concrete, reviewable write plan (port of internal/plan).
public enum CuePlan {
    /// The hot cue order the flags check.
    public static let order = ["IN", "BRIDGE", "DROP", "OUT", "EMERGENCY"]

    /// A planned hot cue. `loop` and `outMS` are set on EMERGENCY only.
    public struct HotCue: Codable, Sendable, Equatable, Hashable {
        public var kind: Int
        public var slot: String
        public var name: String
        public var beat: Int
        public var ms: Int
        public var loop: Int?
        public var outMS: Int?

        enum CodingKeys: String, CodingKey {
            case kind, slot, name, beat, ms, loop
            case outMS = "out_ms"
        }
    }

    /// A planned memory cue.
    public struct MemCue: Codable, Sendable, Equatable, Hashable {
        public var name: String
        public var beat: Int
        public var ms: Int
    }

    /// One track's plan.
    public struct Item: Codable, Sendable, Equatable, Identifiable {
        public var id: String
        public var title: String
        public var path: String
        public var bpm: Double
        public var nbeats: Int
        public var audio: Bool
        public var hot: [HotCue]
        public var mem: [MemCue]
        public var flags: [String]
    }

    /// Beat b's position in milliseconds (clamped to the grid).
    public static func ms(_ beats: [Double], _ b: Int) -> Int {
        Num.round(beats[min(max(b, 1), beats.count) - 1] * 1000)
    }

    /// Plans one track.
    public static func plan(_ t: Track, _ R: Rules) -> Item {
        let hot = CueRules.hotCues(t, R)
        let mem = CueRules.memoryCues(t, hot, R)
        let B = t.beats
        let nb = B.count
        var it = Item(
            id: t.id, title: t.title, path: t.path, bpm: t.bpm, nbeats: nb, audio: t.hasFB, hot: [],
            mem: [], flags: [])
        for hs in Config.hotTemplate {
            guard let b = hot[hs.name] else { continue }
            var c = HotCue(kind: Config.kind[hs.slot]!, slot: hs.slot, name: hs.name, beat: b, ms: ms(B, b))
            if hs.name == "EMERGENCY" {
                let end = b + Config.emergencyLoopBeats
                c.loop = Config.emergencyLoopBeats
                c.outMS = end <= nb ? ms(B, end) : Num.round((B[nb - 1] + 60 / t.bpm) * 1000)
            }
            it.hot.append(c)
        }
        it.mem.append(MemCue(name: "START", beat: mem.start, ms: ms(B, mem.start)))
        for b in mem.drops { it.mem.append(MemCue(name: "DROP", beat: b, ms: ms(B, b))) }
        if mem.bassSwap != 0 {
            it.mem.append(MemCue(name: "BASS SWAP", beat: mem.bassSwap, ms: ms(B, mem.bassSwap)))
        }
        if hot["BRIDGE"] == nil { it.flags.append("no bridge") }
        if mem.bassSwap == 0 { it.flags.append("no bass swap") }
        if !t.hasFB { it.flags.append("phrase analysis only") }
        let pos = order.compactMap { hot[$0] }
        if pos != pos.sorted() { it.flags.append("cue order") }
        return it
    }

    /// Plans every track whose category is in categories.
    public static func make(_ ts: [Track], _ categories: [String], _ R: Rules) -> [Item] {
        ts.filter { categories.contains($0.category) }.map { plan($0, R) }
    }

    /// Counts the flags (most common first, ties in first-seen order).
    public static func summary(_ p: [Item]) -> String {
        var counts: [String: Int] = [:]
        var seen: [String] = []
        var drops = 0
        for x in p {
            for f in x.flags {
                if counts[f] == nil { seen.append(f) }
                counts[f, default: 0] += 1
            }
            drops += x.mem.filter { $0.name == "DROP" }.count
        }
        let sorted = seen.enumerated().sorted {
            counts[$0.element]! != counts[$1.element]!
                ? counts[$0.element]! > counts[$1.element]! : $0.offset < $1.offset
        }.map(\.element)
        var lines = ["\(p.count) tracks planned"]
        lines += sorted.map { "  \($0): \(counts[$0]!)" }
        lines.append("  memory DROP cues: \(drops)")
        return lines.joined(separator: "\n")
    }

    public static func save(_ p: [Item], to path: String) throws { try JSONFile.write(p, to: path) }

    public static func load(_ path: String) throws -> [Item] { try JSONFile.read([Item].self, from: path) }

    /// The plan items as the cue writer takes them.
    public static func toDB(_ p: [Item]) -> [PlanTrack] {
        p.map { x in
            PlanTrack(
                id: x.id, title: x.title,
                hot: x.hot.map {
                    PlanHot(kind: $0.kind, name: $0.name, ms: $0.ms, loop: $0.loop ?? 0, outMS: $0.outMS ?? 0)
                },
                mem: x.mem.map { PlanMem(name: $0.name, ms: $0.ms) })
        }
    }
}
