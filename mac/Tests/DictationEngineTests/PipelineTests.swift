@testable import DictationEngine
import Foundation
import Testing

// Three fakes cover hardware, the network and the pasteboard.

final class StubMic: MicCapture, @unchecked Sendable {
    let milliseconds: Int
    init(milliseconds: Int) { self.milliseconds = milliseconds }
    func start(frames: @escaping @Sendable (Data) -> Void) async throws {
        frames(Data(count: Wire.bytesPerSecond * milliseconds / 1000))
    }
    func stop() async {}
}

struct StubMicFactory: MicCaptureFactory {
    var milliseconds = 500
    func make() -> any MicCapture { StubMic(milliseconds: milliseconds) }
}

final class StubSession: TranscriptionSession, @unchecked Sendable {
    let lock = NSLock()
    let response: Result<DictationResponse, DictationError>
    var config: DictationConfig?
    var bytes = 0
    var cancelled = false
    init(response: Result<DictationResponse, DictationError>) { self.response = response }
    func send(_ pcm: Data) { lock.withLock { bytes += pcm.count } }
    func open(config: DictationConfig) { lock.withLock { self.config = config } }
    func finish() async throws -> DictationResponse {
        if audioBytes * 1000 < Wire.minAudioMs * Wire.bytesPerSecond { throw DictationError.tooShort }
        return try response.get()
    }
    func cancel() { lock.withLock { cancelled = true } }
    var audioBytes: Int { lock.withLock { bytes } }
}

final class StubTranscriber: Transcriber, @unchecked Sendable {
    let lock = NSLock()
    var responses: [Result<DictationResponse, DictationError>]
    var sessions: [StubSession] = []
    init(_ responses: [Result<DictationResponse, DictationError>]) { self.responses = responses }
    func warm() {}
    func makeSession(apiKey: String) -> any TranscriptionSession {
        lock.withLock {
            let session = StubSession(response: responses.isEmpty ? .success(DictationResponse(text: "")) : responses.removeFirst())
            sessions.append(session)
            return session
        }
    }
}

final class StubInjector: TextInjecting, @unchecked Sendable {
    let outcome: InjectionOutcome
    private(set) var injected: [String] = []
    init(outcome: InjectionOutcome = .pasted) { self.outcome = outcome }
    @MainActor func inject(_ text: String, into target: FocusSnapshot) async -> InjectionOutcome {
        injected.append(text)
        return outcome
    }
}

struct StubFocus: FocusReading {
    var snapshot: FocusSnapshot
    func read() async -> FocusSnapshot { snapshot }
}

@Suite struct PipelineTests {
    let focus = FocusSnapshot(pid: 1, bundleID: "com.example", windowTitle: "Doc", priorText: "Dear team,")

    func makePipeline(
        _ transcriber: StubTranscriber, injector: StubInjector = StubInjector(),
        mic: StubMicFactory = StubMicFactory(), focus: FocusSnapshot? = nil,
        settings: RequestSettings = RequestSettings(apiKey: "key")
    ) -> DictationPipeline {
        DictationPipeline(
            transcriber: transcriber, micFactory: mic, injector: injector,
            focus: StubFocus(snapshot: focus ?? self.focus), settings: { settings }
        )
    }

    /// Drives one dictation and collects phases up to the first terminal (or idle after work).
    func dictate(_ pipeline: DictationPipeline, cancelWhileRecording: Bool = false) async -> [Phase] {
        var phases: [Phase] = []
        pipeline.submit(.press)
        for await phase in pipeline.phases {
            phases.append(phase)
            if phase == .recording { pipeline.submit(cancelWhileRecording ? .cancel : .release) }
            if phase.isTerminal || (phase == .idle && phases.count > 1) { break }
        }
        return phases
    }

