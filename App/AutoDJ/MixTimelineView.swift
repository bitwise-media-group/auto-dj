// Copyright 2026 BitWise Media Group Ltd
// SPDX-License-Identifier: MIT

import AppKit
import AutoDJKit
import SwiftUI

/// The whole set on a CDJ-style screen: two deck lanes (the tracks alternate between them, as
/// they would across two players) with each track's 3-band waveform as it renders, its hot cue
/// pads above and its memory cue arrows, a time ruler, the red playhead, and an overview of the
/// whole set below with the zoomed window. Click to play from there; drag, scroll or swipe to
/// move; pinch, ⌥-scroll or −/+ to zoom. A transition preview shows as a highlighted window
/// with the playhead running through it.
struct MixTimelineView: View {
    let model: SetModel
    @Environment(Player.self) private var player
    /// Seconds shown across the lanes; 0 shows the whole set.
    @State private var span = 0.0
    @State private var t0 = 0.0
    @State private var follow = true
    @State private var width: CGFloat = 1
    @State private var hover: Double?
    @State private var drag: (t0: Double, moved: Bool)?
    @State private var pinch: (span: Double, anchor: Double, x: CGFloat)?
    @State private var glide: Task<Void, Never>?

    static let minSpan = 8.0

    var dur: Double { max(model.plan?.duration ?? 0, 1) }
    var visible: Double { span <= 0 ? dur : min(span, dur) }
    var viewport: Viewport {
        Viewport(t0: min(max(t0, 0), max(dur - visible, 0)), span: visible, width: width)
    }

