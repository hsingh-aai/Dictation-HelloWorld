import Foundation
import os

/// One HTTP request per utterance, opened at press and streamed as the mic produces frames.
public protocol TranscriptionSession: AnyObject, Sendable {
    /// Frames sent before `open` are buffered and flushed right after the config part.
    func send(_ pcm: Data)
    /// Opens the request: config part first (audio-first is a 400), then the buffered frames.
    func open(config: DictationConfig)
    /// Closes the body and waits for the single JSON response.
    func finish() async throws -> DictationResponse
    func cancel()
    var audioBytes: Int { get }
}

public protocol Transcriber: Sendable {
    /// Fire-and-forget `/warm` GET; the transcribe request coalesces onto its connection.
    func warm()
    func makeSession(apiKey: String) -> any TranscriptionSession
}

public enum KeyCheck: Sendable, Equatable {
    case valid
    case invalid(String)
    case unreachable(String)
}

public struct DictationClient: Transcriber {
    let session: URLSession
    let userAgent: String

    public init(appName: String = "DictationHello", version: String = "0.1") {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = Wire.idleTimeout   // idle, resets when bytes move
        configuration.waitsForConnectivity = false
        configuration.httpMaximumConnectionsPerHost = 4
        session = URLSession(configuration: configuration)
        let os = ProcessInfo.processInfo.operatingSystemVersion
        userAgent = "\(appName)/\(version) (macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion))"
    }

    public func warm() {
        var request = URLRequest(url: Wire.warmURL)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        session.dataTask(with: request).resume()
    }

    public func makeSession(apiKey: String) -> any TranscriptionSession {
        StreamingSession(urlSession: session, apiKey: apiKey, userAgent: userAgent)
    }

    /// Only 400/401/403/422 may mean "invalid". 404/405/410 (endpoint moved) and 451 (corporate
    /// proxy) say nothing about the key; reporting them as invalid would block a working key.
    public func validate(apiKey: String) async -> KeyCheck {
        var request = URLRequest(url: Wire.keyCheckURL)
        request.setValue(apiKey, forHTTPHeaderField: "Authorization")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch status {
            case 400, 401, 403, 422: return .invalid(ErrorBody.message(from: data))
            default: return .valid
            }
        } catch {
            return .unreachable(error.localizedDescription)
        }
    }
}

/// Streams a multipart body through a bound stream pair. Thread-safe; all mutable state is
/// behind `lock`, and all writes happen in order on `writer`.
final class StreamingSession: NSObject, TranscriptionSession, URLSessionDataDelegate, @unchecked Sendable {
    private static let log = Logger(subsystem: "com.example.dictationhello", category: "stt")

    private let urlSession: URLSession
    private let apiKey: String
    private let userAgent: String
    private let boundary = "dictation-\(UUID().uuidString)"
    private let writer = DispatchQueue(label: "dictation.body-writer")
    private let input: InputStream
    private let output: OutputStream

    private let lock = NSLock()
    private var opened = false
    private var pending: [Data] = []
    private var bytes = 0
    private var cancelled = false
    private var bodyHandedOut = false
    private var task: URLSessionUploadTask?
    private var status = 0
    private var retryAfter: String?
    private var received = Data()
    private var outcome: Result<DictationResponse, DictationError>?
    private var continuation: CheckedContinuation<DictationResponse, Error>?
    private var finishedAt: DispatchTime?

    init(urlSession: URLSession, apiKey: String, userAgent: String) {
        self.urlSession = urlSession
        self.apiKey = apiKey
        self.userAgent = userAgent
        var input: InputStream?
        var output: OutputStream?
        Stream.getBoundStreams(withBufferSize: 64 * 1024, inputStream: &input, outputStream: &output)
        guard let input, let output else { preconditionFailure("bound stream pair unavailable") }
        self.input = input
        self.output = output
        super.init()
    }

    var audioBytes: Int { lock.withLock { bytes } }

    func send(_ pcm: Data) {
        guard !pcm.isEmpty else { return }
        lock.withLock {
            guard !cancelled else { return }
            bytes += pcm.count
            if opened {
                writer.async { self.write(pcm) }
            } else {
                pending.append(pcm)
            }
        }
    }

