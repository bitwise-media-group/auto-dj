// Copyright 2026 BitWise Media Group Ltd
// SPDX-License-Identifier: MIT

package synth

import "math"

// stereo is a pair of sample buffers.
type stereo struct{ l, r []float64 }

func newStereo(n int) stereo { return stereo{make([]float64, n), make([]float64, n)} }

// add mixes v into sample i with an equal-power pan (-1 left .. 1 right).
func (s stereo) add(i int, v, pan float64) {
	if i < 0 || i >= len(s.l) {
		return
	}
	s.l[i] += v * math.Cos((pan+1)*math.Pi/4)
	s.r[i] += v * math.Sin((pan+1)*math.Pi/4)
}

// svf is a TPT state-variable filter (Zavalishin).
type svf struct{ ic1, ic2 float64 }

func (f *svf) run(x, fc, q float64) (lp, bp, hp float64) {
	fc = math.Min(math.Max(fc, 20), SR*0.45)
	g := math.Tan(math.Pi * fc / SR)
	k := 1 / q
	a1 := 1 / (1 + g*(g+k))
	a2 := g * a1
	a3 := g * a2
	v3 := x - f.ic2
	v1 := a1*f.ic1 + a2*v3
	v2 := f.ic2 + a2*f.ic1 + a3*v3
	f.ic1 = 2*v1 - f.ic1
	f.ic2 = 2*v2 - f.ic2
	return v2, v1, x - k*v1 - v2
}

// polyblep smooths a saw's discontinuity to keep aliasing down.
func polyblep(t, dt float64) float64 {
	if t < dt {
		t /= dt
		return t + t - t*t - 1
	}
	if t > 1-dt {
		t = (t - 1) / dt
		return t*t + t + t + 1
	}
	return 0
}

type saw struct{ ph float64 }

func (o *saw) next(f float64) float64 {
	dt := f / SR
	v := 2*o.ph - 1 - polyblep(o.ph, dt)
	o.ph += dt
	if o.ph >= 1 {
		o.ph--
	}
	return v
}

type comb struct {
	buf          []float64
	i            int
	fb, damp, lp float64
}

func (c *comb) run(x float64) float64 {
	y := c.buf[c.i]
	c.lp = y*(1-c.damp) + c.lp*c.damp
	c.buf[c.i] = x + c.lp*c.fb
	c.i = (c.i + 1) % len(c.buf)
	return y
}

type allpass struct {
	buf []float64
	i   int
}

func (a *allpass) run(x float64) float64 {
	b := a.buf[a.i]
	y := -x + b
	a.buf[a.i] = x + b*0.5
	a.i = (a.i + 1) % len(a.buf)
	return y
}

// reverb is a small stereo Freeverb.
type reverb struct {
	cl, cr []*comb
	al, ar []*allpass
}

func newReverb(room, damp float64) *reverb {
	r := &reverb{}
	for _, n := range []int{1116, 1188, 1277, 1356, 1422, 1491, 1557, 1617} {
		r.cl = append(r.cl, &comb{buf: make([]float64, n), fb: room, damp: damp})
		r.cr = append(r.cr, &comb{buf: make([]float64, n+23), fb: room, damp: damp})
	}
	for _, n := range []int{556, 441, 341, 225} {
		r.al = append(r.al, &allpass{buf: make([]float64, n)})
		r.ar = append(r.ar, &allpass{buf: make([]float64, n+23)})
	}
	return r
}

func (r *reverb) run(x float64) (float64, float64) {
	x *= 0.015
	var l, rr float64
	for i := range r.cl {
		l += r.cl[i].run(x)
		rr += r.cr[i].run(x)
	}
	for i := range r.al {
		l = r.al[i].run(l)
		rr = r.ar[i].run(rr)
	}
	return l, rr
}