    var body: some View {
        VStack(spacing: 8) {
            toolbar
            GeometryReader { geo in
                let lanesH = geo.size.height - Overview.height - 6
                VStack(spacing: 6) {
                    ZStack(alignment: .topLeading) {
                        TimelineLanes(model: model, vp: viewport)
                        PlayheadLayer(model: model, vp: viewport, hover: hover)
                    }
                    .frame(height: lanesH)
                    .contentShape(Rectangle())
                    .gesture(lanesDrag(lanesH))
                    .simultaneousGesture(magnify)
                    .onContinuousHover { phase in
                        if case .active(let p) = phase { hover = viewport.t(p.x) } else { hover = nil }
                    }
                    .background(ScrollCatcher { dx, dy, zoom, x in scrolled(dx, dy, zoom: zoom, at: x) })
                    Overview(model: model, vp: viewport, dur: dur) { t in
                        follow = false
                        t0 = t - visible / 2
                    }
                    .frame(height: Overview.height)
                }
            }
            .onGeometryChange(for: CGFloat.self) {
                $0.size.width
            } action: {
                width = max($0, 1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Deck.screen)
        .environment(\.colorScheme, .dark)
        .onChange(of: model.playheadInMix) { _, ph in
            // a transition preview is fitted to the view instead (below)
            guard follow, player.playing, player.source == .mix, let ph, visible < dur else { return }
            t0 = ph - visible / 2
        }
        .onChange(of: clipPlaying) { _, i in if let i { fit(clip: i) } }
        .onChange(of: model.plan?.duration) { _, _ in if span >= dur { span = 0 } }
        .onAppear { (span, t0, follow) = model.timelineView }
        .onChange(of: span) { _, v in model.timelineView.span = v }
        .onChange(of: t0) { _, v in model.timelineView.t0 = v }
        .onChange(of: follow) { _, v in model.timelineView.follow = v }
    }

    // MARK: toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            let playingMix = player.source == .mix && player.playing
            Button {
                if playingMix { player.pause() } else { player.playMix() }
            } label: {
                Image(systemName: playingMix ? "pause.fill" : "play.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Deck.fg)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Deck.padFace))
                    .overlay(Circle().strokeBorder(playingMix ? Deck.pad("E") : Deck.line, lineWidth: 1.5))
            }
            .buttonStyle(.plain)
            .disabled(model.renderedSeconds <= 0)
            .help("Play the full set (from the playhead)")
            VStack(alignment: .leading, spacing: 1) {
                Text("FULL SET").font(.system(size: 10, weight: .bold, design: .rounded)).tracking(1.2)
                    .foregroundStyle(Deck.dim)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(clock(model.playheadInMix ?? 0)).font(
                        .system(size: 17, weight: .semibold, design: .monospaced)
                    )
                    .foregroundStyle(Deck.fg)
                    Text("/ \(hms(model.plan?.duration ?? 0))").font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Deck.dim)
                }
            }
            if case .clip(let i) = player.source {
                Tag(text: "PREVIEW \(i + 1) → \(i + 2)", color: Deck.pad("B"))
            }
            if !model.mixDone && (model.plan?.duration ?? 0) > 0 {
                Tag(text: "RENDERED \(hms(model.renderedSeconds))", color: Deck.dim)
            }
            Spacer()
            Legend()
            Divider().frame(height: 18)
            HStack(spacing: 2) {
                DeckButton(icon: "minus.magnifyingglass", help: "Zoom out (⌥-scroll or pinch)") { zoom(1.6) }
                    .disabled(visible >= dur)
                DeckButton(icon: "plus.magnifyingglass", help: "Zoom in (⌥-scroll or pinch)") { zoom(1 / 1.6) }
                    .disabled(visible <= Self.minSpan)
                DeckButton(label: "FIT", help: "Show the whole set") { span = 0 }.disabled(span == 0)
                DeckButton(icon: "scope", help: "Keep the playhead in view while playing", on: follow) {
                    follow.toggle()
                }
            }
        }
    }

    // MARK: interaction

    private func lanesDrag(_ h: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { g in
                if drag == nil { drag = (viewport.t0, false) }
                guard var d = drag else { return }
                if abs(g.translation.width) > 3 { d.moved = true }
                drag = d
                if d.moved, visible < dur {
                    glide?.cancel()
                    follow = false
                    t0 = d.t0 - Double(g.translation.width / width) * visible
                }
            }
            .onEnded { g in
                defer { drag = nil }
                guard drag?.moved != true else { return }
                tapped(g.location, h)
            }
    }

    private var magnify: some Gesture {
        MagnifyGesture()
            .onChanged { g in
                if pinch == nil {
                    pinch = (visible, viewport.t(g.startLocation.x), g.startLocation.x)
                }
                guard let p = pinch else { return }
                setSpan(p.span / g.magnification, anchor: p.anchor, at: p.x)
            }
            .onEnded { _ in pinch = nil }
    }

    /// Plays from the click (up to the rendered edge) and selects the track under it.
    private func tapped(_ p: CGPoint, _ h: CGFloat) {
        let t = viewport.t(p.x)
        let layout = LaneLayout(size: CGSize(width: width, height: h))
        if let lane = layout.lane(at: p.y),
            let s = TimelineLanes.segs(model).enumerated().first(where: {
                $0.offset % 2 == lane && $0.element.start <= t && t <= $0.element.end
            })?.element, s.n - 1 < model.tracks.count
        {
            model.selection = model.tracks[s.n - 1].no
        }
        guard model.renderedSeconds > 0 else { return }
        follow = true
        player.playMix(from: min(max(t, 0), model.renderedSeconds))
    }

    private func scrolled(_ dx: CGFloat, _ dy: CGFloat, zoom: Bool, at x: CGFloat) {
        glide?.cancel()
        if zoom {
            let anchor = viewport.t(x)
            setSpan(visible * exp(Double(dy) * 0.01), anchor: anchor, at: x)
            return
        }
        guard visible < dur else { return }
        let d = abs(dx) > abs(dy) ? dx : dy
        follow = false
        t0 = viewport.t0 - Double(d / width) * visible
    }

    /// The transition whose preview is playing.
    private var clipPlaying: Int? {
        if player.playing, case .clip(let i) = player.source { i } else { nil }
    }

    /// Zooms to transition i's preview, with a little room either side.
    private func fit(clip i: Int) {
        guard let w = model.clipWindow(i) else { return }
        let pad = max((w.end - w.start) * 0.06, 1)
        let s = min(max(w.end - w.start + 2 * pad, Self.minSpan), dur)
        glide(span: s, t0: (w.start + w.end) / 2 - s / 2)
    }

    /// Eases the view to span seconds from t0 (zooming on a log scale, so it feels even).
    private func glide(span s1: Double, t0 a1: Double) {
        let (s0, a0) = (visible, viewport.t0)
        glide?.cancel()
        glide = Task { @MainActor in
            let n = 20
            for k in 1...n {
                let x = Double(k) / Double(n)
                let e = x < 0.5 ? 2 * x * x : 1 - pow(-2 * x + 2, 2) / 2
                let s = exp(log(s0) + (log(s1) - log(s0)) * e)
                span = s >= dur - 1e-6 ? 0 : s
                t0 = a0 + (a1 - a0) * e
                try? await Task.sleep(for: .milliseconds(16))
                if Task.isCancelled { return }
            }
        }
    }

    /// Zooms by factor f around the playhead when it's in view, else the middle.
    private func zoom(_ f: Double) {
        let vp = viewport
        var anchor = vp.t0 + vp.span / 2
        if let ph = model.playheadInMix, vp.t0 <= ph && ph <= vp.t0 + vp.span { anchor = ph }
        setSpan(visible * f, anchor: anchor, at: vp.x(anchor))
    }

    /// Shows s seconds with mix second anchor staying at x.
    private func setSpan(_ s: Double, anchor: Double, at x: CGFloat) {
        glide?.cancel()
        let s = min(max(s, Self.minSpan), dur)
        span = s >= dur ? 0 : s
        t0 = anchor - Double(x / width) * s
    }

    func clock(_ s: Double) -> String {
        let t = max(s, 0)
        return hms(t) + String(format: ".%d", Int(t * 10) % 10)
    }
}

