// Shared helpers: cached TTS, ffmpeg effect chains, float mixing.
import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { speak, wavHeader, SAMPLE_RATE as SR } from "./speak.js";

export { SR };
export const here = path.dirname(fileURLToPath(import.meta.url));
export const OUT = path.join(here, "out");
const CACHE = path.join(OUT, "cache");
fs.mkdirSync(CACHE, { recursive: true });

// TTS with a disk cache so re-mixing doesn't re-hit the API.
export async function tts(text, voice) {
  const id = crypto.createHash("sha1").update(voice + "|" + text).digest("hex").slice(0, 12);
  const file = path.join(CACHE, `${voice}-${id}.wav`);
  if (!fs.existsSync(file)) {
    const pcm = await speak(text, voice);
    fs.writeFileSync(file, Buffer.concat([wavHeader(pcm.length), pcm]));
    console.log(`  tts ${voice}: ${text}`);
  }
  return file;
}

// Run TTS calls a few at a time.
export async function ttsAll(items, concurrency = 4) {
  const out = new Array(items.length);
  let i = 0;
  await Promise.all(Array.from({ length: concurrency }, async () => {
    while (i < items.length) { const k = i++; out[k] = await tts(items[k].text, items[k].voice); }
  }));
  return out;
}

// Pitch shift by semitones, keeping duration (asetrate changes both, atempo undoes speed).
export function pitch(semis) {
  const r = 2 ** (semis / 12);
  const tempos = [];
  let t = 1 / r;
  while (t < 0.5) { tempos.push(0.5); t /= 0.5; }
  while (t > 2) { tempos.push(2); t /= 2; }
  tempos.push(t);
  return [`asetrate=${Math.round(SR * r)}`, `aresample=${SR}`, ...tempos.map((x) => `atempo=${x.toFixed(5)}`)].join(",");
}

// Apply an ffmpeg -af chain to a wav and return mono Float32Array at SR.
export function processToFloat(file, chain) {
  const args = ["-v", "error", "-i", file];
  if (chain) args.push("-af", chain);
  args.push("-ac", "1", "-ar", String(SR), "-f", "f32le", "-");
  const buf = execFileSync("ffmpeg", args, { maxBuffer: 1 << 28 });
  return new Float32Array(buf.buffer, buf.byteOffset, buf.length / 4).slice();
}

export function mixInto(dst, src, atSec, gain = 1) {
  const off = Math.round(atSec * SR);
  for (let i = 0; i < src.length && off + i < dst.length; i++) if (off + i >= 0) dst[off + i] += src[i] * gain;
}

// Write float mono -> wav via ffmpeg with a light master chain (limiter + normalize).
export function writeMaster(samples, outFile, extra = "") {
  const raw = Buffer.from(samples.buffer, samples.byteOffset, samples.byteLength);
  const chain = [extra, "alimiter=limit=0.9", "loudnorm=I=-14:TP=-1"].filter(Boolean).join(",");
  execFileSync("ffmpeg", ["-v", "error", "-y", "-f", "f32le", "-ar", String(SR), "-ac", "1", "-i", "-",
    "-af", chain, "-ar", "44100", "-b:a", "192k", outFile], { input: raw, maxBuffer: 1 << 28 });
  console.log("wrote", path.relative(here, outFile));
}
