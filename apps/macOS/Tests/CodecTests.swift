import XCTest
@testable import Loadout

/// Round-trip + regression tests for the MCP config codec/write path — the only code that
/// edits the user's real config files, where a bug silently corrupts rather than crashes.
/// Everything here drives the pure, disk-free `McpWriteEngine.patchedText` except the small
/// `apply` smoke tests at the end, which use a temp dir.
final class CodecTests: XCTestCase {

    // MARK: - Fixtures

    private func loc(_ harness: McpHarness, _ format: McpConfigFormat,
                     _ keyPath: [String], _ name: String = "x") -> McpConfigLocation {
        McpConfigLocation(harness: harness, url: URL(fileURLWithPath: "/tmp/\(name)"),
                          format: format, keyPath: keyPath, label: "test", isPrimary: true)
    }
    private var claudeLoc: McpConfigLocation { loc(.claudeCode, .json, ["mcpServers"]) }
    private var opencodeLoc: McpConfigLocation { loc(.opencode, .jsonc, ["mcp"]) }
    private var codexLoc: McpConfigLocation { loc(.codex, .toml, ["mcp_servers"]) }

    private func stdio(_ command: String = "npx", _ args: [String] = ["-y", "pkg"],
                       env: [String: McpValueExpr] = [:]) -> PortableMcpDefinition {
        PortableMcpDefinition(kind: .stdio, command: command, args: args, env: env,
                              cwd: nil, url: nil, remoteTransport: nil)
    }
    private func upsert(_ name: String, _ def: PortableMcpDefinition,
                        _ enabled: Bool = true) -> McpWriteEngine.Op {
        .upsert(name: name, def: def, enabled: enabled)
    }
    private func patched(_ current: String?, _ location: McpConfigLocation,
                         _ op: McpWriteEngine.Op) throws -> String {
        try McpWriteEngine.patchedText(current: current, location: location, op: op)
    }
    private func parsesAsJSON(_ text: String) -> Bool {
        let stripped = McpConfigCodec.stripJsonc(text)
        return (try? JSONSerialization.jsonObject(with: Data(stripped.utf8))) != nil
    }

    // MARK: - JSON (Claude Code)

    func testJsonUpsertIntoEmptyProducesValidServer() throws {
        let t = try patched(nil, claudeLoc, upsert("foo", stdio()))
        XCTAssertTrue(parsesAsJSON(t))
        XCTAssertTrue(t.contains("\"foo\""))
        XCTAssertTrue(t.contains("\"npx\""))
    }

    func testJsonUpsertIsIdempotent() throws {
        let t1 = try patched(nil, claudeLoc, upsert("foo", stdio()))
        let t2 = try patched(t1, claudeLoc, upsert("foo", stdio()))
        XCTAssertEqual(t1, t2, "re-applying the same upsert must be byte-identical")
    }

    func testJsonRemoveLeavesValidJson() throws {
        let t1 = try patched(nil, claudeLoc, upsert("foo", stdio()))
        let t2 = try patched(t1, claudeLoc, upsert("bar", stdio("node")))
        let t3 = try patched(t2, claudeLoc, .remove(name: "foo"))
        XCTAssertTrue(parsesAsJSON(t3))
        XCTAssertFalse(t3.contains("\"foo\""))
        XCTAssertTrue(t3.contains("\"bar\""))
    }

    func testJsonMalformedIsRefusedNotFixed() {
        XCTAssertThrowsError(try patched("{ not valid json", claudeLoc, upsert("foo", stdio())))
    }

    // MARK: - JSONC (opencode) — comments, trailing commas, unmanaged keys survive

    func testJsoncPreservesCommentsAndUnmanagedKeysOnSiblingUpsert() throws {
        let src = """
        {
          // top comment
          "mcp": {
            "existing": { "type": "local", "command": ["a"], "headers": { "X": "y" }, "enabled": true } // keep me
          }
        }
        """
        let t = try patched(src, opencodeLoc, upsert("added", stdio("svr", [])))
        XCTAssertTrue(t.contains("// top comment"), "block comment preserved")
        XCTAssertTrue(t.contains("// keep me"), "trailing line comment preserved")
        XCTAssertTrue(t.contains("\"headers\""), "unmanaged auth key preserved")
        XCTAssertTrue(t.contains("\"existing\"") && t.contains("\"added\""))
        XCTAssertTrue(parsesAsJSON(t), "result still parses after JSONC strip")
    }

