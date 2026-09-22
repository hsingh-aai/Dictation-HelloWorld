@testable import DictationEngine
import Testing

@Suite struct TriggerGateTests {
    @Test func tapLatchesAndNextTapStops() {
        var gate = TriggerGate()
        #expect(gate.modifierDown(at: 0) == .start)
        #expect(gate.modifierUp(at: 0.2) == .none)
        #expect(gate.state == .latched)
        #expect(gate.modifierDown(at: 3) == .stop)
        #expect(gate.modifierUp(at: 3.1) == .none)
        #expect(gate.state == .idle)
    }

    @Test func holdStopsOnRelease() {
        var gate = TriggerGate()
        #expect(gate.modifierDown(at: 10) == .start)
        #expect(gate.modifierUp(at: 11.5) == .stop)
        #expect(gate.state == .idle)
    }

    @Test func comboFromIdleCancels() {
        var gate = TriggerGate()
        _ = gate.modifierDown(at: 0)
        #expect(gate.otherKeyDown() == .cancel)   // ⌘C: the fresh capture is discarded
        #expect(gate.modifierUp(at: 0.1) == .none)
        #expect(gate.state == .idle)
    }

    @Test func comboOverLatchedPassesThrough() {
        var gate = TriggerGate()
        _ = gate.modifierDown(at: 0)
        _ = gate.modifierUp(at: 0.1)
        #expect(gate.otherKeyDown() == .none)
        #expect(gate.state == .latched)
    }

    @Test func tapOnlyLatchesEvenOnLongPress() {
        var gate = TriggerGate(mode: .tapOnly)
        _ = gate.modifierDown(at: 0)
        #expect(gate.modifierUp(at: 5) == .none)
        #expect(gate.state == .latched)
    }

    @Test func holdOnlyStopsEvenOnShortPress() {
        var gate = TriggerGate(mode: .holdOnly)
        _ = gate.modifierDown(at: 0)
        #expect(gate.modifierUp(at: 0.1) == .stop)
    }

    @Test func droppedEventsKeepStateOnlyWhileHeld() {
        var gate = TriggerGate()
        _ = gate.modifierDown(at: 0)
        #expect(gate.resync(triggerHeld: true) == .none)
        #expect(gate.state == .armed(downAt: 0))
        #expect(gate.resync(triggerHeld: false) == .cancel)
        #expect(gate.state == .idle)
    }

    @Test func terminalPhaseResetUnlatches() {
        var gate = TriggerGate()
        _ = gate.modifierDown(at: 0)
        _ = gate.modifierUp(at: 0.1)
        gate.reset()   // e.g. the 115 s auto-release ended it with no key event
        #expect(gate.modifierDown(at: 200) == .start)
    }
}

@Suite struct TriggerRouterTests {
    @Test func repeatedFlagsChangedDoesNotDoubleFire() {
        var router = TriggerRouter(key: .rightCommand)
        let down: UInt64 = 0x100010
        #expect(router.flagsChanged(keyCode: 54, flags: down) == .down)
        #expect(router.flagsChanged(keyCode: 54, flags: down) == nil)
        #expect(router.flagsChanged(keyCode: 54, flags: 0x100) == .up)
        #expect(router.flagsChanged(keyCode: 54, flags: 0x100) == nil)
    }

    @Test func otherModifiersAreIgnored() {
        var router = TriggerRouter(key: .rightCommand)
        // Left ⌘ (keycode 55) sets the generic command bit but not the right-hand device bit.
        #expect(router.flagsChanged(keyCode: 55, flags: 0x100008) == nil)
        #expect(router.flagsChanged(keyCode: 54, flags: 0x100008) == nil)
    }

    @Test func rightOptionUsesItsDeviceMask() {
        var router = TriggerRouter(key: .rightOption)
        #expect(router.flagsChanged(keyCode: 61, flags: 0x80040) == .down)
        #expect(router.flagsChanged(keyCode: 61, flags: 0x100) == .up)
    }
}
