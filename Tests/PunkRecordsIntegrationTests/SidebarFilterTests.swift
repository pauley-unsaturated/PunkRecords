import Testing
import Foundation
@testable import PunkRecordsCore

@Suite("SidebarFilter")
struct SidebarFilterTests {

    private func doc(_ title: String, path: String) -> Document {
        Document(
            id: UUID(),
            title: title,
            content: "",
            path: path
        )
    }

    @Test("Empty query returns every document grouped by folder")
    func emptyQueryReturnsAll() {
        let docs = [
            doc("Alpha", path: "Alpha.md"),
            doc("Beta", path: "Notes/Beta.md"),
            doc("Gamma", path: "Notes/Gamma.md"),
        ]
        let groups = SidebarFilter.filter(documents: docs, query: "")

        #expect(groups.count == 2)
        #expect(groups[0].folder == "")        // vault root first
        #expect(groups[0].documents.count == 1)
        #expect(groups[1].folder == "Notes")
        #expect(groups[1].documents.count == 2)
        #expect(groups[1].hitCount == 2)
    }

    @Test("Whitespace-only query is treated as empty")
    func whitespaceQueryIsEmpty() {
        let docs = [
            doc("Alpha", path: "Alpha.md"),
            doc("Beta", path: "Beta.md"),
        ]
        let groups = SidebarFilter.filter(documents: docs, query: "   \n\t  ")
        #expect(groups.first?.documents.count == 2)
    }

    @Test("Title substring match is case-insensitive")
    func caseInsensitiveMatch() {
        let docs = [
            doc("Apple Pie Recipe", path: "Recipes/apple-pie.md"),
            doc("Banana Split", path: "Recipes/banana.md"),
        ]
        let groups = SidebarFilter.filter(documents: docs, query: "APPLE")
        #expect(groups.count == 1)
        #expect(groups[0].documents.count == 1)
        #expect(groups[0].documents[0].title == "Apple Pie Recipe")
    }

    @Test("Diacritic-insensitive match (café matches cafe)")
    func diacriticInsensitiveMatch() {
        let docs = [
            doc("Café Notes", path: "cafe.md"),
            doc("Other", path: "other.md"),
        ]
        let groups = SidebarFilter.filter(documents: docs, query: "cafe")
        #expect(groups.first?.documents.count == 1)
        #expect(groups.first?.documents.first?.title == "Café Notes")
    }

    @Test("Folder is kept when any contained doc matches, dropped otherwise")
    func folderAncestorsPreserved() {
        let docs = [
            doc("Apple", path: "Fruit/Apple.md"),
            doc("Banana", path: "Fruit/Banana.md"),
            doc("Carrot", path: "Veg/Carrot.md"),
        ]
        let groups = SidebarFilter.filter(documents: docs, query: "Apple")
        #expect(groups.count == 1, "Veg folder should drop — no matches inside")
        #expect(groups[0].folder == "Fruit")
        #expect(groups[0].documents.count == 1)
        #expect(groups[0].hitCount == 1)
    }

    @Test("Hit count equals matched-doc count in each folder")
    func hitCountReflectsMatches() {
        let docs = [
            doc("Apple", path: "Fruit/Apple.md"),
            doc("Pineapple", path: "Fruit/Pineapple.md"),
            doc("Pear", path: "Fruit/Pear.md"),
        ]
        let groups = SidebarFilter.filter(documents: docs, query: "apple")
        #expect(groups.count == 1)
        #expect(groups[0].hitCount == 2, "Apple + Pineapple both match")
        #expect(groups[0].documents.count == 2)
    }

    @Test("Folder name itself doesn't match — only doc titles do")
    func folderNameNotMatched() {
        // A folder named "Apple" should NOT contribute matches on its own;
        // only docs inside it that match the query do.
        let docs = [
            doc("Banana", path: "Apple/Banana.md"),
            doc("Orange", path: "Citrus/Orange.md"),
        ]
        let groups = SidebarFilter.filter(documents: docs, query: "Apple")
        #expect(groups.isEmpty, "Folder names should not match the query")
    }

    @Test("Vault root folder always sorts first, others alphabetical")
    func sortOrder() {
        let docs = [
            doc("Zeta", path: "Zeta/Zeta.md"),
            doc("Alpha", path: "Alpha/Alpha.md"),
            doc("Root", path: "Root.md"),
            doc("Mid", path: "Mid/Mid.md"),
        ]
        let groups = SidebarFilter.filter(documents: docs, query: "")
        #expect(groups.map(\.folder) == ["", "Alpha", "Mid", "Zeta"])
    }

    @Test("Documents within a folder are sorted by localized title")
    func documentsSortedByTitle() {
        let docs = [
            doc("zebra", path: "x/z.md"),
            doc("Apple", path: "x/a.md"),
            doc("banana", path: "x/b.md"),
        ]
        let groups = SidebarFilter.filter(documents: docs, query: "")
        #expect(groups.first?.documents.map(\.title) == ["Apple", "banana", "zebra"])
    }

    @Test("Unicode + emoji titles match cleanly")
    func unicodeMatch() {
        let docs = [
            doc("🦄 Unicorn Notes", path: "u.md"),
            doc("Mundane", path: "m.md"),
        ]
        let groups = SidebarFilter.filter(documents: docs, query: "unicorn")
        #expect(groups.first?.documents.first?.title == "🦄 Unicorn Notes")
    }

    @Test("Filter on 10k docs completes in well under 50ms")
    func performanceFloor() {
        var docs: [Document] = []
        docs.reserveCapacity(10_000)
        for i in 0..<10_000 {
            let folder = "Folder\(i % 50)"
            docs.append(doc("Note \(i)", path: "\(folder)/note-\(i).md"))
        }
        let start = Date()
        let groups = SidebarFilter.filter(documents: docs, query: "Note 1234")
        let elapsed = Date().timeIntervalSince(start)
        #expect(elapsed < 0.05, "Filter took \(elapsed * 1000)ms — should be well under 50ms")
        // 10000, 11234, ..., 21234, ..., 91234 — anything containing "1234"
        let allMatches = (0..<10_000).filter { String($0).contains("1234") }.count
        #expect(groups.reduce(0) { $0 + $1.hitCount } == allMatches)
    }
}
