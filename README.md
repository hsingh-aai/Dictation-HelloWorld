# Dictation Hello

Wispr Flow–style dictation on [AssemblyAI's Dictation API](https://www.assemblyai.com/docs/dictation).
Speak, and get back both the **verbatim** transcript and an **LLM-cleaned** rewrite — from a single
HTTP request per utterance. No polling, no second LLM call, no local model.

Two builds share one set of logic:

| | [`web/`](web) | [`mac/`](mac) |
|---|---|---|
| Trigger | Hold `Space` or click the mic | Lone right-side modifier, system-wide (tap to toggle, hold to talk) |
| Where the key lives | Server-side proxy only | Keychain, in-process |
| Pastes at the cursor | No | Yes |
| Good for | Trying instructions, key terms and languages quickly | Actually using it |

A ~6 s clip round-trips in about a second; measured post-speech latency is ~500–700 ms.

## The skill

[`SKILL for Dictation.md`](SKILL%20for%20Dictation.md) is the reason this repo is worth cloning.
It is a self-contained build guide for dictation clients on this API — the full wire contract,
the pipeline, macOS-native / Electron / web recipes, and the UI/UX decisions behind them. Every
wire fact in it was measured against the live route.

It is also installed at `.claude/skills/blurt-dictation/SKILL.md`, so if you open this repo in
Claude Code it loads automatically whenever your work touches `dictation.assemblyai.com`. The
macOS app in `mac/` was built straight from it.

## Setup

```bash
cp .env.example .env    # then paste your key in
```

Get a key at [assemblyai.com/dashboard/api-keys](https://www.assemblyai.com/dashboard/api-keys).
`.env` is gitignored; no key is committed anywhere in this repo.

## Web app

```bash
cd web && npm install && npm start
```

Open http://localhost:3000. The browser records via `MediaRecorder`, resamples to 16 kHz mono WAV
in an `OfflineAudioContext`, and posts to a small Express proxy. **The key never reaches the
browser** — that is the entire reason the proxy exists.

You get a before/after diff (a word-level LCS of `text` against `llm_response`, which is what makes
the cleanup legible), plus live controls for every config parameter the API accepts.

## macOS app

```bash
cd mac && ./build.sh && open "/Applications/Dictation Hello Dev.app"
```

Requires full Xcode. See [`mac/README.md`](mac/README.md) for the trigger model, permissions,
signing and the headless self-test.

## Instruction modifiers and shortcuts

The cleanup instruction is composed rather than typed: a measured base task, plus optional
clauses appended after a precedence preamble. The web app ships spelling (American/British) as
an instruction modifier, and shortcuts — say a phrase, get written text — as a **local**
transform.

**The `llm_instruction` cap is 2048 characters, and going over rejects the whole request.**
Measured on the live route: 2048 passes, 2049 returns `400 llm_instruction: String should have
at most 2048 characters`, before any audio is read. So one character over means every dictation
fails, not a degraded rewrite. It counts *codepoints*, not bytes — 2048 `é` is 4096 bytes and
passes. The base instruction alone is 1529, so the UI shows a live meter and disables the mic
when over.

**A modifier clause must name the rule it overrides, or it silently does nothing.**

| Clause | Result |
|---|---|
| "Use British English spellings, not American." | **no-op** |
| "Respell words into British English (color→colour, organize→organise). This spelling change overrides the rule above about keeping words exactly as spoken." | **works** |
| A longer, more forceful imperative | **no-op** |

The base says "keep every remaining word exactly as spoken… do not correct or rephrase", which
beats a politely-worded preference even after the precedence preamble. Naming the specific
conflict is what wins — not emphasis, not length.

**Shortcuts are applied client-side, and shouldn't be an LLM instruction at all.** They started
out as a clause in `llm_instruction`, which was wrong twice over:

- It spent the budget the cleanup task needs, capping you at about two shortcuts.
- It asked a language model to perform a literal substitution, which it did unreliably. The
  obvious phrasing prepended the replacement at the *start* of the text, where a removed filler
  had been, and left the spoken phrase untouched:

  > said: "um send the invoice to my **personal email** and then let me know"
  > got: "**you@example.com**, send the invoice to my personal email and then let me know"

  Wording around that was possible ("in place", plus keeping the pairs as an arrow list) but
  fragile — merging pairs into prose passed with one shortcut and dropped half the sentence with
  two.

`shared/shortcuts.js` does it as a case-insensitive, word-boundary-aware replacement on the
returned text: exact, deterministic, unlimited, and free of instruction budget. The verbatim pane
is deliberately left untouched, since that pane is what you actually said.

The general lesson, if you add your own: **put deterministic text transforms in code and keep the
instruction for things only a model can do.** A style preference is a good clause; a find-and-replace
is not.

## Config parameters

The API accepts exactly five config fields. `sample_rate`/`channels` are required for raw PCM only;
both builds send WAV, which carries them in its header.

| Parameter | Cap | In the web UI |
|---|---|---|
| `llm_instruction` | 2048 characters | Composed — preset + modifiers |
| `stt_prompt` | 4096 Unicode scalars | "Audio context" |
| `keyterms_prompt` | 2048 bytes **and** 100 terms | "Key terms" |
| `sample_rate`, `channels` | — | n/a (WAV) |

Caps are clamped client-side rather than sent and rejected. The numbers differ per field — reusing
one field's figure for another is a documented way to break every dictation at once.

The web app also exposes `language_codes` (32 codes, filtered against the API's own list and omitted
when the selection is just English). The skill argues for sending no language field at all, since
detection works and pinning a language measurably hurts non-English speech — worth reading before
you rely on the picker.

## Gotchas worth knowing

- **`Authorization: <key>`** — raw, no `Bearer` prefix.
- **The `config` part must precede the `audio` part.** Reversed, it's a hard 400: the route cannot
  open its upstream call without the config. Both builds depend on this ordering and comment it,
  because it looks like arbitrary style.
- **Audio below ~80 ms returns 200 with an empty transcript**, not an error. Guard client-side or
  you pay for nothing.
- **The rewrite is best-effort** (5 s server-side budget). `llm_error` can be set on an otherwise
  fine 200 — always fall back to `text`.
- Only documented field names are accepted; unknown keys are rejected outright, and legacy aliases
  (`prompt`, `keyterms`, `word_boost`) collide with their modern names for a 400.

## Layout

```text
SKILL for Dictation.md        the build guide — start here
.claude/skills/               same file, auto-loaded by Claude Code
shared/                       one copy of the logic both builds use
  instruction.js              instruction composer, character budget, modifier clauses
  shortcuts.js                local phrase replacement (no instruction budget)
  diff.js                     word-level LCS diff
  wav.js                      MediaRecorder blob → 16 kHz mono WAV
  presets.js                  rewrite instructions
  languages.js                the 32 supported language codes
web/
  server.js                   Express proxy — holds the key, builds the multipart body
  public/                     UI over the shared modules
mac/                          native Swift app (see mac/README.md)
```

## License

MIT.
