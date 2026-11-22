// Copyright 2026 BitWise Media Group Ltd
// SPDX-License-Identifier: MIT

import AppKit
import AutoDJKit
import SwiftUI

/// A track's feature analysis as the tables show it.
enum TrackStatus: Equatable {
    case analysing(Double)
    case missing
    case failed(String)
    case noAudio
    case analysed
    /// The library hasn't been read yet.
    case unknown

    init(_ a: LibraryTrack.Analysis) {
        switch a {
        case .analysed: self = .analysed
        case .missing: self = .missing
        case .noAudio: self = .noAudio
        }
    }

    /// Sort order: what needs attention first.
    var order: Int {
        switch self {
        case .analysing: 0
        case .failed: 1
        case .missing: 2
        case .noAudio: 3
        case .analysed: 4
        case .unknown: 5
        }
    }
}

/// One row of a track table.
struct TrackRowData: Identifiable {
    var id: String
    /// The play position in a history (nil in the library).
    var no: Int?
    var title: String
    var artist: String
    var year: Int
    var genre: String
    var bpm: Double
    var key: String
    var status: TrackStatus
    /// Your rating, else Mixed In Key's level halved (ADR 0021).
    var energy: Energy.Level?
    /// A cue plan's hot cue slots ("A"...), memory cue colours and flags.
    var hot: [String] = []
    var memory: [Int?] = []
    var flags: [String] = []
    /// The key on the Camelot wheel, parsed once (sorting by key compares it a lot).
    let camelot: Camelot?

    init(
        id: String, no: Int? = nil, title: String, artist: String, year: Int = 0, genre: String = "", bpm: Double,
        key: String, status: TrackStatus = .unknown
    ) {
        (self.id, self.no, self.title, self.artist, self.year, self.genre) = (id, no, title, artist, year, genre)
        (self.bpm, self.key, self.status, camelot) = (bpm, key, status, Camelot(key))
    }
}

enum TrackColumn: String, CaseIterable {
    case no, track, artist, year, genre, tempo, key, energy, cues, memory, flags, status

    /// The library's and histories' columns.
    static let library: [TrackColumn] = [.no, .track, .artist, .year, .genre, .tempo, .key, .energy, .status]

    var title: String {
        switch self {
        case .no: "#"
        case .track: "Track"
        case .artist: "Artist"
        case .year: "Year"
        case .genre: "Genre"
        case .tempo: "Tempo"
        case .key: "Key"
        case .energy: "Energy"
        case .cues: "Hot cues"
        case .memory: "Memory"
        case .flags: "Flags"
        case .status: "Status"
        }
    }

    /// The default width, or nil for the track title, which takes the space left over.
    var width: CGFloat? {
        switch self {
        case .no: 48
        case .track: nil
        case .artist: 220
        case .year: 70
        case .genre: 140
        case .tempo: 84
        case .key: 70
        case .energy: 84
        case .cues: 170
        case .memory: 120
        case .flags: 180
        case .status: 136
        }
    }

    /// The narrowest it can be resized to: its title in bold with the sort arrow on one line
    /// (and room for some text in the text columns).
    var minWidth: CGFloat {
        let font = NSFont.systemFont(ofSize: 10.5, weight: .bold)
        let w = (title.uppercased() as NSString).size(withAttributes: [.font: font, .kern: 0.8]).width
        let header = (w + 4 + 10 + 20 + 4).rounded(.up)  // title, gap, arrow, padding, slack
        switch self {
        case .track: return max(header, 140)
        case .artist, .genre: return max(header, 80)
        case .status: return max(header, 100)
        default: return header
        }
    }

    var trailing: Bool { self == .no || self == .year || self == .tempo || self == .energy }

