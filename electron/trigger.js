// Pure, clock-free trigger machine for a lone modifier — the same rules as the Mac app's
// TriggerGate. Callers pass monotonic timestamps; nothing here touches the keyboard.
//
//   down from idle            → start (recording always begins on key-down)
//   up after ≥ holdMs         → stop  (push-to-talk)
//   up sooner                 → latch; the next tap stops
//   another key while armed   → cancel (it was a shortcut like ⌥E, not a dictation)
//   another key while latched → nothing (passes through as a normal shortcut)

export const HOLD_MS = 1000;

export function createGate({ holdMs = HOLD_MS } = {}) {
  let state = 'idle';   // idle | armed | latched
  let downAt = 0;
  let isDown = false;   // edge filter: a repeated key-down must not double-fire

  return {
    get state() { return state; },

    down(now) {
      if (isDown) return null;
      isDown = true;
      if (state === 'idle') { state = 'armed'; downAt = now; return 'start'; }
      if (state === 'latched') { state = 'idle'; return 'stop'; }
      return null;
    },

    up(now) {
      if (!isDown) return null;
      isDown = false;
      if (state !== 'armed') return null;
      if (now - downAt >= holdMs) { state = 'idle'; return 'stop'; }
      state = 'latched';
      return null;
    },

    otherKey() {
      if (state !== 'armed') return null;
      state = 'idle';
      return 'cancel';
    },

    /** A dictation ended with no key event (auto-stop, an error): un-latch. */
    reset() { state = 'idle'; },
  };
}
