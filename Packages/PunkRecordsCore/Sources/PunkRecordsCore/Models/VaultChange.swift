import Foundation

public enum VaultChange: Sendable {
    case added(Document)
    case modified(Document)
    case deleted(DocumentID, path: RelativePath)
}