/// The visible stretch of the mix: mix seconds <-> x.
struct Viewport: Equatable {
    var t0: Double
    var span: Double
    var width: CGFloat

    func x(_ t: Double) -> CGFloat { CGFloat((t - t0) / span) * width }
    func t(_ x: CGFloat) -> Double { t0 + Double(x / width) * span }
    var t1: Double { t0 + span }
}

/// The lanes' rows: the time ruler, then per deck a cue strip (hot cue pads over memory cue
/// arrows) above its waveform.
struct LaneLayout {
    static let ruler: CGFloat = 18
    static let strip: CGFloat = 24
    static let gap: CGFloat = 6

    var size: CGSize
    /// How many deck lanes: two for a set, one for a single track.
    var decks = 2

    var rulerRect: CGRect { CGRect(x: 0, y: 0, width: size.width, height: Self.ruler) }
    var waveH: CGFloat {
        let n = CGFloat(decks)
        return max((size.height - Self.ruler - n * Self.strip - (n - 1) * Self.gap) / n, 12)
    }

    func strip(_ k: Int) -> CGRect {
        CGRect(
            x: 0, y: Self.ruler + CGFloat(k) * (Self.strip + waveH + Self.gap), width: size.width, height: Self.strip)
    }

    func wave(_ k: Int) -> CGRect {
        CGRect(x: 0, y: strip(k).maxY, width: size.width, height: waveH)
    }

    /// The deck lane at y (its strip or waveform).
    func lane(at y: CGFloat) -> Int? {
        (0..<decks).first { strip($0).minY <= y && y <= wave($0).maxY }
    }
}

/// The ruler, both deck lanes, every track's waveform, title and cues (everything that
/// doesn't move with the playhead).
struct TimelineLanes: View {
    let model: SetModel
    let vp: Viewport

    static func segs(_ m: SetModel) -> [Seg] { m.plan?.mix.filter { !$0.missing } ?? [] }

