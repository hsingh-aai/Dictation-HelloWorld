// Text -> WAV using AssemblyAI's Voice Agent API voices.
// The agent's `greeting` is spoken verbatim at session start, so we use it as a
// plain TTS call: open a session, collect reply.audio until reply.done, close.
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));

function loadKey() {
  if (process.env.ASSEMBLY_AI_KEY) return process.env.ASSEMBLY_AI_KEY;
  const env = fs.readFileSync(path.join(here, "..", ".env"), "utf8");
  const m = env.match(/^ASSEMBLY_AI_KEY=(.+)$/m);
  if (!m) throw new Error("ASSEMBLY_AI_KEY missing from .env");
  return m[1].trim();
}

export const SAMPLE_RATE = 24000;

async function getToken(key) {
  const url = new URL("https://agents.assemblyai.com/v1/token");
  url.searchParams.set("expires_in_seconds", "60");
  url.searchParams.set("max_session_duration_seconds", "120");
  const res = await fetch(url, { headers: { Authorization: key } });
  if (!res.ok) throw new Error(`token ${res.status}: ${await res.text()}`);
  return (await res.json()).token;
}

// Returns raw PCM16 mono 24 kHz as a Buffer.
export async function speak(text, voice = "alba") {
  const token = await getToken(loadKey());
  const url = new URL("wss://agents.assemblyai.com/v1/ws");
  url.searchParams.set("token", token);
  const ws = new WebSocket(url);
  const chunks = [];

  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => { ws.close(); reject(new Error("timeout")); }, 45000);
    const finish = () => { clearTimeout(timer); resolve(Buffer.concat(chunks)); };

    ws.addEventListener("open", () => {
      ws.send(JSON.stringify({
        type: "session.update",
        session: {
          system_prompt: "You only ever repeat your greeting. Never add anything.",
          greeting: text,
          output: { voice },
        },
      }));
    });
    ws.addEventListener("message", (ev) => {
      const msg = JSON.parse(ev.data);
      if (msg.type === "reply.audio") chunks.push(Buffer.from(msg.data, "base64"));
      else if (msg.type === "reply.done") {
        ws.send(JSON.stringify({ type: "session.end" }));
        setTimeout(() => { ws.close(); finish(); }, 200);
      } else if (msg.type === "session.error") {
        clearTimeout(timer); ws.close(); reject(new Error(`${msg.code}: ${msg.message}`));
      }
    });
    ws.addEventListener("error", (e) => { clearTimeout(timer); reject(e.error ?? new Error("ws error")); });
  });
}

export function wavHeader(dataLen, rate = SAMPLE_RATE) {
  const h = Buffer.alloc(44);
  h.write("RIFF", 0); h.writeUInt32LE(36 + dataLen, 4); h.write("WAVE", 8);
  h.write("fmt ", 12); h.writeUInt32LE(16, 16); h.writeUInt16LE(1, 20); h.writeUInt16LE(1, 22);
  h.writeUInt32LE(rate, 24); h.writeUInt32LE(rate * 2, 28); h.writeUInt16LE(2, 32); h.writeUInt16LE(16, 34);
  h.write("data", 36); h.writeUInt32LE(dataLen, 40);
  return h;
}

export async function speakToWav(text, voice, outFile) {
  const pcm = await speak(text, voice);
  fs.writeFileSync(outFile, Buffer.concat([wavHeader(pcm.length), pcm]));
  return outFile;
}

// CLI: node speak.js "text" [voice] [out.wav]
if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const [text = "Hello from AssemblyAI.", voice = "alba", out = "out/hello.wav"] = process.argv.slice(2);
  fs.mkdirSync(path.dirname(path.resolve(out)), { recursive: true });
  speakToWav(text, voice, out).then((f) => console.log("wrote", f), (e) => { console.error(e); process.exit(1); });
}
