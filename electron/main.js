// Main process: tray, global shortcut, the API call and the paste. The API key lives
// here and only here — the renderer reaches the network solely through `transcribe`.
import {
  app, BrowserWindow, Tray, globalShortcut, ipcMain, clipboard, systemPreferences,
  nativeImage, protocol, net, screen, session, shell,
} from 'electron';
import { execFile } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import dotenv from 'dotenv';
import uiohook from 'uiohook-napi';
import { createGate } from './trigger.js';
import { BASE_INSTRUCTION } from '../shared/instruction.js';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.join(here, '..');
dotenv.config({ path: path.join(root, '.env'), quiet: true });

const API_KEY = process.env.ASSEMBLY_AI_KEY || process.env.ASSEMBLYAI_API_KEY;
const ENDPOINT = 'https://dictation.assemblyai.com/v1/transcribe/live';
const WARM = 'https://dictation.assemblyai.com/warm';
// globalShortcut registers combinations only — it never sees a lone Right ⌥ held — so
// this build toggles: press to start, press again to stop.
const HOTKEY = process.env.DICTATION_HOTKEY || 'Control+Alt+D';
// …so the lone-modifier trigger (tap to toggle, hold to talk) comes from a native hook.
// DICTATION_TRIGGER=off disables it and leaves just the combination above.
const TRIGGER = (process.env.DICTATION_TRIGGER || 'right-option').toLowerCase();
const UA = `DictationHelloElectron/${app.getVersion()} (macOS ${process.getSystemVersion()})`;

// Caps, each its own number. Over any of them the API 400s the whole request.
const STT_PROMPT_MAX = 4096;        // Unicode scalars
const KEYTERMS_MAX_BYTES = 2048;    // summed UTF-8 bytes
const KEYTERMS_MAX_COUNT = 100;
const INSTRUCTION_MAX = 2048;       // codepoints (measured, see shared/instruction.js)
const PASTE_SETTLE_MS = 400;

protocol.registerSchemesAsPrivileged([
  { scheme: 'app', privileges: { standard: true, secure: true, supportFetchAPI: true } },
]);

let tray;
let win;
let rendererState = 'idle';

// ---- The request ---------------------------------------------------------------------

/** Only documented fields, only when set — empty values are omitted, never sent as ""/[]. */
function fitConfig(incoming = {}) {
  const config = { sample_rate: 16000, channels: 1 };
  const prompt = typeof incoming.stt_prompt === 'string' ? incoming.stt_prompt.trim() : '';
  if (prompt) {
    const scalars = [...prompt];
    // Nearest the cursor is what the utterance continues from: keep the tail.
    config.stt_prompt = scalars.length > STT_PROMPT_MAX ? scalars.slice(-STT_PROMPT_MAX).join('') : prompt;
  }
  if (Array.isArray(incoming.keyterms_prompt)) {
    const seen = new Set();
    const terms = [];
    let bytes = 0;
    for (const raw of incoming.keyterms_prompt) {
      const term = String(raw).trim();
      if (!term || seen.has(term)) continue;
      const cost = Buffer.byteLength(term);
      if (terms.length >= KEYTERMS_MAX_COUNT || bytes + cost > KEYTERMS_MAX_BYTES) break;
      seen.add(term);
      terms.push(term);
      bytes += cost;
    }
    if (terms.length) config.keyterms_prompt = terms;
  }
  const instruction = typeof incoming.llm_instruction === 'string' ? incoming.llm_instruction.trim() : '';
  if (instruction && [...instruction].length <= INSTRUCTION_MAX) config.llm_instruction = instruction;
  return config;
}

/** Error text: `error`, then string `detail`, then `title`, then the raw body (capped). */
function errorMessage(body, raw) {
  if (body && typeof body.error === 'string' && body.error) return body.error;
  if (body && typeof body.detail === 'string' && body.detail) return body.detail;
  if (body && typeof body.title === 'string' && body.title) return body.title;
  const text = raw.trim();
  return text ? text.slice(0, 500) : 'empty response';
}

