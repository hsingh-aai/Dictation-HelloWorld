import express from 'express';
import multer from 'multer';
import dotenv from 'dotenv';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

dotenv.config({ path: path.join(path.dirname(fileURLToPath(import.meta.url)), '..', '.env') });

const API_KEY = process.env.ASSEMBLY_AI_KEY;
const ENDPOINT = 'https://dictation.assemblyai.com/v1/transcribe/live';
const PORT = process.env.PORT || 3000;

// Authoritative list, as returned verbatim by the API's own 400 on a bad code.
const LANGUAGE_CODES = [
  'en', 'es', 'de', 'fr', 'it', 'pt', 'tr', 'nl', 'sv', 'no', 'da', 'fi', 'hi', 'vi',
  'ar', 'he', 'ja', 'ur', 'zh', 'ko', 'ca', 'gl', 'ru', 'ro', 'et', 'fa', 'yue', 'af',
  'mr', 'zu', 'xh', 'nn',
];

// 120s of 16kHz mono 16-bit PCM is ~3.8MB. 8MB leaves generous headroom.
const upload = multer({ storage: multer.memoryStorage(), limits: { fileSize: 8 * 1024 * 1024 } });

const app = express();
const here = path.dirname(fileURLToPath(import.meta.url));
app.use(express.static(path.join(here, 'public')));
// diff.js / languages.js live one level up so the Electron build uses the same copies.
app.use('/shared', express.static(path.join(here, '..', 'shared')));

app.post('/api/transcribe', upload.single('audio'), async (req, res) => {
  if (!API_KEY) {
    return res.status(500).json({ error: 'ASSEMBLY_AI_KEY is not set in .env' });
  }
  if (!req.file) {
    return res.status(400).json({ error: 'No audio uploaded' });
  }

  // Only forward parameters the caller actually set — the API rejects nulls.
  const incoming = JSON.parse(req.body.config || '{}');
  const config = {};
  if (incoming.llm_instruction?.trim()) config.llm_instruction = incoming.llm_instruction.trim();
  if (incoming.stt_prompt?.trim()) config.stt_prompt = incoming.stt_prompt.trim();
  if (Array.isArray(incoming.keyterms_prompt) && incoming.keyterms_prompt.length) {
    config.keyterms_prompt = incoming.keyterms_prompt.slice(0, 100);
  }
  // Omit entirely when it's just the default — extra codes cost accuracy on
  // ambiguous segments, so we only send what the caller actually picked.
  if (Array.isArray(incoming.language_codes) && incoming.language_codes.length) {
    const allowed = new Set(LANGUAGE_CODES);
    const codes = incoming.language_codes.filter((c) => allowed.has(c));
    if (codes.length && !(codes.length === 1 && codes[0] === 'en')) {
      config.language_codes = codes;
    }
  }

  const form = new FormData();
  // Order is load-bearing: the endpoint 400s if `audio` arrives before `config`,
  // because it cannot open the upstream call without the config.
  form.append('config', new Blob([JSON.stringify(config)], { type: 'application/json' }));
  form.append('audio', new Blob([req.file.buffer], { type: 'audio/wav' }), 'audio.wav');

  try {
    const started = Date.now();
    const upstream = await fetch(ENDPOINT, {
      method: 'POST',
      headers: { Authorization: API_KEY },
      body: form,
      signal: AbortSignal.timeout(90_000),
    });

    const raw = await upstream.text();
    let body;
    try {
      body = JSON.parse(raw);
    } catch {
      return res.status(502).json({ error: `Unparseable upstream response: ${raw.slice(0, 300)}` });
    }

    if (!upstream.ok) {
      const retryAfter = upstream.headers.get('retry-after');
      return res.status(upstream.status).json({
        error: body.detail || body.error || body.title || 'Request failed',
        error_code: body.error_code,
        status: upstream.status,
        ...(retryAfter ? { retry_after: Number(retryAfter) } : {}),
      });
    }

    body.round_trip_ms = Date.now() - started;
    res.json(body);
  } catch (err) {
    const timedOut = err.name === 'TimeoutError' || err.name === 'AbortError';
    res.status(timedOut ? 504 : 500).json({
      error: timedOut ? 'Upstream timed out after 90s' : `Proxy error: ${err.message}`,
    });
  }
});

// Intake form: re-fill from an edited transcript. The mic path never needs this —
// its llm_instruction returns the fields as JSON in the transcribe request itself.
app.post('/api/extract', express.json({ limit: '200kb' }), async (req, res) => {
  if (!API_KEY) return res.status(500).json({ error: 'ASSEMBLY_AI_KEY is not set in .env' });
  const { transcript, instruction } = req.body || {};
  if (!transcript?.trim() || !instruction?.trim()) {
    return res.status(400).json({ error: 'transcript and instruction are required' });
  }
  try {
    const upstream = await fetch('https://llm-gateway.assemblyai.com/v1/chat/completions', {
      method: 'POST',
      headers: { Authorization: API_KEY, 'Content-Type': 'application/json' },
      body: JSON.stringify({
        model: process.env.LLM_MODEL || 'claude-sonnet-4-5-20250929',
        max_tokens: 1500,
        messages: [
          { role: 'system', content: instruction },
          { role: 'user', content: transcript },
        ],
      }),
      signal: AbortSignal.timeout(60_000),
    });
    const body = await upstream.json().catch(() => ({}));
    if (!upstream.ok) {
      return res.status(upstream.status).json({ error: body.error?.message || body.error || 'Request failed' });
    }
    res.json({ llm_response: body.choices?.[0]?.message?.content || '' });
  } catch (err) {
    res.status(500).json({ error: `Proxy error: ${err.message}` });
  }
});

app.listen(PORT, () => {
  console.log(`Dictation demo:  http://localhost:${PORT}`);
  if (!API_KEY) console.warn('WARNING: ASSEMBLY_AI_KEY missing from ../.env — requests will fail.');
});
