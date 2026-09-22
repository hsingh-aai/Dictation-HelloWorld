import Foundation

/// A spoken shortcut: say the trigger, get the expansion pasted instead.
public struct Snippet: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var trigger: String
    public var expansion: String

    public init(id: UUID = UUID(), trigger: String, expansion: String) {
        self.id = id
        self.trigger = trigger
        self.expansion = expansion
    }
}

/// Replaces spoken triggers in a transcript, applied after the cleaned/verbatim text is picked.
///
/// Matching ignores case, punctuation, spacing and the spoken word "dot", so "Personal link tree."
/// matches "personal Linktree" and "personal cal dot com" matches "personal cal.com". When the
/// utterance is nothing but the trigger, the result is the bare expansion — no trailing period
/// the rewrite added.
public enum SnippetExpander {
    public static func expand(_ text: String, snippets: [Snippet]) -> String {
        let candidates = snippets
            .map { (key: normalized($0.trigger), expansion: $0.expansion) }
            .filter { !$0.key.isEmpty && !$0.expansion.isEmpty }
            .sorted { $0.key.count > $1.key.count }   // longest first: "link tree" beats "link"
        guard !candidates.isEmpty else { return text }

        let tokens = words(in: text)
        var result = ""
        var cursor = text.startIndex
        var index = 0
        var replaced = false
        while index < tokens.count {
            guard let (end, expansion) = match(at: index, tokens: tokens, candidates: candidates) else {
                index += 1
                continue
            }
            result += text[cursor..<tokens[index].range.lowerBound]
            result += expansion
            cursor = tokens[end].range.upperBound
            index = end + 1
            replaced = true
        }
        guard replaced else { return text }
        result += text[cursor...]

        // The whole utterance was one shortcut: drop the punctuation the rewrite wrapped around it.
        let expansions = candidates.map(\.expansion)
        let trimmed = result.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
        if let only = expansions.first(where: { trimmed == $0.trimmingCharacters(in: .punctuationCharacters) }) {
            return only
        }
        return result
    }

    /// Trigger phrases worth biasing recognition toward, for `keyterms_prompt`.
    public static func keyterms(for snippets: [Snippet]) -> [String] {
        snippets.map { $0.trigger.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    // MARK: Matching

    private struct Word {
        let range: Range<String.Index>
        let key: String
    }

    private static func match(
        at start: Int, tokens: [Word], candidates: [(key: String, expansion: String)]
    ) -> (end: Int, expansion: String)? {
        guard tokens[start].key != "dot" else { return nil }
        for candidate in candidates {
            var joined = ""
            var end = start
            while end < tokens.count {
                if end == start || tokens[end].key != "dot" { joined += tokens[end].key }
                if joined.count >= candidate.key.count { break }
                end += 1
            }
            if joined == candidate.key, end < tokens.count { return (end, candidate.expansion) }
        }
        return nil
    }

    private static func words(in text: String) -> [Word] {
        var result: [Word] = []
        var start: String.Index?
        var index = text.startIndex
        while index < text.endIndex {
            let isWordCharacter = text[index].isLetter || text[index].isNumber
            if isWordCharacter, start == nil { start = index }
            if !isWordCharacter, let begin = start {
                result.append(Word(range: begin..<index, key: text[begin..<index].lowercased()))
                start = nil
            }
            index = text.index(after: index)
        }
        if let begin = start {
            result.append(Word(range: begin..<text.endIndex, key: text[begin...].lowercased()))
        }
        return result
    }

    static func normalized(_ trigger: String) -> String {
        words(in: trigger).map(\.key).filter { $0 != "dot" }.joined()
    }
}
