// Copyright 2026 BitWise Media Group Ltd
// SPDX-License-Identifier: MIT

import AutoDJKit
import SwiftUI

/// Tracks' 3-band waveforms, decoded from their audio in the background and kept for the
/// session (a few hundred kB each).
@MainActor @Observable
final class WaveCache {
    private(set) var waves: [String: Waveform] = [:]
    private(set) var loading: Set<String> = []
    private(set) var failed: [String: String] = [:]

    /// path's waveform, starting its decode when it isn't known yet.
    func wave(_ path: String) -> Waveform? {
        if let w = waves[path] { return w }
        if !path.isEmpty, !loading.contains(path), failed[path] == nil { load(path) }
        return nil
    }

    private func load(_ path: String) {
        loading.insert(path)
        Task {
            let r = await Task.detached(priority: .userInitiated) { () -> Result<Waveform, Error> in
                Result {
                    let c = try AudioDecoder.decode(path, sampleRate: Mix.sampleRate, channels: 2)
                    return Waveform.of(Stereo(l: c[0], r: c[1]), start: 0)
                }
            }.value
            loading.remove(path)
            switch r {
            case .success(let w): waves[path] = w
            case .failure(let e): failed[path] = "\(e)"
            }
        }
    }
}

/// One track on the deck screen, like a CDJ's waveform display: the time ruler, its cues
/// (hot cue pads and memory cue arrows, as the write leaves them), the 3-band waveform and
/// the beat grid. Zooms (buttons, pinch, option-scroll) and scrolls (drag, scroll); a click
/// plays the track from there, with the red playhead following it.
struct TrackTimelineView: View {
    let title: String
    let track: Track?
    let marks: [CueMark]
    @Environment(AppModel.self) private var app
    @Environment(Player.self) private var player
    /// Seconds shown; 0 shows the whole track.
    @State private var span = 0.0
    @State private var t0 = 0.0
    @State private var width: CGFloat = 1
    @State private var hover: Double?
    @State private var drag: (t0: Double, moved: Bool)?
    @State private var pinch: (span: Double, anchor: Double, x: CGFloat)?

    static let minSpan = 4.0

    var wave: Waveform? { track.flatMap { app.waves.wave($0.path) } }

    var dur: Double {
        max(track?.length ?? 0, wave?.end ?? 0, track?.beats.last ?? 0, 1)
    }
    var visible: Double { span <= 0 ? dur : min(span, dur) }
    var viewport: Viewport {
        Viewport(t0: min(max(t0, 0), max(dur - visible, 0)), span: visible, width: width)
    }

