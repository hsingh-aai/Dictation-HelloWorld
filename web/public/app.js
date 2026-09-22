import { diff, words } from '/shared/diff.js';
import { toWav, MAX_MS, MIN_MS } from '/shared/wav.js';
import { PRESETS } from '/shared/presets.js';
import { buildInstruction, MODIFIERS, EXCLUSIVE_GROUPS } from '/shared/instruction.js';
import { applyShortcuts, matchedShortcuts } from '/shared/shortcuts.js';
import { LANGUAGES } from '/shared/languages.js';

const el = {
  mic: document.getElementById('mic'),
  meter: document.querySelector('#meter span'),
  timer: document.getElementById('timer'),
  status: document.getElementById('status'),
  verbatim: document.getElementById('verbatim'),
  cleaned: document.getElementById('cleaned'),
  copy: document.getElementById('copy'),
  stats: document.getElementById('stats'),
  instruction: document.getElementById('instruction'),
  keyterms: document.getElementById('keyterms'),
  sttprompt: document.getElementById('sttprompt'),
  langs: document.getElementById('langs'),
  dialects: document.getElementById('dialects'),
  shortcuts: document.getElementById('shortcuts'),
  addShortcut: document.getElementById('addShortcut'),
  budget: document.getElementById('budget'),
};

el.instruction.value = PRESETS.clean;

el.langs.innerHTML = LANGUAGES.map(([code, name]) => `
  <label title="${code}">
    <input type="checkbox" value="${code}"${code === 'en' ? ' checked' : ''}>
    <span>${name}</span>
  </label>`).join('');

const selectedLanguages = () =>
  [...el.langs.querySelectorAll('input:checked')].map((i) => i.value);

// ---- Additive instruction modifiers -------------------------------------------------
const activeModifiers = new Set();

el.dialects.innerHTML = Object.entries(MODIFIERS).map(([key, m]) => `
  <button type="button" class="chip" data-mod="${key}" aria-pressed="false">
    ${m.label}<small>${m.hint}</small>
  </button>`).join('');

el.dialects.querySelectorAll('.chip').forEach((chip) => {
  chip.onclick = () => {
    const key = chip.dataset.mod;
    if (activeModifiers.has(key)) {
      activeModifiers.delete(key);
    } else {
      // Mutually exclusive: two dialects would contradict and waste the byte budget.
      for (const group of EXCLUSIVE_GROUPS) {
        if (group.includes(key)) group.forEach((k) => activeModifiers.delete(k));
      }
      activeModifiers.add(key);
    }
    el.dialects.querySelectorAll('.chip').forEach((c) =>
      c.setAttribute('aria-pressed', String(activeModifiers.has(c.dataset.mod))));
    updateBudget();
  };
});

function addShortcutRow(phrase = '', replacement = '') {
  const row = document.createElement('div');
  row.className = 'shortcut-row';
  row.innerHTML = `
    <input type="text" class="sc-phrase" placeholder="personal email" aria-label="Spoken phrase">
    <span class="arrow">&rarr;</span>
    <input type="text" class="sc-replacement" placeholder="you@example.com" aria-label="Replacement text">
    <button type="button" class="rm" title="Remove" aria-label="Remove shortcut">&times;</button>`;
  row.querySelector('.sc-phrase').value = phrase;
  row.querySelector('.sc-replacement').value = replacement;
  row.querySelector('.rm').onclick = () => { row.remove(); updateBudget(); };
  row.querySelectorAll('input').forEach((i) => i.addEventListener('input', updateBudget));
  el.shortcuts.appendChild(row);
  updateBudget();
}

const currentExpansions = () => [...el.shortcuts.querySelectorAll('.shortcut-row')].map((row) => ({
  phrase: row.querySelector('.sc-phrase').value,
  replacement: row.querySelector('.sc-replacement').value,
}));

const composeInstruction = () => buildInstruction({
  base: el.instruction.value,
  modifiers: [...activeModifiers],
});

/**
 * The cap is enforced by the API on the whole request: over it, every dictation
 * 400s rather than degrading. So the budget is shown, not assumed.
 */
