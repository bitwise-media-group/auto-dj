// Copyright 2026 BitWise Media Group Ltd
// SPDX-License-Identifier: MIT

@preconcurrency import AVFoundation
import AutoDJKit
import Foundation
import Observation

/// Plays rendered PCM from the render cache: one transition clip, or the full-set mix as its
/// chunks arrive. The mix can be played and sought anywhere up to the rendered edge; chunks
/// that finish while it plays are queued behind the ones already scheduled.
@MainActor @Observable
final class Player {
    enum Source: Equatable {
        case clip(Int)
        case mix
    }

    private(set) var source: Source?
    private(set) var playing = false
    /// Where playback is (seconds into the clip or the mix).
    private(set) var position = 0.0
    /// The clip's or mix's length so far.
    private(set) var duration = 0.0

    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private let node = AVAudioPlayerNode()
    @ObservationIgnored private var startFrame = 0  // frame of the source at the node's time 0
    @ObservationIgnored private var scheduledEnd = 0  // frame scheduled up to
    @ObservationIgnored private var chunks: [MixChunk] = []
    @ObservationIgnored private var clipFile: String?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var generation = 0

    static let sr = Mix.sampleRate

    init() {
        engine.attach(node)
        engine.connect(
            node, to: engine.mainMixerNode, format: AVAudioFormat(standardFormatWithSampleRate: Self.sr, channels: 2))
    }

    /// Forgets the mix chunks (a new render started).
    func resetMix() {
        if source == .mix { stop() }
        chunks = []
        if source == nil || source == .mix { duration = 0 }
    }

    /// A finished mix chunk: playable now; queued when the mix is playing up to its start.
    func addChunk(_ c: MixChunk) {
        chunks.append(c)
        chunks.sort { $0.index < $1.index }
        guard source == .mix else { return }
        duration = Double(renderedFrames) / Self.sr
        if playing && scheduledEnd == c.start { schedule(c, from: c.start) }
    }

    /// Frames of mix audio rendered contiguously from the start.
    var renderedFrames: Int {
        var end = 0
        for c in chunks where c.start == end { end = c.start + c.frames }
        return end
    }

    func playClip(_ i: Int, file: String, frames: Int) {
        stop()
        source = .clip(i)
        clipFile = file
        duration = Double(frames) / Self.sr
        play(from: 0)
    }

    func playMix(from seconds: Double? = nil) {
        if source != .mix { stop() }
        source = .mix
        duration = Double(renderedFrames) / Self.sr
        play(from: seconds ?? (position < duration ? position : 0))
    }

    func toggle() {
        if playing {
            pause()
        } else if source != nil {
            play(from: position)
        }
    }

    func pause() {
        position = currentPosition()
        node.stop()
        playing = false
        timer?.invalidate()
    }

    func stop() {
        node.stop()
        playing = false
        position = 0
        timer?.invalidate()
    }

    /// Seeks (clamped to what is rendered).
    func seek(_ seconds: Double) {
        let t = max(0, min(seconds, duration))
        if playing { play(from: t) } else { position = t }
    }

    private func play(from seconds: Double) {
        generation += 1
        node.stop()
        let frame = Int(seconds * Self.sr)
        startFrame = frame
        scheduledEnd = frame
        switch source {
        case .clip:
            if let f = clipFile, let file = try? AVAudioFile(forReading: URL(fileURLWithPath: f)) {
                let n = AVAudioFrameCount(max(file.length - AVAudioFramePosition(frame), 0))
                if n > 0 {
                    node.scheduleSegment(file, startingFrame: AVAudioFramePosition(frame), frameCount: n, at: nil)
                }
                scheduledEnd = Int(file.length)
            }
        case .mix:
            for c in chunks where c.start + c.frames > frame && c.start <= scheduledEnd {
                schedule(c, from: max(frame, c.start))
            }
        case nil: return
        }
        do {
            if !engine.isRunning { try engine.start() }
        } catch {
            return
        }
        node.play()
        playing = true
        position = seconds
        timer?.invalidate()
        let gen = generation
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.generation == gen else { return }
                self.position = self.currentPosition()
                if self.position >= Double(self.scheduledEnd) / Self.sr - 0.01 {
                    // the mix's next chunk is still rendering: keep waiting for it
                    if self.source == .mix, self.scheduledEnd < self.renderedFrames { return }
                    self.pause()
                }
            }
        }
    }

    /// Schedules chunk c from source frame `from` (inside it).
    private func schedule(_ c: MixChunk, from: Int) {
        guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: c.file)) else { return }
        let off = from - c.start
        let n = c.frames - off
        if n <= 0 { return }
        node.scheduleSegment(file, startingFrame: AVAudioFramePosition(off), frameCount: AVAudioFrameCount(n), at: nil)
        scheduledEnd = c.start + c.frames
    }

    private func currentPosition() -> Double {
        guard let nt = node.lastRenderTime, let pt = node.playerTime(forNodeTime: nt) else { return position }
        return Double(startFrame + Int(pt.sampleTime)) / Self.sr
    }
}
