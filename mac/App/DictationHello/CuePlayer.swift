import AppKit
import DictationEngine

/// Start/stop chimes, decoded once so the first one doesn't stall the pill.
@MainActor
final class CuePlayer {
    private var start: NSSound?
    private var stop: NSSound?
    private var loaded: SoundPack?

    func load(_ pack: SoundPack) {
        guard pack != loaded else { return }
        loaded = pack
        start = pack.sounds.flatMap { NSSound(named: $0.start) }
        stop = pack.sounds.flatMap { NSSound(named: $0.stop) }
        start?.volume = 0.5
        stop?.volume = 0.5
    }

    func play(_ cue: Cue) {
        let sound = cue == .start ? start : stop
        sound?.stop()
        sound?.play()
    }
}
