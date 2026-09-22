@testable import DictationEngine
import Foundation
import Testing

@Suite struct PromptFitterTests {
    @Test func emptyOmitsTheField() {
        #expect(PromptFitter.fit(history: [], priorText: nil) == nil)
        #expect(PromptFitter.fit(history: ["  "], priorText: "") == nil)
    }

    @Test func oldestFirstPriorTextLast() {
        #expect(PromptFitter.fit(history: ["one", "two"], priorText: "before cursor") == "one\ntwo\nbefore cursor")
    }

    @Test func dropsOldestWholeAndChargesNewlines() {
        // "bb\ncc" is 5 scalars; adding "aa\n" would make 8.
        #expect(PromptFitter.fit(history: ["aa", "bb", "cc"], priorText: nil, cap: 5) == "bb\ncc")
        #expect(PromptFitter.fit(history: ["aa", "bb", "cc"], priorText: nil, cap: 4) == "cc")
    }

    @Test func keepsAContiguousNewestRun() {
        // "tiny" would fit after "huge" is skipped, but that would break contiguity.
        #expect(PromptFitter.fit(history: ["tiny", String(repeating: "x", count: 50), "new"], priorText: nil, cap: 56) ==
            String(repeating: "x", count: 50) + "\nnew")
    }

    @Test func singleOversizedEntryIsClippedToItsTail() {
        #expect(PromptFitter.fit(history: [], priorText: "abcdefghij", cap: 4) == "ghij")
    }

    @Test func capIsCountedInScalars() {
        let family = "👨‍👩‍👧‍👦"   // 1 grapheme, 7 scalars
        let prompt = String(repeating: family, count: 820)   // 5740 scalars: over the cap
        let fitted = PromptFitter.fit(history: [], priorText: prompt)
        #expect(fitted.map { $0.unicodeScalars.count } == 4096)
        let accented = String(repeating: "é", count: 4096)   // 4096 scalars, 8192 bytes: accepted
        #expect(PromptFitter.fit(history: [], priorText: accented) == accented)
    }
}

@Suite struct KeytermFitterTests {
    @Test func byteCapReachedIndependently() {
        let terms = (0..<30).map { String(format: "%03d", $0) + String(repeating: "k", count: 97) }
        #expect(KeytermFitter.fit(terms).count == 20)   // 20 × 100 = 2000 ≤ 2048 < 2100
    }

    @Test func countCapReachedIndependently() {
        let terms = (0..<150).map { "t\($0)" }   // ~500 bytes: clears the byte cap
        #expect(KeytermFitter.fit(terms).count == 100)
    }

    @Test func trimsDedupesAndKeepsOrder() {
        #expect(KeytermFitter.fit([" Blurt ", "AssemblyAI", "Blurt", ""]) == ["Blurt", "AssemblyAI"])
        #expect(KeytermFitter.parse("a, b\nc,,") == ["a", "b", "c"])
    }
}

@Suite struct ConfigEncodingTests {
    @Test func emptiesAreAbsentNotEmpty() throws {
        let object = try JSONSerialization.jsonObject(with: DictationConfig(sttPrompt: "", keyterms: []).jsonData()) as? [String: Any]
        #expect(Set(object?.keys ?? [:].keys) == ["sample_rate", "channels"])
    }

    @Test func onlyDocumentedFieldsEverGoOut() throws {
        let config = DictationConfig(sttPrompt: "hi", keyterms: ["x"], llmInstruction: Instruction.build(style: "lowercase"))
        let object = try #require(try JSONSerialization.jsonObject(with: config.jsonData()) as? [String: Any])
        #expect(Set(object.keys) == ["sample_rate", "channels", "stt_prompt", "keyterms_prompt", "llm_instruction"])
        for banned in ["prompt", "keyterms", "word_boost", "language_code", "language_codes", "llm", "conversation_context"] {
            #expect(object[banned] == nil)
        }
        #expect(object["stt_prompt"] is String)
        #expect(object["keyterms_prompt"] is [String])
    }
}

@Suite struct InstructionTests {
    @Test func baseFitsAndStyleIsBudgeted() {
        #expect(Instruction.build(style: nil) == Instruction.base)
        #expect(Instruction.build(style: "  ") == Instruction.base)
        let long = Instruction.build(style: String(repeating: "é", count: 5000))
        #expect(long.utf8.count <= Wire.llmInstructionCapBytes)
        #expect(long.hasPrefix(Instruction.base + Instruction.stylePreamble))
        #expect(Instruction.styleBudgetBytes > 200)
    }
}

@Suite struct ResponseTests {
    @Test func decodesWithUndocumentedExtras() throws {
        let json = #"{"text":"um hi","llm_response":"Hi.","words":[{"text":"um","confidence":0.4}],"confidence":0.9,"auth_time_ms":3,"audio_duration_ms":1200,"request_time_ms":400.5}"#
        let response = try JSONDecoder().decode(DictationResponse.self, from: Data(json.utf8))
        #expect(response.transcript(enhanced: true) == "Hi.")
        #expect(response.transcript(enhanced: false) == "um hi")
        #expect(response.audioDurationMs == 1200)
    }

    @Test func blankOrFailedRewriteFallsBackToText() throws {
        let failed = try JSONDecoder().decode(DictationResponse.self, from: Data(#"{"text":"hello","llm_response":null,"llm_error":"timeout"}"#.utf8))
        #expect(failed.transcript(enhanced: true) == "hello")
        let blank = DictationResponse(text: "hello", llmResponse: "  ")
        #expect(blank.transcript(enhanced: true) == "hello")
    }

    @Test func bothErrorShapesAndRawFallback() {
        #expect(ErrorBody.message(from: Data(#"{"error":"bad config","error_code":"invalid"}"#.utf8)) == "bad config")
        #expect(ErrorBody.message(from: Data(#"{"status":404,"title":"Not Found","detail":"Invalid API key"}"#.utf8)) == "Invalid API key")
        #expect(ErrorBody.message(from: Data(#"{"detail":[{"loc":["x"]}]}"#.utf8)).hasPrefix("{\"detail\""))
        #expect(ErrorBody.message(from: Data("<html>502 Bad Gateway</html>".utf8)) == "<html>502 Bad Gateway</html>")
        #expect(ErrorBody.message(from: Data(String(repeating: "x", count: 900).utf8)).count == 501)
    }

    @Test func statusClassification() {
        #expect(ErrorBody.error(status: 404, data: Data(), retryAfter: nil).isSetup)
        #expect(ErrorBody.error(status: 401, data: Data(), retryAfter: nil).isSetup)
        #expect(ErrorBody.error(status: 429, data: Data(), retryAfter: "3") == .rateLimited(retryAfter: 3, message: "empty response"))
        #expect(!ErrorBody.error(status: 400, data: Data(), retryAfter: nil).isSetup)
    }

    @Test func wavPayloadExtraction() {
        var wav = Data("RIFF".utf8) + Data([0, 0, 0, 0]) + Data("WAVE".utf8)
        wav += Data("fmt ".utf8) + Data([2, 0, 0, 0, 9, 9])
        wav += Data("data".utf8) + Data([3, 0, 0, 0, 1, 2, 3])
        #expect(WAV.pcm(from: wav) == Data([1, 2, 3]))
    }
}
