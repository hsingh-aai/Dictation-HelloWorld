import CoreGraphics
import Foundation

/// Listen-only `CGEventTap` for `flagsChanged` (the bound modifier) and `keyDown` (any other key).
/// It swallows nothing: a lone modifier types nothing anyway, and combos pass straight through.
@MainActor
public final class HotkeyMonitor {
    public var onAction: ((TriggerGate.Action) -> Void)?

    public private(set) var gate: TriggerGate
    private var router: TriggerRouter
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    public init(key: TriggerKey, mode: ActivationMode) {
        gate = TriggerGate(mode: mode)
        router = TriggerRouter(key: key)
    }

    public var isRunning: Bool { tap != nil }

    /// Needs the Accessibility grant; returns false (and can be retried) without it.
    @discardableResult
    public func start() -> Bool {
        guard tap == nil else { return true }
        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(mask),
            callback: hotkeyTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        _ = router.setHeld(isTriggerPhysicallyHeld)
        return true
    }

    public func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
    }

    /// Rebinding mid-recording takes the same discard-and-cancel path as a reset.
    public func configure(key: TriggerKey, mode: ActivationMode) {
        guard key != router.key || mode != gate.mode else { return }
        let wasActive = gate.state != .idle
        router = TriggerRouter(key: key)
        _ = router.setHeld(isTriggerPhysicallyHeld)
        gate = TriggerGate(mode: mode)
        if wasActive { onAction?(.cancel) }
    }

    /// Call on every terminal phase: a dictation can end with no key event.
    public func dictationEnded() {
        gate.reset()
    }

    private var isTriggerPhysicallyHeld: Bool {
        CGEventSource.flagsState(.combinedSessionState).rawValue & router.key.deviceMask != 0
    }

    fileprivate func handle(type: CGEventType, keyCode: Int64, flags: UInt64) {
        let now = ProcessInfo.processInfo.systemUptime
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            let held = isTriggerPhysicallyHeld
            _ = router.setHeld(held)
            emit(gate.resync(triggerHeld: held))
        case .flagsChanged:
            switch router.flagsChanged(keyCode: keyCode, flags: flags) {
            case .down: emit(gate.modifierDown(at: now))
            case .up: emit(gate.modifierUp(at: now))
            case nil: break
            }
        case .keyDown:
            emit(gate.otherKeyDown())
        default:
            break
        }
    }

    private func emit(_ action: TriggerGate.Action) {
        guard action != .none else { return }
        onAction?(action)
    }
}

private func hotkeyTapCallback(
    proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if let userInfo {
        let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
        // The tap's run-loop source is on the main run loop.
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags.rawValue
        MainActor.assumeIsolated { monitor.handle(type: type, keyCode: keyCode, flags: flags) }
    }
    return Unmanaged.passUnretained(event)
}
