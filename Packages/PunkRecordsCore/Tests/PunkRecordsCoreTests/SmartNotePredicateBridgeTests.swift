import Foundation
import Testing
@testable import PunkRecordsCore

@Suite("SmartNotePredicateBridge (NSPredicate round-trip)")
struct SmartNotePredicateBridgeTests {

    /// AST → NSPredicate → AST must reproduce the original for every supported
    /// field/operator/value.
    private func assertRoundTrip(_ comparison: SmartNoteComparison, _ line: Int = #line) throws {
        let query = SmartNoteQuery(root: .comparison(comparison))
        let predicate = SmartNotePredicateBridge.makePredicate(query)
        let recovered = try SmartNotePredicateBridge.makeQuery(from: predicate)
        #expect(recovered == query, "round-trip failed for \(comparison) (line \(line))")
    }

    @Test("Tag operators round-trip")
    func tagOperators() throws {
        try assertRoundTrip(SmartNoteComparison(.tag, .contains, .text("web")))
        try assertRoundTrip(SmartNoteComparison(.tag, .equalTo, .text("swift")))
        try assertRoundTrip(SmartNoteComparison(.tag, .notEqualTo, .text("swift")))
        try assertRoundTrip(SmartNoteComparison(.tag, .beginsWith, .text("w")))
        try assertRoundTrip(SmartNoteComparison(.tag, .exists, .empty))
        try assertRoundTrip(SmartNoteComparison(.tag, .notExists, .empty))
    }

    @Test("Status operators round-trip")
    func statusOperators() throws {
        for status in PropsStatus.allCases {
            try assertRoundTrip(SmartNoteComparison(.status, .equalTo, .status(status)))
            try assertRoundTrip(SmartNoteComparison(.status, .notEqualTo, .status(status)))
        }
        try assertRoundTrip(SmartNoteComparison(.status, .exists, .empty))
        try assertRoundTrip(SmartNoteComparison(.status, .notExists, .empty))
    }

    @Test("Date fields round-trip with relative and absolute anchors")
    func dateFields() throws {
        let absolute = Date(timeIntervalSince1970: 1_800_000_000)
        let fields: [SmartNoteField] = [.scheduled, .due, .created, .modified]
        for field in fields {
            try assertRoundTrip(SmartNoteComparison(field, .lessThanOrEqualTo, .date(.today)))
            try assertRoundTrip(SmartNoteComparison(field, .greaterThanOrEqualTo, .date(.startOfWeek)))
            try assertRoundTrip(SmartNoteComparison(field, .lessThan, .date(.endOfWeek)))
            try assertRoundTrip(SmartNoteComparison(field, .greaterThan, .date(.daysFromToday(-7))))
            try assertRoundTrip(SmartNoteComparison(field, .equalTo, .date(.absolute(absolute))))
            try assertRoundTrip(SmartNoteComparison(field, .exists, .empty))
            try assertRoundTrip(SmartNoteComparison(field, .notExists, .empty))
        }
    }

    @Test("Text fields round-trip")
    func textFields() throws {
        try assertRoundTrip(SmartNoteComparison(.fullText, .contains, .text("quantum")))
        try assertRoundTrip(SmartNoteComparison(.path, .beginsWith, .text("Web/")))
        try assertRoundTrip(SmartNoteComparison(.path, .contains, .text("/")))
        try assertRoundTrip(SmartNoteComparison(.title, .equalTo, .text("Ideas")))
        try assertRoundTrip(SmartNoteComparison(.title, .notEqualTo, .text("Ideas")))
    }

    @Test("Frontmatter property field round-trips (key preserved via keyPath)")
    func propertyField() throws {
        try assertRoundTrip(SmartNoteComparison(.property(key: "owner"), .equalTo, .text("Mark")))
        try assertRoundTrip(SmartNoteComparison(.property(key: "owner"), .contains, .text("ar")))
        try assertRoundTrip(SmartNoteComparison(.property(key: "priority"), .exists, .empty))
        try assertRoundTrip(SmartNoteComparison(.property(key: "priority"), .notExists, .empty))
    }

    @Test("Compound AND / OR / NOT round-trip")
    func compound() throws {
        let query = SmartNoteQuery(root: .and([
            .comparison(SmartNoteComparison(.scheduled, .lessThanOrEqualTo, .date(.today))),
            .not(.comparison(SmartNoteComparison(.status, .equalTo, .status(.done)))),
            .or([
                .comparison(SmartNoteComparison(.tag, .contains, .text("a"))),
                .comparison(SmartNoteComparison(.tag, .contains, .text("b")))
            ])
        ]))
        let predicate = SmartNotePredicateBridge.makePredicate(query)
        let recovered = try SmartNotePredicateBridge.makeQuery(from: predicate)
        #expect(recovered == query)
    }

    @Test("Existence and notEqualTo do not collide (NSNull sentinel)")
    func existenceDoesNotCollideWithNotEqual() throws {
        // `tag is set` and `tag != "x"` both map to NSComparisonPredicate
        // .notEqualTo; the NSNull constant is what keeps them distinct.
        let exists = SmartNoteQuery(root: .comparison(SmartNoteComparison(.tag, .exists, .empty)))
        let notEqual = SmartNoteQuery(root: .comparison(SmartNoteComparison(.tag, .notEqualTo, .text("x"))))
        #expect(try SmartNotePredicateBridge.makeQuery(from: SmartNotePredicateBridge.makePredicate(exists)) == exists)
        #expect(try SmartNotePredicateBridge.makeQuery(from: SmartNotePredicateBridge.makePredicate(notEqual)) == notEqual)
    }

    @Test("An unrepresentable predicate throws")
    func unrepresentable() {
        let predicate = NSPredicate(format: "unknownField == 5")
        #expect(throws: SmartNotePredicateBridgeError.unrepresentable) {
            _ = try SmartNotePredicateBridge.makeQuery(from: predicate)
        }
    }

    @Test("Every built-in query round-trips through NSPredicate")
    func builtinsRoundTrip() throws {
        for builtin in SmartNoteBuiltins.all {
            let predicate = SmartNotePredicateBridge.makePredicate(builtin.query)
            let recovered = try SmartNotePredicateBridge.makeQuery(from: predicate)
            #expect(recovered == builtin.query, "built-in \(builtin.name) failed round-trip")
        }
    }
}
