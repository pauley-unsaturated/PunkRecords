import Testing
import Foundation
@testable import PunkRecordsInfra

@Suite("SearchQueryParser Tests")
struct SearchQueryParserTests {

    @Test("Simple terms are passed through")
    func simpleTerms() {
        let parsed = SearchQueryParser.parse("swift concurrency")
        #expect(parsed.terms == ["swift", "concurrency"])
        #expect(parsed.ftsQuery.contains("swift"))
        #expect(parsed.ftsQuery.contains("concurrency"))
    }

    @Test("Quoted phrases are preserved")
    func quotedPhrases() {
        let parsed = SearchQueryParser.parse(#""async await" patterns"#)
        #expect(parsed.phrases == ["async await"])
        #expect(parsed.terms == ["patterns"])
        #expect(parsed.ftsQuery.contains("\"async await\""))
    }

    @Test("Excluded terms use NOT prefix")
    func excludedTerms() {
        let parsed = SearchQueryParser.parse("swift -objc")
        #expect(parsed.terms == ["swift"])
        #expect(parsed.excludedTerms == ["objc"])
        #expect(parsed.ftsQuery.contains("NOT objc"))
    }

    @Test("tag: prefix sets tagFilter")
    func tagFilter() {
        let parsed = SearchQueryParser.parse("concurrency tag:swift")
        #expect(parsed.tagFilter == "swift")
        #expect(parsed.terms == ["concurrency"])
    }

    @Test("title: prefix sets titleFilter")
    func titleFilter() {
        let parsed = SearchQueryParser.parse("title:MyNote content")
        #expect(parsed.titleFilter == "MyNote")
        #expect(parsed.terms == ["content"])
    }

    @Test("Empty query produces empty ftsQuery")
    func emptyQuery() {
        let parsed = SearchQueryParser.parse("")
        #expect(parsed.ftsQuery.isEmpty)
    }

    @Test("FTS special characters are sanitized from terms")
    func specialCharsSanitized() {
        let parsed = SearchQueryParser.parse("what? why* how()")
        let fts = parsed.ftsQuery
        #expect(!fts.contains("?"))
        #expect(!fts.contains("*"))
        #expect(!fts.contains("("))
        #expect(!fts.contains(")"))
    }

    @Test("FTS special characters are sanitized from phrases")
    func specialCharsSanitizedInPhrases() {
        let parsed = SearchQueryParser.parse(#""what's the point?""#)
        let fts = parsed.ftsQuery
        #expect(!fts.contains("?"))
    }

    @Test("Mixed query with all features")
    func mixedQuery() {
        let parsed = SearchQueryParser.parse(#""exact match" swift -legacy tag:concurrency title:Guide"#)
        #expect(parsed.phrases == ["exact match"])
        #expect(parsed.terms == ["swift"])
        #expect(parsed.excludedTerms == ["legacy"])
        #expect(parsed.tagFilter == "concurrency")
        #expect(parsed.titleFilter == "Guide")
    }

    @Test("Multiple excluded terms")
    func multipleExcluded() {
        let parsed = SearchQueryParser.parse("swift -objc -legacy -deprecated")
        #expect(parsed.excludedTerms.count == 3)
        #expect(parsed.terms == ["swift"])
    }

    // MARK: - Regression tests for LLM-generated queries with punctuation
    //
    // Context: when the agent loop's `vault_search` tool receives a query
    // containing a file path, comma-separated terms, or other punctuation,
    // the old tokenizer left the punctuation attached and FTS5 threw a
    // `syntax error near ","` (or similar) error. The fix splits on
    // non-word boundaries so punctuation becomes a delimiter, not a token.

    @Test("File path with slashes and periods splits into clean words")
    func filePathQuery() {
        let parsed = SearchQueryParser.parse("/Users/markpauley/Programs/Flatline/KNOWLEDGE-BASE.md")
        #expect(parsed.terms.contains("KNOWLEDGE"))
        #expect(parsed.terms.contains("BASE"))
        #expect(parsed.terms.contains("md"))
        // No punctuation should survive to the FTS query
        let fts = parsed.ftsQuery
        #expect(!fts.contains("/"))
        #expect(!fts.contains("."))
    }

    @Test("Comma-separated query does not produce FTS5 syntax error")
    func commaSeparatedQuery() {
        // This is the exact shape that triggered the reported bug.
        let parsed = SearchQueryParser.parse("link, right")
        #expect(parsed.terms == ["link", "right"])
        let fts = parsed.ftsQuery
        #expect(!fts.contains(","))
    }

    @Test("Question marks and trailing punctuation are stripped")
    func trailingPunctuation() {
        let parsed = SearchQueryParser.parse("What is actor reentrancy?")
        #expect(parsed.terms.contains("What"))
        #expect(parsed.terms.contains("reentrancy"))
        #expect(!parsed.ftsQuery.contains("?"))
    }

    @Test("Semicolons and colons outside tag:/title: prefixes are treated as separators")
    func semicolonsAndColons() {
        let parsed = SearchQueryParser.parse("foo;bar baz:qux")
        // Each becomes its own word (`:` outside a recognised prefix is a separator)
        #expect(parsed.terms.contains("foo"))
        #expect(parsed.terms.contains("bar"))
        #expect(parsed.terms.contains("baz"))
        #expect(parsed.terms.contains("qux"))
    }

    @Test("Excluded term with attached punctuation still excludes cleanly")
    func excludedWithPunctuation() {
        let parsed = SearchQueryParser.parse("swift -objc,legacy")
        // The comma between objc and legacy is a word boundary, both get excluded
        #expect(parsed.terms == ["swift"])
        #expect(parsed.excludedTerms.contains("objc"))
        #expect(parsed.excludedTerms.contains("legacy"))
    }

    @Test("ftsQuery output contains only FTS-safe characters")
    func ftsQueryIsAlwaysSafe() {
        // Throw a mix of pathological input at the parser; the emitted query
        // must only contain letters, digits, underscores, spaces, quotes, and "NOT".
        let messyInput = "/path/to/file.md, 'quote'; what?! tag:swift-lang"
        let parsed = SearchQueryParser.parse(messyInput)
        let fts = parsed.ftsQuery
        let unsafe = CharacterSet(charactersIn: "/,.;'?!&|<>@#$%^*()[]{}")
        for scalar in fts.unicodeScalars {
            #expect(!unsafe.contains(scalar),
                    "Unsafe character '\(scalar)' in ftsQuery: \(fts)")
        }
    }
}
