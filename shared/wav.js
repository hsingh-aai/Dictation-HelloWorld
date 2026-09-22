export const TARGET_RATE = 16000;  // API accepts any WAV rate; 16k mono keeps uploads small.
export const MAX_MS = 120_000;     // Hard API limit.
export const MIN_MS = 80;          // Hard API floor.

/** Decode whatever MediaRecorder produced, downmix to mono, resample, emit a WAV blob. */
export async function toWav(blob) {
  const ctx = new AudioContext();
  const decoded = await ctx.decodeAudioData(await blob.arrayBuffer());
  await ctx.close();

  const frames = Math.ceil(decoded.duration * TARGET_RATE);
  const offline = new OfflineAudioContext(1, frames, TARGET_RATE);
  const node = offline.createBufferSource();
  node.buffer = decoded;
  node.connect(offline.destination);
  node.start();
  const mono = (await offline.startRendering()).getChannelData(0);

  const bytes = new ArrayBuffer(44 + mono.length * 2);
  const view = new DataView(bytes);
  const ascii = (off, s) => [...s].forEach((c, i) => view.setUint8(off + i, c.charCodeAt(0)));
  ascii(0, 'RIFF');
  view.setUint32(4, 36 + mono.length * 2, true);
  ascii(8, 'WAVEfmt ');
  view.setUint32(16, 16, true);
  view.setUint16(20, 1, true);
  view.setUint16(22, 1, true);
  view.setUint32(24, TARGET_RATE, true);
  view.setUint32(28, TARGET_RATE * 2, true);
  view.setUint16(32, 2, true);
  view.setUint16(34, 16, true);
  ascii(36, 'data');
  view.setUint32(40, mono.length * 2, true);
  for (let i = 0; i < mono.length; i++) {
    const s = Math.max(-1, Math.min(1, mono[i]));
    view.setInt16(44 + i * 2, s < 0 ? s * 0x8000 : s * 0x7fff, true);
  }
  return new Blob([bytes], { type: 'audio/wav' });
}
