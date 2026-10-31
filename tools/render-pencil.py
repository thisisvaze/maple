"""Render Skuzic's pencil friction once; only the WAV ships in the audio path.
Run with Python 3 and ffmpeg. See Maple/Pencil-LICENSE.txt for provenance.
"""
import array
import math
from pathlib import Path
import random
import subprocess
import tempfile
import wave

rate = 24_000
rng = random.Random(140)
tooth = 0.0
grain = []
k = 1 - math.exp(-2 * math.pi * 140 / rate)
for _ in range(round(rate * 4.28)):
    tooth += (abs(rng.uniform(-1, 1)) - tooth) * k
    grain.append(tooth)
mean = sum(grain) / len(grain)
noise = array.array('f', (rng.uniform(-1, 1) * (0.15 + 0.85 * g / mean) for g in grain))

with tempfile.TemporaryDirectory() as folder:
    raw, filtered = Path(folder) / 'paper.f32', Path(folder) / 'paper.wav'
    raw.write_bytes(noise.tobytes())
    subprocess.run([
        'ffmpeg', '-v', 'error', '-f', 'f32le', '-ar', str(rate), '-ac', '1', '-i', str(raw),
        '-af', 'lowpass=f=4200:t=q:w=0.5,highpass=f=700:t=q:w=0.6,equalizer=f=3200:t=q:w=0.9:g=5,volume=0.35',
        '-c:a', 'pcm_s16le', str(filtered),
    ], check=True)
    with wave.open(str(filtered)) as audio:
        samples = list(array.array('h', audio.readframes(audio.getnframes())))[round(rate * 0.2):]

# Equal-power wrap, with no recorded pen lifts or new attack at the loop boundary.
overlap = round(rate * 0.08)
blend = [samples[-overlap + i] * math.cos(i / (overlap - 1) * math.pi / 2)
         + samples[i] * math.sin(i / (overlap - 1) * math.pi / 2) for i in range(overlap)]
samples = samples[overlap:-overlap] + blend
rms = math.sqrt(sum(s * s for s in samples) / len(samples))
samples = array.array('h', (round(s * 0.14 * 32767 / rms) for s in samples))

# A sustained line must not contain the short scribbles' rhythmic dips.
window = round(rate * 0.02)
levels = [math.sqrt(sum(s * s for s in samples[i:i + window]) / window)
          for i in range(0, len(samples), window)]
average = sum(levels) / len(levels)
assert len(samples) == rate * 4
assert min(levels) > average * 0.6 and max(levels) < average * 1.5
assert max(map(abs, samples)) < 32767 * 0.9
assert abs(samples[0] - samples[-1]) < max(abs(a - b) for a, b in zip(samples, samples[1:]))

destination = Path(__file__).resolve().parents[1] / 'Maple' / 'pencil.wav'
with wave.open(str(destination), 'wb') as audio:
    audio.setparams((1, 2, rate, 0, 'NONE', 'not compressed'))
    audio.writeframes(samples.tobytes())
print(f'{destination.name}: 4 s, {destination.stat().st_size:,} bytes; 20 ms levels {min(levels) / average:.2f}–{max(levels) / average:.2f} of mean')
