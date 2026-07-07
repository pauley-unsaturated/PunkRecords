import Testing
import Foundation
@testable import PunkRecordsCore

@Suite("SidebarFilter")
struct SidebarFilterTests {

    private func doc(_ title: String, path: String, tags: [String] = []) -> Document {
        Document(
            id: UUID(),
            title: title,
            content: "",
            path: path,
            tags: tags
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

    @Test("tag: prefix filters by tag, not title")
    func tagPrefixFiltersByTag() {
        let docs = [
            doc("Swift Notes", path: "a.md", tags: ["swift", "ios"]),
            doc("Rust Notes", path: "b.md", tags: ["rust"]),
            doc("Swift Mention", path: "c.md", tags: []), // title says swift, no tag
        ]
        let groups = SidebarFilter.filter(documents: docs, query: "tag:swift")
        let titles = groups.flatMap(\.documents).map(\.title)
        #expect(titles == ["Swift Notes"], "Only the tagged note survives, not the title match")
    }

    @Test("tag: matching is case-insensitive")
    func tagPrefixCaseInsensitive() {
        let docs = [doc("A", path: "a.md", tags: ["swift"])]
        let groups = SidebarFilter.filter(documents: docs, query: "tag:SWIFT")
        #expect(groups.flatMap(\.documents).count == 1)
    }

    @Test("Bare tag: with no name returns everything")
    func emptyTagReturnsAll() {
        let docs = [
            doc("A", path: "a.md", tags: ["x"]),
            doc("B", path: "b.md", tags: []),
        ]
        let groups = SidebarFilter.filter(documents: docs, query: "tag:")
        #expect(groups.flatMap(\.documents).count == 2)
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

/// Tree-assembly tests for the recursive sidebar (PUNK-9y1). Exercises the pure
/// ``SidebarFilter/folderTree(from:)`` end-to-end through the real grouping step,
/// so filtering + title sort + nesting are all covered together.
@Suite("SidebarFolderTree")
struct SidebarFolderTreeTests {

    private func doc(_ title: String, path: String, tags: [String] = []) -> Document {
        Document(id: UUID(), title: title, content: "", path: path, tags: tags)
    }

    /// Build the tree the way the view does: group, then nest.
    private func tree(_ docs: [Document], query: String = "") -> [SidebarFolderNode] {
        SidebarFilter.folderTree(from: SidebarFilter.filter(documents: docs, query: query))
    }

    @Test("Single folder yields one top-level node named by its last component")
    func singleFolder() {
        let nodes = tree([doc("A", path: "Notes/A.md")])
        #expect(nodes.count == 1)
        #expect(nodes[0].name == "Notes")
        #expect(nodes[0].path == "Notes")
        #expect(nodes[0].documents.map(\.title) == ["A"])
        #expect(nodes[0].children.isEmpty)
    }

    @Test("Subfolders nest under ONE top-level parent, not as flat siblings")
    func nestsUnderParent() {
        let nodes = tree([
            doc("Code", path: "vault/code/Code.md"),
            doc("Exp", path: "vault/experiments/Exp.md"),
            doc("Note", path: "vault/notes/Note.md"),
        ])
        #expect(nodes.count == 1, "vault is ONE top-level node, not three full-path rows")
        let vault = nodes[0]
        #expect(vault.name == "vault")
        #expect(vault.documents.isEmpty, "vault holds no direct docs")
        #expect(vault.children.map(\.name) == ["code", "experiments", "notes"])
    }

    @Test("Deep nesting (4+ levels) builds a chain of nodes with cumulative paths")
    func deepNesting() {
        let nodes = tree([doc("Leaf", path: "a/b/c/d/Leaf.md")])
        var node = nodes[0]
        #expect(node.name == "a")
        #expect(node.path == "a")
        node = node.children[0]; #expect(node.name == "b"); #expect(node.path == "a/b")
        node = node.children[0]; #expect(node.name == "c"); #expect(node.path == "a/b/c")
        node = node.children[0]; #expect(node.name == "d"); #expect(node.path == "a/b/c/d")
        #expect(node.children.isEmpty)
        #expect(node.documents.map(\.title) == ["Leaf"])
    }

    @Test("Intermediate folders with no direct docs are still synthesized as nodes")
    func doclessIntermediates() {
        let nodes = tree([doc("Leaf", path: "code/blackwork/node/Leaf.md")])
        let code = nodes[0]
        #expect(code.name == "code")
        #expect(code.documents.isEmpty, "code has no direct docs")
        let blackwork = code.children[0]
        #expect(blackwork.name == "blackwork")
        #expect(blackwork.documents.isEmpty, "blackwork has no direct docs")
        let nodeFolder = blackwork.children[0]
        #expect(nodeFolder.name == "node")
        #expect(nodeFolder.documents.map(\.title) == ["Leaf"])
    }

    @Test("Files at every level: a folder holds direct docs AND subfolders")
    func filesAtEveryLevel() {
        let nodes = tree([
            doc("TopDoc", path: "proj/TopDoc.md"),
            doc("SubDoc", path: "proj/sub/SubDoc.md"),
        ])
        let proj = nodes[0]
        #expect(proj.documents.map(\.title) == ["TopDoc"])
        #expect(proj.children.map(\.name) == ["sub"])
        #expect(proj.children[0].documents.map(\.title) == ["SubDoc"])
    }

    @Test("Sibling folders sort case-insensitively at every level")
    func siblingSort() {
        let nodes = tree([
            doc("Z", path: "root/Zeta/Z.md"),
            doc("a", path: "root/alpha/a.md"),
            doc("M", path: "root/Mid/M.md"),
        ])
        #expect(nodes[0].children.map(\.name) == ["alpha", "Mid", "Zeta"])
    }

    @Test("Top-level folders sort case-insensitively too")
    func topLevelSort() {
        let nodes = tree([
            doc("Z", path: "Zeta/Z.md"),
            doc("a", path: "alpha/a.md"),
            doc("M", path: "Mid/M.md"),
        ])
        #expect(nodes.map(\.name) == ["alpha", "Mid", "Zeta"])
    }

    @Test("Root-level documents are excluded from the tree (render flat above it)")
    func rootDocsExcluded() {
        let nodes = tree([
            doc("RootNote", path: "RootNote.md"),
            doc("Nested", path: "Folder/Nested.md"),
        ])
        #expect(nodes.map(\.name) == ["Folder"], "root doc must not appear as a node")
        #expect(nodes[0].documents.map(\.title) == ["Nested"])
    }

    @Test("totalDocumentCount sums the whole subtree")
    func totalDocumentCount() {
        let nodes = tree([
            doc("A", path: "x/A.md"),
            doc("B", path: "x/y/B.md"),
            doc("C", path: "x/y/z/C.md"),
        ])
        #expect(nodes[0].totalDocumentCount == 3)     // x and everything below
        #expect(nodes[0].children[0].totalDocumentCount == 2) // x/y and below
    }

    @Test("Filtering prunes the tree to only the matches' ancestor folders")
    func filterPrunesToMatches() {
        let docs = [
            doc("Apple", path: "fruit/red/Apple.md"),
            doc("Banana", path: "fruit/yellow/Banana.md"),
            doc("Carrot", path: "veg/Carrot.md"),
        ]
        let nodes = tree(docs, query: "Apple")
        #expect(nodes.map(\.name) == ["fruit"], "veg drops — no match inside")
        let fruit = nodes[0]
        #expect(fruit.children.map(\.name) == ["red"], "yellow drops — Banana filtered out")
        #expect(fruit.children[0].documents.map(\.title) == ["Apple"])
    }

    @Test("Documents within a folder keep the group's localized title sort")
    func docsSortedByTitle() {
        let nodes = tree([
            doc("zebra", path: "x/z.md"),
            doc("Apple", path: "x/a.md"),
            doc("banana", path: "x/b.md"),
        ])
        #expect(nodes[0].documents.map(\.title) == ["Apple", "banana", "zebra"])
    }

    @Test("Empty vault yields an empty tree")
    func emptyVault() {
        #expect(tree([]).isEmpty)
        #expect(tree([doc("Only", path: "Only.md")]).isEmpty, "root-only docs mean no folder nodes")
    }
}
