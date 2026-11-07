#!/usr/bin/env python3
"""Composes the rhythm mode's three tracks and the accents their notes follow.

Every sound is synthesised here from code (no samples, no recordings, no borrowed melodies), so the music is
original and released under CC0. Replace the tracks at any time: tracks.json only needs a file, a tempo, the second
of the first playable beat and, optionally, accents.

Usage: python3 compose_tracks.py <out dir>      needs numpy, scipy and ffmpeg (aac encoder)
Writes <id>.m4a for each track and tracks.json next to them.
"""
import json
import os
import subprocess
import sys
import tempfile

import numpy as np
from scipy import signal
from scipy.io import wavfile

SR = 44100
rng = np.random.default_rng(2026)

LETTER = {"C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11}

# Bars of each section. Notes are played from the first bar of A to the first beat of the ending.
FORM = [("intro", 2), ("A", 8), ("B", 8), ("D", 4), ("A2", 8), ("end", 2)]
FIRST_BAR = 2
PLAY_BEATS = 4 * (8 + 8 + 4 + 8) + 1  # through the downbeat of the ending

# Motifs are two bars of (eighth, MIDI note, length in eighths), written over the first two chords of their section.
TRACKS = [
    dict(id="orbit", title="Орбита", bpm=88, style="calm", scale=[0, 2, 4, 5, 7, 9, 11],
         prog={"intro": ["C", "G"], "A": ["Am", "F", "C", "G"], "B": ["C", "G", "Am", "F"],
               "D": ["F", "G", "Am", "Am"], "end": ["Am"]},
         motif={"A": [(0, 76, 2), (3, 72, 1), (4, 74, 1), (5, 76, 3), (8, 77, 2), (11, 76, 1), (12, 72, 2), (14, 69, 2)],
                "B": [(0, 79, 2), (3, 76, 1), (4, 74, 2), (6, 72, 2), (8, 74, 3), (11, 71, 1), (12, 74, 4)]}),
    dict(id="stardust", title="Звёздная пыль", bpm=104, style="bright", scale=[2, 4, 6, 7, 9, 11, 1],
         prog={"intro": ["G", "A"], "A": ["D", "Bm", "G", "A"], "B": ["G", "A", "D", "Bm"],
               "D": ["Bm", "G", "D", "A"], "end": ["D"]},
         motif={"A": [(0, 78, 2), (2, 81, 2), (4, 83, 1), (5, 81, 1), (6, 78, 2), (8, 78, 2), (10, 74, 2), (12, 76, 2),
                      (14, 78, 2)],
                "B": [(0, 79, 2), (2, 83, 2), (4, 81, 2), (6, 79, 1), (7, 78, 1), (8, 76, 3), (11, 78, 1), (12, 81, 4)]}),
    dict(id="meteor-shower", title="Метеоритный дождь", bpm=124, style="drive", scale=[7, 9, 11, 0, 2, 4, 6],
         prog={"intro": ["G", "D"], "A": ["Em", "C", "G", "D"], "B": ["G", "D", "Em", "C"],
               "D": ["C", "D", "Em", "Em"], "end": ["Em"]},
         motif={"A": [(0, 76, 1), (2, 76, 1), (3, 79, 1), (4, 83, 2), (6, 81, 1), (7, 79, 1), (8, 76, 2), (10, 79, 1),
                      (11, 76, 1), (12, 74, 2), (14, 72, 2)],
                "B": [(0, 74, 1), (2, 79, 1), (3, 81, 1), (4, 83, 2), (6, 81, 2), (8, 78, 2), (10, 74, 1), (11, 78, 1),
                      (12, 81, 4)]}),
]


# ---------------------------------------------------------------- harmony

def hz(m):
    return 440.0 * 2.0 ** ((m - 69) / 12)


def chord(name):
    """'F#m' -> (root pitch class, set of chord pitch classes)."""
    root, rest = LETTER[name[0]], name[1:]
    if rest[:1] == "#":
        root, rest = root + 1, rest[1:]
    elif rest[:1] == "b":
        root, rest = root - 1, rest[1:]
    root %= 12
    third = 3 if rest[:1] == "m" else 4
    return root, {root, (root + third) % 12, (root + 7) % 12}


def scale_notes(scale):
    return [n for n in range(24, 110) if n % 12 in scale]


def steps_between(root_from, root_to, scale):
    """Scale steps from one chord root to another, -3..3."""
    d = (scale.index(root_to) - scale.index(root_from)) % 7
    return d - 7 if d > 3 else d


def diatonic(m, steps, scale):
    notes = scale_notes(scale)
    i = min(range(len(notes)), key=lambda j: abs(notes[j] - m))
    return notes[i + steps]


def snap(m, pcs):
    """Nearest note of the chord, upwards on a tie."""
    for d in (0, 1, -1, 2, -2, 3, -3, 4, -4):
        if (m + d) % 12 in pcs:
            return m + d
    return m


def voicing(pcs, prev):
    """Three chord tones between E3 and B4, moving as little as possible from the last chord."""
    options = [[n for n in range(52, 72) if n % 12 == pc] for pc in sorted(pcs)]
    best, best_cost = None, None
    for a in options[0]:
        for b in options[1]:
            for c in options[2]:
                v = sorted((a, b, c))
                if v[2] - v[0] > 12:
                    continue
                cost = abs(sum(v) / 3 - 62) * 0.3
                if prev:
                    cost += sum(abs(x - y) for x, y in zip(v, prev))
                if best_cost is None or cost < best_cost:
                    best, best_cost = v, cost
    return best


# ---------------------------------------------------------------- instruments

def band_noise(n, lo, hi):
    sos = signal.butter(2, [lo, hi], "band", fs=SR, output="sos")
    return signal.sosfilt(sos, rng.standard_normal(n))


def high_noise(n, lo, order=4):
    sos = signal.butter(order, lo, "high", fs=SR, output="sos")
    return signal.sosfilt(sos, rng.standard_normal(n))


def saw(f, n, fc, phase=0.0):
    """Band-limited sawtooth through a 24 dB/octave low-pass at fc (Hz, a number or one per sample)."""
    t = np.arange(n) / SR
    w = 2 * np.pi * f * t + phase
    out = np.zeros(n)
    top = min(SR / 2 - 1500, 3.0 * float(np.max(fc)))
    k = 1
    while k * f < top:
        g = 1.0 / np.sqrt(1.0 + (k * f / fc) ** 8)
        out += g * np.sin(k * w) / k
        k += 1
    return out


def release(env, t, at, tau):
    off = t > at
    env[off] *= np.exp(-(t[off] - at) / tau)
    return env


def kick(soft=False):
    n = int(0.45 * SR)
    t = np.arange(n) / SR
    f = 50 + (150 if soft else 185) * np.exp(-t / 0.03)
    body = np.sin(2 * np.pi * np.cumsum(f) / SR) * np.exp(-t / (0.15 if soft else 0.18))
    body = np.tanh(2.4 * body) / np.tanh(2.4)  # overtones, so a phone speaker plays it
    click = band_noise(n, 1800, 7000) * np.exp(-t / 0.003) * (0.35 if soft else 0.55)
    s = (body + click) * (1 - np.exp(-t / 0.0007))
    return s / np.max(np.abs(s))


def clap():
    n = int(0.4 * SR)
    t = np.arange(n) / SR
    env = np.zeros(n)
    for d in (0.0, 0.010, 0.021):
        on = t >= d
        env[on] += np.exp(-(t[on] - d) / 0.005)
    on = t >= 0.021
    env[on] += 0.7 * np.exp(-(t[on] - 0.021) / 0.10)
    s = band_noise(n, 900, 5200) * env + 0.35 * np.sin(2 * np.pi * 185 * t) * np.exp(-t / 0.035)
    return s / np.max(np.abs(s))


def snare():
    n = int(0.3 * SR)
    t = np.arange(n) / SR
    f = 175 + 60 * np.exp(-t / 0.01)
    body = np.sin(2 * np.pi * np.cumsum(f) / SR) * np.exp(-t / 0.05)
    s = 0.6 * body + band_noise(n, 1500, 9000) * np.exp(-t / 0.075)
    s *= 1 - np.exp(-t / 0.0005)
    return s / np.max(np.abs(s))


def hat(open_=False):
    n = int((0.4 if open_ else 0.09) * SR)
    t = np.arange(n) / SR
    metal = sum(np.sign(np.sin(2 * np.pi * f * t + rng.uniform(0, 6.28)))
                for f in (205.3, 304.4, 369.6, 522.7, 540.0, 800.0)) / 6
    s = 0.5 * metal + 0.8 * rng.standard_normal(n)
    s = signal.sosfilt(signal.butter(4, 7000, "high", fs=SR, output="sos"), s)
    s *= np.exp(-t / (0.11 if open_ else 0.017)) * (1 - np.exp(-t / 0.0004))
    return s / np.max(np.abs(s))


def shaker():
    n = int(0.12 * SR)
    t = np.arange(n) / SR
    s = band_noise(n, 4500, 11000) * (1 - np.exp(-t / 0.008)) * np.exp(-t / 0.035)
    return s / np.max(np.abs(s))


def crash():
    n = int(2.2 * SR)
    t = np.arange(n) / SR
    metal = sum(np.sign(np.sin(2 * np.pi * f * t + rng.uniform(0, 6.28)))
                for f in (311.0, 437.0, 529.0, 697.0, 853.0, 1021.0)) / 6
    s = 0.4 * metal + rng.standard_normal(n)
    s = signal.sosfilt(signal.butter(2, 3500, "high", fs=SR, output="sos"), s)
    s *= np.exp(-t / 0.7) * (1 - np.exp(-t / 0.001))
    return np.vstack([s, np.roll(s, 220)]) / np.max(np.abs(s))


def tick():
    n = int(0.05 * SR)
    t = np.arange(n) / SR
    s = band_noise(n, 2500, 8000) * np.exp(-t / 0.006) + 0.3 * np.sin(2 * np.pi * 1650 * t) * np.exp(-t / 0.01)
    return s / np.max(np.abs(s))


def riser(sec):
    n = int(sec * SR)
    t = np.arange(n) / SR
    x = t / sec
    f = 300 * 2 ** (4.5 * x)
    sweep = np.sin(2 * np.pi * np.cumsum(f) / SR) * 0.15
    s = (high_noise(n, 1200, 2) * 0.6 + sweep) * x ** 2.2
    return s / np.max(np.abs(s))


def pad_chord(notes, sec, fc):
    n = int((sec + 0.8) * SR)
    t = np.arange(n) / SR
    env = release(np.minimum(1.0, t / 0.07), t, sec, 0.28)
    left, right = np.zeros(n), np.zeros(n)
    for m in notes:
        for cents, wl, wr in ((-7, 0.85, 0.2), (0, 0.5, 0.5), (7, 0.2, 0.85)):
            s = saw(hz(m) * 2 ** (cents / 1200), n, fc, rng.uniform(0, 2 * np.pi))
            left += wl * s
            right += wr * s
    return np.vstack([left, right]) * env


def bass_note(m, sec, bright):
    n = int((sec + 0.03) * SR)
    t = np.arange(n) / SR
    fc = 240 + 1100 * bright * np.exp(-t / 0.075)
    s = 0.75 * saw(hz(m), n, fc) + 0.55 * np.sin(2 * np.pi * hz(m) * t)
    env = release(1 - np.exp(-t / 0.0025), t, sec, 0.012)
    return s * env


def pluck(m, sec, bright=1.0, ring=1.0, body=0.22):
    """Struck partials that fade faster the higher they are, over a soft sustained tone that holds long notes."""
    f = hz(m)
    n = int((sec + 0.55 * ring) * SR)
    t = np.arange(n) / SR
    out = np.zeros(n)
    for k in range(1, 14):
        fk = f * k * (1 + 0.0003 * k * k)
        if fk > 15000:
            break
        tau = ring * 0.8 / (1 + 0.55 * (k - 1)) * (440 / f) ** 0.25
        out += bright ** (k - 1) / k ** 1.1 * np.exp(-t / tau) * np.sin(2 * np.pi * fk * t)
    sustain = np.sin(2 * np.pi * f * t) + 0.25 * np.sin(4 * np.pi * f * t)
    out += body * sustain * np.minimum(1.0, t / 0.04)
    out *= 1 - np.exp(-t / 0.0015)
    return release(out, t, sec, 0.08 * ring)


def reverb(x, rt60, pre=0.018):
    n = int((rt60 + pre) * SR)
    t = np.arange(n) / SR
    ir = rng.standard_normal((2, n)) * np.exp(-6.9 * t / rt60)
    ir = signal.sosfilt(signal.butter(1, 5500, "low", fs=SR, output="sos"), ir, axis=1)
    ir[:, : int(pre * SR)] = 0
    ir /= np.sqrt(np.sum(ir ** 2, axis=1, keepdims=True))
    return np.vstack([signal.fftconvolve(x[0], ir[0])[: x.shape[1]], signal.fftconvolve(x[1], ir[1])[: x.shape[1]]])


def ping_pong(x, delay, feedback=0.4, taps=6):
    n = x.shape[1]
    out = np.zeros_like(x)
    y = signal.sosfilt(signal.butter(2, [350, 5200], "band", fs=SR, output="sos"), 0.5 * (x[0] + x[1]))
    darker = signal.butter(1, 3500, "low", fs=SR, output="sos")
    d = int(round(delay * SR))
    for k in range(1, taps + 1):
        if k * d >= n:
            break
        out[(k - 1) % 2, k * d:] += feedback ** (k - 1) * y[: n - k * d]
        y = signal.sosfilt(darker, y)
    return out


# ---------------------------------------------------------------- arrangement

class Mixer:
    BUSES = ("drums", "bass", "pads", "lead", "arp", "verb", "echo")

    def __init__(self, sec):
        self.n = int(sec * SR)
        self.bus = {b: np.zeros((2, self.n)) for b in self.BUSES}

    def add(self, bus, sig, at, gain=1.0, pan=0.0, sends=()):
        i = int(round(at * SR))
        if i >= self.n:
            return
        if sig.ndim == 1:
            a = (pan + 1) * np.pi / 4
            sig = np.vstack([sig * np.cos(a), sig * np.sin(a)]) * np.sqrt(2)
        k = min(sig.shape[1], self.n - i)
        part = sig[:, :k] * gain
        self.bus[bus][:, i:i + k] += part
        for b, amount in sends:
            self.bus[b][:, i:i + k] += part * amount


def sections():
    bar = 0
    for name, bars in FORM:
        yield name, bar, bars
        bar += bars


def compose(tr):
    style, scale, prog, motif = tr["style"], tr["scale"], tr["prog"], tr["motif"]
    beat = 60.0 / tr["bpm"]
    bar_sec, e8, e16 = 4 * beat, beat / 2, beat / 4
    total_bars = sum(b for _, b in FORM)
    mix = Mixer(total_bars * bar_sec + 1.5)
    soft = style == "calm"
    k_sound, c_sound, s_sound = kick(soft), clap(), snare()
    hats = [hat() for _ in range(6)]
    o_hat, cr, tk, sh = hat(True), crash(), tick(), [shaker() for _ in range(4)]
    kicks = []

    # Chords of every bar, and the melody: (sixteenth from the start, MIDI, length in sixteenths, velocity, section).
    bar_chords, melody = [], []
    for name, b0, bars in sections():
        key = "A" if name == "A2" else name
        for i in range(bars):
            bar_chords.append(prog[key][i % len(prog[key])])
        if name in ("A", "B", "A2", "D"):
            m = motif["B" if name == "B" else "A"]
            ref = chord(prog["B" if name == "B" else "A"][0])[0]
            for rep in range(bars // 2):
                c1, c2 = bar_chords[b0 + 2 * rep], bar_chords[b0 + 2 * rep + 1]
                shift = steps_between(ref, chord(c1)[0], scale)
                for e, note, length in m:
                    if name == "D" and length < 2:
                        continue  # the breakdown keeps only the long notes
                    p = diatonic(note, shift, scale)
                    if e % 8 == 0 or length >= 3:
                        p = snap(p, chord(c1 if e < 8 else c2)[1])
                    on_beat = e % 2 == 0
                    vel = 1.0 if e % 8 == 0 else 0.88 if on_beat else 0.78
                    melody.append(((b0 + 2 * rep) * 16 + 2 * e, p, 2 * length, vel * (0.75 if name == "D" else 1), name))
        if name == "end":
            last = melody[-1][1]
            root = chord(prog["end"][0])[0]
            final = min((n for n in range(60, 90) if n % 12 == root), key=lambda n: abs(n - last))
            melody.append((b0 * 16, final, 24, 1.0, name))

    # Section of each bar.
    bar_section = []
    for name, b0, bars in sections():
        bar_section += [name] * bars

    # ---- pads
    prev = None
    pad_cache = {}
    for b, c in enumerate(bar_chords):
        name = bar_section[b]
        fc = {"intro": 900, "A": 1500, "B": 1900, "D": 1200, "A2": 2100, "end": 1300}[name]
        v = voicing(chord(c)[1], prev)
        prev = v
        hold_bars = 2 if name == "end" else 1
        if name == "end" and b > FORM_START("end"):
            continue
        key = (tuple(v), hold_bars, fc)
        if key not in pad_cache:
            pad_cache[key] = pad_chord(v, hold_bars * bar_sec, fc)
        mix.add("pads", pad_cache[key], b * bar_sec, gain=0.034, sends=(("verb", 0.45 if name == "D" else 0.3),))

    # ---- bass, in sixteenths: (start, length, octave up, velocity)
    off8 = [(s, 2, 0, 0.9) for s in (2, 6, 10, 14)]
    run8 = [(s, 2, 12 if s in (6, 14) else 0, 1.0 if s % 4 == 0 else 0.85) for s in range(0, 16, 2)]
    run16 = [(s, 1, 12 if s % 8 == 6 else 0, 1.0 if s % 4 == 0 else 0.75) for s in range(16)]
    held = [(0, 16, 0, 0.8)]
    patterns = {
        "calm": {"intro": None, "A": off8, "B": run8, "D": held, "A2": off8 + [(7, 1, 12, 0.6)], "end": [(0, 16, 0, 0.8)]},
        "bright": {"intro": None, "A": off8, "B": run8, "D": held, "A2": run8, "end": [(0, 16, 0, 0.8)]},
        "drive": {"intro": None, "A": run8, "B": run16, "D": held, "A2": run8, "end": [(0, 16, 0, 0.8)]},
    }[style]
    bass_cache = {}
    for b, c in enumerate(bar_chords):
        name = bar_section[b]
        pat = patterns[name]
        if name == "intro" and b == 1:
            pat = held
        if pat is None or (name == "end" and b > FORM_START("end")):
            continue
        root = 36 + chord(c)[0]
        bright = 0.6 if name in ("D", "end", "intro") else 1.0 if name == "A2" else 0.85
        for s, length, up, vel in pat:
            key = (root + up, length, bright)
            if key not in bass_cache:
                bass_cache[key] = bass_note(root + up, length * e16 * 0.92, bright)
            mix.add("bass", bass_cache[key], b * bar_sec + s * e16, gain=0.16 * vel)

    # ---- drums
    for b in range(total_bars):
        name = bar_section[b]
        t0 = b * bar_sec
        if name == "intro":
            for q in range(4):
                g = 0.45 if b == 0 else 0.7
                mix.add("drums", k_sound, t0 + q * beat, gain=0.8 * g)
                kicks.append(t0 + q * beat)
            if b == 1:
                for s in (2, 6, 10, 14):
                    mix.add("drums", hats[s % 6], t0 + s * e16, gain=0.07, pan=0.25)
                mix.add("drums", c_sound, t0 + 12 * e16, gain=0.22, sends=(("verb", 0.2),))
            continue
        if name == "end":
            if b == FORM_START("end"):
                mix.add("drums", k_sound, t0, gain=0.8)
                kicks.append(t0)
                mix.add("drums", cr, t0, gain=0.16)
            continue
        if name == "D":
            last = b == FORM_START("D") + 3
            if not last:
                for q in range(4):
                    mix.add("drums", tk, t0 + q * beat, gain=0.05 if q else 0.08, pan=-0.2)
            else:
                step = 2 if soft else 1
                hits = list(range(0, 16, step))
                for j, s in enumerate(hits):
                    g = 0.05 + 0.25 * (j / len(hits)) ** 1.6
                    mix.add("drums", s_sound if not soft else c_sound, t0 + s * e16, gain=g, sends=(("verb", 0.2),))
                mix.add("drums", riser(2 * bar_sec), t0 - bar_sec, gain=0.10)
            continue
        # A, B, A2
        if b == FORM_START(name):
            mix.add("drums", cr, t0, gain=0.16)
        for q in range(4):
            mix.add("drums", k_sound, t0 + q * beat, gain=0.8)
            kicks.append(t0 + q * beat)
        for q in (1, 3):
            mix.add("drums", c_sound, t0 + q * beat, gain=0.32, sends=(("verb", 0.15),))
            if style == "drive":
                mix.add("drums", s_sound, t0 + q * beat, gain=0.16)
        dense = name in ("B", "A2")
        if soft:
            for s in range(0, 16, 2):
                mix.add("drums", sh[s % 4], t0 + s * e16, gain=0.06 if s % 4 else 0.035, pan=0.3)
            if name != "A":
                for s in (2, 6, 10, 14):
                    mix.add("drums", hats[s % 6], t0 + s * e16, gain=0.05, pan=-0.2)
        elif dense:
            for s in range(16):
                g = 0.075 if s % 4 == 2 else 0.04 if s % 2 else 0.03
                mix.add("drums", hats[s % 6], t0 + s * e16, gain=g, pan=0.25)
            if b % 2 == 1:
                mix.add("drums", o_hat, t0 + 14 * e16, gain=0.07, pan=0.25)
        else:
            for s in (2, 6, 10, 14):
                mix.add("drums", hats[s % 6], t0 + s * e16, gain=0.075, pan=0.25)

    # ---- lead
    for s, p, length, vel, name in melody:
        at = s * e16
        sec = length * e16 * 0.95
        ring = 1.6 if name in ("D", "end") else 1.0
        mix.add("lead", pluck(p, sec, bright=0.62, ring=ring), at, gain=0.2 * vel, pan=-0.05,
                sends=(("echo", 0.22), ("verb", 0.5 if name in ("D", "end") else 0.25)))
        if name == "A2":
            mix.add("lead", pluck(p + 12, sec, bright=0.45, ring=0.8, body=0.05), at, gain=0.06 * vel, pan=0.3,
                    sends=(("echo", 0.3), ("verb", 0.3)))

    # ---- arpeggio over the chords in B and A2 (eighths on the calm track)
    for b, c in enumerate(bar_chords):
        name = bar_section[b]
        if name not in ("B", "A2"):
            continue
        root, pcs = chord(c)
        tones = sorted(n for n in range(74, 92) if n % 12 in pcs)[:4]
        order = tones + tones[-2:0:-1]
        step = 2 if soft else 1
        for j, s in enumerate(range(0, 16, step)):
            p = order[j % len(order)]
            mix.add("arp", pluck(p, step * e16 * 0.6, bright=0.5, ring=0.45, body=0.0), b * bar_sec + s * e16,
                    gain=(0.09 if s % 4 == 0 else 0.06), pan=0.4 if j % 2 else -0.4,
                    sends=(("echo", 0.3), ("verb", 0.3)))

    # ---- mix down
    duck = np.ones(mix.n)
    tail = np.arange(int(0.25 * SR)) / SR
    shape = 1 - (1 - np.exp(-tail / 0.003)) * np.exp(-tail / (0.14 if soft else 0.11))
    for kt in kicks:
        i = int(round(kt * SR))
        k = min(len(shape), mix.n - i)
        duck[i:i + k] = np.minimum(duck[i:i + k], 1 - 0.5 * (1 - shape[:k]))
    if os.environ.get("COMPOSE_LEVELS"):
        # Loudness per bus, weighted like K-weighting (headphones) and with a phone speaker's missing lows.
        shelf = signal.butter(1, 1500, "high", fs=SR, output="sos")
        def level(x, lo):
            y = signal.sosfilt(signal.butter(2, lo, "high", fs=SR, output="sos"), x[0] + x[1])
            y = y + 0.58 * signal.sosfilt(shelf, y)
            return 10 * np.log10(np.mean(y ** 2) + 1e-20)
        ref = level(mix.bus["drums"], 40)
        print("  K-weighted re drums: " + ", ".join(f"{b} {level(mix.bus[b], 40) - ref:+.1f}" for b in mix.BUSES))
        ref = level(mix.bus["drums"], 250)
        print("  phone re drums:      " + ", ".join(f"{b} {level(mix.bus[b], 250) - ref:+.1f}" for b in mix.BUSES))
    out = mix.bus["drums"] + mix.bus["lead"] + mix.bus["arp"]
    out += (mix.bus["bass"] + mix.bus["pads"]) * duck
    out += ping_pong(mix.bus["echo"], 0.75 * beat) * 0.6
    out += reverb(mix.bus["verb"], 2.4 if soft else 1.9) * 0.45
    out = signal.sosfilt(signal.butter(2, 30, "high", fs=SR, output="sos"), out, axis=1)
    out *= 0.15 / np.sqrt(np.mean(out ** 2))
    out = np.tanh(out / 0.92) * 0.92
    out *= 0.95 / np.max(np.abs(out))
    fade_in = int(0.02 * SR)
    out[:, :fade_in] *= np.linspace(0, 1, fade_in)
    start = int(FORM_START("end") * bar_sec * SR + bar_sec * SR)
    out[:, start:] *= np.linspace(1, 0, mix.n - start) ** 1.5
    return out, melody, bar_section, beat


def FORM_START(name):
    for n, b0, _ in sections():
        if n == name:
            return b0
    raise KeyError(name)


# ---------------------------------------------------------------- accents

def accents(melody, bar_section):
    """[beat from the first playable beat, strength 1..3]: 3 for downbeats and long melody notes, 2 for melody
    notes on the beat or held, 1 for short off-beat notes and plain beats. The breakdown is one step lighter."""
    first = FIRST_BAR * 16
    last = first + (PLAY_BEATS - 1) * 4
    acc = {}

    def put(s16, strength):
        if first <= s16 <= last:
            acc[s16] = max(acc.get(s16, 0), strength)

    onsets = {s for s, *_ in melody}
    for s, p, length, vel, name in melody:
        q = (s // 4) % 4 if s % 4 == 0 else None
        strength = 1 + (length >= 4) + (q == 0 or length >= 6)
        if name == "D":
            strength = max(1, strength - 1)
        put(s, min(3, strength))
    for b, name in enumerate(bar_section):
        for q in range(4):
            s = b * 16 + q * 4
            if name in ("A", "B", "A2"):
                if q == 0:
                    put(s, 3)
                elif not ({s - 2, s, s + 2} & onsets):
                    put(s, 1)
            elif name == "D" and q == 0:
                put(s, 2)
            elif name == "end" and q == 0 and b == FORM_START("end"):
                put(s, 3)
    return [[(s - first) / 4, v] for s, v in sorted(acc.items())]


# ---------------------------------------------------------------- output

def encode(audio, path):
    with tempfile.TemporaryDirectory() as tmp:
        wav = os.path.join(tmp, "x.wav")
        wavfile.write(wav, SR, (audio.T * 32767).astype(np.int16))
        subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", wav, "-c:a", "aac", "-b:a", "160k",
                        "-movflags", "+faststart", path], check=True)


def main():
    out_dir = sys.argv[1] if len(sys.argv) > 1 else "."
    os.makedirs(out_dir, exist_ok=True)
    entries = []
    for tr in TRACKS:
        audio, melody, bar_section, beat = compose(tr)
        path = os.path.join(out_dir, tr["id"] + ".m4a")
        encode(audio, path)
        acc = accents(melody, bar_section)
        entries.append({"id": tr["id"], "title": tr["title"], "author": "SPANTHER", "license": "CC0",
                        "file": tr["id"] + ".m4a", "bpm": tr["bpm"], "firstBeatSec": round(FIRST_BAR * 4 * beat, 6),
                        "beats": PLAY_BEATS, "phraseBeats": 8, "accents": acc})
        counts = {k: sum(1 for _, v in acc if v >= k) for k in (1, 2, 3)}
        print(f"{tr['id']}: {audio.shape[1] / SR:.1f} s, accents >=1 {counts[1]}, >=2 {counts[2]}, >=3 {counts[3]}")
    with open(os.path.join(out_dir, "tracks.json"), "w", encoding="utf-8") as f:
        f.write(json_dump(entries))


def json_dump(entries):
    """One track per block, one accent pair per item, so the file stays readable."""
    blocks = []
    for e in entries:
        head = {k: v for k, v in e.items() if k != "accents"}
        body = json.dumps(head, ensure_ascii=False)[:-1]
        pairs = ", ".join(f"[{b:g}, {v}]" for b, v in e["accents"])
        blocks.append(f'  {body},\n   "accents": [{pairs}]}}')
    return "[\n" + ",\n".join(blocks) + "\n]\n"


if __name__ == "__main__":
    main()
