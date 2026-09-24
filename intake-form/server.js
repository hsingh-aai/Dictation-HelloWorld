// Voice-filled patient intake form on AssemblyAI's Dictation API.
// Zero dependencies (Node 18+). Serves the page and proxies dictation so the
// API key never reaches the browser. Without this server the page still works
// as a static file: each visitor pastes their own key and it calls the API directly.
const http = require("http");
const fs = require("fs");
const path = require("path");

// Key from ./.env, then the repo-root ../.env (shared with web/ and mac/).
for (const envPath of [path.join(__dirname, ".env"), path.join(__dirname, "..", ".env")]) {
  if (!fs.existsSync(envPath)) continue;
  for (const line of fs.readFileSync(envPath, "utf8").split("\n")) {
    const m = line.match(/^\s*([\w.]+)\s*=\s*(.*?)\s*$/);
    if (m && !process.env[m[1]]) process.env[m[1]] = m[2];
  }
}

const PORT = process.env.PORT || 3000;
const API_KEY = process.env.ASSEMBLY_AI_KEY || process.env.ASSEMBLYAI_API_KEY;
const DICTATION_URL = "https://dictation.assemblyai.com/v1/transcribe/live";
const GATEWAY_URL = "https://llm-gateway.assemblyai.com/v1/chat/completions";
const LLM_MODEL = process.env.LLM_MODEL || "claude-sonnet-4-5-20250929";
const MAX_BODY = 8 * 1024 * 1024; // 120 s of 16 kHz mono WAV is ~3.8 MB, ~5 MB as base64

if (!API_KEY || API_KEY === "your_key_here") {
  console.error("Set ASSEMBLY_AI_KEY in .env (see .env.example) before starting the server.");
  process.exit(1);
}

function json(res, status, body) {
  res.writeHead(status, { "Content-Type": "application/json" });
  res.end(JSON.stringify(body));
}

function readJson(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    req.on("data", (c) => {
      size += c.length;
      if (size > MAX_BODY) { reject(Object.assign(new Error("Recording too large"), { status: 413 })); req.destroy(); }
      else chunks.push(c);
    });
    req.on("end", () => {
      try { resolve(JSON.parse(Buffer.concat(chunks).toString("utf8") || "{}")); }
      catch { reject(Object.assign(new Error("Invalid JSON body"), { status: 400 })); }
    });
    req.on("error", reject);
  });
}

// Upstream error bodies come in two shapes: {error} and {detail}. Fall back to raw text.
function upstreamMessage(text) {
  try {
    const d = JSON.parse(text);
    return d.error?.message || d.error || (typeof d.detail === "string" && d.detail) || d.title || text.slice(0, 500);
  } catch {
    return text.slice(0, 500);
  }
}

async function dictate({ audio, config = {} }) {
  if (!audio) throw Object.assign(new Error("No audio"), { status: 400 });

  // Only documented fields, omitted when empty — the API rejects anything else.
  const cfg = { sample_rate: 16000, channels: 1 };
  if (config.llm_instruction?.trim()) cfg.llm_instruction = [...config.llm_instruction.trim()].slice(0, 2048).join("");
  if (config.stt_prompt?.trim()) cfg.stt_prompt = [...config.stt_prompt.trim()].slice(-4096).join("");
  if (Array.isArray(config.keyterms_prompt) && config.keyterms_prompt.length) {
    cfg.keyterms_prompt = config.keyterms_prompt.slice(0, 100);
  }

  const form = new FormData(); // config must precede audio
  form.append("config", new Blob([JSON.stringify(cfg)], { type: "application/json" }));
  form.append("audio", new Blob([Buffer.from(audio, "base64")], { type: "audio/wav" }), "audio.wav");

  const r = await fetch(DICTATION_URL, {
    method: "POST",
    headers: { Authorization: API_KEY, "User-Agent": "DictationHello-IntakeForm/1.0" },
    body: form,
    signal: AbortSignal.timeout(90_000),
  });
  const text = await r.text();
  if (!r.ok) throw Object.assign(new Error(upstreamMessage(text)), { status: r.status });
  return JSON.parse(text);
}

// Fallback / re-fill path: structure an (edited) transcript with the LLM Gateway.
async function extract({ transcript, instruction }) {
  if (!transcript?.trim()) throw Object.assign(new Error("Empty transcript"), { status: 400 });
  const r = await fetch(GATEWAY_URL, {
    method: "POST",
    headers: { Authorization: API_KEY, "Content-Type": "application/json" },
    body: JSON.stringify({
      model: LLM_MODEL,
      max_tokens: 1500,
      messages: [
        { role: "system", content: instruction },
        { role: "user", content: transcript },
      ],
    }),
  });
  const text = await r.text();
  if (!r.ok) throw Object.assign(new Error(upstreamMessage(text)), { status: r.status });
  return { llm_response: JSON.parse(text).choices?.[0]?.message?.content || "" };
}

http
  .createServer(async (req, res) => {
    try {
      if (req.url === "/health") return json(res, 200, { proxy: true });
      if (req.url === "/dictate" && req.method === "POST") return json(res, 200, await dictate(await readJson(req)));
      if (req.url === "/extract" && req.method === "POST") return json(res, 200, await extract(await readJson(req)));
      if (req.url === "/" || req.url === "/index.html") {
        res.writeHead(200, { "Content-Type": "text/html; charset=utf-8" });
        return fs.createReadStream(path.join(__dirname, "index.html")).pipe(res);
      }
      res.writeHead(404);
      res.end("Not found");
    } catch (err) {
      json(res, err.status || 500, { error: err.message });
    }
  })
  .listen(PORT, () => console.log(`Intake form running at http://localhost:${PORT}`));
