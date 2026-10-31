// Copyright 2026 BitWise Media Group Ltd
// SPDX-License-Identifier: MIT

// Package synth renders simple, original house tracks for the docs demo set: kick, clap
// and hats, an off-beat bass, chord stabs, a breakdown pad and a pluck lead, arranged in
// 16-bar phrases the way a DJ-friendly extended mix is. Rendering is deterministic: the
// same Song gives the same samples on the same platform.
package synth

import (
	"math"
	"math/rand"
)

// SR is the sample rate.
const SR = 44100.0

// Layout is a track's arrangement in bars, in order: intro (drums), groove (+ stabs, and
// the bass from its ninth bar), main (+ lead at the end), breakdown (no kick or bass; build over the last 4
// bars), drop (everything) and outro (drums; the bass stops 8 bars before the end).
type Layout struct{ Intro, Groove, Main, Break, Drop, Outro int }

// Bars is the arranged length in bars.
func (l Layout) Bars() int { return l.Intro + l.Groove + l.Main + l.Break + l.Drop + l.Outro }

// Chord is a bass root and a voicing (MIDI notes).
type Chord struct {
	Root  float64
	Notes []float64
}

// Note is a lead note: Step counts 16ths from the start of a 4-bar loop.
type Note struct{ Step, Midi, Len float64 }

// Hit is a bass hit within a bar: Step (16ths), interval above the octave-up root, length
// in 16ths and gain.
type Hit struct{ Step, Interval, Len, Gain float64 }

// Song is everything that makes one track.
type Song struct {
	BPM       float64
	Transpose float64 // semitones applied to every note
	Seed      int64
	Prog      [4]Chord // one chord per bar, looped
	Lead      []Note   // 4-bar loop
	Bass      []Hit    // per bar
	Stabs     []float64
	StabCut   float64 // stab low-pass when fully open (Hz)
	Layout    Layout
}

// Sections are a Layout's bar boundaries.
type Sections struct{ Groove, Main, Break, Drop, Outro, End int }

// Of returns l's section starts.
func (l Layout) Of() Sections {
	g := l.Intro
	m := g + l.Groove
	b := m + l.Main
	d := b + l.Break
	o := d + l.Drop
	return Sections{g, m, b, d, o, o + l.Outro}
}

// renderer renders one song into its buses.
type renderer struct {
	s       Song
	sec     Sections
	rng     *rand.Rand
	stepLen float64
	cut     float64 // stab low-pass when fully open

	drums, bass, stabs, pads, lead, fx stereo
	kicks                              []int
}

func (r *renderer) at(bar, step float64) int { return int((bar*16 + step) * r.stepLen) }

func in(bar, a, b int) bool { return bar >= a && bar < b }

// Render returns the song as interleaved stereo float32, peak-normalised to -1 dBFS.
func Render(s Song) []float32 {
	beatLen := SR * 60 / s.BPM
	r := &renderer{s: s, sec: s.Layout.Of(), rng: rand.New(rand.NewSource(s.Seed)), stepLen: beatLen / 4,
		cut: s.StabCut}
	if r.cut == 0 {
		r.cut = 1800
	}
	n := int(float64(r.sec.End)*16*r.stepLen) + int(2*SR)
	r.drums, r.bass, r.stabs = newStereo(n), newStereo(n), newStereo(n)
	r.pads, r.lead, r.fx = newStereo(n), newStereo(n), newStereo(n)
	// one bar at a time, every part in a fixed order: the parts share the random source
	for bar := range r.sec.End {
		r.drumBar(bar)
		r.bassBar(bar)
		r.stabBar(bar)
		r.padBar(bar)
		r.leadBar(bar)
	}
	r.build()
	return mixdown(n, beatLen, r.kicks, r.drums, r.bass, r.stabs, r.pads, r.lead, r.fx)
}

// drumBar is the kick (not in the breakdown), claps from bar 8, off-beat hats (back for
// the build), 16th hats from bar 4 and an open hat where the groove is full.
func (r *renderer) drumBar(bar int) {
	sec, fb := r.sec, float64(bar)
	if !in(bar, sec.Break, sec.Drop) {
		for beat := range 4 {
			p := r.at(fb, float64(beat*4))
			r.kick(r.drums, p, 0.8)
			r.kicks = append(r.kicks, p)
		}
	}
	if in(bar, 8, sec.Break) || in(bar, sec.Drop, sec.End) {
		r.clap(r.drums, r.at(fb, 4), 0.55, 0)
		r.clap(r.drums, r.at(fb, 12), 0.55, 0)
	}
	if !in(bar, sec.Break, sec.Drop-4) {
		for beat := range 4 {
			r.hat(r.drums, r.at(fb, float64(beat*4+2)), 0.045, 0.32, 0.25)
		}
	}
	if in(bar, 4, sec.Break) || in(bar, sec.Drop, sec.End) {
		for st := range 16 {
			g := 0.07
			if st%4 == 2 {
				continue
			}
			if st%2 == 1 {
				g = 0.11
			}
			r.hat(r.drums, r.at(fb, float64(st)), 0.018, g, -0.3)
		}
	}
	if in(bar, sec.Groove, sec.Break) || in(bar, sec.Drop, sec.End-8) {
		r.hat(r.drums, r.at(fb, 14), 0.16, 0.13, 0.4)
	}
}