async function transcribe(audio, incoming) {
  if (!API_KEY) return { ok: false, error: 'ASSEMBLY_AI_KEY is not set in the repo .env', setup: true };
  const config = fitConfig(incoming);
  const form = new FormData();
  // Order is load-bearing: audio before config is a 400 on the streaming route.
  form.append('config', new Blob([JSON.stringify(config)], { type: 'application/json' }));
  form.append('audio', new Blob([Buffer.from(audio)], { type: 'audio/wav' }), 'audio.wav');
  const started = Date.now();
  try {
    const res = await fetch(ENDPOINT, {
      method: 'POST',
      headers: { Authorization: API_KEY, 'User-Agent': UA },   // raw key, no Bearer
      body: form,
      signal: AbortSignal.timeout(90_000),
    });
    const raw = await res.text();
    let body = null;
    try { body = JSON.parse(raw); } catch { /* reported below */ }
    if (!res.ok || !body) {
      const keyRejected = [401, 403, 404].includes(res.status);
      return {
        ok: false,
        status: res.status,
        setup: keyRejected,
        error: keyRejected ? `API key rejected: ${errorMessage(body, raw)}` : errorMessage(body, raw),
        retryAfter: Number(res.headers.get('retry-after')) || undefined,
      };
    }
    body.round_trip_ms = Date.now() - started;
    console.log(`[dictation] session=${body.session_id} audio=${body.audio_duration_ms}ms round_trip=${body.round_trip_ms}ms llm_error=${body.llm_error ?? '-'}`);
    return { ok: true, body };
  } catch (err) {
    const timedOut = err.name === 'TimeoutError' || err.name === 'AbortError';
    return { ok: false, error: timedOut ? 'Timed out after 90 s' : `Network error: ${err.message}` };
  }
}

// ---- Paste ---------------------------------------------------------------------------

const accessibilityGranted = () =>
  process.platform !== 'darwin' || systemPreferences.isTrustedAccessibilityClient(false);

/**
 * Clipboard paste with save/restore. Every failure path leaves the transcript on the
 * clipboard, so the user's words are never lost.
 */
async function paste(text) {
  const saved = clipboard.readText();
  clipboard.writeText(text);
  // osascript fails *silently* without Accessibility — check, and report the fallback.
  if (!accessibilityGranted()) return { pasted: false, reason: 'accessibility' };
  // Our own panel has focus: there's no other app to paste into.
  if (win?.isFocused()) return { pasted: false, reason: 'focused' };
  const error = await new Promise((resolve) => {
    execFile('osascript', ['-e', 'tell application "System Events" to keystroke "v" using command down'],
      (err) => resolve(err));
  });
  if (error) return { pasted: false, reason: error.message.trim() };
  setTimeout(() => {
    // Only restore if nothing else claimed the clipboard in the meantime.
    if (clipboard.readText() === text) clipboard.writeText(saved);
  }, PASTE_SETTLE_MS);
  return { pasted: true };
}

// ---- Shell ---------------------------------------------------------------------------

const GLYPHS = { idle: '◎', starting: '◍', recording: '●', transcribing: '◍' };

function loadDefaults() {
  // Personal shortcuts live in a gitignored file next to this one.
  const file = path.join(here, 'shortcuts.local.json');
  let shortcuts = [];
  try { shortcuts = JSON.parse(fs.readFileSync(file, 'utf8')); } catch { /* none */ }
  return { shortcuts, hotkey: HOTKEY, trigger: TRIGGER_KEYS[TRIGGER] ? TRIGGER : null, hasKey: Boolean(API_KEY) };
}