    func open(config: DictationConfig) {
        let configJSON = (try? config.jsonData()) ?? Data("{}".utf8)
        var preamble = Data()
        preamble.append("--\(boundary)\r\n")
        preamble.append("Content-Disposition: form-data; name=\"config\"\r\n")
        preamble.append("Content-Type: application/json\r\n\r\n")
        preamble.append(configJSON)
        preamble.append("\r\n--\(boundary)\r\n")
        preamble.append("Content-Disposition: form-data; name=\"audio\"; filename=\"audio.pcm\"\r\n")
        preamble.append("Content-Type: audio/pcm\r\n\r\n")

        var request = URLRequest(url: Wire.transcribeURL)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "Authorization")   // raw key, no Bearer
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let header = preamble
        lock.withLock {
            guard !opened, !cancelled else { return }
            opened = true
            let buffered = pending
            pending = []
            // Enqueued under the lock, so no frame from `send` can overtake the config part.
            writer.async {
                self.output.open()
                self.write(header)
                buffered.forEach(self.write)
            }
            let task = urlSession.uploadTask(withStreamedRequest: request)
            task.delegate = self
            self.task = task
            task.resume()
        }
    }

    func finish() async throws -> DictationResponse {
        let (isOpen, sent) = lock.withLock { (opened, bytes) }
        guard isOpen else { throw DictationError.network("request was never opened") }
        // Enforced where the body closes too: on a fast link the producer can close the request
        // before a pipeline-level guard runs, and below the floor the API bills an empty 200.
        guard sent * 1000 >= Wire.minAudioMs * Wire.bytesPerSecond else {
            cancel()
            throw DictationError.tooShort
        }
        writer.async {
            self.lock.withLock { self.finishedAt = .now() }
            self.write(Data("\r\n--\(self.boundary)--\r\n".utf8))
            self.output.close()
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock {
                    if let outcome {
                        continuation.resume(with: outcome.mapError { $0 as Error })
                    } else {
                        self.continuation = continuation
                    }
                }
            }
        } onCancel: {
            self.cancel()
        }
    }

    func cancel() {
        let task = lock.withLock { () -> URLSessionUploadTask? in
            cancelled = true
            return self.task
        }
        task?.cancel()
        complete(.failure(.cancelled))
        writer.async { self.output.close() }
    }

    // MARK: Body writing

    private func write(_ data: Data) {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                if lock.withLock({ cancelled || outcome != nil }) { return }
                switch output.streamStatus {
                case .error, .closed, .notOpen: return
                default: break
                }
                guard output.hasSpaceAvailable else { usleep(1_000); continue }
                let written = output.write(base + offset, maxLength: raw.count - offset)
                if written < 0 { return }
                if written == 0 { usleep(1_000); continue }
                offset += written
            }
        }
    }

    // MARK: URLSession task delegate

    /// Hands the body over once. A second request is the client trying to replay a streamed body,
    /// which would upload a blank transcript — refuse it.
    func urlSession(_ session: URLSession, task: URLSessionTask, needNewBodyStream completionHandler: @escaping @Sendable (InputStream?) -> Void) {
        let first = lock.withLock { () -> Bool in
            defer { bodyHandedOut = true }
            return !bodyHandedOut
        }
        completionHandler(first ? input : nil)
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        if let http = response as? HTTPURLResponse {
            lock.withLock {
                status = http.statusCode
                retryAfter = http.value(forHTTPHeaderField: "Retry-After")
            }
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.withLock { received.append(data) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let (status, data, retryAfter, sent, finishedAt) = lock.withLock {
            (self.status, received, self.retryAfter, bytes, self.finishedAt)
        }
        if let error {
            let nsError = error as NSError
            complete(.failure(nsError.code == NSURLErrorCancelled ? .cancelled : .network(error.localizedDescription)))
            return
        }
        guard (200..<300).contains(status) else {
            complete(.failure(ErrorBody.error(status: status, data: data, retryAfter: retryAfter)))
            return
        }
        guard let response = try? JSONDecoder().decode(DictationResponse.self, from: data) else {
            complete(.failure(.server(status: status, message: "unreadable response: \(ErrorBody.message(from: data))")))
            return
        }
        let sentMs = Double(sent) * 1000 / Double(Wire.bytesPerSecond)
        let postSpeechMs = finishedAt.map { Double(DispatchTime.now().uptimeNanoseconds - $0.uptimeNanoseconds) / 1e6 } ?? -1
        Self.log.info("""
            session=\(response.sessionId ?? "-", privacy: .public) audioMs=\(Int(sentMs)) \
            serverAudioMs=\(Int(response.audioDurationMs ?? -1)) postSpeechMs=\(Int(postSpeechMs)) \
            llmError=\(response.llmError ?? "-", privacy: .public)
            """)
        // A disagreement means a truncated upload, which no other signal distinguishes from a
        // user who stopped talking early.
        if let server = response.audioDurationMs, abs(server - sentMs) > 250 {
            Self.log.error("audio length mismatch: sent \(Int(sentMs)) ms, server saw \(Int(server)) ms")
        }
        complete(.success(response))
    }

    private func complete(_ result: Result<DictationResponse, DictationError>) {
        let continuation = lock.withLock { () -> CheckedContinuation<DictationResponse, Error>? in
            guard outcome == nil else { return nil }
            outcome = result
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(with: result.mapError { $0 as Error })
    }
}

private extension Data {
    mutating func append(_ string: String) { append(Data(string.utf8)) }
}

/// Reads the PCM payload out of a 16 kHz mono 16-bit WAV. Used by the headless self-test.
public enum WAV {
    public static func pcm(from input: Data) -> Data? {
        let data = Data(input)   // zero-based indices
        guard data.count > 12, data.prefix(4) == Data("RIFF".utf8), data[8..<12] == Data("WAVE".utf8) else { return nil }
        var offset = 12
        while offset + 8 <= data.count {
            let id = data[offset..<offset + 4]
            let size = data[offset + 4..<offset + 8].enumerated().reduce(0) { $0 | Int($1.element) << (8 * $1.offset) }
            let body = offset + 8
            if id == Data("data".utf8) { return Data(data[body..<min(body + size, data.count)]) }
            offset = body + size + (size & 1)
        }
        return nil
    }
}
