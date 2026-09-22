@testable import DictationEngine
import CoreGraphics
import Testing

@Suite struct PhaseUITests {
    @Test func connectingNeverInvitesSpeech() {
        let pill = PillState.from(.connecting)
        #expect(!pill.showsMeter && !pill.showsRecTag && pill.visible)
        #expect(PillState.from(.recording).showsMeter)
    }

    @Test func injectingNeverLooksIdle() {
        #expect(PillState.from(.injecting).visible)
        #expect(PillState.from(.injecting).dismissAfter == nil)
        #expect(Phase.injecting.isBusy)
    }

    @Test func noTargetIsAQuietNotice() {
        let pill = PillState.from(.noTarget(DictationRecord(text: "a", verbatim: "a", styleName: "Default")))
        #expect(pill.tone == .neutral && pill.label == "Copied to clipboard")
    }

    @Test func cuesFireOnTheRecordingEdge() {
        #expect(CueEdge.detect(from: .idle, to: .connecting) == nil)
        #expect(CueEdge.detect(from: .connecting, to: .recording) == .start)
        #expect(CueEdge.detect(from: .recording, to: .transcribing) == .stop)
        #expect(CueEdge.detect(from: .recording, to: .cancelled) == nil)
    }

    @Test func readinessIgnoresTheTriggerKey() {
        #expect(SetupReadiness(microphone: true, accessibility: true, apiKey: true).isReady)
        #expect(!SetupReadiness(microphone: true, accessibility: false, apiKey: true).isReady)
    }
}

@Suite struct SeparatorTests {
    let context = FocusSnapshot(bundleID: "com.apple.TextEdit", windowTitle: "Notes", priorText: "Hello there.")

    @Test func joinsWithASpaceAfterText() {
        #expect(Separator.leading(for: "Next.", context: context, lastPaste: nil) == " ")
    }

    @Test func noSpaceAtStartOrAfterWhitespaceOrBeforePunctuation() {
        var start = context
        start.priorText = ""
        #expect(Separator.leading(for: "Hi", context: start, lastPaste: nil) == "")
        var spaced = context
        spaced.priorText = "Hello "
        #expect(Separator.leading(for: "Hi", context: spaced, lastPaste: nil) == "")
        #expect(Separator.leading(for: ", and", context: context, lastPaste: nil) == "")
    }

    @Test func unreadableFallsBackToSameWindowOnly() {
        var unreadable = context
        unreadable.priorText = nil
        let same = LastPaste(bundleID: "com.apple.TextEdit", windowTitle: "Notes", text: "First.")
        let otherTab = LastPaste(bundleID: "com.apple.TextEdit", windowTitle: "Other", text: "First.")
        #expect(Separator.leading(for: "Second.", context: unreadable, lastPaste: same) == " ")
        #expect(Separator.leading(for: "Second.", context: unreadable, lastPaste: otherTab) == "")
        #expect(Separator.leading(for: "Second.", context: unreadable, lastPaste: nil) == "")
    }
}

@Suite struct GeometryTests {
    let screen = CGRect(x: 0, y: 25, width: 1440, height: 875)

    @Test func defaultsToBottomCentre() {
        let origin = OverlayGeometry.origin(saved: nil, visibleFrames: [screen], main: screen)
        #expect(origin.x == 590)
        #expect(origin.y == 25 + OverlayGeometry.bottomInset)
    }

    @Test func savedOriginOffScreenFallsBack() {
        let origin = OverlayGeometry.origin(saved: CGPoint(x: 5000, y: 5000), visibleFrames: [screen], main: screen)
        #expect(origin.x == 590)
        let kept = OverlayGeometry.origin(saved: CGPoint(x: 100, y: 300), visibleFrames: [screen], main: screen)
        #expect(kept == CGPoint(x: 100, y: 300))
    }
}
