import Foundation

/// Every wire and timing constant in one place. Before changing a wire constant, re-measure it
/// against the live route and record the date and observed error string next to it.
public enum Wire {
    public static let transcribeURL = url("https://dictation.assemblyai.com/v1/transcribe/live")
    /// Unauthenticated no-op, answers `{"warm":"toasty"}`. Unversioned, at the host root.
    public static let warmURL = url("https://dictation.assemblyai.com/warm")
    /// Key check lives on the regular API host, not the dictation host.
    public static let keyCheckURL = url("https://api.assemblyai.com/v2/transcript?limit=1")

    public static let sampleRate = 16_000
    public static let channels = 1
    public static let bytesPerSecond = sampleRate * channels * 2

    /// Below ~80–100 ms the route answers 200 with an empty transcript — guard client-side.
    public static let minAudioMs = 100
    /// 120 s is the server's exact cap; auto-release a little before it.
    public static let maxAudioSeconds: Double = 120
    public static let autoReleaseSeconds: Double = 115

    /// `stt_prompt`: 4096 Unicode scalars, API-enforced, rejects rather than trims.
    /// Measured: 4096 `é` accepted, 820 family emoji (4100 scalars) rejected.
    public static let sttPromptCapScalars = 4096
    /// `keyterms_prompt`: 2048 chars summed (counted as UTF-8 bytes) AND 100 terms — independent.
    public static let keytermsCapBytes = 2048
    public static let keytermsMaxCount = 100
    /// `llm_instruction`: 2048 chars (counted as UTF-8 bytes). A different field, a different number.
    public static let llmInstructionCapBytes = 2048

    /// Idle timeout: resets whenever bytes move, so it spans the recording.
    public static let idleTimeout: TimeInterval = 90

    private static func url(_ string: StaticString) -> URL {
        guard let url = URL(string: "\(string)") else { preconditionFailure("bad URL \(string)") }
        return url
    }
}

public enum Timing {
    public static let holdThreshold: TimeInterval = 1.0
    public static let contextReadBudget: TimeInterval = 0.5
    public static let pasteSettle: TimeInterval = 0.4
    public static let activationWait: TimeInterval = 0.3
    public static let livenessWired: TimeInterval = 0.3
    public static let livenessUnknown: TimeInterval = 1.0
    public static let livenessBluetooth: TimeInterval = 2.5
    public static let historyCap = 100
    public static let recentShown = 3
}
