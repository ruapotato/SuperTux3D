#!/usr/bin/env python3
"""Synthesize clean WAV sound effects for the Godot SM64-like game.

Pure stdlib only (wave + math + struct + random). Replaces ROM-ripped
sounds with friendly original synths.
"""
import math
import os
import random
import struct
import wave

SR = 44100          # sample rate
BITS = 16
CHANNELS = 1
OUT_DIR = "/home/david/gd_mario/godot/assets/sounds"
FADE_MS = 10        # click-free envelope edges


# ---------------------------------------------------------------------------
# Sample helpers
# ---------------------------------------------------------------------------
def n_samples(seconds):
    return int(round(seconds * SR))


def silence(seconds):
    return [0.0] * n_samples(seconds)


def mix(a, b, gain_b=1.0):
    """In-place add b*gain_b into a, extending a as needed."""
    if len(b) > len(a):
        a.extend([0.0] * (len(b) - len(a)))
    for i in range(len(b)):
        a[i] += b[i] * gain_b
    return a


def scale(buf, g):
    return [s * g for s in buf]


def apply_fades(buf, fade_ms=FADE_MS):
    """Linear fade-in/fade-out to avoid pops."""
    f = min(int(SR * fade_ms / 1000), len(buf) // 2)
    if f <= 0:
        return buf
    for i in range(f):
        k = i / f
        buf[i] *= k
        buf[-1 - i] *= k
    return buf


def clip(buf):
    return [max(-1.0, min(1.0, s)) for s in buf]


def normalize(buf, target=0.9):
    peak = max((abs(s) for s in buf), default=0.0)
    if peak < 1e-9:
        return buf
    g = target / peak
    return [s * g for s in buf]


def write_wav(path, samples):
    samples = apply_fades(list(samples))
    samples = clip(normalize(samples))
    with wave.open(path, "wb") as w:
        w.setnchannels(CHANNELS)
        w.setsampwidth(BITS // 8)
        w.setframerate(SR)
        frames = bytearray()
        for s in samples:
            v = int(round(s * 32767))
            if v > 32767:
                v = 32767
            elif v < -32768:
                v = -32768
            frames += struct.pack("<h", v)
        w.writeframes(bytes(frames))


# ---------------------------------------------------------------------------
# Generators
# ---------------------------------------------------------------------------
def sine(freq, seconds, amp=1.0, phase=0.0, freq_end=None):
    """Sine with optional linear frequency glide from freq to freq_end."""
    N = n_samples(seconds)
    out = [0.0] * N
    if freq_end is None:
        freq_end = freq
    p = phase
    for i in range(N):
        t = i / N
        f = freq + (freq_end - freq) * t
        p += 2 * math.pi * f / SR
        out[i] = amp * math.sin(p)
    return out


def saw(freq, seconds, amp=1.0):
    N = n_samples(seconds)
    out = [0.0] * N
    p = 0.0
    for i in range(N):
        p += freq / SR
        p -= math.floor(p)
        out[i] = amp * (2.0 * p - 1.0)
    return out


def noise(seconds, amp=1.0):
    N = n_samples(seconds)
    return [amp * (random.random() * 2.0 - 1.0) for _ in range(N)]


def lowpass(buf, cutoff_hz):
    """Simple one-pole lowpass."""
    rc = 1.0 / (2 * math.pi * max(cutoff_hz, 1.0))
    dt = 1.0 / SR
    a = dt / (rc + dt)
    out = [0.0] * len(buf)
    y = 0.0
    for i, x in enumerate(buf):
        y += a * (x - y)
        out[i] = y
    return out


def highpass(buf, cutoff_hz):
    rc = 1.0 / (2 * math.pi * max(cutoff_hz, 1.0))
    dt = 1.0 / SR
    a = rc / (rc + dt)
    out = [0.0] * len(buf)
    prev_x = 0.0
    prev_y = 0.0
    for i, x in enumerate(buf):
        y = a * (prev_y + x - prev_x)
        out[i] = y
        prev_x = x
        prev_y = y
    return out


def bandpass(buf, center, width=200):
    return highpass(lowpass(buf, center + width), max(center - width, 20))


def adsr(N, a=0.01, d=0.05, s=0.6, r=0.1):
    """ADSR as a list of length N (a,d,r in seconds)."""
    an = int(a * SR)
    dn = int(d * SR)
    rn = int(r * SR)
    sn = max(0, N - an - dn - rn)
    env = [0.0] * N
    i = 0
    for k in range(an):
        if i >= N: break
        env[i] = k / max(an, 1); i += 1
    for k in range(dn):
        if i >= N: break
        env[i] = 1.0 + (s - 1.0) * (k / max(dn, 1)); i += 1
    for _ in range(sn):
        if i >= N: break
        env[i] = s; i += 1
    for k in range(rn):
        if i >= N: break
        env[i] = s * (1.0 - k / max(rn, 1)); i += 1
    while i < N:
        env[i] = 0.0; i += 1
    return env


def apply_env(buf, env):
    n = min(len(buf), len(env))
    return [buf[i] * env[i] for i in range(n)]


def exp_decay(N, tau_sec):
    return [math.exp(-i / (tau_sec * SR)) for i in range(N)]


# ---------------------------------------------------------------------------
# SFX definitions
# ---------------------------------------------------------------------------
def sfx_jump():
    # Two sine stacks sweeping down slightly (vowel-ish "hoo")
    dur = 0.35
    f1 = sine(350, dur, 0.7, freq_end=260)
    f2 = sine(700, dur, 0.25, freq_end=520)  # upper formant
    buf = [f1[i] + f2[i] for i in range(len(f1))]
    env = exp_decay(len(buf), 0.18)
    return apply_env(buf, env)


def sfx_double_jump():
    dur = 0.35
    f1 = sine(450, dur, 0.7, freq_end=340)
    f2 = sine(900, dur, 0.3, freq_end=680)
    buf = [f1[i] + f2[i] for i in range(len(f1))]
    return apply_env(buf, exp_decay(len(buf), 0.17))


def sfx_triple_jump():
    # "Yahoo": two formant bumps, ascending then holding
    dur = 0.6
    N = n_samples(dur)
    out = [0.0] * N
    # first syllable "ya"
    s1 = sine(380, 0.25, 0.6, freq_end=520)
    s1b = sine(760, 0.25, 0.25, freq_end=1040)
    bump1 = [s1[i] + s1b[i] for i in range(len(s1))]
    bump1 = apply_env(bump1, exp_decay(len(bump1), 0.12))
    # second "hoo" higher
    s2 = sine(560, 0.35, 0.7, freq_end=700)
    s2b = sine(1120, 0.35, 0.3, freq_end=1400)
    bump2 = [s2[i] + s2b[i] for i in range(len(s2))]
    bump2 = apply_env(bump2, exp_decay(len(bump2), 0.18))
    mix(out, bump1)
    off = n_samples(0.22)
    for i in range(len(bump2)):
        if off + i < N:
            out[off + i] += bump2[i]
    return out


def sfx_land():
    dur = 0.15
    thud = sine(90, dur, 0.9, freq_end=55)
    n = lowpass(noise(dur, 0.6), 400)
    buf = [thud[i] + n[i] for i in range(len(thud))]
    return apply_env(buf, exp_decay(len(buf), 0.07))


def sfx_land_hard():
    dur = 0.25
    thud = sine(75, dur, 1.0, freq_end=45)
    n = lowpass(noise(dur, 0.8), 350)
    buf = [thud[i] + n[i] for i in range(len(thud))]
    return apply_env(buf, exp_decay(len(buf), 0.12))


def sfx_ground_pound():
    dur = 0.5
    sweep = sine(200, dur, 1.0, freq_end=60)
    crunch = lowpass(noise(dur, 0.7), 800)
    crunch = apply_env(crunch, exp_decay(len(crunch), 0.1))
    buf = [sweep[i] + crunch[i] for i in range(len(sweep))]
    return apply_env(buf, exp_decay(len(buf), 0.25))


def sfx_step():
    dur = 0.1
    n = bandpass(noise(dur, 1.0), 1200, 600)
    return apply_env(n, exp_decay(len(n), 0.03))


def _ding(freq, dur):
    buf = sine(freq, dur, 0.9)
    harm = sine(freq * 2, dur, 0.25)
    buf = [buf[i] + harm[i] for i in range(len(buf))]
    return apply_env(buf, exp_decay(len(buf), dur * 0.6))


def sfx_coin():
    a = _ding(988, 0.08)
    b = _ding(1319, 0.14)
    out = list(a)
    off = n_samples(0.06)
    for i in range(len(b)):
        idx = off + i
        if idx >= len(out):
            out.append(0.0)
        out[idx] += b[i]
    return out


def sfx_coin_red():
    a = _ding(988, 0.09)
    b = _ding(1319, 0.16)
    # richer third-harmonic on each
    def enrich(buf, base):
        h3 = sine(base * 3, len(buf) / SR, 0.15)
        h3 = apply_env(h3, exp_decay(len(h3), 0.1))
        return [buf[i] + (h3[i] if i < len(h3) else 0.0) for i in range(len(buf))]
    a = enrich(a, 988)
    b = enrich(b, 1319)
    out = list(a)
    off = n_samples(0.07)
    for i in range(len(b)):
        idx = off + i
        if idx >= len(out):
            out.append(0.0)
        out[idx] += b[i]
    return out


def _reverb(buf, delays_ms=(37, 71, 113), decays=(0.4, 0.25, 0.15)):
    out = list(buf)
    for dm, g in zip(delays_ms, decays):
        d = int(SR * dm / 1000)
        for i in range(len(buf)):
            j = i + d
            if j >= len(out):
                out.extend([0.0] * (j - len(out) + 1))
            out[j] += buf[i] * g
    return out


def sfx_star_get():
    # C E G C ascending (C5=523, E5=659, G5=784, C6=1047)
    notes = [523.25, 659.25, 783.99, 1046.50]
    dur = 0.15
    out = []
    for i, f in enumerate(notes):
        tone = sine(f, dur, 0.8)
        tone_h = sine(f * 2, dur, 0.2)
        tone = [tone[j] + tone_h[j] for j in range(len(tone))]
        tone = apply_env(tone, exp_decay(len(tone), 0.1))
        out.extend(tone)
    return _reverb(out)


def sfx_oneup():
    # happy 3-note trill (E G C)
    notes = [659.25, 783.99, 1046.50]
    out = []
    for f in notes:
        tone = sine(f, 0.1, 0.8)
        tone = apply_env(tone, exp_decay(len(tone), 0.08))
        out.extend(tone)
    return _reverb(out)


def sfx_hurt():
    # "wagh" falling buzz - saw sweep
    dur = 0.3
    s = saw(320, dur, 0.7)
    # apply pitch fall via resampling-ish trick: mix in lower sine sweep
    bend = sine(320, dur, 0.6, freq_end=140)
    buf = [s[i] * 0.4 + bend[i] * 0.7 for i in range(len(s))]
    buf = lowpass(buf, 1800)
    return apply_env(buf, exp_decay(len(buf), 0.18))


def sfx_death():
    # descending sad trombone: 3 pitches falling
    notes = [(330, 0.25), (247, 0.25), (165, 0.45)]
    out = []
    for f, d in notes:
        base = saw(f, d, 0.5)
        s1 = sine(f, d, 0.6)
        s2 = sine(f * 2, d, 0.2)
        buf = [base[i] + s1[i] + s2[i] for i in range(len(base))]
        buf = lowpass(buf, 1400)
        buf = apply_env(buf, exp_decay(len(buf), d * 0.7))
        out.extend(buf)
    return out


def sfx_enemy_squish():
    dur = 0.18
    n = lowpass(noise(dur, 1.0), 600)
    sweep = sine(300, dur, 0.5, freq_end=80)
    buf = [n[i] + sweep[i] for i in range(len(n))]
    return apply_env(buf, exp_decay(len(buf), 0.08))


def sfx_bomb_explode():
    dur = 0.4
    n = lowpass(noise(dur, 1.0), 1500)
    sweep = sine(180, dur, 0.8, freq_end=40)
    buf = [n[i] * 0.9 + sweep[i] for i in range(len(n))]
    buf = apply_env(buf, exp_decay(len(buf), 0.22))
    # low rumble tail
    tail = sine(50, 0.25, 0.5)
    tail = apply_env(tail, exp_decay(len(tail), 0.15))
    out = list(buf)
    off = n_samples(0.25)
    for i in range(len(tail)):
        idx = off + i
        if idx >= len(out):
            out.append(0.0)
        out[idx] += tail[i]
    return out


def sfx_cap_get():
    # rising bright arpeggio (G B D G)
    notes = [392.00, 493.88, 587.33, 783.99]
    out = []
    for f in notes:
        tone = sine(f, 0.09, 0.7)
        tone_h = sine(f * 2, 0.09, 0.3)
        tone = [tone[j] + tone_h[j] for j in range(len(tone))]
        tone = apply_env(tone, exp_decay(len(tone), 0.07))
        out.extend(tone)
    return _reverb(out)


def sfx_pause():
    dur = 0.08
    tone = sine(660, dur, 0.7)
    tone = lowpass(tone, 2000)
    return apply_env(tone, exp_decay(len(tone), 0.04))


def sfx_warp():
    # 0.6s swirl: chord rising + tremolo
    dur = 0.6
    N = n_samples(dur)
    out = [0.0] * N
    base_freqs = [220, 277, 330, 440]
    for bf in base_freqs:
        tone = sine(bf, dur, 0.35, freq_end=bf * 1.8)
        for i in range(N):
            out[i] += tone[i]
    # tremolo
    for i in range(N):
        trem = 0.85 + 0.15 * math.sin(2 * math.pi * 6.0 * i / SR)
        out[i] *= trem
    # gentle swell env
    env = [0.0] * N
    for i in range(N):
        t = i / N
        env[i] = math.sin(math.pi * t)  # fade in and out
    out = apply_env(out, env)
    return _reverb(out, delays_ms=(53, 97, 151), decays=(0.35, 0.22, 0.12))


# ---------------------------------------------------------------------------
# Driver
# ---------------------------------------------------------------------------
SFX = [
    ("jump.wav", sfx_jump),
    ("double_jump.wav", sfx_double_jump),
    ("triple_jump.wav", sfx_triple_jump),
    ("land.wav", sfx_land),
    ("land_hard.wav", sfx_land_hard),
    ("ground_pound.wav", sfx_ground_pound),
    ("step.wav", sfx_step),
    ("coin.wav", sfx_coin),
    ("coin_red.wav", sfx_coin_red),
    ("star_get.wav", sfx_star_get),
    ("oneup.wav", sfx_oneup),
    ("hurt.wav", sfx_hurt),
    ("death.wav", sfx_death),
    ("enemy_squish.wav", sfx_enemy_squish),
    ("bomb_explode.wav", sfx_bomb_explode),
    ("cap_get.wav", sfx_cap_get),
    ("pause.wav", sfx_pause),
    ("warp.wav", sfx_warp),
]


def main():
    random.seed(1729)  # deterministic noise
    os.makedirs(OUT_DIR, exist_ok=True)
    print(f"Writing SFX to {OUT_DIR}")
    written = []
    for name, fn in SFX:
        path = os.path.join(OUT_DIR, name)
        samples = fn()
        write_wav(path, samples)
        size = os.path.getsize(path)
        dur_s = len(samples) / SR
        written.append((name, dur_s, size))
        print(f"  {name:<20s}  {dur_s:5.2f}s  {size:>7d} bytes")
    print(f"\nDone. {len(written)} files written.")


if __name__ == "__main__":
    main()
