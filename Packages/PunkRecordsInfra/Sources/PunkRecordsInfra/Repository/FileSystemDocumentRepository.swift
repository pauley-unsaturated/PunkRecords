import Foundation
import PunkRecordsCore

/// Reads/writes .md files from a vault folder and watches for changes via FSEventStream.
public actor FileSystemDocumentRepository: DocumentRepository {
    private let vaultRoot: URL
    private let parser: MarkdownParser
    private let ignoredPaths: [String]
    private let changesContinuation: AsyncStream<VaultChange>.Continuation
    public let changes: AsyncStream<VaultChange>
    private var watcher: FSEventStreamWatcher?

    public init(vaultRoot: URL, ignoredPaths: [String] = []) {
        self.vaultRoot = vaultRoot.standardizedFileURL
        self.parser = MarkdownParser()
        self.ignoredPaths = ignoredPaths

        let (stream, continuation) = AsyncStream<VaultChange>.makeStream()
        self.changes = stream
        self.changesContinuation = continuation
    }

    // MARK: - DocumentRepository

    public func document(withID id: DocumentID) async throws -> Document? {
        let allDocs = try await allDocuments()
        return allDocs.first { $0.id == id }
    }

    public func document(atPath path: RelativePath) async throws -> Document? {
        let fileURL = vaultRoot.appendingPathComponent(path)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        return try readDocument(at: fileURL, relativePath: path)
    }

    public func allDocuments() async throws -> [Document] {
        try listMarkdownFiles(in: vaultRoot, relativeTo: vaultRoot)
    }

    /// Like ``allDocuments()``, but reports the running count of notes read so a
    /// vault open can show progress. `onProgress` is invoked on this actor as
    /// each note is loaded — the count is monotonic (1, 2, 3, …).
    public func allDocuments(onProgress: @escaping @Sendable (Int) -> Void) async throws -> [Document] {
        try listMarkdownFiles(in: vaultRoot, relativeTo: vaultRoot, onProgress: onProgress)
    }

    public func documentsInFolder(_ path: RelativePath) async throws -> [Document] {
        let folderURL = vaultRoot.appendingPathComponent(path)
        guard FileManager.default.isReadableFile(atPath: folderURL.path) ||
              FileManager.default.fileExists(atPath: folderURL.path) else {
            return []
        }
        return try listMarkdownFiles(in: folderURL, relativeTo: vaultRoot)
    }

    public func save(_ document: Document) async throws {
        let fileURL = vaultRoot.appendingPathComponent(document.path)
        let directory = fileURL.deletingLastPathComponent()

        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        try document.content.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    public func delete(_ document: Document) async throws {
        let fileURL = vaultRoot.appendingPathComponent(document.path)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
    }

    public func move(_ document: Document, to newPath: RelativePath) async throws {
        let oldURL = vaultRoot.appendingPathComponent(document.path)
        let newURL = vaultRoot.appendingPathComponent(newPath)
        let directory = newURL.deletingLastPathComponent()

        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        try FileManager.default.moveItem(at: oldURL, to: newURL)
    }

    // MARK: - Duplicate ID Healing

    /// Records one document whose ID collided with another in the vault and was rewritten.
    public struct HealedDuplicate: Sendable, Equatable {
        public let path: RelativePath
        public let oldID: DocumentID
        public let newID: DocumentID
    }

    /// Find documents sharing a frontmatter `id:` and rewrite the duplicates with fresh
    /// UUIDs. The first hit (lexicographically smallest path) keeps the original ID so
    /// the choice is stable across runs. The replacement is scoped to the frontmatter
    /// block to avoid clobbering any body text that happens to match the old UUID.
    /// Returns the list of healed files; an empty array means the vault was clean.
    public func healDuplicateIDs() async throws -> [HealedDuplicate] {
        let docs = try await allDocuments()
        var groups: [DocumentID: [Document]] = [:]
        for doc in docs { groups[doc.id, default: []].append(doc) }

        var healed: [HealedDuplicate] = []
        for (id, dupes) in groups where dupes.count > 1 {
            let sorted = dupes.sorted { $0.path < $1.path }
            for victim in sorted.dropFirst() {
                let newID = DocumentID()
                let fileURL = vaultRoot.appendingPathComponent(victim.path)
                let content = try String(contentsOf: fileURL, encoding: .utf8)
                guard let rewritten = Self.rewriteFrontmatterID(
                    in: content,
                    oldID: id,
                    newID: newID
                ) else {
                    continue
                }
                try rewritten.write(to: fileURL, atomically: true, encoding: .utf8)
                healed.append(HealedDuplicate(path: victim.path, oldID: id, newID: newID))
            }
        }
        return healed
    }

    /// Replace the `id:` line inside the frontmatter block only. Returns nil if no
    /// frontmatter block is present or the old ID can't be found in it.
    public static func rewriteFrontmatterID(
        in content: String,
        oldID: DocumentID,
        newID: DocumentID
    ) -> String? {
        let lines = content.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return nil }

        var closingIndex: Int?
        for i in 1..<lines.count where lines[i].trimmingCharacters(in: .whitespaces) == "---" {
            closingIndex = i
            break
        }
        guard let endIndex = closingIndex else { return nil }

        var rewrote = false
        var newLines = lines
        for i in 1..<endIndex {
            let line = newLines[i]
            guard let colonIndex = line.firstIndex(of: ":") else { continue }
            let key = String(line[line.startIndex..<colonIndex]).trimmingCharacters(in: .whitespaces)
            guard key == "id" else { continue }
            let value = String(line[line.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)
            guard UUID(uuidString: value) == oldID else { continue }
            // Preserve any indentation before "id:" (rare, but possible)
            let prefix = line.prefix { $0 == " " || $0 == "\t" }
            newLines[i] = "\(prefix)id: \(newID.uuidString)"
            rewrote = true
            break
        }
        guard rewrote else { return nil }
        return newLines.joined(separator: "\n")
    }

    // MARK: - File Watching

    public func startWatching() {
        let root = vaultRoot
        let ignored = ignoredPaths
        let continuation = changesContinuation
        let parserCopy = parser

        watcher = FSEventStreamWatcher(path: root.path, debounceInterval: 0.3) { events in
            for event in events {
                let relativePath = String(event.path.dropFirst(root.path.count + 1))

                // Skip ignored paths
                if ignored.contains(where: { Self.pathMatchesGlob(relativePath, glob: $0) }) {
                    continue
                }

                guard relativePath.hasSuffix(".md") else { continue }

                let fileURL = root.appendingPathComponent(relativePath)

                if event.isRemoved {
                    // We don't have the ID readily available for deleted files
                    let id = UUID() // placeholder — index should handle by path
                    continuation.yield(.deleted(id, path: relativePath))
                } else {
                    do {
                        let content = try String(contentsOf: fileURL, encoding: .utf8)
                        let filename = fileURL.lastPathComponent
                        let parsed = parserCopy.parse(content: content, filename: filename)
                        let doc = Document(
                            id: parsed.id,
                            title: parsed.title,
                            content: content,
                            path: relativePath,
                            tags: parsed.tags,
                            created: Date(),
                            modified: Date()
                        )
                        if event.isCreated {
                            continuation.yield(.added(doc))
                        } else {
                            continuation.yield(.modified(doc))
                        }
                    } catch {
                        // Skip files we can't read
                    }
                }
            }
        }
        watcher?.start()
    }

    public func stopWatching() {
        watcher?.stop()
        watcher = nil
    }

    // MARK: - Private

    private func readDocument(at url: URL, relativePath: RelativePath) throws -> Document {
        let content = try String(contentsOf: url, encoding: .utf8)
        let filename = url.lastPathComponent
        let parsed = parser.parse(content: content, filename: filename)

        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let created = attributes[.creationDate] as? Date ?? Date()
        let modified = attributes[.modificationDate] as? Date ?? Date()

        var doc = Document(
            id: parsed.id,
            title: parsed.title,
            content: content,
            path: relativePath,
            tags: parsed.tags,
            created: created,
            modified: modified,
            frontmatter: parsed.frontmatter
        )

        // If the file didn't have an ID, write one back
        if parsed.needsIDAssigned {
            let newFrontmatter = parser.generateFrontmatter(
                id: doc.id,
                tags: doc.tags,
                created: created,
                modified: modified
            )
            let newContent = newFrontmatter + "\n\n" + parsed.body
            doc = Document(
                id: doc.id,
                title: doc.title,
                content: newContent,
                path: relativePath,
                tags: doc.tags,
                created: created,
                modified: modified,
                frontmatter: doc.frontmatter
            )
            try newContent.write(to: url, atomically: true, encoding: .utf8)
        }

        return doc
    }

    private func listMarkdownFiles(
        in directory: URL,
        relativeTo root: URL,
        onProgress: (@Sendable (Int) -> Void)? = nil
    ) throws -> [Document] {
        let fm = FileManager.default
        let standardRoot = root.standardizedFileURL
        guard let enumerator = fm.enumerator(
            at: directory.standardizedFileURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var documents: [Document] = []

        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "md" else { continue }

            let standardFile = fileURL.standardizedFileURL
            let relativePath = standardFile.path.replacingOccurrences(of: standardRoot.path + "/", with: "")

            // Skip ignored paths
            if ignoredPaths.contains(where: { Self.pathMatchesGlob(relativePath, glob: $0) }) {
                continue
            }

            do {
                let doc = try readDocument(at: fileURL, relativePath: relativePath)
                documents.append(doc)
                onProgress?(documents.count)
            } catch {
                continue
            }
        }

        return documents
    }

    private static func pathMatchesGlob(_ path: String, glob: String) -> Bool {
        // Simple glob matching: support * and **
        let pattern = glob
            .replacingOccurrences(of: ".", with: "\\.")
            .replacingOccurrences(of: "**", with: ".*")
            .replacingOccurrences(of: "*", with: "[^/]*")
        guard let regex = try? NSRegularExpression(pattern: "^" + pattern + "$") else { return false }
        return regex.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)) != nil
    }
}
