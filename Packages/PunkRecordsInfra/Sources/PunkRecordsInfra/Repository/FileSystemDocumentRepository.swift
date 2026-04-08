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

    private func listMarkdownFiles(in directory: URL, relativeTo root: URL) throws -> [Document] {
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
