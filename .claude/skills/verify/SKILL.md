---
name: verify
description: How to run and drive the tts/ demo (AssemblyAI TTS song + Halloween voices) to verify changes.
---

# Verifying tts/

- Render: `cd tts && node furby-song.js && node halloween.js` (needs `ASSEMBLY_AI_KEY` in repo `.env`, ffmpeg). TTS is cached in `tts/out/cache/`; delete a cache file to force a fresh API call.
- Single line: `node speak.js "text" <voice> out/x.wav`. A bad voice gives a clean `invalid_value` error listing the valid voices.
- Page: `preview_start {name: "tts-demo"}` (python http.server on :4317), then open `/playground.html`. Click play buttons and read `#song-time`, `.lyrics li.on`, `.card.playing`.
- Gotchas:
  - python http.server sends no `Accept-Ranges`, so Chrome can't seek: lyric or progress-bar clicks restart at 0:00. To test seeking, swap `songBtn.dataset.src` to a blob URL.
  - `playground.html` has no `<meta charset>`; the artifact host adds one. Locally, curly quotes and minus signs render garbled. That's local-only.
  - The published artifact (claude.ai) needs a sign-in, so the browser pane can't open it. Check the published files with `Artifact list scope:files` instead.
- Intelligibility check: upload the mp3 to AssemblyAI `/v2/upload`, transcribe it, and compare the text with the scripts.
