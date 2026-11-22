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
        /// A library track's own audio file (by track ID), e.g. from the cue plan's timeline.
        case track(String)
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
    /// The playing source's sample rate: the mix's for clips and the mix, a track file's own
    /// (the mixer converts it).
    @ObservationIgnored private var rate = Player.sr
    @ObservationIgnored private var connected: AVAudioFormat?

    static let sr = Mix.sampleRate

    static let mixFormat = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2)!

    init() {
        engine.attach(node)
        connect(Self.mixFormat)
    }

    /// Connects the player node in format f (the node must be stopped).
    private func connect(_ f: AVAudioFormat) {
        if let c = connected, c == f { return }
        engine.disconnectNodeOutput(node)
        engine.connect(node, to: engine.mainMixerNode, format: f)
        connected = f
        rate = f.sampleRate
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
        connect(Self.mixFormat)
        source = .clip(i)
        clipFile = file
        duration = Double(frames) / Self.sr
        play(from: 0)
    }

    func playMix(from seconds: Double? = nil) {
        if source != .mix { stop() }
        connect(Self.mixFormat)
        source = .mix
        duration = Double(renderedFrames) / Self.sr
        play(from: seconds ?? (position < duration ? position : 0))
    }

    /// Plays track id's audio file from source second `seconds`.
    func playTrack(_ id: String, file: String, from seconds: Double) {
        guard let f = try? AVAudioFile(forReading: URL(fileURLWithPath: file)) else { return }
        stop()
        connect(f.processingFormat)
        source = .track(id)
        clipFile = file
        duration = Double(f.length) / f.processingFormat.sampleRate
        play(from: min(max(seconds, 0), duration))
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
        let frame = Int(seconds * rate)
        startFrame = frame
        scheduledEnd = frame
        switch source {
        case .clip, .track:
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
                if self.position >= Double(self.scheduledEnd) / self.rate - 0.01 {
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
        return Double(startFrame + Int(pt.sampleTime)) / rate
    }
}
