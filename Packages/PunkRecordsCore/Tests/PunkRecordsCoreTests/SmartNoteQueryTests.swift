import Foundation
import Testing
@testable import PunkRecordsCore

@Suite("SmartNoteQuery AST")
struct SmartNoteQueryTests {

    private func roundTrip(_ query: SmartNoteQuery) throws -> SmartNoteQuery {
        try SmartNoteQuery.fromJSON(query.toJSON())
    }

    @Test("JSON round-trips a comparison leaf")
    func comparisonRoundTrip() throws {
        let query = SmartNoteQuery(root: .comparison(
            SmartNoteComparison(.tag, .contains, .text("web"))
        ))
        #expect(try roundTrip(query) == query)
    }

    @Test("JSON round-trips nested AND / OR / NOT with mixed value kinds")
    func nestedRoundTrip() throws {
        let query = SmartNoteQuery(root: .and([
            .or([
                .comparison(SmartNoteComparison(.status, .equalTo, .status(.doing))),
                .comparison(SmartNoteComparison(.status, .equalTo, .status(.todo)))
            ]),
            .not(.comparison(SmartNoteComparison(.path, .contains, .text("/")))),
            .comparison(SmartNoteComparison(.scheduled, .lessThanOrEqualTo, .date(.today))),
            .comparison(SmartNoteComparison(.tag, .notExists, .empty))
        ]))
        #expect(try roundTrip(query) == query)
    }

    @Test("JSON round-trips every date anchor kind")
    func dateAnchorsRoundTrip() throws {
        let absolute = Date(timeIntervalSince1970: 1_800_000_000)
        let anchors: [SmartNoteDate] = [.today, .startOfWeek, .endOfWeek, .daysFromToday(-7), .absolute(absolute)]
        for anchor in anchors {
            let query = SmartNoteQuery(root: .comparison(
                SmartNoteComparison(.due, .greaterThanOrEqualTo, .date(anchor))
            ))
            #expect(try roundTrip(query) == query)
        }
    }

    @Test("JSON round-trips a frontmatter-key (property) field")
    func propertyFieldRoundTrip() throws {
        let query = SmartNoteQuery(root: .comparison(
            SmartNoteComparison(.property(key: "owner"), .equalTo, .text("Mark"))
        ))
        #expect(try roundTrip(query) == query)
        // The field token preserves the key.
        #expect(SmartNoteField.property(key: "owner").token == "property:owner")
        #expect(SmartNoteField.parse(token: "property:owner") == .property(key: "owner"))
    }

    @Test("fromJSON rejects an unknown/future schema version")
    func rejectsUnknownVersion() throws {
        var query = SmartNoteQuery(root: .comparison(SmartNoteComparison(.tag, .exists, .empty)))
        query.version = SmartNoteQuery.currentVersion + 1
        let json = try query.toJSON()
        #expect(throws: SmartNoteQueryError.unsupportedVersion(SmartNoteQuery.currentVersion + 1)) {
            _ = try SmartNoteQuery.fromJSON(json)
        }
    }

    @Test("usesPerHeadingFields detects status/scheduled/due anywhere in the tree")
    func perHeadingDetection() {
        let docLevel = SmartNoteQuery(root: .comparison(SmartNoteComparison(.tag, .contains, .text("x"))))
        #expect(docLevel.usesPerHeadingFields == false)

        let perHeading = SmartNoteQuery(root: .and([
            .comparison(SmartNoteComparison(.tag, .contains, .text("x"))),
            .not(.comparison(SmartNoteComparison(.status, .equalTo, .status(.done))))
        ]))
        #expect(perHeading.usesPerHeadingFields == true)
    }

    @Test("Unknown field token fails to decode")
    func unknownFieldToken() {
        #expect(SmartNoteField.parse(token: "bogus") == nil)
    }
}
