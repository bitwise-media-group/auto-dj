// Copyright 2026 BitWise Media Group Ltd
// SPDX-License-Identifier: MIT

import Foundation

/// A JSON scalar for the pages' compact row arrays ([name, beat, seconds], …).
public enum JSONScalar: Encodable, Sendable, Equatable {
    case s(String)
    case i(Int)
    case d(Double)

    public func encode(to e: Encoder) throws {
        var c = e.singleValueContainer()
        switch self {
        case .s(let v): try c.encode(v)
        case .i(let v): try c.encode(v)
        case .d(let v): try c.encode(v)
        }
    }
}

/// Renders a plan as a self-contained HTML review page: an energy strip and cue markers per
/// track (port of internal/review).
public enum Review {
    /// One track as the page draws it.
    public struct Row: Encodable, Sendable {
        public var t: String
        public var a = ""
        public var bpm: Double
        public var nb: Int
        public var dur: Double
        public var h: [[JSONScalar]] = []
        public var m: [[JSONScalar]] = []
        public var ph: [[JSONScalar]] = []
        /// Bass and mid energy strips: one digit 0-9 per 4 beats.
        public var lo: String?
        public var md: String?
    }

    /// The energy strip of a normalised level: one digit 0-9 per 4 beats.
    public static func strip(_ lv: [Double]) -> String {
        let k = 4
        return (0..<lv.count / k).map { i in
            String(min(9, Int(Num.mean(lv[i * k..<(i + 1) * k]) * 9)))
        }.joined()
    }

    public static func row(_ t: Track, _ x: CuePlan.Item) -> Row {
        let nb = t.beats.count
        var r = Row(t: x.title, bpm: x.bpm, nb: nb, dur: Num.roundTo(t.beats[nb - 1], 1))
        if !t.path.hasPrefix("/contents_"), !t.path.isEmpty {
            let base = (t.path as NSString).lastPathComponent
            r.a = base.components(separatedBy: " - ").first ?? base
        }
        r.h = x.hot.map { [.s($0.name), .i($0.beat), .d(Num.roundTo(Double($0.ms) / 1000, 2))] }
        r.m = x.mem.map { [.s($0.name), .i($0.beat), .d(Num.roundTo(Double($0.ms) / 1000, 2))] }
        r.ph = t.phrases.map { [.i($0.beat), .s(String($0.label.prefix(1)))] }
        if t.hasFB {
            r.lo = strip(Track.normLevel(t.col(0)))
            r.md = strip(Track.normLevel(t.col(2)))
        }
        return r
    }

    /// The review page's rows for the plan, sorted by artist then title.
    public static func rows(_ ts: [Track], _ p: [CuePlan.Item]) -> [Row] {
        let byID = Dictionary(ts.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return p.compactMap { x in byID[x.id].map { row($0, x) } }.sorted {
            let (a, b) = ($0.a.lowercased(), $1.a.lowercased())
            return a != b ? a < b : $0.t.lowercased() < $1.t.lowercased()
        }
    }

    /// JSON made safe to inline in a <script> element (no "</script>" or "<!--" inside).
    public static func scriptSafe(_ json: String) -> String {
        json.replacingOccurrences(of: "<", with: "\\u003c").replacingOccurrences(of: ">", with: "\\u003e")
            .replacingOccurrences(of: "&", with: "\\u0026")
    }

    /// Writes the review page for the plan to out.
    public static func render(_ ts: [Track], _ p: [CuePlan.Item], to out: String) throws -> String {
        let rows = rows(ts, p)
        let e = JSONEncoder()
        e.outputFormatting = [.withoutEscapingSlashes]
        let data = scriptSafe(String(decoding: try e.encode(rows), as: UTF8.self))
        let html = Templates.review.replacingOccurrences(of: "__DATA__", with: data)
            .replacingOccurrences(of: "__COUNT__", with: String(rows.count))
        try FileManager.default.createDirectory(
            atPath: (out as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data(html.utf8).write(to: URL(fileURLWithPath: out))
        return out
    }
}