function positionUnderTray() {
  const trayBounds = tray.getBounds();
  const { width } = win.getBounds();
  const display = screen.getDisplayNearestPoint({ x: trayBounds.x, y: trayBounds.y });
  const x = Math.round(Math.min(
    Math.max(trayBounds.x + trayBounds.width / 2 - width / 2, display.workArea.x + 8),
    display.workArea.x + display.workArea.width - width - 8,
  ));
  const y = Math.round(trayBounds.y + trayBounds.height + 6);
  win.setPosition(x, y, false);
}

function togglePanel() {
  if (win.isVisible()) {
    win.hide();
    return;
  }
  positionUnderTray();
  win.show();
}

function createWindow() {
  win = new BrowserWindow({
    width: 420,
    height: 600,
    show: false,
    frame: false,
    resizable: false,
    fullscreenable: false,
    skipTaskbar: true,
    alwaysOnTop: true,
    transparent: false,
    backgroundColor: '#00000000',
    vibrancy: 'popover',
    webPreferences: {
      preload: path.join(here, 'preload.cjs'),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
      // Recording runs while the panel is hidden; don't let Chromium throttle it.
      backgroundThrottling: false,
    },
  });
  win.loadURL('app://renderer/index.html');
  // Surface renderer errors in the terminal that ran `npm start`.
  win.webContents.on('console-message', ({ level, message }) => {
    if (level === 'error' || level === 'warning') console.log(`[renderer:${level}] ${message}`);
  });
  win.webContents.on('did-fail-load', (_e, code, desc, url) => console.error(`[renderer] load failed ${code} ${desc} ${url}`));
  // DICTATION_SHOW=1 opens the panel at launch, for trying it out without the tray.
  if (process.env.DICTATION_SHOW) win.once('ready-to-show', () => { positionUnderTray(); win.show(); });
  // A tray popover hides when you click away — except in DICTATION_SHOW mode, which pins it.
  win.on('blur', () => { if (!process.env.DICTATION_SHOW && !win.webContents.isDevToolsOpened()) win.hide(); });
}

function serveAppProtocol() {
  // One origin, so CSP 'self' and module loading just work:
  // app://renderer/shared/* → the repo's shared modules, app://renderer/* → electron/renderer.
  const rendererDir = path.join(here, 'renderer');
  const sharedDir = path.join(root, 'shared');
  protocol.handle('app', (request) => {
    const url = new URL(request.url);
    const pathname = decodeURIComponent(url.pathname);
    const [base, rest] = pathname.startsWith('/shared/')
      ? [sharedDir, pathname.slice('/shared'.length)]
      : [rendererDir, pathname];
    const file = path.normalize(path.join(base, rest));
    if (url.host !== 'renderer' || !file.startsWith(base + path.sep)) {
      return new Response('Not found', { status: 404 });
    }
    return net.fetch(pathToFileURL(file).toString());
  });
}

function registerIpc() {
  ipcMain.handle('transcribe', (_e, { audio, config }) => transcribe(audio, config));
  ipcMain.handle('paste', (_e, text) => paste(String(text)));
  ipcMain.handle('defaults', () => loadDefaults());
  ipcMain.handle('permissions', async () => ({
    accessibility: accessibilityGranted(),
    microphone: process.platform === 'darwin' ? systemPreferences.getMediaAccessStatus('microphone') : 'granted',
  }));
  ipcMain.handle('request-accessibility', () => {
    systemPreferences.isTrustedAccessibilityClient(true);   // shows the system prompt
    shell.openExternal('x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility');
  });
  ipcMain.handle('warm', () => { fetch(WARM, { headers: { 'User-Agent': UA } }).catch(() => {}); });
  ipcMain.on('state', (_e, state) => {
    rendererState = state;
    // A dictation can end with no key event (auto-stop, an error): un-latch the trigger.
    if (state === 'idle') gate.reset();
    tray?.setTitle(` ${GLYPHS[state] ?? GLYPHS.idle}`);
    tray?.setToolTip(`Dictation Hello — ${state}`);
  });
  ipcMain.on('hide', () => win?.hide());
}

