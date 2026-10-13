// Renderer: capture → 16 kHz mono WAV → main-process request → paste. Imports the same
// shared modules as the web build; never sees the API key.
import { toWav, MAX_MS } from './shared/wav.js';
import { diff, words } from './shared/diff.js';
import { BASE_INSTRUCTION } from './shared/instruction.js';
import { applyShortcuts } from './shared/shortcuts.js';

const MIN_MS = 100;            // below ~80–100 ms the API bills an empty 200
const AUTO_STOP_MS = MAX_MS - 5_000;   // auto-release before the 120 s cap
const HISTORY_CAP = 100;
const PROMPT_MAX = 4096;       // stt_prompt, in Unicode scalars

const $ = (id) => document.getElementById(id);
const el = {
  mic: $('mic'), meter: document.querySelector('#meter span'), status: $('status'),
  panes: $('panes'), verbatim: $('verbatim'), cleaned: $('cleaned'), stats: $('stats'),
  recent: $('recent'), enhanced: $('enhanced'), keyterms: $('keyterms'),
  shortcuts: $('shortcuts'), addShortcut: $('addShortcut'), hotkey: $('hotkey'),
  keyWarning: $('keyWarning'), axWarning: $('axWarning'),
};

// ---- Settings (per-viewer conveniences, so localStorage) -----------------------------

const store = {
  get(key, fallback) {
    try { const v = localStorage.getItem(key); return v === null ? fallback : JSON.parse(v); } catch { return fallback; }
  },
  set(key, value) { try { localStorage.setItem(key, JSON.stringify(value)); } catch { /* ignore */ } },
};

const defaults = await window.dictation.defaults();
el.hotkey.textContent = defaults.hotkey.replace('Control', 'Ctrl');
if (defaults.trigger) {
  const name = defaults.trigger === 'right-option' ? 'Right ⌥' : 'Right ⌘';
  $('hint').innerHTML = `Tap <kbd>${name}</kbd> to start and stop, hold it to talk — or <kbd>${el.hotkey.textContent}</kbd>`;
}
el.keyWarning.hidden = defaults.hasKey;

el.enhanced.checked = store.get('enhanced', true);
el.enhanced.onchange = () => store.set('enhanced', el.enhanced.checked);
el.keyterms.value = store.get('keyterms', '');
el.keyterms.oninput = () => store.set('keyterms', el.keyterms.value);

function saveShortcuts() {
  store.set('shortcuts', currentShortcuts());
}

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
  row.querySelector('.rm').onclick = () => { row.remove(); saveShortcuts(); };
  row.querySelectorAll('input').forEach((i) => i.addEventListener('input', saveShortcuts));
  el.shortcuts.appendChild(row);
}

const currentShortcuts = () => [...el.shortcuts.querySelectorAll('.shortcut-row')].map((row) => ({
  phrase: row.querySelector('.sc-phrase').value,
  replacement: row.querySelector('.sc-replacement').value,
}));

// Saved rows win; otherwise seed from electron/shortcuts.local.json (gitignored).
const seeded = store.get('shortcuts', null) ??
  defaults.shortcuts.map((s) => ({ phrase: s.trigger ?? s.phrase, replacement: s.expansion ?? s.replacement }));
seeded.forEach((s) => addShortcutRow(s.phrase, s.replacement));
el.addShortcut.onclick = () => addShortcutRow();

async function refreshPermissions() {
  const p = await window.dictation.permissions();
  el.axWarning.hidden = p.accessibility;
}
$('grantAx').onclick = () => window.dictation.requestAccessibility();
$('close').onclick = () => window.dictation.hide();
refreshPermissions();
setInterval(refreshPermissions, 3000);

// ---- State ---------------------------------------------------------------------------

let phase = 'idle';   // idle | starting | recording | transcribing
let stopWhenStarted = false;   // a hold released before the mic came up
const history = [];   // memory only, cleared on quit — also request context
const recent = [];

function setPhase(next, message, kind = '') {
  phase = next;
  window.dictation.setState(next);
  el.mic.classList.toggle('recording', next === 'recording');
  el.mic.classList.toggle('busy', next === 'transcribing');
  el.mic.setAttribute('aria-label', next === 'recording' ? 'Stop dictation' : 'Start dictation');
  if (message !== undefined) setStatus(message, kind);
}

function setStatus(message, kind = '') {
  el.status.textContent = message;
  el.status.className = `status ${kind}`;
}

// ---- Capture -------------------------------------------------------------------------

let stream, recorder, chunks = [], startedAt = 0, autoStop, audioCtx, rafId;

async function start() {
  if (phase !== 'idle') return;
  if (!defaults.hasKey) return setPhase('idle', 'Add ASSEMBLY_AI_KEY to .env first.', 'error');
  window.dictation.warm();
  stopWhenStarted = false;
  // Claim the phase before the mic opens, so a quick release isn't lost.
  setPhase('starting', 'Starting…');
  try {
    // Opened per dictation and closed after — the mic isn't held open between uses.
    stream = await navigator.mediaDevices.getUserMedia({
      audio: { channelCount: 1, echoCancellation: true, noiseSuppression: true, autoGainControl: true },
    });
  } catch (err) {
    return setPhase('idle', `Microphone unavailable: ${err.message}`, 'error');
  }
  if (phase !== 'starting') {   // cancelled while the mic came up
    stream.getTracks().forEach((t) => t.stop());
    return;
  }
  chunks = [];
  recorder = new MediaRecorder(stream);
  recorder.ondataavailable = (e) => e.data.size && chunks.push(e.data);
  recorder.onstop = finish;
  recorder.start();
  startedAt = performance.now();
  startMeter(stream);
  autoStop = setTimeout(stop, AUTO_STOP_MS);
  setPhase('recording', 'Listening…');
  if (stopWhenStarted) stop();
}