    func testOpencodeEnvDialectRoundTrip() throws {
        // A ${VAR} interpolation normalized to .envVar must render in opencode's {env:VAR}.
        let def = stdio("x", [], env: ["TOKEN": .envVar("TOKEN")])
        let t = try patched(nil, opencodeLoc, upsert("s", def))
        XCTAssertTrue(t.contains("{env:TOKEN}"))
    }

    // MARK: - TOML (Codex) — the quoted-key regression + duplicate guard

    func testTomlUpsertPlainNameIdempotent() throws {
        let t1 = try patched(nil, codexLoc, upsert("github", stdio()))
        let t2 = try patched(t1, codexLoc, upsert("github", stdio()))
        XCTAssertEqual(t1, t2)
        XCTAssertTrue(t1.contains("[mcp_servers.github]"))
    }

    /// Regression: a name needing a quoted key segment must be FOUND again after insert —
    /// before the fix, the header was rendered quoted but looked up unquoted, so a second
    /// upsert appended a duplicate block and remove no-op'd.
    func testTomlQuotedNameDoesNotDuplicateAndCanBeRemoved() throws {
        let name = "my.server"
        let t1 = try patched(nil, codexLoc, upsert(name, stdio("a")))
        XCTAssertTrue(t1.contains("[mcp_servers.\"my.server\"]"))

        let t2 = try patched(t1, codexLoc, upsert(name, stdio("b")))
        let headers = t2.components(separatedBy: "[mcp_servers.\"my.server\"]").count - 1
        XCTAssertEqual(headers, 1, "second upsert must replace, not append a duplicate block")
        XCTAssertTrue(t2.contains("\"b\"") && !t2.contains("\"a\""), "value was actually updated")

        let t3 = try patched(t2, codexLoc, .remove(name: name))
        XCTAssertFalse(t3.contains("my.server"), "remove must locate the quoted block")
    }

    func testTomlPreservesCommentsAndUnmanagedKeys() throws {
        let src = """
        [mcp_servers.foo]
        command = "old"
        # a note
        bearer_token_env_var = "TOK"
        """
        let t = try patched(src, codexLoc, upsert("foo", stdio("new", [])))
        XCTAssertTrue(t.contains("# a note"), "comment preserved")
        XCTAssertTrue(t.contains("bearer_token_env_var = \"TOK\""), "unmanaged key preserved")
        XCTAssertTrue(t.contains("command = \"new\"") && !t.contains("\"old\""), "managed key rewritten")
    }

    func testTomlDuplicateTablesRefused() {
        let dup = """
        [mcp_servers.foo]
        command = "a"

        [mcp_servers.foo]
        command = "b"
        """
        XCTAssertThrowsError(try patched(dup, codexLoc, upsert("foo", stdio())),
                             "duplicate tables must fail closed, not edit only the first")
    }

    func testTomlPlainServersTableRefused() {
        XCTAssertThrowsError(try patched("[mcp_servers]\nfoo = 1\n", codexLoc, upsert("foo", stdio())))
    }

    // MARK: - TomlMiniReader: line-continuation backslash must not eat a literal '#'

    func testTomlMultilineLineContinuationKeepsHash() throws {
        let src = "x = \"\"\"abc\\\n#keep\"\"\"\n"
        let parsed = try TomlMiniReader.parse(src)
        XCTAssertEqual(parsed["x"] as? String, "abc#keep")
    }

    // MARK: - Disk apply (atomic, verified) — touches only its own temp file

    func testApplyWritesParseableFileAndIsIdempotent() throws {
        let dir = try tempDir()
        let url = dir.appendingPathComponent(".mcp.json")
        let location = McpConfigLocation(harness: .claudeCode, url: url, format: .json,
                                         keyPath: ["mcpServers"], label: "t", isPrimary: true)
        try McpWriteEngine.apply(upsert("foo", stdio()), at: location)
        let back = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(parsesAsJSON(back))
        XCTAssertTrue(back.contains("\"foo\""))

        // Second identical apply must be a no-op: bytes unchanged.
        let before = try Data(contentsOf: url)
        try McpWriteEngine.apply(upsert("foo", stdio()), at: location)
        XCTAssertEqual(before, try Data(contentsOf: url))
    }

