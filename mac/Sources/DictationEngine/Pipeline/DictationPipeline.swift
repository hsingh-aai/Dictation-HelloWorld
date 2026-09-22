import Foundation
import os

/// What a single dictation needs from settings, read once at press.
public struct RequestSettings: Sendable, Equatable {
    public var apiKey: String?
    public var keyterms: [String]
    public var styleName: String
    public var styleInstruction: String?
    /// Cleanup on → `llm_response` (falling back to `text`); off → `text`. Decided on the response.
    public var enhanced: Bool

    public init(apiKey: String?, keyterms: [String] = [], styleName: String = "Default", styleInstruction: String? = nil, enhanced: Bool = true) {
        self.apiKey = apiKey
        self.keyterms = keyterms
        self.styleName = styleName
        self.styleInstruction = styleInstruction
        self.enhanced = enhanced
    }
}

/// press → connecting → recording → transcribing → injecting → pasted | noTarget | failed | cancelled
public actor DictationPipeline {
    public enum Command: Sendable { case press, release, cancel, cancelRecording }

    private static let log = Logger(subsystem: "com.example.dictationhello", category: "pipeline")

    public nonisolated let phases: AsyncStream<Phase>
    private nonisolated let phaseSink: AsyncStream<Phase>.Continuation
    private nonisolated let commandSink: AsyncStream<Command>.Continuation

    private let transcriber: any Transcriber
    private let micFactory: any MicCaptureFactory
    private let injector: any TextInjecting
    private let focus: any FocusReading
    private let settingsProvider: @Sendable () async -> RequestSettings
    private let devLog: DevLog?

    public private(set) var phase: Phase = .idle
    private var generation = 0
    private var settings = RequestSettings(apiKey: nil)
    private var mic: (any MicCapture)?
    private var session: (any TranscriptionSession)?
    private var contextTask: Task<FocusSnapshot, Never>?
    private var finishTask: Task<Void, Never>?
    private var autoRelease: Task<Void, Never>?
    private var releasedAt = ContinuousClock.now
    /// In memory only, capped, cleared on quit; never holds what went into a password field.
    private var history: [String] = []
    private var lastPaste: LastPaste?

    public init(
        transcriber: any Transcriber,
        micFactory: any MicCaptureFactory,
        injector: any TextInjecting,
        focus: any FocusReading,
        devLog: DevLog? = nil,
        settings: @escaping @Sendable () async -> RequestSettings
    ) {
        self.transcriber = transcriber
        self.micFactory = micFactory
        self.injector = injector
        self.focus = focus
        self.devLog = devLog
        self.settingsProvider = settings
        (phases, phaseSink) = AsyncStream.makeStream(of: Phase.self, bufferingPolicy: .unbounded)
        let (commands, commandSink) = AsyncStream.makeStream(of: Command.self, bufferingPolicy: .unbounded)
        self.commandSink = commandSink
        Task { [weak self] in
            for await command in commands {
                await self?.handle(command)
            }
        }
    }

    /// Synchronous and fire-and-forget for callback-shaped hosts (an event-tap callback).
    /// Preserves emit order — spawning a task per callback would reorder commands.
    public nonisolated func submit(_ command: Command) {
        commandSink.yield(command)
    }

    public func clearHistory() {
        history.removeAll()
        lastPaste = nil
    }

    private func handle(_ command: Command) async {
        switch command {
        case .press: await press()
        case .release: release()
        case .cancel: await cancel(includingRequest: true)
        case .cancelRecording: await cancel(includingRequest: false)
        }
    }

    // MARK: Press

    private func press() async {
        guard !phase.isBusy else { return }
        let settings = await settingsProvider()
        // Refuse the press without a key, so it surfaces before the user speaks.
        guard let apiKey = settings.apiKey, !apiKey.isEmpty else {
            setPhase(.failed(DictationFailure(.missingAPIKey)))
            return
        }
        generation += 1
        let generation = self.generation
        self.settings = settings
        // Claim "connecting" before the mic starts, so the UI answers the key-down immediately.
        setPhase(.connecting)
        transcriber.warm()

        let session = transcriber.makeSession(apiKey: apiKey)
        self.session = session
        let history = self.history
        let focus = self.focus
        let config = { (context: FocusSnapshot) in
            DictationConfig(
                sttPrompt: PromptFitter.fit(history: history, priorText: context.isSecure ? nil : context.priorText),
                keyterms: KeytermFitter.fit(settings.keyterms),
                llmInstruction: Instruction.build(style: settings.styleInstruction)
            )
        }
        // The bounded context read resolves before the request opens, so nothing ever sits
        // between the final frame and the closing boundary. Frames captured meanwhile buffer.
        contextTask = Task {
            let context = await focus.read()
            session.open(config: config(context))
            return context
        }

        let mic = micFactory.make()
        self.mic = mic
        do {
            try await mic.start { session.send($0) }
        } catch {
            guard generation == self.generation else { return }
            session.cancel()
            self.mic = nil
            fail(error)
            return
        }
        guard generation == self.generation, phase == .connecting else {
            await mic.stop()
            return
        }
        setPhase(.recording)
        autoRelease = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Wire.autoReleaseSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.autoReleaseFired(generation)
        }
    }

    private func autoReleaseFired(_ generation: Int) {
        guard generation == self.generation, phase == .recording else { return }
        Self.log.info("auto-release at \(Wire.autoReleaseSeconds) s")
        release()
    }

    // MARK: Release

    private func release() {
        guard phase == .recording else { return }
        autoRelease?.cancel()
        // Claim "transcribing" before stopping the mic, so the stop cue lands at key-up and a
        // Bluetooth tail linger sits inside stop() without the user waiting on it.
        setPhase(.transcribing)
        releasedAt = .now
        let generation = self.generation
        finishTask = Task { await self.complete(generation) }
    }

    private func complete(_ generation: Int) async {
        guard let session, let contextTask else { return }
        if let mic {
            await mic.stop()
            self.mic = nil
        }
        let context = await contextTask.value
        do {
            let response = try await session.finish()
            guard generation == self.generation, phase == .transcribing else { return }
            if let llmError = response.llmError {
                Self.log.notice("rewrite degraded (\(llmError, privacy: .public)); using verbatim text")
            }
            let text = response.transcript(enhanced: settings.enhanced).trimmingCharacters(in: .whitespacesAndNewlines)
            // An empty transcript returns to idle without injecting or reporting.
            guard !text.isEmpty else {
                setPhase(.idle)
                return
            }
            if !context.isSecure {
                history.append(text)
                if history.count > Timing.historyCap { history.removeFirst(history.count - Timing.historyCap) }
            }
            let record = DictationRecord(text: text, verbatim: response.text, styleName: settings.styleName, sensitive: context.isSecure)
            setPhase(.injecting)
            let separator = Separator.leading(for: text, context: context, lastPaste: lastPaste)
            let outcome = await injector.inject(separator + text, into: context)
            let elapsed = ContinuousClock.now - releasedAt
            Self.log.info("release→\(outcome == .pasted ? "pasted" : "copied", privacy: .public) \(Int(elapsed / .milliseconds(1))) ms")
            if outcome == .pasted {
                lastPaste = LastPaste(bundleID: context.bundleID, windowTitle: context.windowTitle, text: text)
            }
            setPhase(outcome == .pasted ? .pasted(record) : .noTarget(record), context: context)
        } catch DictationError.tooShort {
            if generation == self.generation { setPhase(.idle) }
        } catch DictationError.cancelled {
            if generation == self.generation, phase != .cancelled { setPhase(.cancelled) }
        } catch {
            if generation == self.generation { fail(error, context: context) }
        }
    }

    // MARK: Cancel

    private func cancel(includingRequest: Bool) async {
        switch phase {
        case .connecting, .recording:
            generation += 1
            autoRelease?.cancel()
            contextTask?.cancel()
            session?.cancel()
            session = nil
            setPhase(.cancelled)
            if let mic {
                self.mic = nil
                await mic.stop()
            }
        case .transcribing where includingRequest:
            generation += 1
            finishTask?.cancel()
            session?.cancel()
            session = nil
            setPhase(.cancelled)
        default:
            break
        }
    }

    // MARK: Phase

    private func fail(_ error: Error, context: FocusSnapshot? = nil) {
        let dictationError = error as? DictationError ?? .network(error.localizedDescription)
        setPhase(.failed(DictationFailure(dictationError)), context: context)
    }

    /// The developer log hooks in here, not at call sites, so a failure path added later is
    /// logged by construction.
    private func setPhase(_ new: Phase, context: FocusSnapshot? = nil) {
        phase = new
        phaseSink.yield(new)
        switch new {
        case .pasted(let record), .noTarget(let record):
            if !record.sensitive { devLog?.dictation(record, context: context) }
        case .failed(let failure):
            devLog?.failure(failure, context: context)
            Self.log.error("\(failure.name, privacy: .public): \(failure.message, privacy: .public)")
        default:
            break
        }
    }
}
