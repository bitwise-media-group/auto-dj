// Copyright 2026 BitWise Media Group Ltd
// SPDX-License-Identifier: MIT

import Foundation

/// A key on the Camelot wheel: number and letter (A minor, B major).
public struct Camelot: Sendable, Equatable, CustomStringConvertible {
    public var n: Int
    public var letter: String

    public var description: String { "\(n)\(letter)" }

    /// Note names (upper-cased) to pitch classes.
    static let notes = [
        "C": 0, "C#": 1, "DB": 1, "D": 2, "D#": 3, "EB": 3, "E": 4, "F": 5, "F#": 6, "GB": 6,
        "G": 7, "G#": 8, "AB": 8, "A": 9, "A#": 10, "BB": 10, "B": 11,
    ]

    /// The Camelot number of a minor key by tonic pitch class (8A = Am); a major key has its
    /// relative minor's number.
    static let minorCamelot = [9: 8, 4: 9, 11: 10, 6: 11, 1: 12, 8: 1, 3: 2, 10: 3, 5: 4, 0: 5, 7: 6, 2: 7]

    /// Parses 'F#m' / 'Abm' / 'Eb' / '9A'; nil for an unknown key.
    public init?(_ key: String) {
        let k = key.trimmingCharacters(in: .whitespaces)
        if k.isEmpty { return nil }
        if let m = k.uppercased().wholeMatch(of: /(\d{1,2})([AB])/) {
            n = Int(m.1)!
            letter = String(m.2)
            return
        }
        guard let m = k.wholeMatch(of: /([A-Ga-g])([#b]?)\s*(m|min|minor)?/),
            let pc = Self.notes[(String(m.1) + String(m.2)).uppercased()]
        else { return nil }
        if m.3 != nil {
            n = Self.minorCamelot[pc]!
            letter = "A"
        } else {
            n = Self.minorCamelot[(pc + 9) % 12]!  // major: same number as its relative minor
            letter = "B"
        }
    }
}

/// Key moves and the suggested order (port of internal/setlist/keys.go).
public enum Keys {
    /// A key move: harmonic or not, a description and a cost.
    public struct Move: Sendable, Equatable {
        public var ok: Bool
        public var desc: String
        public var cost: Int
    }

    static func signed(_ d: Int) -> String { d >= 0 ? "+\(d)" : "\(d)" }

    /// Whether mixing from key a into key b is harmonic. Mixed In Key's harmonic chart: same
    /// key, Camelot +-1, relative major/minor (cost 0); energy boost +-2 semitones (Camelot +-2,
    /// cost 1) and +-1 semitone (Camelot +-7, cost 2).
    public static func move(_ a: String, _ b: String) -> Move {
        guard let ca = Camelot(a), let cb = Camelot(b) else { return Move(ok: true, desc: "key unknown", cost: 1) }
        var d = ((cb.n - ca.n) % 12 + 12) % 12
        if d > 6 { d -= 12 }
        if ca.letter == cb.letter {
            switch abs(d) {
            case 0: return Move(ok: true, desc: "same key", cost: 0)
            case 1: return Move(ok: true, desc: "Camelot \(signed(d))", cost: 0)
            case 2: return Move(ok: true, desc: "\(signed(d)) semitones (energy boost)", cost: 1)
            case 5: return Move(ok: true, desc: (d == -5 ? "+1" : "-1") + " semitone (energy boost)", cost: 2)
            default: return Move(ok: false, desc: "clash (Camelot \(signed(d)))", cost: 100)
            }
        }
        if d == 0 { return Move(ok: true, desc: "relative major/minor", cost: 0) }
        return Move(ok: false, desc: "clash (\(ca) -> \(cb))", cost: 100)
    }

    /// What `suggestOrder` needs per track.
    public struct Item: Sendable {
        public var key: String
        public var bpm: Double

        public init(key: String, bpm: Double) {
            self.key = key
            self.bpm = bpm
        }
    }

    /// The cheapest path through all tracks (Held-Karp DP up to 14 tracks, local search above).
    /// Cost = key-move cost (clash 100, energy boost 1-2) + 0.02 per BPM of tempo jump + 0.5 for
    /// every pair of neighbours that isn't already next to each other in your order, so the
    /// suggestion changes as little as possible. Returns the order and its total key cost.
    public static func suggestOrder(_ items: [Item], keepFirst: Bool) -> (order: [Int], keyCost: Int) {
        let n = items.count
        func keyCost(_ o: [Int]) -> Int {
            zip(o, o.dropFirst()).reduce(0) { $0 + move(items[$1.0].key, items[$1.1].key).cost }
        }
        if n <= 2 {
            let o = Array(0..<n)
            return (o, keyCost(o))
        }
        var costs = [Double](repeating: 0, count: n * n)
        for i in 0..<n {
            for j in 0..<n {
                var v = Double(move(items[i].key, items[j].key).cost) + 0.02 * abs(items[i].bpm - items[j].bpm)
                if j != i + 1 { v += 0.5 }  // keep your existing neighbours where possible
                costs[i * n + j] = v
            }
        }
        let c = { (i: Int, j: Int) in costs[i * n + j] }
        let order = n > 14 ? localSearch(n, c, keepFirst) : heldKarp(n, c, keepFirst)
        return (order, keyCost(order))
    }

    /// The exact cheapest path through all n tracks (from track 0 when keepFirst; starting
    /// elsewhere costs 0.5).
    static func heldKarp(_ n: Int, _ c: (Int, Int) -> Double, _ keepFirst: Bool) -> [Int] {
        let size = 1 << n
        var dp = [Double](repeating: .infinity, count: size * n)
        var parent = [Int](repeating: -1, count: size * n)
        for s in 0..<n {
            if s == 0 { dp[(1 << s) * n + s] = 0 } else if !keepFirst { dp[(1 << s) * n + s] = 0.5 }
        }
        for mask in 0..<size {
            for j in 0..<n {
                let v = dp[mask * n + j]
                if v == .infinity || (mask >> j) & 1 == 0 { continue }
                for nxt in 0..<n where (mask >> nxt) & 1 == 0 {
                    let nm = mask | 1 << nxt
                    let cost = v + c(j, nxt)
                    if cost < dp[nm * n + nxt] {
                        dp[nm * n + nxt] = cost
                        parent[nm * n + nxt] = j
                    }
                }
            }
        }
        let full = size - 1
        var end = 0
        for j in 1..<n where dp[full * n + j] < dp[full * n + end] { end = j }
        var rev: [Int] = []
        var mask = full
        var cur = end
        while cur != -1 {
            rev.append(cur)
            let prev = parent[mask * n + cur]
            mask ^= 1 << cur
            cur = prev
        }
        return rev.reversed()
    }

    /// Improves your order by moving one track at a time.
    static func localSearch(_ n: Int, _ c: (Int, Int) -> Double, _ keepFirst: Bool) -> [Int] {
        var order = Array(0..<n)
        func cost(_ o: [Int]) -> Double {
            zip(o, o.dropFirst()).reduce(0) { $0 + c($1.0, $1.1) } + (o[0] != 0 ? 0.5 : 0)
        }
        var best = cost(order)
        let start = keepFirst ? 1 : 0
        var improved = true
        while improved {
            improved = false
            for i in start..<n {
                for j in start..<n where i != j {
                    var o = order
                    let x = o.remove(at: i)
                    o.insert(x, at: j)
                    let v = cost(o)
                    if v < best - 1e-9 {
                        (order, best, improved) = (o, v, true)
                    }
                }
            }
        }
        return order
    }

    /// The key move between order[i] and order[j].
    public struct Check: Sendable, Equatable {
        public var i: Int
        public var j: Int
        public var move: Move
    }

    /// The key move between each pair of neighbours.
    public static func checkOrder(_ order: [PlaylistTrack]) -> [Check] {
        zip(order.indices, order.indices.dropFirst()).map { i, j in
            Check(i: i, j: j, move: move(order[i].key, order[j].key))
        }
    }
}