function updateBudget() {
  const { chars, max, fits, overBy, remaining } = composeInstruction();
  const pct = Math.min(100, (chars / max) * 100);
  const count = currentExpansions().filter((e) => e.phrase.trim() && e.replacement.trim()).length;
  el.budget.className = `budget ${!fits ? 'over' : remaining < 150 ? 'warn' : ''}`;
  el.budget.innerHTML = `
    ${fits
      ? `instruction <b>${chars}</b> / ${max} chars · ${remaining} left`
      : `instruction <b>${chars}</b> / ${max} chars — over by ${overBy}. Shorten it; the API rejects the whole request.`}
    ${count ? `· ${count} shortcut${count === 1 ? '' : 's'}, applied locally — no budget cost` : ''}
    <span class="bar"><span style="width:${pct}%"></span></span>`;
  el.mic.disabled = !fits;
  el.mic.style.opacity = fits ? '' : '.45';
}

el.addShortcut.onclick = () => addShortcutRow();
el.instruction.addEventListener('input', updateBudget);
addShortcutRow('personal email', 'you@example.com');

let stream, recorder, chunks = [], startedAt = 0, ticker, audioCtx, analyser, rafId, busy = false;

function setStatus(msg, kind = '') {
  el.status.textContent = msg;
  el.status.className = `status ${kind}`;
}

async function ensureMic() {
  if (stream?.active) return stream;
  stream = await navigator.mediaDevices.getUserMedia({
    audio: { channelCount: 1, echoCancellation: true, noiseSuppression: true, autoGainControl: true },
  });
  return stream;
}

function startMeter(src) {
  audioCtx = audioCtx || new AudioContext();
  analyser = audioCtx.createAnalyser();
  analyser.fftSize = 512;
  audioCtx.createMediaStreamSource(src).connect(analyser);
  const buf = new Uint8Array(analyser.frequencyBinCount);
  const loop = () => {
    analyser.getByteTimeDomainData(buf);
    let peak = 0;
    for (const v of buf) peak = Math.max(peak, Math.abs(v - 128));
    el.meter.style.width = `${Math.min(100, (peak / 128) * 180)}%`;
    rafId = requestAnimationFrame(loop);
  };
  loop();
}

function stopMeter() {
  cancelAnimationFrame(rafId);
  el.meter.style.width = '0%';
}

async function startRecording() {
  if (busy || recorder?.state === 'recording') return;
  if (!composeInstruction().fits) {
    return setStatus('Instruction is over the 2048-byte cap — trim it before recording.', 'error');
  }
  try {
    const src = await ensureMic();
    chunks = [];
    recorder = new MediaRecorder(src);
    recorder.ondataavailable = (e) => e.data.size && chunks.push(e.data);
    recorder.onstop = handleStop;
    recorder.start();
    startedAt = performance.now();
    el.mic.classList.add('recording');
    setStatus('Listening…');
    ticker = setInterval(() => {
      const ms = performance.now() - startedAt;
      el.timer.textContent = `${(ms / 1000).toFixed(1)}s`;
      el.timer.classList.toggle('warn', ms > MAX_MS - 15_000);
      if (ms >= MAX_MS) {
        setStatus('Hit the 120s limit — sending.');
        stopRecording();
      }
    }, 100);
  } catch (err) {
    setStatus(`Microphone unavailable: ${err.message}`, 'error');
  }
}

function stopRecording() {
  if (recorder?.state !== 'recording') return;
  clearInterval(ticker);
  recorder.stop();
  el.mic.classList.remove('recording');
}

async function handleStop() {
  stopMeter();
  const durationMs = performance.now() - startedAt;
  if (durationMs < MIN_MS) return setStatus('Too short — hold a little longer.', 'error');

  busy = true;
  el.mic.classList.add('busy');
  setStatus('Transcribing…');

  try {
    const wav = await toWav(new Blob(chunks, { type: chunks[0]?.type || 'audio/webm' }));
    const form = new FormData();
    form.append('config', JSON.stringify({
      llm_instruction: composeInstruction().text,
      stt_prompt: el.sttprompt.value,
      keyterms_prompt: el.keyterms.value.split(',').map((s) => s.trim()).filter(Boolean).slice(0, 100),
      language_codes: selectedLanguages(),
    }));
    form.append('audio', wav, 'audio.wav');

    const res = await fetch('/api/transcribe', { method: 'POST', body: form });
    const data = await res.json();
    if (!res.ok) throw new Error(data.error || `Request failed (${res.status})`);
    render(data);
  } catch (err) {
    setStatus(err.message, 'error');
  } finally {
    busy = false;
    el.mic.classList.remove('busy');
  }
}

