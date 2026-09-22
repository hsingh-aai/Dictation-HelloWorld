@testable import DictationEngine
import Testing

@Suite struct SnippetTests {
    let snippets = [
        Snippet(trigger: "Personal Link Tree", expansion: "https://linktr.ee/example"),
        Snippet(trigger: "personal cal.com", expansion: "https://cal.com/example"),
        Snippet(trigger: "Personal Profession", expansion: "Content Creator (YouTube)"),
        Snippet(trigger: "personal link", expansion: "SHORTER"),
    ]

    @Test func wholeUtteranceBecomesTheBareExpansion() {
        #expect(SnippetExpander.expand("Personal link tree.", snippets: snippets) == "https://linktr.ee/example")
        #expect(SnippetExpander.expand("Personal profession.", snippets: snippets) == "Content Creator (YouTube)")
    }

    @Test func spacingAndSpokenDotAreIgnored() {
        #expect(SnippetExpander.expand("personal linktree", snippets: snippets) == "https://linktr.ee/example")
        #expect(SnippetExpander.expand("Personal cal dot com.", snippets: snippets) == "https://cal.com/example")
        #expect(SnippetExpander.expand("Personal cal.com", snippets: snippets) == "https://cal.com/example")
    }

    @Test func midSentenceKeepsTheRest() {
        #expect(SnippetExpander.expand("Book time at personal cal dot com, thanks.", snippets: snippets)
            == "Book time at https://cal.com/example, thanks.")
    }

    @Test func longestTriggerWins() {
        #expect(SnippetExpander.expand("personal link tree", snippets: snippets) == "https://linktr.ee/example")
        #expect(SnippetExpander.expand("my personal link please", snippets: snippets) == "my SHORTER please")
    }

    @Test func noMatchLeavesTextAlone() {
        #expect(SnippetExpander.expand("A personal matter.", snippets: snippets) == "A personal matter.")
        #expect(SnippetExpander.expand("Hello.", snippets: []) == "Hello.")
    }
}