    /// Whether a is before b, ascending; empty values sort last.
    func less(_ a: TrackRowData, _ b: TrackRowData) -> Bool {
        func text(_ x: String, _ y: String) -> Bool {
            if x.isEmpty != y.isEmpty { return !x.isEmpty }
            return x.localizedStandardCompare(y) == .orderedAscending
        }
        func num<T: Comparable & Numeric>(_ x: T, _ y: T) -> Bool {
            if (x == 0) != (y == 0) { return x != 0 }
            return x < y
        }
        switch self {
        case .no: return (a.no ?? 0) < (b.no ?? 0)
        case .track: return text(a.title, b.title)
        case .artist: return text(a.artist, b.artist)
        case .year: return num(a.year, b.year)
        case .genre: return text(a.genre, b.genre)
        case .tempo: return num(a.bpm, b.bpm)
        case .key:
            let (x, y) = (a.camelot, b.camelot)
            if (x == nil) != (y == nil) { return x != nil }
            guard let x, let y else { return false }
            return (x.n, x.letter) < (y.n, y.letter)
        case .energy: return num(a.energy?.stars ?? 0, b.energy?.stars ?? 0)
        case .cues: return (a.hot.count, a.hot.joined()) < (b.hot.count, b.hot.joined())
        case .memory: return a.memory.count < b.memory.count
        case .flags:
            if a.flags.count != b.flags.count { return a.flags.count > b.flags.count }  // most first
            return text(a.flags.joined(separator: ", "), b.flags.joined(separator: ", "))
        case .status: return a.status.order < b.status.order
        }
    }
}

/// The library / history track table on the deck screen: sortable headers (click to sort,
/// again to reverse), Camelot key chips coloured round the wheel, and each track's analysis.
struct TrackTable: View {
    let rows: [TrackRowData]
    var numbered = false
    /// The columns this table offers (those that don't fit are dropped).
    var available = TrackColumn.library
    /// The selected row, when rows can be selected.
    var selection: Binding<String?>?
    /// Space and Return on the selected row (e.g. preview it, pick it).
    var onSpace: ((String) -> Void)?
    var onReturn: ((String) -> Void)?
    /// The sort column and direction, kept per table ("library", "history", "plan") across
    /// sections and launches.
    @AppStorage private var sortRaw: String
    @AppStorage private var ascending: Bool
    @State private var width: CGFloat = 0
    /// The selection when the caller doesn't keep one.
    @State private var local: String?
    @FocusState private var focused: Bool
    /// Column widths set by dragging a header divider ("artist=240,genre=120"), shared by
    /// the library and history tables.
    @AppStorage("trackTableWidths") private var saved = ""
    /// The column being resized and its width when the drag began.
    @State private var resizing: (TrackColumn, CGFloat)?

    /// name keys the table's saved sort.
    init(
        _ name: String, rows: [TrackRowData], numbered: Bool = false, available: [TrackColumn] = TrackColumn.library,
        selection: Binding<String?>? = nil, onSpace: ((String) -> Void)? = nil, onReturn: ((String) -> Void)? = nil
    ) {
        (self.rows, self.numbered, self.available, self.selection) = (rows, numbered, available, selection)
        (self.onSpace, self.onReturn) = (onSpace, onReturn)
        _sortRaw = AppStorage(wrappedValue: "", "trackTable.\(name).sort")
        _ascending = AppStorage(wrappedValue: true, "trackTable.\(name).ascending")
    }

    var sort: TrackColumn? { TrackColumn(rawValue: sortRaw).flatMap { available.contains($0) ? $0 : nil } }

    var widths: [TrackColumn: CGFloat] {
        var out: [TrackColumn: CGFloat] = [:]
        for c in TrackColumn.allCases { if let w = c.width { out[c] = w } }
        for kv in saved.split(separator: ",") {
            let p = kv.split(separator: "=")
            if p.count == 2, let c = TrackColumn.allCases.first(where: { "\($0)" == p[0] }), c != .track,
                let w = Double(p[1])
            {
                out[c] = max(CGFloat(w), c.minWidth)
            }
        }
        return out
    }

    private func setWidth(_ c: TrackColumn, _ w: CGFloat?) {
        var ws = widths
        ws[c] = w ?? c.width
        saved = TrackColumn.allCases.compactMap { c in
            guard let w = ws[c], w != c.width else { return nil }
            return "\(c)=\(Int(w))"
        }.joined(separator: ",")
    }

