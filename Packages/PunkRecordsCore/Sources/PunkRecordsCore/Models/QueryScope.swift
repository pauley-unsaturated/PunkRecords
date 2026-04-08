import Foundation

public enum QueryScope: Sendable {
    case global
    case folder(RelativePath)
    case document(DocumentID)
    case selection
}