const esc = (s) => s.replace(/[&<>]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;' }[c]));

function render(data) {
  // Deliberately NOT named `shortcuts`: an element id leaks into the global scope,
  // so a bare `shortcuts` silently resolves to <div id="shortcuts"> instead.
  const shortcutPairs = currentExpansions();
  const verbatim = data.text || '';
  // Literal substitution, applied here rather than asked of the model: exact,
  // unlimited, and it costs no instruction budget. Verbatim is left untouched —
  // that pane is what you actually said.
  const cleaned = applyShortcuts(data.llm_response || '', shortcutPairs);
  el.verbatim.textContent = verbatim;

  if (data.llm_error) {
    el.cleaned.innerHTML = `<span class="ph">Rewrite failed (${esc(data.llm_error)}) — verbatim transcript is still valid.</span>`;
    el.copy.hidden = true;
    setStatus(`Transcribed, but the rewrite ${data.llm_error === 'timeout' ? 'timed out' : 'failed'}.`, 'error');
  } else if (cleaned) {
    const ops = diff(words(verbatim), words(cleaned));
    el.verbatim.innerHTML = ops.filter((o) => o.t !== '+')
      .map((o) => (o.t === '-' ? `<del>${esc(o.a)}</del>` : esc(o.a))).join(' ');
    el.cleaned.innerHTML = ops.filter((o) => o.t !== '-')
      .map((o) => (o.t === '+' ? `<ins>${esc(o.b)}</ins>` : esc(o.b))).join(' ');
    el.copy.hidden = false;
    el.copy.onclick = async () => {
      await navigator.clipboard.writeText(cleaned);
      el.copy.textContent = 'Copied';
      setTimeout(() => (el.copy.textContent = 'Copy'), 1200);
    };
    const fired = matchedShortcuts(data.llm_response || '', shortcutPairs);
    setStatus(fired.length ? `Done · replaced ${fired.map((f) => `"${f}"`).join(', ')}` : 'Done', 'ok');
  } else {
    el.cleaned.innerHTML = '<span class="ph">No rewrite returned.</span>';
    setStatus('Done', 'ok');
  }

  el.stats.hidden = false;
  el.stats.innerHTML = [
    ['audio', `${(data.audio_duration_ms / 1000).toFixed(1)}s`],
    ['round trip', `${data.round_trip_ms}ms`],
    ['server', `${Math.round(data.request_time_ms)}ms`],
    ['stt', `${Math.round(data.sync_time_ms)}ms`],
    ['confidence', `${(data.confidence * 100).toFixed(1)}%`],
  ].map(([k, v]) => `<span>${k} <b>${v}</b></span>`).join('');
}

// Hold-to-talk: pointer and spacebar.
el.mic.addEventListener('pointerdown', async () => { await startRecording(); if (stream) startMeter(stream); });
el.mic.addEventListener('pointerup', stopRecording);
el.mic.addEventListener('pointerleave', stopRecording);

document.addEventListener('keydown', async (e) => {
  if (e.code !== 'Space' || e.repeat || /INPUT|TEXTAREA/.test(e.target.tagName)) return;
  e.preventDefault();
  await startRecording();
  if (stream) startMeter(stream);
});
document.addEventListener('keyup', (e) => {
  if (e.code === 'Space' && !/INPUT|TEXTAREA/.test(e.target.tagName)) { e.preventDefault(); stopRecording(); }
});

document.querySelectorAll('.presets button').forEach((b) => {
  b.onclick = () => {
    el.instruction.value = PRESETS[b.dataset.preset];
    updateBudget();
    setStatus(`Preset: ${b.textContent}`);
  };
});