    /// The columns that fit the table's width, dropping genre, then year, then artist.
    var columns: [TrackColumn] {
        let ws = widths
        var cs = available.filter { numbered || $0 != .no }
        func need() -> CGFloat { cs.reduce(CGFloat(cs.count - 1)) { $0 + (ws[$1] ?? $1.minWidth) } }
        for drop in [TrackColumn.genre, .year, .energy, .memory, .flags, .artist] where width > 0 && need() > width {
            cs.removeAll { $0 == drop }
        }
        return cs
    }

    var sorted: [TrackRowData] {
        let by = sort ?? (numbered ? .no : .track)
        return rows.sorted { a, b in
            if by.less(a, b) { return ascending }
            if by.less(b, a) { return !ascending }
            return TrackColumn.track.less(a, b)
        }
    }

    /// The selected row: the caller's selection when it passes one, else the table's own.
    var selected: String? { selection.map(\.wrappedValue) ?? local }

    func select(_ id: String?) {
        if let selection { selection.wrappedValue = id } else { local = id }
    }

    var body: some View {
        let order = sorted
        return VStack(spacing: 0) {
            header
            Rectangle().fill(Deck.line).frame(height: 1)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(order.enumerated()), id: \.element.id) { i, r in
                            TrackRow(
                                row: r, columns: columns, widths: widths, odd: !i.isMultiple(of: 2),
                                selected: selected == r.id
                            ) {
                                select(r.id)
                                focused = true
                            }
                            .id(r.id)
                        }
                    }
                }
                // the keyboard moves the selection while the table has focus (click a row)
                .focusable()
                .focused($focused)
                .focusEffectDisabled()
                .onKeyPress(keys: [.upArrow, .downArrow, .pageUp, .pageDown, .home, .end]) { k in
                    let ids = order.map(\.id)
                    guard !ids.isEmpty else { return .ignored }
                    let page = 12
                    let at = selected.flatMap { ids.firstIndex(of: $0) }
                    let to: Int =
                        switch k.key {
                        case .upArrow: at.map { $0 - 1 } ?? 0
                        case .downArrow: at.map { $0 + 1 } ?? 0
                        case .pageUp: (at ?? 0) - page
                        case .pageDown: (at ?? -1) + page
                        case .home: 0
                        default: ids.count - 1
                        }
                    let id = ids[min(max(to, 0), ids.count - 1)]
                    select(id)
                    proxy.scrollTo(id)
                    return .handled
                }
                .onKeyPress(.escape) {
                    focused = false
                    return .handled
                }
                .onKeyPress(.space) {
                    guard let s = selected, let onSpace else { return .ignored }
                    onSpace(s)
                    return .handled
                }
                .onKeyPress(.return) {
                    guard let s = selected, let onReturn else { return .ignored }
                    onReturn(s)
                    return .handled
                }
            }
        }
        .background(Deck.screen)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(focused ? Deck.low.opacity(0.8) : Deck.line, lineWidth: focused ? 1.5 : 1)
        )
        .environment(\.colorScheme, .dark)
        // measure the width on offer (not the columns' own), so narrow panes drop columns
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) {
            $0.size.width
        } action: {
            width = $0
        }
    }

    var header: some View {
        let ws = widths
        return HStack(spacing: 0) {
            ForEach(columns, id: \.self) { c in
                let active = c == (sort ?? (numbered ? .no : .track))
                Button {
                    if active { ascending.toggle() } else { (sortRaw, ascending) = (c.rawValue, true) }
                } label: {
                    HStack(spacing: 4) {
                        if c.trailing { Spacer(minLength: 0) }
                        Text(c.title.uppercased())
                            .font(.system(size: 10.5, weight: .bold, design: .rounded))
                            .tracking(0.8)
                            .lineLimit(1)
                            .fixedSize()
                        if active {
                            Image(systemName: ascending ? "chevron.up" : "chevron.down")
                                .font(.system(size: 8, weight: .heavy))
                        }
                        if !c.trailing { Spacer(minLength: 0) }
                    }
                    .foregroundStyle(active ? Deck.fg : Deck.dim)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 9)
                    .frame(maxHeight: .infinity)
                    .background(active ? Deck.padFace : .clear)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .cell(c, ws[c])
                if c != columns.last { divider(after: c).zIndex(1) }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .background(Deck.screen2)
    }

    /// A header divider that resizes the column to its left by dragging (or, right of the
    /// title, which fills the rest, the column to its right), and resets it on double-click.
    func divider(after c: TrackColumn) -> some View {
        let cs = columns
        let target = c == .track ? cs[cs.firstIndex(of: c)! + 1] : c
        let sign: CGFloat = c == .track ? -1 : 1
        let on = resizing?.0 == target
        return Rectangle()
            .fill(on ? Deck.fg.opacity(0.6) : Deck.line)
            .frame(width: 1)
            .padding(.vertical, on ? 0 : 6)
            .overlay {
                Color.clear
                    .frame(width: 9)
                    .contentShape(Rectangle())
                    .pointerStyle(.columnResize)
                    .onTapGesture(count: 2) { setWidth(target, nil) }
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { g in
                                let start = resizing?.1 ?? widths[target] ?? target.minWidth
                                if resizing == nil { resizing = (target, start) }
                                setWidth(target, max(start + sign * g.translation.width, target.minWidth).rounded())
                            }
                            .onEnded { _ in resizing = nil }
                    )
            }
    }
}

