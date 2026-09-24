# Voice intake form

A Google Forms–style patient intake form where every answer can be spoken, built on the
[Dictation API](https://www.assemblyai.com/docs/dictation).

- **One big mic fills the whole form.** Talk through everything in one go ("My name is Maria
  Lopez, born March 4th 1985, I'm here for a sore throat…"). The recording goes up in a single
  request whose `llm_instruction` swaps the usual cleanup rewrite for field extraction, so
  `llm_response` comes back as JSON with one key per question. There's no second LLM call.
  About 2 s for a 15 s clip.
- **A mic on every question** fills whatever's left. Each request carries an instruction scoped
  to that one question plus its formatting rule, so `"um my number is uh four one five…"` lands as
  `(415) 555-0123`, spoken emails come back as addresses, and dates come back as `March 4, 1985`.
- **Key terms per field.** Medications, allergies, history and insurance send `keyterms_prompt`
  lists (lisinopril, penicillin, Aetna…) so the spellings come back right.
- Questions the big mic didn't catch get flagged, with links that jump to each one. It fills only
  what was actually said, never clears an answer already given, and never ticks the consent box.

## Run it

```bash
cd intake-form && node server.js
```

Needs Node 18+, no `npm install`. It reads `ASSEMBLY_AI_KEY` from the repo-root `.env` (same as
`web/`) and proxies to the API, so the key never reaches the browser. Open http://localhost:3000.

## Or host it as a static page

`index.html` works on its own too. Without the server it asks each visitor for their own API
key (kept in that browser's `localStorage`) and calls `dictation.assemblyai.com` directly, since
the route allows cross-origin requests. That makes it fine for GitHub Pages or any static host.
Microphone access needs HTTPS or `localhost`.

With the server, the transcript under the big mic can also be edited and re-run through the
LLM Gateway ("Fill form from transcript"). The same gateway call also backs up the big mic when
the rewrite comes back empty (`llm_error`).

Submissions aren't stored anywhere. Submit just shows the captured JSON. It's a demo, not a
records system.
