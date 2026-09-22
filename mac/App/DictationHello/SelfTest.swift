import DictationEngine
import Foundation

enum SelfTest {
    static func run(path: String) -> Int32 {
        guard let wav = FileManager.default.contents(atPath: path), let pcm = WAV.pcm(from: wav) else {
            print("selftest: can't read a 16 kHz mono 16-bit WAV at '\(path)'")
            return 2
        }
        let key = ProcessInfo.processInfo.environment["ASSEMBLYAI_API_KEY"] ?? AppIdentity.keychain.read()
        guard let key, !key.isEmpty else {
            print("selftest: no API key (set ASSEMBLYAI_API_KEY or save one in the app)")
            return 2
        }
        let done = DispatchSemaphore(value: 0)
        let status = LockedBox<Int32>(1)
        Task.detached {
            let client = DictationClient(appName: AppIdentity.userAgentName, version: AppIdentity.version)
            client.warm()
            let session = client.makeSession(apiKey: key)
            session.open(config: DictationConfig(llmInstruction: Instruction.build(style: nil)))
            // Stream in 100 ms frames at 10x real time, as the mic would.
            let frame = Wire.bytesPerSecond / 10
            var offset = 0
            while offset < pcm.count {
                session.send(pcm.subdata(in: offset..<min(offset + frame, pcm.count)))
                offset += frame
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            let start = Date()
            do {
                let response = try await session.finish()
                print("verbatim : \(response.text)")
                print("cleaned  : \(response.llmResponse ?? "(nil, llm_error=\(response.llmError ?? "-"))")")
                print("audio    : \(Int(response.audioDurationMs ?? -1)) ms (sent \(pcm.count * 1000 / Wire.bytesPerSecond) ms)")
                print("post-body: \(Int(Date().timeIntervalSince(start) * 1000)) ms  session=\(response.sessionId ?? "-")")
                status.value = response.text.isEmpty ? 1 : 0
            } catch {
                print("selftest failed: \(error.localizedDescription)")
            }
            done.signal()
        }
        done.wait()
        return status.value
    }
}

final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