/// One table row. It keeps its own hover state, so hovering redraws just this row rather
/// than the whole (sorted) table.
struct TrackRow: View {
    let row: TrackRowData
    let columns: [TrackColumn]
    let widths: [TrackColumn: CGFloat]
    let odd: Bool
    var selected = false
    var select: (() -> Void)?
    @State private var hover = false

    var body: some View {
        HStack(spacing: 0) {
            ForEach(columns, id: \.self) { c in
                cell(c, row)
                    .padding(.horizontal, 10)
                    .cell(c, widths[c])
                if c != columns.last { Color.clear.frame(width: 1) }
            }
        }
        .padding(.vertical, 6)
        .overlay(alignment: .bottom) { Rectangle().fill(Deck.line.opacity(0.6)).frame(height: 1) }
        .background(selected ? Deck.low.opacity(0.32) : hover ? Deck.padFace : odd ? Deck.lane : Deck.screen)
        .overlay(alignment: .leading) { if selected { Rectangle().fill(Deck.low).frame(width: 3) } }
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { select?() }
    }

    @ViewBuilder func cell(_ c: TrackColumn, _ r: TrackRowData) -> some View {
        switch c {
        case .no:
            Text(r.no.map(String.init) ?? "").font(.system(.callout, design: .monospaced)).foregroundStyle(Deck.dim)
        case .track: Text(r.title).font(.system(size: 13, weight: .medium)).foregroundStyle(Deck.fg).lineLimit(1)
        case .artist: Text(r.artist.isEmpty ? "—" : r.artist).foregroundStyle(Deck.fg.opacity(0.8)).lineLimit(1)
        case .year:
            Text(r.year > 0 ? String(r.year) : "—").monospacedDigit().foregroundStyle(Deck.dim)
        case .genre: Text(r.genre.isEmpty ? "—" : r.genre).foregroundStyle(Deck.dim).lineLimit(1)
        case .tempo:
            Text(r.bpm > 0 ? tempo(r.bpm) : "—")
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(Deck.fg)
        case .key: KeyChip(key: r.key, camelot: r.camelot)
        case .energy: EnergyChip(energy: r.energy)
        case .status: StatusChip(status: r.status)
        case .cues:
            HStack(spacing: 3) {
                ForEach(r.hot, id: \.self) { PadBadge(slot: $0, size: 16, glow: false) }
            }
        case .memory:
            HStack(spacing: -4) {
                ForEach(Array(r.memory.prefix(6).enumerated()), id: \.offset) { _, c in
                    MemoryArrow(color: Deck.memory(c), size: 9)
                }
                if r.memory.count > 6 {
                    Text("+\(r.memory.count - 6)").font(.caption2).foregroundStyle(Deck.dim).padding(.leading, 6)
                }
            }
        case .flags:
            Text(r.flags.joined(separator: ", ")).font(.callout).foregroundStyle(Deck.mid).lineLimit(1)
                .help(r.flags.joined(separator: "\n"))
        }
    }