function stop() {
  if (phase === 'starting') { stopWhenStarted = true; return; }
  if (phase !== 'recording') return;
  clearTimeout(autoStop);
  // Claim "transcribing" before the recorder finishes flushing.
  setPhase('transcribing', 'Transcribing…');
  recorder.stop();
}

function startMeter(src) {
  audioCtx = audioCtx || new AudioContext();
  const analyser = audioCtx.createAnalyser();
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

/** Recent dictations, oldest first, dropping the oldest whole to fit 4096 scalars. */
function promptFromHistory() {
  const kept = [];
  let used = 0;
  for (let i = history.length - 1; i >= 0; i--) {
    const cost = [...history[i]].length + (kept.length ? 1 : 0);
    if (used + cost > PROMPT_MAX) break;
    kept.unshift(history[i]);
    used += cost;
  }
  return kept.join('\n');
}

async function finish() {
  cancelAnimationFrame(rafId);
  el.meter.style.width = '0%';
  stream?.getTracks().forEach((t) => t.stop());
  const durationMs = performance.now() - startedAt;
  if (durationMs < MIN_MS) return setPhase('idle', 'Too short.', 'error');

  try {
    const wav = await toWav(new Blob(chunks, { type: chunks[0]?.type || 'audio/webm' }));
    const shortcuts = currentShortcuts();
    const keyterms = [
      ...el.keyterms.value.split(',').map((s) => s.trim()),
      ...shortcuts.map((s) => s.phrase.trim()),   // bias recognition toward the trigger spellings
    ].filter(Boolean);
    const result = await window.dictation.transcribe(await wav.arrayBuffer(), {
      llm_instruction: BASE_INSTRUCTION,
      stt_prompt: promptFromHistory(),
      keyterms_prompt: keyterms,
    });
    if (!result.ok) {
      const retry = result.retryAfter ? ` Retry in ${result.retryAfter}s.` : '';
      return setPhase('idle', `${result.error}${retry}`, 'error');
    }
    const data = result.body;
    const verbatim = (data.text || '').trim();
    // The rewrite can't be declined on the wire; the switch picks which text to use.
    const rewrite = (data.llm_response || '').trim();
    const picked = el.enhanced.checked && rewrite ? rewrite : verbatim;
    const text = applyShortcuts(picked, shortcuts).trim();
    if (!text) return setPhase('idle', 'Nothing heard.');

    history.push(text);
    if (history.length > HISTORY_CAP) history.shift();
    const outcome = await window.dictation.paste(text);
    render(verbatim, text, data);
    addRecent(text);
    const note = data.llm_error ? ` (rewrite ${data.llm_error}; used verbatim)` : '';
    if (outcome.pasted) setPhase('idle', `Pasted${note}`, 'ok');
    else if (outcome.reason === 'accessibility') setPhase('idle', 'Copied to clipboard — grant Accessibility to auto-paste.');
    else setPhase('idle', `Copied to clipboard${note}`);
  } catch (err) {
    setPhase('idle', err.message, 'error');
  }
}

// ---- Render --------------------------------------------------------------------------

const esc = (s) => s.replace(/[&<>]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;' }[c]));

function render(verbatim, pasted, data) {
  el.panes.hidden = false;
  const ops = diff(words(verbatim), words(pasted));
  el.verbatim.innerHTML = ops.filter((o) => o.t !== '+')
    .map((o) => (o.t === '-' ? `<del>${esc(o.a)}</del>` : esc(o.a))).join(' ');
  el.cleaned.innerHTML = ops.filter((o) => o.t !== '-')
    .map((o) => (o.t === '+' ? `<ins>${esc(o.b)}</ins>` : esc(o.b))).join(' ');
  el.stats.innerHTML = [
    ['audio', `${((data.audio_duration_ms ?? 0) / 1000).toFixed(1)}s`],
    ['round trip', `${data.round_trip_ms}ms`],
    ['server', `${Math.round(data.request_time_ms ?? 0)}ms`],
  ].map(([k, v]) => `<span>${k} <b>${v}</b></span>`).join('');
}

function addRecent(text) {
  recent.unshift({ text, at: Date.now() });
  el.recent.innerHTML = '';
  for (const item of recent.slice(0, 3)) {
    const li = document.createElement('li');
    const span = document.createElement('span');
    span.textContent = item.text;
    const copy = document.createElement('button');
    copy.textContent = 'Copy';
    copy.onclick = async () => {
      await navigator.clipboard.writeText(item.text);
      copy.textContent = 'Copied';
    };
    li.append(span, copy);
    el.recent.appendChild(li);
  }
}

// ---- Triggers ------------------------------------------------------------------------

const toggle = () => (phase === 'recording' || phase === 'starting' ? stop() : start());
window.dictation.onHotkey(toggle);
el.mic.addEventListener('click', toggle);
function cancel() {
  if (phase === 'starting') return setPhase('idle', 'Cancelled.');
  if (phase !== 'recording') return;
  clearTimeout(autoStop);
  recorder.onstop = () => { stream?.getTracks().forEach((t) => t.stop()); cancelAnimationFrame(rafId); el.meter.style.width = '0%'; };
  recorder.stop();
  setPhase('idle', 'Cancelled.');
}

window.dictation.onTrigger((action) => {
  if (action === 'start') start();
  else if (action === 'stop') stop();
  else if (action === 'cancel') cancel();
});
document.addEventListener('keydown', (e) => {
  if (e.key === 'Escape') cancel();
});
