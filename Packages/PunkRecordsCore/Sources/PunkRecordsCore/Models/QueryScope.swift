import Foundation

public enum QueryScope: Sendable, Codable, Equatable {
    case global
    case folder(RelativePath)
    case document(DocumentID)
    case selection
}
