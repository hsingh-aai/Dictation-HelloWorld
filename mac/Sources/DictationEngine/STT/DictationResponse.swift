import Foundation

/// Everything but `text` is optional — even fields the reference marks required — so a field the
/// service stops sending can never turn into a failed dictation. Undocumented extras are ignored.
public struct DictationResponse: Decodable, Sendable, Equatable {
    public let text: String
    public let llmResponse: String?
    /// "timeout" | "error", set only when the rewrite failed. A logged degradation, never an error.
    public let llmError: String?
    public let sessionId: String?
    public let audioDurationMs: Double?
    public let requestTimeMs: Double?
    public let syncTimeMs: Double?

    enum CodingKeys: String, CodingKey {
        case text
        case llmResponse = "llm_response"
        case llmError = "llm_error"
        case sessionId = "session_id"
        case audioDurationMs = "audio_duration_ms"
        case requestTimeMs = "request_time_ms"
        case syncTimeMs = "sync_time_ms"
    }

    public init(
        text: String, llmResponse: String? = nil, llmError: String? = nil, sessionId: String? = nil,
        audioDurationMs: Double? = nil, requestTimeMs: Double? = nil, syncTimeMs: Double? = nil
    ) {
        self.text = text
        self.llmResponse = llmResponse
        self.llmError = llmError
        self.sessionId = sessionId
        self.audioDurationMs = audioDurationMs
        self.requestTimeMs = requestTimeMs
        self.syncTimeMs = syncTimeMs
    }

    /// The rewrite can't be declined on the wire, so the "cleanup" switch is applied here, to the
    /// response it's about. Blank counts as unusable alongside null.
    public func transcript(enhanced: Bool) -> String {
        if enhanced, let rewrite = llmResponse, !rewrite.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return rewrite
        }
        return text
    }
}

public enum DictationError: Error, Sendable, Equatable, LocalizedError {
    /// Unfinished setup — routes to the settings UI rather than an error flash.
    case missingAPIKey
    case keyRejected(String)
    case rateLimited(retryAfter: TimeInterval?, message: String)
    case server(status: Int, message: String)
    case network(String)
    case microphone(String)
    case tooShort
    case cancelled

    public var isSetup: Bool {
        switch self {
        case .missingAPIKey, .keyRejected: true
        default: false
        }
    }

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey: "Add your AssemblyAI API key to start dictating."
        case .keyRejected(let message): "API key rejected: \(message)"
        case .rateLimited(let retry, let message):
            retry.map { "Rate limited — retry in \(Int($0.rounded(.up))) s. \(message)" } ?? "Rate limited. \(message)"
        case .server(let status, let message): "Dictation failed (\(status)): \(message)"
        case .network(let message): "Network error: \(message)"
        case .microphone(let message): "Microphone: \(message)"
        case .tooShort: "Recording too short."
        case .cancelled: "Cancelled."
        }
    }

    /// Stable name for the developer-mode error log.
    public var name: String {
        switch self {
        case .missingAPIKey: "missingAPIKey"
        case .keyRejected: "keyRejected"
        case .rateLimited: "rateLimited"
        case .server: "server"
        case .network: "network"
        case .microphone: "microphone"
        case .tooShort: "tooShort"
        case .cancelled: "cancelled"
        }
    }
}

public enum ErrorBody {
    /// Reads `error`, then `detail`, then falls back to the raw body (trimmed, capped ~500 chars),
    /// which turns a proxy's HTML 502 or a captive portal into something diagnosable.
    /// A non-string `detail` (FastAPI validation array) falls through to the raw body.
    public static func message(from data: Data) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let error = object["error"] as? String, !error.isEmpty { return error }
            if let detail = object["detail"] as? String, !detail.isEmpty { return detail }
        }
        let raw = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty { return "empty response" }
        return raw.count > 500 ? String(raw.prefix(500)) + "…" : raw
    }

    public static func error(status: Int, data: Data, retryAfter: String?) -> DictationError {
        let message = message(from: data)
        switch status {
        // The reference says an invalid key is 404; other clients observe 401. Treat them alike.
        case 401, 403, 404: return .keyRejected(message)
        case 429: return .rateLimited(retryAfter: retryAfter.flatMap(TimeInterval.init), message: message)
        default: return .server(status: status, message: message)
        }
    }
}
