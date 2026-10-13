# TTS demo

AssemblyAI Voice Agent API voices used as plain TTS: the session `greeting` is spoken verbatim, and we collect the `reply.audio` PCM (24 kHz). ffmpeg effects and a JS synth do the rest.

```
node speak.js "Hello there" alba out/hello.wav   # one-off line in any voice
node furby-song.js                                # -> out/furby-girl.mp3
node halloween.js                                 # -> out/halloween-*.mp3 + reel
open index.html                                   # player page
```

Needs `ASSEMBLY_AI_KEY` in the repo `.env`, Node 22+, and ffmpeg. TTS results are cached in `out/cache/`.
Voices: alba eve george jane jean mary michael (US), anna charles paul vera (UK), giovanni lola juergen rafael estelle.