    var body: some View {
        // read here so Observation redraws on these, not on the player
        let segs = Self.segs(model)
        let waves = model.waves
        let ref = model.waveRef
        let marks = model.marks
        let grid = model.grid
        let rendered = model.renderedSeconds
        let dur = model.plan?.duration ?? 0
        let errors = model.trackErrors
        let selected = model.selection.flatMap { no in model.tracks.firstIndex { $0.no == no } }.map { $0 + 1 }
        Canvas { ctx, size in
            let L = LaneLayout(size: size)
            Ruler.draw(&ctx, vp, L.rulerRect)
            for k in 0..<2 {
                let w = L.wave(k)
                ctx.fill(Path(roundedRect: w, cornerRadius: 4), with: .color(Deck.lane))
                var mid = Path()
                mid.move(to: CGPoint(x: 0, y: w.midY))
                mid.addLine(to: CGPoint(x: w.maxX, y: w.midY))
                ctx.stroke(mid, with: .color(Deck.line), lineWidth: 0.5)
            }
            var lane: [Int: Int] = [:]
            for (k, s) in segs.enumerated() {
                lane[s.n] = k % 2
                guard s.end >= vp.t0, s.start <= vp.t1 else { continue }
                let w = L.wave(k % 2)
                let r = CGRect(
                    x: vp.x(s.start), y: w.minY, width: max(vp.x(s.end) - vp.x(s.start), 1), height: w.height)
                let box = Path(roundedRect: r, cornerRadius: 4)
                ctx.fill(box, with: .color(errors[s.n] != nil ? Color.red.opacity(0.15) : Deck.screen2))
                if let wave = waves[s.n] {
                    Waves.draw(&ctx, wave, ref, vp, r)
                    BeatGrid.draw(&ctx, grid[s.n] ?? [], vp, r)
                } else {
                    var hatch = ctx
                    hatch.clip(to: box)
                    hatch.fill(Waves.hatch(r), with: .color(Deck.line.opacity(0.6)))
                }
                ctx.stroke(
                    box, with: .color(selected == s.n ? Deck.fg.opacity(0.9) : Deck.line),
                    lineWidth: selected == s.n ? 1.5 : 1)
                // the title, kept in view while the track is
                var label = ctx
                label.clip(to: Path(r.insetBy(dx: 2, dy: 0)))
                let title =
                    Text("\(s.n)  ").font(.system(size: 10, weight: .heavy, design: .rounded))
                    .foregroundColor(Deck.dim)
                    + Text(s.title).font(.system(size: 10, weight: .semibold)).foregroundColor(Deck.fg)
                let res = label.resolve(title)
                let ts = res.measure(in: CGSize(width: 600, height: 20))
                let lx = min(max(r.minX, 0) + 5, max(r.maxX - ts.width - 9, r.minX + 5))
                let chip = CGRect(x: lx - 4, y: r.minY + 3, width: ts.width + 8, height: ts.height + 2)
                label.fill(Path(roundedRect: chip, cornerRadius: 3), with: .color(Deck.screen.opacity(0.72)))
                label.draw(res, at: CGPoint(x: lx, y: chip.midY), anchor: .leading)
            }
            // bass swaps: across both decks while they overlap
            for s in segs {
                guard let sw = s.swapT, sw >= vp.t0, sw <= vp.t1 else { continue }
                var p = Path()
                p.move(to: CGPoint(x: vp.x(sw), y: L.wave(0).minY))
                p.addLine(to: CGPoint(x: vp.x(sw), y: L.wave(1).maxY))
                ctx.stroke(
                    p, with: .color(Deck.memory(2).opacity(s.estimatedSwap ? 0.35 : 0.8)),
                    style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
            Cues.draw(&ctx, marks, lane, vp, L)
            // not rendered yet
            if rendered < dur, vp.x(rendered) < size.width {
                let x = max(vp.x(rendered), 0)
                let r = CGRect(x: x, y: L.strip(0).minY, width: size.width - x, height: size.height - L.strip(0).minY)
                ctx.fill(Path(r), with: .color(Deck.screen.opacity(0.45)))
                if rendered > 0 {
                    var edge = Path()
                    edge.move(to: CGPoint(x: x, y: r.minY))
                    edge.addLine(to: CGPoint(x: x, y: r.maxY))
                    ctx.stroke(
                        edge, with: .color(Deck.dim.opacity(0.8)), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
                }
            }
        }
    }
}

/// The time ruler: labelled ticks at a step that suits the zoom.
enum Ruler {
    static let steps: [Double] = [1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800]

    static func draw(_ ctx: inout GraphicsContext, _ vp: Viewport, _ r: CGRect) {
        let step = steps.first { CGFloat($0 / vp.span) * vp.width >= 70 } ?? 3600
        let minor = step / 5
        var t = (vp.t0 / minor).rounded(.down) * minor
        var ticks = Path()
        var majors = Path()
        while t <= vp.t1 {
            let x = vp.x(t)
            let major = abs((t / step).rounded() * step - t) < 1e-6
            if major {
                majors.move(to: CGPoint(x: x, y: r.maxY - 7))
                majors.addLine(to: CGPoint(x: x, y: r.maxY))
                if t >= 0 {
                    ctx.draw(
                        Text(hms(t)).font(.system(size: 9, design: .monospaced)).foregroundColor(Deck.dim),
                        at: CGPoint(x: x + 3, y: r.minY + 6), anchor: .leading)
                }
            } else {
                ticks.move(to: CGPoint(x: x, y: r.maxY - 3))
                ticks.addLine(to: CGPoint(x: x, y: r.maxY))
            }
            t += minor
        }
        ctx.stroke(ticks, with: .color(Deck.line), lineWidth: 1)
        ctx.stroke(majors, with: .color(Deck.dim.opacity(0.7)), lineWidth: 1)
    }
}

/// A CDJ's beat grid when zoomed in far enough to read it: ticks along the waveform's top
/// and bottom edges for each beat, longer and brighter on the first beat of each bar.
enum BeatGrid {
    static func draw(_ ctx: inout GraphicsContext, _ beats: [GridBeat], _ vp: Viewport, _ r: CGRect) {
        guard beats.count > 1 else { return }
        let pxPerBeat = vp.x(beats[1].at) - vp.x(beats[0].at)
        guard pxPerBeat >= 3 else { return }
        var beat = Path()
        var bar = Path()
        for b in beats where b.at >= vp.t0 && b.at <= vp.t1 {
            let x = vp.x(b.at)
            guard x >= r.minX, x <= r.maxX, b.bar || pxPerBeat >= 7 else { continue }
            let len: CGFloat = b.bar ? 7 : 4
            if b.bar {
                bar.move(to: CGPoint(x: x, y: r.minY))
                bar.addLine(to: CGPoint(x: x, y: r.minY + len))
                bar.move(to: CGPoint(x: x, y: r.maxY - len))
                bar.addLine(to: CGPoint(x: x, y: r.maxY))
            } else {
                beat.move(to: CGPoint(x: x, y: r.minY))
                beat.addLine(to: CGPoint(x: x, y: r.minY + len))
                beat.move(to: CGPoint(x: x, y: r.maxY - len))
                beat.addLine(to: CGPoint(x: x, y: r.maxY))
            }
        }
        ctx.stroke(beat, with: .color(Deck.fg.opacity(0.35)), lineWidth: 1)
        ctx.stroke(bar, with: .color(Deck.needle.opacity(0.85)), lineWidth: 1.5)
    }
}

/// Rekordbox's 3-band waveform, mirrored about the lane's middle: lows behind, mids, then highs.
enum Waves {
    typealias Bands = (low: Float, mid: Float, high: Float)

    /// How tall each band draws at its set-wide loud level: lows outermost, highs innermost.
    static let weight: Bands = (1, 0.72, 0.42)

    static func draw(
        _ ctx: inout GraphicsContext, _ w: Waveform, _ ref: Bands, _ vp: Viewport, _ r: CGRect, step: CGFloat = 1
    ) {
        var paths = [Path(), Path(), Path()]
        let half = r.height / 2 - 2
        // Columns sit on a grid of mix time, not of screen pixels: scrolling (following the
        // playhead) slides the same columns along instead of re-binning them every frame,
        // which made the peaks jump about.
        let dt = Double(step / vp.width) * vp.span
        let end = min(r.maxX, vp.width)
        var k = (vp.t(max(r.minX, 0)) / dt).rounded(.down)
        while true {
            let x = vp.x(k * dt)
            guard x < end else { break }
            let p = w.mean(k * dt, (k + 1) * dt)
            for (b, v) in heights(p, ref).enumerated() where v > 0.004 {
                let y = CGFloat(v) * half
                paths[b].addRect(CGRect(x: x, y: r.midY - y, width: step, height: 2 * y))
            }
            k += 1
        }
        ctx.fill(paths[0], with: .color(Deck.low))
        ctx.fill(paths[1], with: .color(Deck.mid))
        ctx.fill(paths[2], with: .color(Deck.high))
    }

    /// Each band's height (0...1) against the set's loud levels.
    static func heights(_ p: Bands, _ ref: Bands) -> [Float] {
        func h(_ v: Float, _ r: Float, _ w: Float) -> Float { min(powf(v / max(r, 1e-4), 0.85), 1.08) * w }
        return [h(p.low, ref.low, weight.low), h(p.mid, ref.mid, weight.mid), h(p.high, ref.high, weight.high)]
    }

    /// Diagonal stripes where a track is still rendering.
    static func hatch(_ r: CGRect) -> Path {
        var p = Path()
        var x = r.minX - r.height
        while x < r.maxX {
            p.move(to: CGPoint(x: x, y: r.maxY))
            p.addLine(to: CGPoint(x: x + r.height, y: r.minY))
            p.addLine(to: CGPoint(x: x + r.height + 3, y: r.minY))
            p.addLine(to: CGPoint(x: x + 3, y: r.maxY))
            p.closeSubpath()
            x += 9
        }
        return p
    }
}

/// Hot cue pads (a lettered square in the pad's colour, a line down through the waveform) and
/// memory cue arrows, with names where there's room.
enum Cues {
    static let pad: CGFloat = 14

    static func draw(
        _ ctx: inout GraphicsContext, _ marks: [MixMark], _ lane: [Int: Int], _ vp: Viewport, _ L: LaneLayout
    ) {
        for k in 0..<L.decks {
            let strip = L.strip(k)
            let wave = L.wave(k)
            let mine = marks.filter { lane[$0.n] == k && $0.at >= vp.t0 - 60 && $0.at <= vp.t1 + 1 }
            let hot = mine.filter { $0.mark.slot != nil }.sorted { $0.at < $1.at }
            let mem = mine.filter { $0.mark.slot == nil }.sorted { $0.at < $1.at }
            // memory cues: an arrow at the strip's foot pointing into the waveform
            for (j, m) in mem.enumerated() {
                let x = vp.x(m.at)
                let c = Deck.color(m.mark)
                var tri = Path()
                tri.move(to: CGPoint(x: x - 5, y: strip.maxY - 8))
                tri.addLine(to: CGPoint(x: x + 5, y: strip.maxY - 8))
                tri.addLine(to: CGPoint(x: x, y: strip.maxY - 1))
                tri.closeSubpath()
                ctx.fill(tri, with: .color(c))
                var tick = Path()
                tick.move(to: CGPoint(x: x, y: wave.minY))
                tick.addLine(to: CGPoint(x: x, y: wave.minY + 5))
                ctx.stroke(tick, with: .color(c.opacity(0.8)), lineWidth: 1)
                let next = j + 1 < mem.count ? vp.x(mem[j + 1].at) : .infinity
                if x >= 0 {
                    label(
                        &ctx, m.mark.name, x: x + 7, y: strip.maxY - 4.5, room: next - x - 12, size: 8.5,
                        color: Deck.dim)
                }
            }
            // hot cues: the pad flag, its line through the waveform
            for (j, m) in hot.enumerated() {
                let x = vp.x(m.at)
                let slot = m.mark.slot!
                let c = Deck.pad(slot)
                var line = Path()
                line.move(to: CGPoint(x: x, y: strip.minY + 1))
                line.addLine(to: CGPoint(x: x, y: wave.maxY))
                ctx.stroke(line, with: .color(c.opacity(0.75)), lineWidth: 1)
                let r = CGRect(x: x, y: strip.minY + 1, width: pad, height: pad)
                let box = Path(roundedRect: r.insetBy(dx: 0.75, dy: 0.75), cornerRadius: 3)
                var glow = ctx
                glow.addFilter(.shadow(color: c.opacity(0.6), radius: 3))
                glow.fill(box, with: .color(Deck.padFace))
                ctx.fill(box, with: .color(c.opacity(0.22)))
                ctx.stroke(box, with: .color(c), lineWidth: 1.5)
                ctx.draw(
                    Text(slot).font(.system(size: 9, weight: .heavy, design: .rounded)).foregroundColor(c),
                    at: CGPoint(x: r.midX, y: r.midY))
                let next = j + 1 < hot.count ? vp.x(hot[j + 1].at) : .infinity
                if x >= 0 {
                    label(
                        &ctx, m.mark.name, x: r.maxX + 4, y: r.midY, room: next - r.maxX - 8, size: 9.5, color: Deck.fg)
                }
            }
        }
    }

    /// Draws name at (x, y) when it fits in room.
    static func label(
        _ ctx: inout GraphicsContext, _ name: String, x: CGFloat, y: CGFloat, room: CGFloat, size: CGFloat,
        color: Color
    ) {
        guard room > 16, !name.isEmpty else { return }
        let t = ctx.resolve(Text(name).font(.system(size: size, weight: .semibold)).foregroundColor(color))
        guard t.measure(in: CGSize(width: 1000, height: 40)).width <= room else { return }
        ctx.draw(t, at: CGPoint(x: x, y: y), anchor: .leading)
    }
}

/// The playhead, the hover line and a playing transition preview's window (everything that
/// moves with the player).
struct PlayheadLayer: View {
    let model: SetModel
    let vp: Viewport
    let hover: Double?
    @Environment(Player.self) private var player

    var body: some View {
        let ph = model.playheadInMix
        let window: (start: Double, end: Double, i: Int)? =
            if case .clip(let i) = player.source, let w = model.clipWindow(i) { (w.start, w.end, i) } else { nil }
        Canvas { ctx, size in
            let L = LaneLayout(size: size)
            let top = L.strip(0).minY
            if let w = window {
                let r = CGRect(x: vp.x(w.start), y: top, width: vp.x(w.end) - vp.x(w.start), height: size.height - top)
                let c = Deck.pad("B")
                ctx.fill(Path(r), with: .color(c.opacity(0.08)))
                for x in [r.minX, r.maxX] {
                    var p = Path()
                    p.move(to: CGPoint(x: x, y: r.minY))
                    p.addLine(to: CGPoint(x: x, y: r.maxY))
                    ctx.stroke(p, with: .color(c.opacity(0.9)), lineWidth: 1.5)
                }
                // a bar along the ruler's foot; the toolbar names the preview
                let band = CGRect(x: r.minX, y: L.rulerRect.maxY - 4, width: r.width, height: 4)
                ctx.fill(Path(roundedRect: band, cornerRadius: 2), with: .color(c.opacity(0.9)))
            }
            if let h = hover {
                let x = vp.x(h)
                var p = Path()
                p.move(to: CGPoint(x: x, y: top))
                p.addLine(to: CGPoint(x: x, y: size.height))
                ctx.stroke(p, with: .color(Deck.fg.opacity(0.25)), lineWidth: 1)
                let t = ctx.resolve(
                    Text(hms(max(h, 0))).font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundColor(Deck.screen))
                let s = t.measure(in: CGSize(width: 200, height: 20))
                let r = CGRect(x: min(x + 3, size.width - s.width - 8), y: 2, width: s.width + 6, height: s.height + 1)
                ctx.fill(Path(roundedRect: r, cornerRadius: 3), with: .color(Deck.fg.opacity(0.85)))
                ctx.draw(t, at: CGPoint(x: r.midX, y: r.midY))
            }
            if let ph, ph >= vp.t0, ph <= vp.t1 {
                let x = vp.x(ph)
                var glow = ctx
                glow.addFilter(.shadow(color: Deck.needle.opacity(0.8), radius: 4))
                var p = Path()
                p.move(to: CGPoint(x: x, y: 6))
                p.addLine(to: CGPoint(x: x, y: size.height))
                glow.stroke(p, with: .color(Deck.needle), lineWidth: 2)
                var tri = Path()
                tri.move(to: CGPoint(x: x - 6, y: 0))
                tri.addLine(to: CGPoint(x: x + 6, y: 0))
                tri.addLine(to: CGPoint(x: x, y: 8))
                tri.closeSubpath()
                glow.fill(tri, with: .color(Deck.needle))
            }
        }
        .allowsHitTesting(false)
    }
}

/// The whole set in one strip, like a CDJ's overview waveform: every track's waveform, the hot
/// cues as ticks, the zoomed window, the playhead. Click or drag to move the window.
struct Overview: View {
    static let height: CGFloat = 30
    let model: SetModel
    let vp: Viewport
    let dur: Double
    let moveTo: (Double) -> Void

    var body: some View {
        GeometryReader { geo in
            let all = Viewport(t0: 0, span: dur, width: geo.size.width)
            ZStack {
                OverviewWaves(model: model, all: all)
                OverviewTop(model: model, all: all, vp: vp)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { moveTo(all.t($0.location.x)) })
        }
    }
}

/// The overview's waveforms and hot cue ticks (redrawn only as tracks render).
struct OverviewWaves: View {
    let model: SetModel
    let all: Viewport

    var body: some View {
        let waves = Array(model.waves.values)
        let ref = model.waveRef
        let marks = model.marks.filter { $0.mark.slot != nil }
        let rendered = model.renderedSeconds
        let dur = all.span
        Canvas { ctx, size in
            let r = CGRect(origin: .zero, size: size)
            ctx.fill(Path(roundedRect: r, cornerRadius: 4), with: .color(Deck.screen2))
            var paths = [Path(), Path(), Path()]
            let half = size.height / 2 - 3
            for x in stride(from: 0, to: size.width, by: 1) {
                let t0 = all.t(x)
                let t1 = all.t(x + 1)
                var p: (low: Float, mid: Float, high: Float) = (0, 0, 0)
                for w in waves where w.start < t1 && w.end > t0 {
                    let q = w.mean(t0, t1)
                    p = (max(p.low, q.low), max(p.mid, q.mid), max(p.high, q.high))
                }
                for (k, v) in Waves.heights(p, ref).enumerated()
                where v > 0.01 {
                    let y = CGFloat(v) * half
                    paths[k].addRect(CGRect(x: x, y: r.midY + 1.5 - y, width: 1, height: 2 * y))
                }
            }
            ctx.fill(paths[0], with: .color(Deck.low.opacity(0.85)))
            ctx.fill(paths[1], with: .color(Deck.mid.opacity(0.85)))
            ctx.fill(paths[2], with: .color(Deck.high.opacity(0.85)))
            for m in marks {
                let x = all.x(m.at)
                ctx.fill(Path(CGRect(x: x - 1, y: 0, width: 2, height: 4)), with: .color(Deck.pad(m.mark.slot!)))
            }
            if rendered < dur {
                let x = all.x(rendered)
                ctx.fill(
                    Path(CGRect(x: x, y: 0, width: size.width - x, height: size.height)),
                    with: .color(Deck.screen.opacity(0.5)))
            }
            ctx.stroke(Path(roundedRect: r, cornerRadius: 4), with: .color(Deck.line), lineWidth: 1)
        }
    }
}

/// The overview's zoomed window and playhead.
struct OverviewTop: View {
    let model: SetModel
    let all: Viewport
    let vp: Viewport

    var body: some View {
        let ph = model.playheadInMix
        Canvas { ctx, size in
            if vp.span < all.span - 0.01 {
                let r = CGRect(
                    x: all.x(vp.t0), y: 0.5, width: max(all.x(vp.t1) - all.x(vp.t0), 2), height: size.height - 1)
                ctx.fill(Path(roundedRect: r, cornerRadius: 3), with: .color(Deck.fg.opacity(0.08)))
                ctx.stroke(Path(roundedRect: r, cornerRadius: 3), with: .color(Deck.fg.opacity(0.75)), lineWidth: 1)
            }
            if let ph {
                let x = all.x(ph)
                ctx.fill(Path(CGRect(x: x - 1, y: 0, width: 2, height: size.height)), with: .color(Deck.needle))
            }
        }
        .allowsHitTesting(false)
    }
}

/// What the lanes' marks mean.
struct Legend: View {
    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 4) {
                PadBadge(slot: "E", size: 13)
                Text("hot cue").foregroundStyle(Deck.dim)
            }
            HStack(spacing: 2) {
                MemoryArrow(color: Deck.memory(2), size: 9).frame(width: 12)
                Text("memory cue").foregroundStyle(Deck.dim)
            }
            HStack(spacing: 4) {
                Rectangle().fill(Deck.memory(2)).frame(width: 1, height: 12)
                Text("bass swap").foregroundStyle(Deck.dim)
            }
            HStack(spacing: 3) {
                ForEach([Deck.low, Deck.mid, Deck.high], id: \.self) { c in
                    RoundedRectangle(cornerRadius: 1).fill(c).frame(width: 4, height: 10)
                }
                Text("low · mid · high").foregroundStyle(Deck.dim)
            }
        }
        .font(.system(size: 10))
        .lineLimit(1)
        .fixedSize()
    }
}