    func tempo(_ bpm: Double) -> String {
        let r = (bpm * 10).rounded() / 10
        return r == r.rounded() ? String(Int(r)) : String(format: "%.1f", r)
    }
}

extension View {
    /// Sizes a table cell for its column: its width, or (the title) the space left over.
    @ViewBuilder fileprivate func cell(_ c: TrackColumn, _ w: CGFloat?) -> some View {
        let align: Alignment = c.trailing ? .trailing : .leading
        if let w {
            frame(width: w, alignment: align)
        } else {
            frame(minWidth: c.minWidth, maxWidth: .infinity, alignment: align)
        }
    }
}

/// The track's Camelot key as a chip coloured by its place on the wheel (minor keys solid,
/// major keys outlined), the way DJ software colours keys.
struct KeyChip: View {
    let key: String
    let camelot: Camelot?

    var body: some View {
        if let c = camelot {
            let color = Deck.camelot(c)
            let minor = c.letter == "A"
            Text(String(format: "%02d%@", c.n, c.letter))
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(minor ? Deck.screen : color)
                .frame(width: 44)
                .padding(.vertical, 3)
                .background(minor ? color : color.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(color, lineWidth: minor ? 0 : 1.2))
                .help(key)
        } else {
            Text("—").foregroundStyle(Deck.dim)
        }
    }
}

/// The track's energy: your rating in stars, or Mixed In Key's level (halved, dimmed, "~").
struct EnergyChip: View {
    let energy: Energy.Level?

    var body: some View {
        if let e = energy {
            HStack(spacing: 3) {
                Text(e.label).font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                Image(systemName: e.source == .rating ? "star.fill" : "star.leadinghalf.filled")
                    .font(.system(size: 9))
            }
            .foregroundStyle(e.source == .rating ? Deck.fg : Deck.dim)
            .help(
                e.source == .rating ? "Your rating" : "Mixed In Key's energy level, halved (rate the track to set it)")
        } else {
            Text("—").foregroundStyle(Deck.dim)
        }
    }
}

/// Whether the track's features are cached, and if not why.
struct StatusChip: View {
    let status: TrackStatus

    var body: some View {
        switch status {
        case .analysed:
            label("Analysed", "checkmark.circle.fill", Deck.pad("E"), dim: true)
        case .missing:
            label("Needs analysis", "exclamationmark.triangle.fill", Deck.mid)
        case .noAudio:
            label("No audio file", "speaker.slash.fill", Deck.dim, dim: true)
                .help("The audio file isn't on this machine")
        case .failed(let e):
            label("Failed", "xmark.octagon.fill", Deck.needle).help(e)
        case .analysing(let p):
            HStack(spacing: 6) {
                ProgressView(value: p).progressViewStyle(.linear).tint(Deck.low).frame(maxWidth: 80)
                Text("\(Int(p * 100))%").font(.caption.monospacedDigit()).foregroundStyle(Deck.dim)
            }
        case .unknown:
            Text("—").foregroundStyle(Deck.dim)
        }
    }

    func label(_ text: String, _ icon: String, _ color: Color, dim: Bool = false) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 10, weight: .bold)).foregroundStyle(color)
            Text(text).font(.system(size: 11.5, weight: .medium)).foregroundStyle(dim ? Deck.dim : color)
        }
    }
}

extension Deck {
    /// A key's colour round the Camelot wheel: 1 aqua, then green, yellow, orange, red, pink,
    /// purple and blue back round to 12 cyan; majors a shade lighter than their relative minor.
    static func camelot(_ c: Camelot) -> Color {
        let hue = (165 - Double(c.n - 1) * 30 + 360).truncatingRemainder(dividingBy: 360) / 360
        return c.letter == "A"
            ? Color(hue: hue, saturation: 0.5, brightness: 0.95) : Color(hue: hue, saturation: 0.38, brightness: 1)
    }
}