    var body: some View {
        VStack(spacing: 8) {
            toolbar
            ZStack(alignment: .topLeading) {
                TrackLane(track: track, marks: marks, wave: wave, status: status, vp: viewport)
                if let hover {
                    HoverLine(t: hover, vp: viewport)
                }
                if let track {
                    TrackPlayhead(id: track.id, vp: viewport)
                }
            }
            .contentShape(Rectangle())
            .gesture(pan)
            .simultaneousGesture(magnify)
            .onContinuousHover { phase in
                if case .active(let p) = phase { hover = viewport.t(p.x) } else { hover = nil }
            }
            .background(ScrollCatcher { dx, dy, zoom, x in scrolled(dx, dy, zoom: zoom, at: x) })
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
        .onChange(of: track?.id) { _, _ in
            (span, t0) = (0, 0)
            if case .track = player.source, player.playing { player.stop() }
        }
        .onChange(of: playhead) { _, ph in
            // page along to keep the playhead in view when zoomed in
            guard let ph, player.playing, visible < dur, drag == nil else { return }
            let vp = viewport
            if ph < vp.t0 || ph > vp.t0 + vp.span * 0.92 { t0 = ph - vp.span * 0.08 }
        }
    }

    /// This track's playing position, when it's what the player plays.
    var playhead: Double? {
        guard let track, player.source == .track(track.id) else { return nil }
        return player.position
    }

    var playingThis: Bool { playhead != nil && player.playing }

    var hasAudio: Bool { track.map { !$0.path.isEmpty && FileManager.default.fileExists(atPath: $0.path) } ?? false }

    /// Plays the track from second t (or pauses / resumes with nil).
    func play(from t: Double? = nil) {
        guard let track, hasAudio else { return }
        if let t {
            player.playTrack(track.id, file: track.path, from: t)
        } else if playingThis {
            player.pause()
        } else if playhead != nil {
            player.toggle()
        } else {
            player.playTrack(track.id, file: track.path, from: 0)
        }
    }

    /// What the lane shows instead of a waveform.
    var status: String? {
        guard let track else { return "Select a track" }
        if wave != nil { return nil }
        if let e = app.waves.failed[track.path] { return "No waveform: \(e)" }
        if track.path.isEmpty || !FileManager.default.fileExists(atPath: track.path) { return "No audio file" }
        return "Reading the audio…"
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Button {
                play()
            } label: {
                Image(systemName: playingThis ? "pause.fill" : "play.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Deck.fg)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Deck.padFace))
                    .overlay(Circle().strokeBorder(playingThis ? Deck.needle : Deck.line, lineWidth: 1.5))
            }
            .buttonStyle(.plain)
            .disabled(!hasAudio)
            .help("Play the track (or click the waveform to play from there)")
            VStack(alignment: .leading, spacing: 1) {
                Text("TRACK").font(.system(size: 9, weight: .bold, design: .rounded)).tracking(1)
                    .foregroundStyle(Deck.dim)
                Text(track == nil ? "—" : title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Deck.fg)
                    .lineLimit(1)
            }
            if let t = track {
                Text(String(format: "%.1f BPM", t.bpm)).font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Deck.dim)
                Text((playhead.map { hms($0) + " / " } ?? "") + hms(dur))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(playhead == nil ? Deck.dim : Deck.fg)
            }
            Spacer()
            Legend()
            HStack(spacing: 4) {
                DeckButton(icon: "minus.magnifyingglass", help: "Zoom out") { zoom(1.6) }.disabled(span == 0)
                DeckButton(icon: "plus.magnifyingglass", help: "Zoom in (or pinch, or ⌥-scroll)") { zoom(1 / 1.6) }
                    .disabled(visible <= Self.minSpan)
                DeckButton(label: "FIT", help: "Show the whole track") { span = 0 }.disabled(span == 0)
            }
        }
    }

    /// Drag to scroll; a click (no drag) plays from there.
    private var pan: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { g in
                if drag == nil { drag = (viewport.t0, false) }
                guard var d = drag else { return }
                if abs(g.translation.width) > 3 { d.moved = true }
                drag = d
                if d.moved, visible < dur { t0 = d.t0 - Double(g.translation.width / width) * visible }
            }
            .onEnded { g in
                defer { drag = nil }
                guard drag?.moved != true, g.location.y > LaneLayout.ruler else { return }
                play(from: viewport.t(g.location.x))
            }
    }

    private var magnify: some Gesture {
        MagnifyGesture()
            .onChanged { g in
                if pinch == nil {
                    let x = g.startLocation.x
                    pinch = (visible, viewport.t(x), x)
                }
                guard let p = pinch else { return }
                setSpan(p.span / g.magnification, anchor: p.anchor, at: p.x)
            }
            .onEnded { _ in pinch = nil }
    }

    private func scrolled(_ dx: CGFloat, _ dy: CGFloat, zoom: Bool, at x: CGFloat) {
        if zoom {
            setSpan(visible * exp(Double(dy) * 0.01), anchor: viewport.t(x), at: x)
            return
        }
        guard visible < dur else { return }
        let d = abs(dx) > abs(dy) ? dx : dy
        t0 = viewport.t0 - Double(d / width) * visible
    }

    private func zoom(_ f: Double) {
        let vp = viewport
        let anchor = hover ?? vp.t0 + vp.span / 2
        setSpan(visible * f, anchor: anchor, at: vp.x(anchor))
    }

    private func setSpan(_ s: Double, anchor: Double, at x: CGFloat) {
        let s = min(max(s, Self.minSpan), dur)
        span = s >= dur ? 0 : s
        t0 = anchor - Double(x / width) * s
    }
}

