import Testing
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
}
