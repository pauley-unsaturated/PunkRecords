import PunkRecordsCore

/// Gates the mutating AgentTools (currently just `create_note`) behind the
/// `--writable` CLI flag. Read-only is the default per PUNK-q9h's scope
/// decision, so an MCP client wired up carelessly can't be tricked into
/// writing to the vault.
public enum WritableGate {
    /// AgentTool names that mutate the vault. `vault_search`, `read_document`,
    /// and `list_documents` are all read-only and always available.
    public static let mutatingToolNames: Set<String> = ["create_note"]

    /// Filters a list of tool names down to the read-only subset unless
    /// `writable` is set. Applied to `tools/list` so a read-only server never
    /// advertises `create_note` to the client in the first place.
    public static func visibleToolNames(from names: [String], writable: Bool) -> [String] {
        writable ? names : names.filter { !mutatingToolNames.contains($0) }
    }

    /// Defense-in-depth check applied at `tools/call` time, in case a client
    /// invokes a mutating tool it was never advertised (e.g. a stale tool list
    /// cached from a previous `--writable` session). Returns a rejection
    /// `ToolResult` when the call should be blocked, or `nil` to proceed.
    public static func rejection(forToolNamed name: String, writable: Bool) -> ToolResult? {
        guard !writable, mutatingToolNames.contains(name) else { return nil }
        return ToolResult(
            content: "'\(name)' is disabled: this server is running read-only. "
                + "Restart punkrecords-mcp with --writable to allow it.",
            isError: true
        )
    }
}
