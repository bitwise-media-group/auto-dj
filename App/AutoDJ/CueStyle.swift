// Copyright 2026 BitWise Media Group Ltd
// SPDX-License-Identifier: MIT

import AutoDJKit
import SwiftUI

/// The CDJ screen and pad colours, shared with the docs site (`docs/stylesheets/extra.css`):
/// each hot cue slot has its pad colour, memory cues Rekordbox's eight memory cue colours.
enum Deck {
    static let screen = Color(hex: 0x0b0c0e)
    static let screen2 = Color(hex: 0x16171a)
    static let lane = Color(hex: 0x111215)
    static let line = Color(hex: 0x26272b)
    static let fg = Color(hex: 0xd9dade)
    static let dim = Color(hex: 0x7d7f87)
    static let padFace = Color(hex: 0x232428)
    /// The playhead (a CDJ's red needle).
    static let needle = Color(hex: 0xff2a3a)

    /// Rekordbox's 3-band waveform: lows blue, mids amber, highs white.
    static let low = Color(hex: 0x2c6dff)
    static let mid = Color(hex: 0xf0a43a)
    static let high = Color(hex: 0xf5f1e8)

    static let pads: [String: Color] = [
        "A": Color(hex: 0xff2d3d), "B": Color(hex: 0x19d3e0), "C": Color(hex: 0xb5e61d), "D": Color(hex: 0x8f5bff),
        "E": Color(hex: 0x1fd46a), "F": Color(hex: 0xff3d9e), "G": Color(hex: 0x2f6bff), "H": Color(hex: 0xff8a1f),
    ]

    /// 0 pink, 1 red, 2 orange, 3 yellow, 4 green, 5 aqua, 6 blue, 7 purple (`Config.memoryColor`).
    static let memory: [Color] = [
        Color(hex: 0xf870c0), Color(hex: 0xe8443a), Color(hex: 0xf08c28), Color(hex: 0xe8d830),
        Color(hex: 0x40c060), Color(hex: 0x30c8d0), Color(hex: 0x3c78e8), Color(hex: 0x9050e0),
    ]

    static func pad(_ slot: String) -> Color { pads[slot] ?? dim }

    /// A memory cue's colour; Rekordbox's default red when the set doesn't colour its name.
    static func memory(_ i: Int?) -> Color { i.map { memory[$0 % memory.count] } ?? memory[1] }

    static func color(_ m: CueMark) -> Color { m.slot.map(pad) ?? memory(m.memoryColor) }

}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB, red: Double(hex >> 16 & 0xff) / 255, green: Double(hex >> 8 & 0xff) / 255,
            blue: Double(hex & 0xff) / 255)
    }
}

/// A hot cue pad: the slot letter in a square outlined in the pad's colour.
struct PadBadge: View {
    let slot: String
    var size: CGFloat = 18
    var dimmed = false
    /// The pad's glow (off in long lists, where the shadows cost scrolling).
    var glow = true

    var body: some View {
        let c = Deck.pad(slot)
        let shape = RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
        Text(slot)
            .font(.system(size: size * 0.6, weight: .heavy, design: .rounded))
            .foregroundStyle(dimmed ? c.opacity(0.5) : c)
            .frame(width: size, height: size)
            .background(shape.fill(c.opacity(dimmed ? 0.06 : 0.16)))
            .overlay(shape.strokeBorder(c.opacity(dimmed ? 0.4 : 1), lineWidth: 1.5))
            .shadow(color: c.opacity(dimmed || !glow ? 0 : 0.45), radius: 3)
    }
}

/// A memory cue: a down arrow in its colour.
struct MemoryArrow: View {
    let color: Color
    var size: CGFloat = 12
    var dimmed = false

    var body: some View {
        DownTriangle()
            .fill(color.opacity(dimmed ? 0.4 : 1))
            .frame(width: size, height: size * 0.8)
            .shadow(color: color.opacity(dimmed ? 0 : 0.45), radius: 2)
            .frame(width: 18)
    }
}

struct DownTriangle: Shape {
    func path(in r: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: r.minX, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
            p.addLine(to: CGPoint(x: r.midX, y: r.maxY))
            p.closeSubpath()
        }
    }
}

/// What the write does to a cue, as a small tag (nothing for a cue left as it is).
struct ChangeTag: View {
    let change: CueMark.Change

    var body: some View {
        if let (text, color) = style {
            Text(text)
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .tracking(0.4)
                .foregroundStyle(color)
                .padding(.horizontal, 5)
                .padding(.vertical, 1.5)
                .background(color.opacity(0.14), in: Capsule())
                .overlay(Capsule().strokeBorder(color.opacity(0.45), lineWidth: 0.5))
        }
    }

    var style: (String, Color)? {
        switch change {
        case .existing: nil
        case .new: ("NEW", .green)
        case .replace: ("REPLACE", .orange)
        case .rename: ("RENAME", .blue)
        case .clear: ("CLEAR", .red)
        case .remove: ("REMOVE", .red)
        }
    }
}
