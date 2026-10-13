// "I Am a Furby Girl" — a bubblegum-pop track built from AssemblyAI TTS voices.
// Vocals: TTS lines pitched up (chipmunk/Furby), doubled an octave up, chorus + 8th-note echo.
// Backing: kick / snare / hats / bass / arp synthesized right here in JS.
import path from "node:path";
import { SR, OUT, ttsAll, pitch, processToFloat, mixInto, writeMaster } from "./fx.js";

const BPM = 128;
const BEAT = 60 / BPM;
const BAR = BEAT * 4;

const FURBY = "jane";   // the Furby
const GUY = "george";   // the sleepy owner

// [bar, voice, text, semitones]
const CHORUS = (start) => [
  [start + 0, FURBY, "I am a Furby girl, in a Furby world!", 4],
  [start + 2, FURBY, "Fuzzy and fluffy, my eyes go blink blink!", 4],
  [start + 4, FURBY, "I can talk, I can sing, I can learn anything!", 4],
  [start + 6, FURBY, "I am a Furby girl, and I never sleep!", 5],
];
const LINES = [
  [1, FURBY, "Dah ay loh oo tye! Kah may may!", 4],
  [2, FURBY, "Hee hee hee! Tickle me!", 4],
  ...CHORUS(4),
  [12, GUY, "Hey Furby, it's three A M. Why are you still talking?", -2],
  [14, FURBY, "Me love you! Me hungry! Tickle me again!", 4],
  [16, GUY, "Where is the off switch? There is no off switch!", -2],
  [18, FURBY, "Oo nye loo lay loo! That means party time!", 4],
  ...CHORUS(20),
  [28, FURBY, "Me sleepy now. Goodnight. Kah may may.", 2],
];
const TOTAL_BARS = 32;

// --- backing track ---------------------------------------------------------
const N = Math.ceil((TOTAL_BARS * BAR + 3) * SR);
const beat = new Float32Array(N);
const noise = () => Math.random() * 2 - 1;
const at = (sec) => Math.round(sec * SR);

function kick(t) {
  const len = at(0.25);
  let ph = 0;
  for (let i = 0; i < len; i++) {
    const s = i / SR;
    ph += (2 * Math.PI * (50 + 110 * Math.exp(-s * 30))) / SR;
    beat[at(t) + i] += Math.sin(ph) * Math.exp(-s * 12) * 0.9;
  }
}
function snare(t) {
  for (let i = 0; i < at(0.18); i++) {
    const s = i / SR;
    beat[at(t) + i] += (noise() * 0.5 + Math.sin(2 * Math.PI * 190 * s) * 0.3) * Math.exp(-s * 22) * 0.6;
  }
}
function hat(t, g = 0.18) {
  let prev = 0;
  for (let i = 0; i < at(0.05); i++) {
    const n = noise();
    beat[at(t) + i] += (n - prev) * Math.exp(-(i / SR) * 90) * g; // crude high-pass
    prev = n;
  }
}
function tone(t, freq, dur, gain, shape) {
  for (let i = 0; i < at(dur); i++) {
    const s = i / SR;
    const p = (freq * s) % 1;
    const w = shape === "saw" ? 2 * p - 1 : p < 0.5 ? 1 : -1;
    beat[at(t) + i] += w * Math.min(1, s * 400) * Math.exp(-s * (3 / dur)) * gain;
  }
}

const hz = (midi) => 440 * 2 ** ((midi - 69) / 12);
// Am - F - C - G, one chord per bar
const CHORDS = [[57, 60, 64], [53, 57, 60], [48, 52, 55], [55, 59, 62]];

for (let bar = 0; bar < TOTAL_BARS; bar++) {
  const t0 = bar * BAR;
  const chord = CHORDS[bar % 4];
  const outro = bar >= 28;
  const breakdown = bar >= 12 && bar < 20;
  for (let b = 0; b < 4; b++) {
    const t = t0 + b * BEAT;
    if (!outro && (!breakdown || b % 2 === 0)) kick(t);
    if (!outro && (b === 1 || b === 3)) snare(t);
    if (!outro) { hat(t + BEAT / 2); if (!breakdown) hat(t, 0.08); }
  }
  for (let e = 0; e < 8; e++) {
    if (bar < 2 || outro) break;
    tone(t0 + e * BEAT / 2, hz(chord[0] - 24), BEAT / 2 * 0.9, 0.28, "saw");
  }
  for (let s = 0; s < 16; s++) {
    if (outro && bar > 29) break;
    const note = chord[[0, 1, 2, 1][s % 4]] + (s >= 8 ? 12 : 0) + 12;
    tone(t0 + s * BEAT / 4, hz(note), BEAT / 4, outro ? 0.05 : 0.08, "square");
  }
}

// --- vocals ----------------------------------------------------------------
console.log("Generating vocals…");
const files = await ttsAll(LINES.map(([, voice, text]) => ({ voice, text })));
const vox = new Float32Array(N);
const SLOT = BAR * 2 * 0.92;

LINES.forEach(([bar, voice, , semis], i) => {
  const dry = processToFloat(files[i], pitch(semis));
  const fit = Math.max(1, dry.length / SR / SLOT);
  const furby = voice === FURBY;
  const fitChain = fit > 1.001 ? `atempo=${fit.toFixed(4)},` : "";
  const isOutro = bar >= 28;
  const main = processToFloat(files[i], [
    pitch(semis),
    fitChain + `highpass=f=${furby ? 140 : 70}`,
    "acompressor=threshold=0.1:ratio=3:attack=5:release=80",
    "equalizer=f=3000:t=q:w=1.2:g=3", // presence, so words cut through the beat
    `aecho=0.8:0.4:${Math.round(BEAT * 500)}:0.1`, // just a hint of slapback
    isOutro ? "vibrato=f=3:d=0.15" : "",
  ].filter(Boolean).join(","));
  mixInto(vox, main, bar * BAR + 0.05, furby ? 1 : 1.1);
});

// Duck the beat under the vocals (simple sidechain) so every word stays clear.
const env = new Float32Array(N);
let e = 0;
for (let i = 0; i < N; i++) {
  const a = Math.abs(vox[i]);
  e = a > e ? e + (a - e) * 0.01 : e * 0.99995;
  env[i] = e;
}
const mix = new Float32Array(N);
for (let i = 0; i < N; i++) mix[i] = beat[i] * 0.42 * (1 - Math.min(0.45, env[i] * 3)) + vox[i];
writeMaster(mix, path.join(OUT, "furby-girl.mp3"), "afade=t=out:st=" + (TOTAL_BARS * BAR - 1).toFixed(2) + ":d=3");