    func testApplyRefusesMalformedAndLeavesFileUntouched() throws {
        let dir = try tempDir()
        let url = dir.appendingPathComponent(".mcp.json")
        let original = "{ this is broken"
        try original.write(to: url, atomically: true, encoding: .utf8)
        let location = McpConfigLocation(harness: .claudeCode, url: url, format: .json,
                                         keyPath: ["mcpServers"], label: "t", isPrimary: true)
        XCTAssertThrowsError(try McpWriteEngine.apply(upsert("foo", stdio()), at: location))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), original,
                       "a malformed file must never be rewritten")
    }

    func testReadRoundTripsThroughCodec() throws {
        let dir = try tempDir()
        let url = dir.appendingPathComponent(".mcp.json")
        let location = McpConfigLocation(harness: .claudeCode, url: url, format: .json,
                                         keyPath: ["mcpServers"], label: "t", isPrimary: true)
        try McpWriteEngine.apply(upsert("foo", stdio("npx", ["-y", "pkg"])), at: location)
        guard case .ok(let map) = McpConfigCodec.read(location) else {
            return XCTFail("expected .ok")
        }
        XCTAssertEqual(map["foo"]?.portable?.command, "npx")
        XCTAssertEqual(map["foo"]?.portable?.args, ["-y", "pkg"])
    }

    // MARK: - RemoteHostIO.parseListDir (the SSH listing parser, no live host needed)

    func testParseListDir() {
        // Records sep \036, fields sep \037: name, isDir, isSymlink, linkTarget.
        let blob = "real-skill\u{1F}1\u{1F}0\u{1F}\u{1E}"
            + "linked\u{1F}1\u{1F}1\u{1F}../../.agents/skills/linked\u{1E}"
            + "notes.md\u{1F}0\u{1F}0\u{1F}\u{1E}"
        let entries = RemoteHostIO.parseListDir(Data(blob.utf8))
        XCTAssertEqual(entries.count, 3)

        XCTAssertEqual(entries[0].name, "real-skill")
        XCTAssertTrue(entries[0].isDir)
        XCTAssertFalse(entries[0].isSymlink)
        XCTAssertNil(entries[0].linkTarget)

        XCTAssertTrue(entries[1].isSymlink)
        XCTAssertTrue(entries[1].isDir) // symlink-to-dir: dir flag follows the link
        XCTAssertEqual(entries[1].linkTarget, "../../.agents/skills/linked")

        XCTAssertFalse(entries[2].isDir)
        XCTAssertNil(entries[2].linkTarget)
    }

    func testParseListDirEmptyAndMalformed() {
        XCTAssertTrue(RemoteHostIO.parseListDir(Data()).isEmpty)
        // A short (malformed) record is dropped, a valid one survives.
        let blob = "bad\u{1F}1\u{1E}good\u{1F}0\u{1F}0\u{1F}\u{1E}"
        let entries = RemoteHostIO.parseListDir(Data(blob.utf8))
        XCTAssertEqual(entries.map(\.name), ["good"])
    }

    // MARK: - RemoteHostIO.classifyConnect (key-fail → prompt routing)

    func testClassifyConnect() {
        XCTAssertEqual(RemoteHostIO.classifyConnect(exit: 0, stderr: ""), .ok)
        // Auth refusals route to the password prompt.
        XCTAssertEqual(
            RemoteHostIO.classifyConnect(exit: 255, stderr: "zackbart@h: Permission denied (publickey,password)."),
            .needsPassword)
        XCTAssertEqual(
            RemoteHostIO.classifyConnect(exit: 255, stderr: "Received disconnect... No more authentication methods available"),
            .needsPassword)
        // Network/DNS failures surface as an error, not a prompt.
        if case .failed = RemoteHostIO.classifyConnect(exit: 255, stderr: "ssh: Could not resolve hostname nope") {
        } else { XCTFail("expected .failed for DNS error") }
    }

    // MARK: - Helpers

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("loadout-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }
}