// bassBar comes in 8 bars after the groove starts, so a DJ has room to swap it in, and
// stops 8 bars before the end.
func (r *renderer) bassBar(bar int) {
	sec := r.sec
	if !in(bar, sec.Groove+8, sec.Break) && !in(bar, sec.Drop, sec.End-8) {
		return
	}
	c := r.s.Prog[bar%4]
	for _, h := range r.s.Bass {
		bassNote(r.bass, r.at(float64(bar), h.Step), c.Root+12+h.Interval+r.s.Transpose, h.Len*r.stepLen/SR, h.Gain)
	}
}

// stabBar plays the chord stabs. Their filter opens through the groove and the end of the
// breakdown, and closes over the last 8 bars.
func (r *renderer) stabBar(bar int) {
	sec, cut := r.sec, r.cut
	if !in(bar, sec.Groove, sec.Break) && !in(bar, sec.Drop-8, sec.End) {
		return
	}
	fc := cut
	if bar < sec.Main {
		fc = 500 + (cut-500)*float64(bar-sec.Groove)/float64(sec.Main-sec.Groove)
	}
	if in(bar, sec.Drop-8, sec.Drop) {
		fc = 400 + (cut-400)*float64(bar-(sec.Drop-8))/8
	}
	if bar >= sec.End-8 {
		fc = cut - (cut-500)*float64(bar-(sec.End-8))/8
	}
	for _, st := range r.s.Stabs {
		d := 1.2 * r.stepLen / SR
		if st == 0 {
			d = 2.5 * r.stepLen / SR
		}
		for _, m := range r.s.Prog[bar%4].Notes {
			r.synthNote(r.stabs, r.at(float64(bar), st), m+r.s.Transpose, d, 0.30, fc, 1.1, 0.002, 0.12, 2, 9)
		}
	}
}

// padBar holds the chord through the breakdown, and quietly under the drop.
func (r *renderer) padBar(bar int) {
	sec := r.sec
	if !in(bar, sec.Break-4, sec.Outro) {
		return
	}
	g := 0.32
	if !in(bar, sec.Break, sec.Drop) {
		g = 0.13
	}
	for _, m := range r.s.Prog[bar%4].Notes {
		r.synthNote(r.pads, r.at(float64(bar), 0), m+r.s.Transpose, 16*r.stepLen/SR, g, 2600, 0.8, 0.35, 0.8, 3, 14)
	}
}

// leadBar teases the lead over the end of the main section, then plays it through the
// breakdown and the drop.
func (r *renderer) leadBar(bar int) {
	sec := r.sec
	if !in(bar, sec.Break-8, sec.Break) && !in(bar, sec.Break+4, sec.Outro) {
		return
	}
	g := 0.24
	if bar < sec.Break {
		g = 0.12
	}
	for _, m := range r.s.Lead {
		if int(m.Step)/16 != bar%4 {
			continue
		}
		at := r.at(float64(bar), math.Mod(m.Step, 16))
		r.synthNote(r.lead, at, m.Midi+r.s.Transpose, m.Len*r.stepLen/SR*0.7, g, 3800, 1.6, 0.003, 0.25, 2, 6)
	}
}

// build is a noise riser and a clap roll over the last 4 bars of the breakdown.
func (r *renderer) build() {
	drop := r.sec.Drop
	var f svf
	a, b := r.at(float64(drop-4), 0), r.at(float64(drop), 0)
	for i := a; i < b; i++ {
		p := float64(i-a) / float64(b-a)
		_, bp, _ := f.run(r.rng.Float64()*2-1, 300*math.Pow(30, p), 2)
		r.fx.add(i, bp*p*p*0.5, 0)
	}
	for k := range 4 {
		div := []int{4, 4, 2, 1}[k]
		for st := 0; st < 16; st += div {
			g := 0.2 + 0.3*float64(k*16+st)/64
			r.clap(r.fx, r.at(float64(drop-4+k), float64(st)), g, 0)
		}
	}
}

