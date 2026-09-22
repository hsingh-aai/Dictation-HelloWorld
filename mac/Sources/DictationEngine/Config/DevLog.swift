import Foundation

/// Developer mode: completed dictations to `dictations.jsonl`, failures to `errors.jsonl`.
/// Failures carry the focused app/window/field but **no** prior text and no prompt — the
/// surrounding text explains nothing about a failure and is the most sensitive part.
public final class DevLog: Sendable {
    public let directory: URL
    private let enabled: @Sendable () -> Bool
    private let queue = DispatchQueue(label: "dictation.devlog")

    public init(appName: String, enabled: @escaping @Sendable () -> Bool) {
        directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/\(appName)", isDirectory: true)
        self.enabled = enabled
    }

    public func dictation(_ record: DictationRecord, context: FocusSnapshot?) {
        var entry: [String: Any] = [
            "date": ISO8601DateFormatter().string(from: record.date),
            "text": record.text,
            "verbatim": record.verbatim,
            "style": record.styleName,
        ]
        if let context {
            entry["app"] = context.appName ?? NSNull()
            entry["bundleID"] = context.bundleID ?? NSNull()
            entry["window"] = context.windowTitle ?? NSNull()
            entry["field"] = context.fieldRole ?? NSNull()
            entry["priorText"] = context.priorText ?? NSNull()
        }
        append(entry, to: "dictations.jsonl")
    }

    public func failure(_ failure: DictationFailure, context: FocusSnapshot?) {
        var entry: [String: Any] = [
            "date": ISO8601DateFormatter().string(from: Date()),
            "error": failure.name,
            "description": failure.message,
        ]
        if let context {
            entry["app"] = context.appName ?? NSNull()
            entry["window"] = context.windowTitle ?? NSNull()
            entry["field"] = context.fieldRole ?? NSNull()
        }
        append(entry, to: "errors.jsonl")
    }

    public func deleteAll() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func append(_ entry: [String: Any], to name: String) {
        guard enabled(), let json = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) else { return }
        let line = json + Data([0x0A])
        let url = directory.appendingPathComponent(name)
        let directory = self.directory
        queue.async {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: line)
            } else {
                try? line.write(to: url)
            }
        }
    }
}
