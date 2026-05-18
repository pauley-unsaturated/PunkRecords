import Testing
@testable import PunkRecordsCore

@Suite("LLMProviderID")
struct LLMProviderIDTests {

    @Test("Every case has a single-word display name that fits a chip")
    func displayNames() {
        for id in LLMProviderID.allCases {
            let name = id.displayName
            #expect(!name.isEmpty)
            #expect(!name.contains(" "), "\(id) display name should be one word for chip layout: '\(name)'")
            #expect(name.count <= 12, "\(id) display name should fit in a chip: '\(name)'")
        }
    }

    @Test("Display names are distinct (so users can tell providers apart)")
    func displayNamesAreDistinct() {
        let names = Set(LLMProviderID.allCases.map(\.displayName))
        #expect(names.count == LLMProviderID.allCases.count,
                "Each provider should map to a unique display name")
    }

    @Test("Raw value round-trips through init?(rawValue:)")
    func rawValueRoundTrip() {
        for id in LLMProviderID.allCases {
            #expect(LLMProviderID(rawValue: id.rawValue) == id)
        }
    }

    @Test("Unknown raw value returns nil — caller is responsible for fallback")
    func unknownRawValueIsNil() {
        #expect(LLMProviderID(rawValue: "unknown-provider") == nil)
        #expect(LLMProviderID(rawValue: "") == nil)
    }
}