// mixdown sidechains the music to the kick, adds a ping-pong delay to the lead and reverb
// to everything melodic, soft-clips and normalises.
func mixdown(n int, beatLen float64, kicks []int, drums, bass, stabs, pads, leadB, fx stereo) []float32 {
	duck := make([]float64, n)
	for i := range duck {
		duck[i] = 1
	}
	rel := int(beatLen * 0.6)
	for _, k := range kicks {
		for i := 0; i < rel && k+i < n; i++ {
			x := 1 - float64(i)/float64(rel)
			duck[k+i] = math.Min(duck[k+i], 1-0.7*x*x)
		}
	}
	dl := int(beatLen * 0.75)
	for i := dl; i < n; i++ {
		leadB.l[i] += leadB.r[i-dl] * 0.38
		leadB.r[i] += leadB.l[i-dl] * 0.38
	}
	rv := newReverb(0.86, 0.35)
	out := newStereo(n)
	var hpL, hpR svf
	for i := range n {
		d := duck[i]
		send := (stabs.l[i]+stabs.r[i])*0.5 + (pads.l[i]+pads.r[i])*0.9 + (leadB.l[i]+leadB.r[i])*0.6 +
			(drums.l[i]+drums.r[i])*0.08 + fx.l[i]*0.4
		wl, wr := rv.run(send)
		l := drums.l[i] + bass.l[i]*d + (stabs.l[i]+pads.l[i])*d + leadB.l[i]*(0.4+0.6*d) + fx.l[i] + wl*1.1*d
		r := drums.r[i] + bass.r[i]*d + (stabs.r[i]+pads.r[i])*d + leadB.r[i]*(0.4+0.6*d) + fx.r[i] + wr*1.1*d
		_, _, l = hpL.run(l, 25, 0.7)
		_, _, r = hpR.run(r, 25, 0.7)
		out.l[i] = math.Tanh(l*1.1) / math.Tanh(1.1)
		out.r[i] = math.Tanh(r*1.1) / math.Tanh(1.1)
	}
	peak := 0.0
	for i := range n {
		peak = math.Max(peak, math.Max(math.Abs(out.l[i]), math.Abs(out.r[i])))
	}
	g := 0.89 / peak
	pcm := make([]float32, 2*n)
	for i := range n {
		pcm[2*i] = float32(out.l[i] * g)
		pcm[2*i+1] = float32(out.r[i] * g)
	}
	return pcm
}

// ------------------------------------------------------------------ voices

func (r *renderer) kick(b stereo, start int, gain float64) {
	n := int(0.3 * SR)
	ph := 0.0
	for i := range n {
		t := float64(i) / SR
		f := 50 + 110*math.Exp(-t*30)
		ph += 2 * math.Pi * f / SR
		env := math.Exp(-t * 14)
		click := math.Exp(-t*900) * 0.6
		v := (math.Sin(ph)*env + click*r.rng.Float64()*0.2) * gain
		b.add(start+i, math.Tanh(v*1.6), 0)
	}
}

func (r *renderer) clap(b stereo, start int, gain, pan float64) {
	var f svf
	n := int(0.3 * SR)
	for i := range n {
		t := float64(i) / SR
		env := math.Exp(-t * 18)
		for _, o := range []float64{0, 0.011, 0.022} {
			if t >= o && t < o+0.01 {
				env += math.Exp(-(t-o)*300) * 0.8
			}
		}
		_, bp, _ := f.run(r.rng.Float64()*2-1, 1300, 1.2)
		b.add(start+i, bp*env*gain, pan)
	}
}

func (r *renderer) hat(b stereo, start int, decay, gain, pan float64) {
	var f svf
	n := int(decay * 6 * SR)
	for i := range n {
		t := float64(i) / SR
		_, _, hp := f.run(r.rng.Float64()*2-1, 7500, 0.9)
		b.add(start+i, hp*math.Exp(-t/decay)*gain, pan)
	}
}

// synthNote renders detuned saws through a low-pass with an amp envelope.
func (r *renderer) synthNote(b stereo, start int, midi, dur, gain, cutoff, res, attack, release float64,
	voices int, spread float64) {
	n := int((dur + release) * SR)
	oscs := make([]saw, voices)
	for i := range oscs {
		oscs[i].ph = r.rng.Float64()
	}
	var fl, fr svf
	f0 := mtof(midi)
	for i := range n {
		t := float64(i) / SR
		var env float64
		switch {
		case t < attack:
			env = t / attack
		case t < dur:
			env = 1
		default:
			env = math.Exp(-(t - dur) / (release / 4))
		}
		var l, rr float64
		for k := range oscs {
			d := (float64(k) - float64(voices-1)/2) * spread
			v := oscs[k].next(f0 * math.Pow(2, d/1200))
			p := 0.5
			if voices > 1 {
				p = float64(k) / float64(voices-1)
			}
			l += v * (1 - p)
			rr += v * p
		}
		fc := cutoff * (0.6 + 0.4*math.Exp(-t*6))
		ll, _, _ := fl.run(l, fc, res)
		rl, _, _ := fr.run(rr, fc, res)
		g := env * gain / float64(voices)
		if i+start >= 0 && i+start < len(b.l) {
			b.l[i+start] += ll * g
			b.r[i+start] += rl * g
		}
	}
}

func bassNote(b stereo, start int, midi, dur, gain float64) {
	n := int((dur + 0.05) * SR)
	var o saw
	var f svf
	f0 := mtof(midi)
	sub := 0.0
	for i := range n {
		t := float64(i) / SR
		env := 1.0
		if t < 0.004 {
			env = t / 0.004
		}
		if t > dur {
			env = math.Exp(-(t - dur) * 60)
		}
		sub += math.Pi * f0 / SR // an octave down: the weight below 100 Hz
		lp, _, _ := f.run(o.next(f0), 260+900*math.Exp(-t*14), 1.4)
		b.add(start+i, (lp*0.6+math.Sin(sub)*1.4)*env*gain, 0)
	}
}

func mtof(m float64) float64 { return 440 * math.Pow(2, (m-69)/12) }
