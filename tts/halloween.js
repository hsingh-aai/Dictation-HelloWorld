// Halloween voice pack: each style = AssemblyAI voice + script + ffmpeg effect chain
// + a little synthesized atmosphere. Writes one mp3 per style plus a combined reel.
import path from "node:path";
import { SR, OUT, ttsAll, pitch, processToFloat, mixInto, writeMaster } from "./fx.js";

const STYLES = [
  {
    id: "demon", name: "Demon", voice: "george",
    text: "You opened the wrong door. Now. You belong. To me.",
    // two octave-ish layers below the voice + dark reverb
    fx: [pitch(-5), "lowpass=f=5000", "aecho=0.8:0.5:60|120:0.25|0.15", "volume=1.4"],
    layer: { fx: [pitch(-12), "lowpass=f=900"], gain: 0.25 },
    bed: "drone",
  },
  {
    id: "ghost", name: "Ghost", voice: "jane",
    text: "Whooo is in my house? I have been waiting. For a hundred years.",
    fx: [pitch(2), "vibrato=f=5:d=0.12", "aecho=0.8:0.7:400|800:0.25|0.12", "highpass=f=200"],
    reverse: true, // reverse-reverb swell before the line
    bed: "wind",
  },
  {
    id: "witch", name: "Witch", voice: "vera",
    text: "Eye of newt, and toe of frog. Into the cauldron, little one! Hee hee hee hee!",
    fx: [pitch(2), "highpass=f=150", "aecho=0.8:0.4:180:0.12"],
    bed: "bubbles",
  },
  {
    id: "vampire", name: "Vampire", voice: "juergen",
    text: "Good evening. I never drink. Wine. Won't you come in? The night is young.",
    fx: [pitch(-3), "atempo=0.92", "aecho=0.8:0.6:90|170:0.2|0.12", "lowpass=f=7000"],
    bed: "organ",
  },
  {
    id: "zombie", name: "Zombie", voice: "michael",
    text: "Braaains. So hungry. Need. Braaaains.",
    fx: [pitch(-4), "atempo=0.85", "vibrato=f=2:d=0.25", "acrusher=bits=8:mix=0.12", "lowpass=f=4500", "volume=1.3"],
    bed: "drone",
  },
  {
    id: "robot", name: "Frankenstein's Robot", voice: "charles",
    text: "It's alive. It's alive! Initiating. Trick. Or. Treat. Protocol.",
    // clean voice with a light metallic comb, plus a quieter robotized (phase-zeroed FFT) double
    fx: ["flanger=delay=1:depth=0:regen=40:speed=0.1", "highpass=f=120"],
    layer: { fx: ["afftfilt=real='hypot(re,im)':imag='0':win_size=512:overlap=0.75", "highpass=f=200"], gain: 0.4 },
    bed: "zap",
  },
  {
    id: "radio", name: "Haunted Radio", voice: "paul",
    text: "This is an emergency broadcast. Do not. Answer. The door. They are already inside.",
    fx: ["highpass=f=300", "lowpass=f=4000", "acrusher=bits=10:mix=0.2", "tremolo=f=7:d=0.15", "volume=1.6"],
    bed: "static",
  },
  {
    id: "possessed", name: "Possessed Child", voice: "eve",
    text: "Ring around the rosie. Do you want to play with us? Forever. And ever. And ever.",
    fx: [pitch(4), "aecho=0.8:0.6:300:0.18", "vibrato=f=4:d=0.08"],
    layer: { fx: [pitch(-12), "lowpass=f=900"], gain: 0.25 }, // the thing behind her voice
    bed: "musicbox",
  },
];

// --- atmosphere beds ---------------------------------------------------------
const noise = () => Math.random() * 2 - 1;
function bed(kind, n) {
  const b = new Float32Array(n);
  let lp = 0, lp2 = 0;
  for (let i = 0; i < n; i++) {
    const t = i / SR;
    const fadeIn = Math.min(1, t / 1.5);
    let v = 0;
    if (kind === "drone") v = (Math.sin(2 * Math.PI * 41 * t) + 0.6 * Math.sin(2 * Math.PI * 43.5 * t) + 0.3 * Math.sin(2 * Math.PI * 61.7 * t)) * 0.18;
    if (kind === "wind") { lp += (noise() - lp) * (0.01 + 0.02 * (1 + Math.sin(t * 0.7))); v = lp * 1.8; }
    if (kind === "static") { v = noise() * 0.05 * (Math.random() < 0.002 ? 6 : 1) + Math.sin(2 * Math.PI * 60 * t) * 0.03; }
    if (kind === "organ") {
      const notes = [36, 39, 43, 42]; const m = notes[Math.floor(t / 2) % 4];
      for (const k of [0, 12, 19]) v += Math.sin(2 * Math.PI * 440 * 2 ** ((m + k - 69) / 12) * t) * 0.06;
    }
    if (kind === "bubbles") {
      lp2 += (noise() - lp2) * 0.05; v = lp2 * 0.4;
      const p = t % 0.37; v += Math.sin(2 * Math.PI * (300 + 900 * p) * p) * Math.exp(-p * 25) * 0.25;
    }
    if (kind === "zap") { const p = t % 2.3; if (p < 0.25) v = noise() * Math.sin(2 * Math.PI * 120 * t) * 0.25 * (1 - p * 4); v += Math.sin(2 * Math.PI * 60 * t) * 0.04; }
    if (kind === "musicbox") {
      const mel = [76, 79, 77, 76, 74, 72, 71, 72]; const step = 0.45;
      const k = Math.floor(t / step), p = t - k * step;
      v = Math.sin(2 * Math.PI * 440 * 2 ** ((mel[k % 8] - 69) / 12) * p * (1 - 0.0004 * k)) * Math.exp(-p * 6) * 0.12; // slowly detuning
    }
    b[i] = v * fadeIn;
  }
  return b;
}

// --- render -----------------------------------------------------------------
console.log("Generating voices…");
const files = await ttsAll(STYLES.map((s) => ({ voice: s.voice, text: s.text })));
const reel = [];

STYLES.forEach((s, i) => {
  const wet = processToFloat(files[i], s.fx.join(","));
  const lead = 1.2;
  const n = wet.length + Math.round((lead + 2.5) * SR);
  const out = bed(s.bed, n);
  for (let k = 0; k < n; k++) out[k] *= 0.28; // keep the atmosphere well under the voice
  mixInto(out, wet, lead);
  if (s.layer) mixInto(out, processToFloat(files[i], s.layer.fx.join(",")), lead, s.layer.gain);
  if (s.reverse) {
    // reverse the echo tail and swell it in before the voice starts
    const swell = processToFloat(files[i], ["areverse", "aecho=0.8:0.8:500|900:0.4|0.25", "areverse", "highpass=f=400"].join(","));
    mixInto(out, swell, lead - swell.length / SR + wet.length / SR * 0.15, 0.35);
  }
  writeMaster(out, path.join(OUT, `halloween-${s.id}.mp3`), `afade=t=out:st=${(n / SR - 1.5).toFixed(2)}:d=1.5`);
  reel.push(out, new Float32Array(Math.round(0.6 * SR)));
});

const total = reel.reduce((a, b) => a + b.length, 0);
const all = new Float32Array(total);
let off = 0;
for (const r of reel) { all.set(r, off); off += r.length; }
writeMaster(all, path.join(OUT, "halloween-reel.mp3"));

// manifest for the demo page
import fs from "node:fs";
fs.writeFileSync(path.join(OUT, "halloween.json"), JSON.stringify(STYLES.map(({ id, name, voice, text }) => ({ id, name, voice, text })), null, 2));
