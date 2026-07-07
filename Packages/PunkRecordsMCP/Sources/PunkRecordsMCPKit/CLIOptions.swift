import Foundation

/// Parsed command-line options for `punkrecords-mcp`. Pure value type — no I/O.
public struct CLIOptions: Equatable, Sendable {
    /// Vault path from `--vault <path>` or the first positional argument.
    /// `nil` means "use the current working directory".
    public var vaultPathArgument: String?
    /// `--writable` — enables `create_note`. Read-only (search/read/list) by default.
    public var writable: Bool
    public var showHelp: Bool
    public var showVersion: Bool

    public init(
        vaultPathArgument: String? = nil,
        writable: Bool = false,
        showHelp: Bool = false,
        showVersion: Bool = false
    ) {
        self.vaultPathArgument = vaultPathArgument
        self.writable = writable
        self.showHelp = showHelp
        self.showVersion = showVersion
    }
}

/// A malformed `punkrecords-mcp` invocation.
public enum CLIParsingError: Error, Equatable, CustomStringConvertible {
    case unknownOption(String)
    case missingValue(forOption: String)
    case tooManyPositionalArguments([String])

    public var description: String {
        switch self {
        case .unknownOption(let option):
            return "Unknown option: \(option)"
        case .missingValue(let option):
            return "\(option) requires a value"
        case .tooManyPositionalArguments(let extras):
            return "Too many positional arguments: \(extras.joined(separator: ", ")). Pass a single vault path."
        }
    }
}

/// Parses `punkrecords-mcp` arguments (everything after argv[0]).
///
/// Grammar: `punkrecords-mcp [vault-path] [--vault <path>] [--writable] [--help] [--version]`
///
/// `--vault` takes precedence over a positional vault path if both are given
/// (the flag is unambiguous; a stray positional alongside it is ignored
/// rather than treated as an error, since the intent is still clear).
public enum CLIParser {
    public static func parse(_ arguments: [String]) -> Result<CLIOptions, CLIParsingError> {
        var options = CLIOptions()
        var positionals: [String] = []
        var iterator = arguments.makeIterator()

        while let arg = iterator.next() {
            switch arg {
            case "--writable":
                options.writable = true
            case "--vault":
                guard let value = iterator.next() else {
                    return .failure(.missingValue(forOption: "--vault"))
                }
                options.vaultPathArgument = value
            case "-h", "--help":
                options.showHelp = true
            case "--version":
                options.showVersion = true
            default:
                let looksLikeOption = arg.hasPrefix("-") && arg != "-"
                if looksLikeOption {
                    return .failure(.unknownOption(arg))
                }
                positionals.append(arg)
            }
        }

        if positionals.count > 1 {
            return .failure(.tooManyPositionalArguments(positionals))
        }
        if options.vaultPathArgument == nil {
            options.vaultPathArgument = positionals.first
        }
        return .success(options)
    }
}

/// Usage text printed for `--help` (to stdout, before any MCP transport
/// starts) and on a parse error (to stderr).
public let cliUsageText = """
    punkrecords-mcp — stdio MCP server exposing a PunkRecords vault's search/read/list \
    tools (and, with --writable, note creation) to MCP-aware clients.

    USAGE:
        punkrecords-mcp [vault-path] [options]

    ARGUMENTS:
        vault-path            Path to the vault directory. Defaults to the current
                               working directory if omitted.

    OPTIONS:
        --vault <path>         Same as the positional argument; takes precedence if both
                               are given.
        --writable             Enable create_note. Omit this flag to run read-only
                               (vault_search, read_document, list_documents only).
        -h, --help             Print this help and exit.
        --version              Print the server version and exit.
    """
