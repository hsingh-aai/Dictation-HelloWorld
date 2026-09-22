import Foundation

/// Usable lone modifiers. Right-side, because a solo press rarely collides with app shortcuts.
public enum TriggerKey: Int, CaseIterable, Sendable, Identifiable {
    case rightCommand = 54
    case rightOption = 61

    public var id: Int { rawValue }
    public var keyCode: Int64 { Int64(rawValue) }

    /// Device-dependent mask; the plain `.maskCommand` can't tell left from right.
    public var deviceMask: UInt64 {
        switch self {
        case .rightCommand: 0x10   // NX_DEVICERCMDKEYMASK
        case .rightOption: 0x40    // NX_DEVICERALTKEYMASK
        }
    }

    public var displayName: String {
        switch self {
        case .rightCommand: "Right Command"
        case .rightOption: "Right Option"
        }
    }

    public var symbol: String {
        switch self {
        case .rightCommand: "right ⌘"
        case .rightOption: "right ⌥"
        }
    }

    public static let `default`: TriggerKey = .rightCommand
}

public enum ActivationMode: String, CaseIterable, Sendable, Identifiable {
    case tapOrHold, tapOnly, holdOnly

    public var id: String { rawValue }
    public static let `default`: ActivationMode = .tapOrHold

    public var displayName: String {
        switch self {
        case .tapOrHold: "Tap or hold"
        case .tapOnly: "Tap to toggle"
        case .holdOnly: "Hold to talk"
        }
    }

    public func readout(for key: TriggerKey) -> String {
        switch self {
        case .tapOrHold: "Tap \(key.displayName) to start and stop, or hold it to talk"
        case .tapOnly: "Tap \(key.displayName) to start and stop"
        case .holdOnly: "Hold \(key.displayName) and speak, release to finish"
        }
    }
}

/// Pure, clock-free trigger machine. Callers pass monotonic timestamps.
///
/// Recording always begins on key-down. A release past the hold threshold is push-to-talk; a
/// shorter one latches and the next tap stops. Another key while freshly armed cancels (it was a
/// shortcut, like ⌘C); over a latched recording it passes through untouched.
public struct TriggerGate: Sendable, Equatable {
    public enum State: Sendable, Equatable {
        case idle
        case armed(downAt: TimeInterval)
        case latched
    }

    public enum Action: Sendable, Equatable {
        case none, start, stop, cancel
    }

    public var mode: ActivationMode
    public var holdThreshold: TimeInterval
    public private(set) var state: State = .idle

    public init(mode: ActivationMode = .default, holdThreshold: TimeInterval = Timing.holdThreshold) {
        self.mode = mode
        self.holdThreshold = holdThreshold
    }

    public mutating func modifierDown(at time: TimeInterval) -> Action {
        switch state {
        case .idle:
            state = .armed(downAt: time)
            return .start
        case .armed:
            return .none
        case .latched:
            state = .idle
            return .stop
        }
    }

    public mutating func modifierUp(at time: TimeInterval) -> Action {
        guard case .armed(let downAt) = state else { return .none }
        let held = time - downAt >= holdThreshold
        switch mode {
        case .holdOnly:
            state = .idle
            return .stop
        case .tapOnly:
            state = .latched
            return .none
        case .tapOrHold:
            if held {
                state = .idle
                return .stop
            }
            state = .latched
            return .none
        }
    }

    public mutating func otherKeyDown() -> Action {
        guard case .armed = state else { return .none }
        state = .idle
        return .cancel
    }

    /// After the event tap was disabled: state survives only while the trigger is still held.
    /// Otherwise its key-up was among the dropped events. Returns `.cancel` when that discards
    /// a live capture.
    public mutating func resync(triggerHeld: Bool) -> Action {
        guard state != .idle, !triggerHeld else { return .none }
        state = .idle
        return .cancel
    }

    /// A dictation ended with no key event (auto-release, a refused press). Un-latch so the
    /// user's next press isn't silently swallowed.
    public mutating func reset() {
        state = .idle
    }
}

/// Turns raw `flagsChanged` reports into genuine edges for the bound key. `flagsChanged`
/// re-reports the bit whether or not it changed, so a repeat must not double-fire.
public struct TriggerRouter: Sendable, Equatable {
    public enum Edge: Sendable, Equatable { case down, up }

    public var key: TriggerKey
    public private(set) var isDown = false

    public init(key: TriggerKey = .default) {
        self.key = key
    }

    public mutating func flagsChanged(keyCode: Int64, flags: UInt64) -> Edge? {
        guard keyCode == key.keyCode else { return nil }
        return setHeld(flags & key.deviceMask != 0)
    }

    /// Also used to re-sync from `CGEventSource.flagsState` after a dropped-event window.
    public mutating func setHeld(_ held: Bool) -> Edge? {
        guard held != isDown else { return nil }
        isDown = held
        return held ? .down : .up
    }
}