// ---- Lone-modifier trigger -----------------------------------------------------------

const { uIOhook, UiohookKey } = uiohook;
const TRIGGER_KEYS = { 'right-option': UiohookKey.AltRight, 'right-command': UiohookKey.MetaRight };
const gate = createGate();
let hookRunning = false;

function sendTrigger(action) {
  if (!action) return;
  // A press the renderer would refuse (still transcribing) must not leave the gate latched.
  if (action === 'start' && rendererState !== 'idle') { gate.reset(); return; }
  win?.webContents.send('trigger', action);
}

/** The hook needs Accessibility, like the paste does; start it once that's granted. */
function startHook() {
  const keycode = TRIGGER_KEYS[TRIGGER];
  if (hookRunning || !keycode || !accessibilityGranted()) return;
  uIOhook.on('keydown', (e) => {
    if (e.keycode === keycode) sendTrigger(gate.down(performance.now()));
    else sendTrigger(gate.otherKey());
  });
  uIOhook.on('keyup', (e) => {
    if (e.keycode === keycode) sendTrigger(gate.up(performance.now()));
  });
  uIOhook.start();
  hookRunning = true;
  console.log(`[dictation] ${TRIGGER}: tap to start and stop, or hold to talk`);
}

// ---- Headless self-test --------------------------------------------------------------

async function selfTest(file) {
  const wav = fs.readFileSync(file);
  const result = await transcribe(wav, { llm_instruction: BASE_INSTRUCTION });
  if (!result.ok) {
    console.error(`selftest failed: ${result.error}`);
    return 1;
  }
  const { text, llm_response, llm_error, audio_duration_ms, round_trip_ms } = result.body;
  console.log(`verbatim : ${text}`);
  console.log(`cleaned  : ${llm_response ?? `(nil, llm_error=${llm_error})`}`);
  console.log(`audio    : ${audio_duration_ms} ms   round trip: ${round_trip_ms} ms`);
  return text ? 0 : 1;
}

// ---- Lifecycle -----------------------------------------------------------------------

app.whenReady().then(async () => {
  if (process.env.DICTATION_SELFTEST) {
    app.exit(await selfTest(process.env.DICTATION_SELFTEST));
    return;
  }

  app.dock?.hide();
  serveAppProtocol();
  registerIpc();

  // Microphone for the renderer's getUserMedia; nothing else is granted.
  session.defaultSession.setPermissionRequestHandler((_wc, permission, callback, details) => {
    callback(permission === 'media' && (details.mediaTypes ?? []).every((t) => t === 'audio'));
  });
  if (process.platform === 'darwin') await systemPreferences.askForMediaAccess('microphone');

  tray = new Tray(nativeImage.createEmpty());
  tray.setTitle(` ${GLYPHS.idle}`);
  tray.setToolTip('Dictation Hello');
  tray.on('click', togglePanel);
  tray.on('right-click', togglePanel);

  createWindow();

  if (!globalShortcut.register(HOTKEY, () => win.webContents.send('hotkey'))) {
    console.error(`[dictation] couldn't register ${HOTKEY} — set DICTATION_HOTKEY to another combination`);
  } else {
    console.log(`[dictation] ready — press ${HOTKEY} to start and stop`);
  }
  startHook();
  if (!hookRunning && TRIGGER_KEYS[TRIGGER]) {
    console.log(`[dictation] ${TRIGGER} trigger waits for Accessibility — grant it to Electron`);
    const poll = setInterval(() => { startHook(); if (hookRunning) clearInterval(poll); }, 2000);
  }
  if (!API_KEY) console.warn('[dictation] ASSEMBLY_AI_KEY missing from ../.env — dictation will fail');
});

app.on('will-quit', () => {
  globalShortcut.unregisterAll();
  if (hookRunning) uIOhook.stop();
});
app.on('window-all-closed', (e) => e.preventDefault());
