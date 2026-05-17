import Foundation

/// Metadata captured for a single agent tool invocation. Stored on the
/// corresponding ChatMessage when role == .tool.
struct ToolCallInfo: Sendable {
    let name: String
    let arguments: String   // raw JSON from the agent event
    var output: String = ""
    var isError: Bool = false
    var isInFlight: Bool = true

    /// SF Symbol shown in the tool's bubble.
    var systemImageName: String {
        switch name {
        case "vault_search":   "magnifyingglass"
        case "read_document":  "doc.text"
        case "create_note":    "square.and.pencil"
        case "list_documents": "list.bullet"
        default:               "wrench.and.screwdriver"
        }
    }

    /// Human-friendly verb shown next to the icon.
    var displayName: String {
        switch name {
        case "vault_search":   "Search vault"
        case "read_document":  "Read document"
        case "create_note":    "Create note"
        case "list_documents": "List documents"
        default:               name.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    /// One-line summary of *what* was called, derived from the arguments JSON.
    var summary: String {
        guard let data = arguments.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return "" }

        switch name {
        case "vault_search":
            if let q = json["query"] as? String { return "“\(q)”" }
        case "read_document":
            if let path = json["path"] as? String { return path }
        case "create_note":
            if let title = json["title"] as? String { return title }
            if let path = json["path"] as? String { return path }
        case "list_documents":
            if let folder = json["folder"] as? String, !folder.isEmpty { return folder }
            return "vault root"
        default:
            break
        }
        return ""
    }
}
