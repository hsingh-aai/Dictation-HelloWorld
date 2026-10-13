# Dictation Hello (Electron)

Tray dictation on AssemblyAI's Dictation API. It's the cross-platform counterpart to [`../mac`](../mac),
and its renderer reuses the repo's `shared/` modules (WAV encoding, diff, the cleanup instruction,
shortcuts).

```bash
npm install
npm start                      # tray app: ◎ idle · ● recording · ◍ transcribing
DICTATION_SHOW=1 npm start     # also pins the panel open, for trying it out
DICTATION_SELFTEST=/path/clip.wav npm start   # headless: one request, prints both transcripts
```

The key comes from `ASSEMBLY_AI_KEY` in the repo's `.env`, and only the main process sees it.
`preload.cjs` exposes a small IPC surface, with `contextIsolation` and `sandbox` on.

**Trigger:** press `Ctrl+Alt+D` to start and again to stop (override with `DICTATION_HOTKEY`). This
build toggles rather than holds: Electron's `globalShortcut` registers key combinations only, so it
can't see a lone modifier being held. Esc cancels while the panel has focus.

**Paste:** saves the clipboard, writes the text, sends ⌘V through `osascript`, then restores the
clipboard after 400 ms. That needs Accessibility for **Electron** (in dev, the `Electron.app` inside
`node_modules`), and macOS will also ask once to let it control System Events. Without the grant,
results are copied to the clipboard and the panel says so.

**Shortcuts:** "say the phrase, get the text", applied locally after transcription. Your personal
list lives in `shortcuts.local.json` (gitignored; see `shortcuts.example.json`). It seeds the panel
on first run, and edits in Settings are saved from then on.

Not done: packaging (`electron-builder` plus signing and notarization), streaming the upload while
you speak (it buffers, then posts), and reading the text before the cursor for context.