/// A small tag in the toolbar.
struct Tag: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .bold, design: .rounded)).tracking(0.6)
            .foregroundStyle(color)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(color.opacity(0.5), lineWidth: 1))
    }
}

/// A square deck-style button.
struct DeckButton: View {
    var icon: String?
    var label: String?
    let help: String
    var on = false
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled

    init(icon: String? = nil, label: String? = nil, help: String, on: Bool = false, action: @escaping () -> Void) {
        self.icon = icon
        self.label = label
        self.help = help
        self.on = on
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Group {
                if let icon { Image(systemName: icon) } else { Text(label ?? "").tracking(0.5) }
            }
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .foregroundStyle(on ? Deck.pad("E") : Deck.fg.opacity(enabled ? 0.9 : 0.35))
            .frame(minWidth: 26, minHeight: 22)
            .padding(.horizontal, label == nil ? 0 : 4)
            .background(RoundedRectangle(cornerRadius: 5).fill(Deck.padFace))
            .overlay(
                RoundedRectangle(cornerRadius: 5).strokeBorder(
                    on ? Deck.pad("E").opacity(0.8) : Deck.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Reports scroll-wheel and trackpad scrolls over the view (dx, dy in points; zoom when ⌥ or
/// ⌘ is held; x in the view) instead of letting them through.
struct ScrollCatcher: NSViewRepresentable {
    let onScroll: (CGFloat, CGFloat, Bool, CGFloat) -> Void

    func makeNSView(context: Context) -> CatcherView {
        let v = CatcherView()
        v.onScroll = onScroll
        return v
    }

    func updateNSView(_ v: CatcherView, context: Context) { v.onScroll = onScroll }

    static func dismantleNSView(_ v: CatcherView, coordinator: ()) { v.stop() }

    final class CatcherView: NSView {
        var onScroll: ((CGFloat, CGFloat, Bool, CGFloat) -> Void)?
        private var monitor: Any?

        override var isFlipped: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] e in
                guard let self, e.window === self.window else { return e }
                let p = self.convert(e.locationInWindow, from: nil)
                guard self.bounds.contains(p) else { return e }
                let k: CGFloat = e.hasPreciseScrollingDeltas ? 1 : 12
                let zoom = !e.modifierFlags.intersection([.option, .command]).isEmpty
                self.onScroll?(e.scrollingDeltaX * k, e.scrollingDeltaY * k, zoom, p.x)
                return nil
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}

func hms(_ s: Double) -> String {
    let t = Int(max(s, 0))
    return t >= 3600
        ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
}