    @Test func happyPathPastesTheRewrite() async {
        let transcriber = StubTranscriber([.success(DictationResponse(text: "um hello", llmResponse: "Hello."))])
        let injector = StubInjector()
        let pipeline = makePipeline(transcriber, injector: injector)
        let phases = await dictate(pipeline)
        #expect(Array(phases.prefix(4)) == [.connecting, .recording, .transcribing, .injecting])
        guard case .pasted(let record) = phases.last else { Issue.record("expected pasted, got \(phases)"); return }
        #expect(record.text == "Hello." && record.verbatim == "um hello")
        #expect(injector.injected == [" Hello."])
        let config = transcriber.sessions.first?.config
        #expect(config?.sttPrompt == "Dear team,")
        #expect(config?.llmInstruction == Instruction.base)
    }

    @Test func historyPrimesTheNextDictation() async {
        let transcriber = StubTranscriber([
            .success(DictationResponse(text: "first", llmResponse: "First.")),
            .success(DictationResponse(text: "second", llmResponse: "Second.")),
        ])
        let pipeline = makePipeline(transcriber)
        _ = await dictate(pipeline)
        _ = await dictate(pipeline)
        #expect(transcriber.sessions.last?.config?.sttPrompt == "First.\nDear team,")
    }

    @Test func missingKeyIsASetupFailureBeforeTheMicStarts() async {
        let transcriber = StubTranscriber([])
        let pipeline = makePipeline(transcriber, settings: RequestSettings(apiKey: nil))
        pipeline.submit(.press)
        var first: Phase?
        for await phase in pipeline.phases { first = phase; break }
        guard case .failed(let failure) = first else { Issue.record("expected failure"); return }
        #expect(failure.isSetup)
        #expect(transcriber.sessions.isEmpty)
    }

    @Test func cleanupOffPastesVerbatim() async {
        let transcriber = StubTranscriber([.success(DictationResponse(text: "um hello", llmResponse: "Hello."))])
        let injector = StubInjector()
        let pipeline = makePipeline(transcriber, injector: injector, settings: RequestSettings(apiKey: "k", enhanced: false))
        _ = await dictate(pipeline)
        #expect(injector.injected == [" um hello"])
    }

    @Test func secureFieldIsNeverContextOrHistory() async {
        let secure = FocusSnapshot(pid: 1, bundleID: "com.example", isSecure: true)
        let transcriber = StubTranscriber([
            .success(DictationResponse(text: "hunter2")),
            .success(DictationResponse(text: "next")),
        ])
        let pipeline = makePipeline(transcriber, focus: secure)
        let phases = await dictate(pipeline)
        guard case .pasted(let record) = phases.last else { Issue.record("expected pasted"); return }
        #expect(record.sensitive)
        _ = await dictate(pipeline)
        #expect(transcriber.sessions.last?.config?.sttPrompt == nil)
    }

    @Test func noTargetCopiesQuietly() async {
        let transcriber = StubTranscriber([.success(DictationResponse(text: "hi"))])
        let pipeline = makePipeline(transcriber, injector: StubInjector(outcome: .copied))
        let phases = await dictate(pipeline)
        guard case .noTarget = phases.last else { Issue.record("expected noTarget, got \(phases)"); return }
    }

    @Test func cancelWhileRecordingCancelsTheRequest() async {
        let transcriber = StubTranscriber([.success(DictationResponse(text: "hi"))])
        let pipeline = makePipeline(transcriber)
        let phases = await dictate(pipeline, cancelWhileRecording: true)
        #expect(phases.last == .cancelled)
        #expect(transcriber.sessions.first?.cancelled == true)
    }

    @Test func tooShortReturnsToIdle() async {
        let transcriber = StubTranscriber([.success(DictationResponse(text: "hi"))])
        let pipeline = makePipeline(transcriber, mic: StubMicFactory(milliseconds: 40))
        let phases = await dictate(pipeline)
        #expect(phases.last == .idle)
    }

    @Test func serverErrorFailsWithoutSetupRouting() async {
        let transcriber = StubTranscriber([.failure(.server(status: 400, message: "stt_prompt too long"))])
        let pipeline = makePipeline(transcriber)
        let phases = await dictate(pipeline)
        guard case .failed(let failure) = phases.last else { Issue.record("expected failure"); return }
        #expect(!failure.isSetup)
    }
}