/// The track's ruler, cue strip, waveform and beat grid (redrawn only when they change, not
/// on hover).
struct TrackLane: View {
    let track: Track?
    let marks: [CueMark]
    let wave: Waveform?
    let status: String?
    let vp: Viewport

    var body: some View {
        let ref = wave.map { w -> Waves.Bands in
            let l = w.level(0.97); return (l.low, l.mid, l.high)
        }
        let grid: [GridBeat] =
            (track?.beats.indices).map { ks in
                ks.map { GridBeat(at: track!.beats[$0], bar: $0 < track!.bnum.count && track!.bnum[$0] == 1) }
            } ?? []
        let shown = marks.filter(\.kept).map { MixMark(n: 0, mark: $0, at: $0.t) }
        Canvas { ctx, size in
            let L = LaneLayout(size: size, decks: 1)
            Ruler.draw(&ctx, vp, L.rulerRect)
            let r = L.wave(0)
            ctx.fill(Path(r), with: .color(Deck.lane))
            if let wave, let ref {
                Waves.draw(&ctx, wave, ref, vp, r)
                BeatGrid.draw(&ctx, grid, vp, r)
            } else if let status {
                ctx.draw(
                    Text(status).font(.system(size: 12)).foregroundColor(Deck.dim), at: CGPoint(x: r.midX, y: r.midY))
            }
            var mid = Path()
            mid.move(to: CGPoint(x: 0, y: r.midY))
            mid.addLine(to: CGPoint(x: size.width, y: r.midY))
            ctx.stroke(mid, with: .color(Deck.line), lineWidth: 1)
            Cues.draw(&ctx, shown, [0: 0], vp, L)
        }
    }
}

/// The hover line and its time.
struct HoverLine: View {
    let t: Double
    let vp: Viewport

    var body: some View {
        Canvas { ctx, size in
            let x = vp.x(t)
            var p = Path()
            p.move(to: CGPoint(x: x, y: LaneLayout.ruler))
            p.addLine(to: CGPoint(x: x, y: size.height))
            ctx.stroke(p, with: .color(Deck.fg.opacity(0.35)), lineWidth: 1)
            let label = ctx.resolve(
                Text(hms(t)).font(.system(size: 9, weight: .semibold, design: .monospaced)).foregroundColor(Deck.fg))
            let w = label.measure(in: CGSize(width: 200, height: 20)).width + 8
            let r = CGRect(x: min(x + 4, size.width - w), y: 1, width: w, height: 14)
            ctx.fill(Path(roundedRect: r, cornerRadius: 3), with: .color(Deck.padFace))
            ctx.draw(label, at: CGPoint(x: r.midX, y: r.midY))
        }
        .allowsHitTesting(false)
    }
}

/// The red playhead while the player plays this track (redrawn on its own, not the lane).
struct TrackPlayhead: View {
    let id: String
    let vp: Viewport
    @Environment(Player.self) private var player

    var body: some View {
        if player.source == .track(id) {
            let t = player.position
            Canvas { ctx, size in
                let x = vp.x(t)
                guard x >= -2, x <= size.width + 2 else { return }
                var p = Path()
                p.move(to: CGPoint(x: x, y: LaneLayout.ruler - 4))
                p.addLine(to: CGPoint(x: x, y: size.height))
                var glow = ctx
                glow.addFilter(.shadow(color: Deck.needle.opacity(0.8), radius: 3))
                glow.stroke(p, with: .color(Deck.needle), lineWidth: 2)
                var head = Path()
                head.move(to: CGPoint(x: x - 5, y: LaneLayout.ruler - 9))
                head.addLine(to: CGPoint(x: x + 5, y: LaneLayout.ruler - 9))
                head.addLine(to: CGPoint(x: x, y: LaneLayout.ruler - 2))
                head.closeSubpath()
                ctx.fill(head, with: .color(Deck.needle))
            }
            .allowsHitTesting(false)
        }
    }
}
