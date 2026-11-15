// Copyright 2026 BitWise Media Group Ltd
// SPDX-License-Identifier: MIT

import AutoDJKit
import SwiftUI

/// The whole set as lanes (setlist.html's overview, drawn natively): each track from where it
/// starts to where it leaves, its fade in, bass swap, exit and jumps; the rendered edge; the
/// playhead. Click to play from there (up to the rendered edge).
struct MixTimelineView: View {
    let model: SetModel
    @Environment(Player.self) private var player

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Button {
                    if player.source == .mix && player.playing { player.pause() } else { player.playMix() }
                } label: {
                    Image(systemName: player.source == .mix && player.playing ? "pause.fill" : "play.fill")
                }
                .disabled(model.renderedSeconds <= 0)
                Text("Full set").font(.headline)
                let dur = model.plan?.duration ?? 0
                Text("\(hms(player.source == .mix ? player.position : 0)) / \(hms(dur))").monospacedDigit()
                    .foregroundStyle(.secondary)
                if !model.mixDone && dur > 0 {
                    Text("rendered to \(hms(model.renderedSeconds))").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            GeometryReader { geo in
                let dur = max(model.plan?.duration ?? 1, 1)
                let segs = model.plan?.mix.filter { !$0.missing } ?? []
                let lanes = 2
                let w = geo.size.width
                let laneH = (geo.size.height - 4) / CGFloat(lanes)
                let x = { (t: Double) in CGFloat(t / dur) * w }
                Canvas { ctx, size in
                    // rendered region
                    ctx.fill(
                        Path(CGRect(x: 0, y: 0, width: x(model.renderedSeconds), height: size.height)),
                        with: .color(.accentColor.opacity(0.07)))
                    for (k, s) in segs.enumerated() {
                        let y = CGFloat(k % lanes) * laneH + 2
                        let r = CGRect(x: x(s.start), y: y, width: max(x(s.end) - x(s.start), 1), height: laneH - 4)
                        ctx.fill(Path(roundedRect: r, cornerRadius: 3), with: .color(color(k).opacity(0.35)))
                        if let fi = s.fadeIn {
                            var p = Path()
                            p.move(to: CGPoint(x: x(fi.0), y: r.maxY))
                            p.addLine(to: CGPoint(x: x(fi.1), y: r.minY))
                            ctx.stroke(p, with: .color(color(k)), lineWidth: 1)
                        }
                        if s.exit.kind == .fade || s.exit.kind == .filter {
                            var p = Path()
                            p.move(to: CGPoint(x: x(s.exit.xs[0]), y: r.minY))
                            p.addLine(to: CGPoint(x: x(s.exit.xs.last!), y: r.maxY))
                            ctx.stroke(
                                p, with: .color(color(k)),
                                style: StrokeStyle(lineWidth: 1, dash: s.exit.kind == .filter ? [3, 2] : []))
                        }
                        if let sw = s.swapT {
                            var p = Path()
                            p.move(to: CGPoint(x: x(sw), y: 0))
                            p.addLine(to: CGPoint(x: x(sw), y: size.height))
                            ctx.stroke(
                                p, with: .color(.orange.opacity(s.estimatedSwap ? 0.4 : 0.9)),
                                style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                        }
                        for j in s.jumps {
                            ctx.fill(
                                Path(ellipseIn: CGRect(x: x(j) - 3, y: r.midY - 3, width: 6, height: 6)),
                                with: .color(.pink))
                        }
                        // the label, clipped to the segment
                        var label = ctx
                        label.clip(to: Path(r.insetBy(dx: 3, dy: 0)))
                        label.draw(
                            Text("\(s.n). \(s.title)").font(.caption2), at: CGPoint(x: r.minX + 4, y: r.midY),
                            anchor: .leading)
                    }
                    // rendered edge and playhead
                    var edge = Path()
                    edge.move(to: CGPoint(x: x(model.renderedSeconds), y: 0))
                    edge.addLine(to: CGPoint(x: x(model.renderedSeconds), y: size.height))
                    ctx.stroke(edge, with: .color(.accentColor.opacity(0.6)), lineWidth: 1)
                    if player.source == .mix {
                        var ph = Path()
                        ph.move(to: CGPoint(x: x(player.position), y: 0))
                        ph.addLine(to: CGPoint(x: x(player.position), y: size.height))
                        ctx.stroke(ph, with: .color(.primary), lineWidth: 2)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { loc in
                    let t = min(Double(loc.x / w) * dur, model.renderedSeconds)
                    player.playMix(from: t)
                }
            }
        }
        .padding(10)
    }

    func color(_ k: Int) -> Color {
        [Color.blue, .purple, .teal, .indigo, .mint, .cyan][k % 6]
    }
}

func hms(_ s: Double) -> String {
    let t = Int(max(s, 0))
    return t >= 3600
        ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
}
