import Testing
@testable import PunkRecordsMCPKit

@Suite("CLIParser — punkrecords-mcp argument parsing")
struct CLIParserTests {
    @Test("no arguments: defaults to read-only, cwd vault, no help/version")
    func noArguments() {
        let result = CLIParser.parse([])
        #expect(result == .success(CLIOptions()))
    }

    @Test("positional vault path is captured")
    func positionalVaultPath() {
        let result = CLIParser.parse(["/tmp/my-vault"])
        #expect(result == .success(CLIOptions(vaultPathArgument: "/tmp/my-vault")))
    }

    @Test("--vault <path> is captured")
    func vaultFlag() {
        let result = CLIParser.parse(["--vault", "/tmp/my-vault"])
        #expect(result == .success(CLIOptions(vaultPathArgument: "/tmp/my-vault")))
    }

    @Test("--vault takes precedence over a stray positional argument")
    func vaultFlagPrecedence() {
        let result = CLIParser.parse(["/tmp/positional-vault", "--vault", "/tmp/flag-vault"])
        #expect(result == .success(CLIOptions(vaultPathArgument: "/tmp/flag-vault")))
    }

    @Test("--writable sets writable = true")
    func writableFlag() {
        let result = CLIParser.parse(["--writable"])
        #expect(result == .success(CLIOptions(writable: true)))
    }

    @Test("combining positional path + --writable")
    func combined() {
        let result = CLIParser.parse(["/tmp/my-vault", "--writable"])
        #expect(result == .success(CLIOptions(vaultPathArgument: "/tmp/my-vault", writable: true)))
    }

    @Test("-h and --help both set showHelp")
    func helpFlags() {
        #expect(CLIParser.parse(["-h"]) == .success(CLIOptions(showHelp: true)))
        #expect(CLIParser.parse(["--help"]) == .success(CLIOptions(showHelp: true)))
    }

    @Test("--version sets showVersion")
    func versionFlag() {
        #expect(CLIParser.parse(["--version"]) == .success(CLIOptions(showVersion: true)))
    }

    @Test("--vault with no following value is an error")
    func missingVaultValue() {
        let result = CLIParser.parse(["--vault"])
        #expect(result == .failure(.missingValue(forOption: "--vault")))
    }

    @Test("an unrecognized flag is an error")
    func unknownOption() {
        let result = CLIParser.parse(["--bogus"])
        #expect(result == .failure(.unknownOption("--bogus")))
    }

    @Test("more than one positional argument is an error")
    func tooManyPositionals() {
        let result = CLIParser.parse(["/tmp/a", "/tmp/b"])
        #expect(result == .failure(.tooManyPositionalArguments(["/tmp/a", "/tmp/b"])))
    }

    @Test("a bare '-' is treated as a positional argument, not an option")
    func bareDash() {
        let result = CLIParser.parse(["-"])
        #expect(result == .success(CLIOptions(vaultPathArgument: "-")))
    }
}
