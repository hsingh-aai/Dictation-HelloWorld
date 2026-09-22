# Dictation Hello (macOS)

Native macOS dictation on AssemblyAI's Dictation API, built from the `blurt-dictation` skill.
Press a lone right-side modifier, speak, and the cleaned transcript is pasted into whatever app
has focus. Each utterance is one streamed `POST /v1/transcribe/live` that returns both the
verbatim text and the cleaned rewrite.

```bash
./build.sh            # dev build → /Applications/Dictation Hello Dev.app
./build.sh --release  # shipping id → /Applications/Dictation Hello.app
./check.sh            # definition of green: warning-free build + all tests
```

Requires full Xcode (the scripts set `DEVELOPER_DIR`). First launch opens a wizard for
Microphone, Accessibility and your API key (validated, then stored in the Keychain).

**Trigger:** Right ⌘ by default (Right ⌥ optional). Tap to start and tap again to stop, or hold
past 1 s for push-to-talk. Combos like ⌘C still work: they cancel a capture that just started,
and they pass through untouched during a latched recording. Esc cancels while the window is key.

**Headless self-test.** This proves the wire contract with no permissions granted:

```bash
say -o /tmp/c.aiff "um so this is a test" && afconvert -f WAVE -d LEI16@16000 -c 1 /tmp/c.aiff /tmp/c.wav
ASSEMBLYAI_API_KEY=... .build/debug/DictationHello --selftest /tmp/c.wav
```

## Layout

```text
Sources/DictationEngine/   dependency-free engine — the whole pipeline
  Config/        wire + timing constants, Keychain, settings roster, developer log
  STT/           config encoding + fitters, streaming multipart client, response/errors
  Audio/         fresh AVCaptureSession per capture, 16 kHz mono S16LE, liveness gate
  Hotkey/        pure TriggerGate/TriggerRouter + listen-only CGEventTap
  FocusCapture/  bounded (500 ms) AX read of the text before the cursor
  Injection/     clipboard paste (snapshot → write → ⌘V → settle → restore), separator
  Pipeline/      DictationPipeline actor, phases, phase→pill mapping, cue edges
App/DictationHello/        SwiftUI/AppKit shell: wizard, ready screen, pill, menu bar, settings
Tests/                     47 tests; three stubs cover mic, network and pasteboard
```

## Signing

`build.sh` signs with `Apple Development` if present (with a designated requirement pinned to the
team, not the rotating leaf), otherwise the local `Dictation Flow Local` certificate (pinned to its
root), otherwise ad-hoc with a warning. Then it installs to `/Applications`, because TCC won't
register apps anywhere else. Check that the identity stays stable across rebuilds:

```bash
codesign -d -r- "/Applications/Dictation Hello Dev.app" 2>&1 | grep designated
```

If a grant goes stale anyway: `tccutil reset Accessibility com.example.dictationhello.dev`.

## Not built

- The update check (there's no release feed to check).
- Vintage synth sound packs. The cues are system sounds instead: Glass, Pop, or off.
