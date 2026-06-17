import Foundation

/// The write pipeline for a single server in a single harness config. Ties the format
/// codecs (`McpJsonWriter` / `TomlMcpWriter`) to the atomic, verified disk write that the
/// safety invariants demand:
///
///   read bytes → refuse if malformed → patch in memory → verify the result parses →
///   confirm on-disk bytes are unchanged since the read → write a temp file in the same dir
///   (perms preserved) → fsync → atomic rename → re-parse the written file, restoring the
///   original on any mismatch.
///
/// Idempotent: a patch that produces byte-identical text writes nothing. Never "fixes" a
/// malformed file. opencode's schema (v1/v2) is detected from the existing file and
/// preserved; a brand-new file uses v1.
enum McpWriteEngine {
    struct WriteError: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    enum Op {
        case upsert(name: String, def: PortableMcpDefinition, enabled: Bool)
        case remove(name: String)
    }

    // MARK: - Pure patch (no disk) — also the unit-testable core

    /// Compute the new file text for `op` at `location`, given the file's current contents
    /// (nil/empty if absent). Throws if the current file is malformed (we never edit blind).
    static func patchedText(current: String?, location: McpConfigLocation, op: Op) throws -> String {
        let text = current ?? ""
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try assertParses(text, format: location.format) // refuse to edit a malformed file
        }
        let schema = detectSchema(text, location: location)
        let keyPath = effectiveKeyPath(location, schema: schema)

        switch location.format {
        case .json, .jsonc:
            switch op {
            case let .upsert(name, def, enabled):
                return try McpJsonWriter.upsert(source: text, harness: location.harness,
                                                keyPath: keyPath, name: name, def: def,
                                                enabled: enabled, schema: schema)
            case let .remove(name):
                return try McpJsonWriter.remove(source: text, keyPath: keyPath, name: name)
            }
        case .toml:
            switch op {
            case let .upsert(name, def, enabled):
                return try TomlMcpWriter.upsert(source: text, name: name, def: def, enabled: enabled)
            case let .remove(name):
                return try TomlMcpWriter.remove(source: text, name: name)
            }
        }
    }

    // MARK: - Disk apply (atomic, verified)

    static func apply(_ op: Op, at location: McpConfigLocation) throws {
        let fm = FileManager.default
        let path = location.url.path
        let existed = fm.fileExists(atPath: path)
        let originalData: Data? = existed ? try Data(contentsOf: location.url) : nil
        let originalPerms = existed
            ? (try? fm.attributesOfItem(atPath: path))?[.posixPermissions] as? NSNumber : nil
        let current = originalData.map { String(decoding: $0, as: UTF8.self) }

        let newText = try patchedText(current: current, location: location, op: op)

        // Idempotent: nothing to write.
        if newText == (current ?? "") { return }
        if !existed, case .remove = op { return }

        // Verify the patched text parses (catch any writer bug BEFORE touching disk).
        try assertParses(newText, format: location.format)
        try assertMembership(newText, location: location, op: op)

        // Concurrent-modification guard: bytes must be what we read.
        if existed, try Data(contentsOf: location.url) != originalData {
            throw WriteError(message: "\(location.url.lastPathComponent) changed on disk during the edit — aborted, nothing written")
        }

        try atomicWrite(Data(newText.utf8), to: location.url, perms: originalPerms)

        // Re-parse the written file; restore the original on any mismatch.
        do {
            let back = String(decoding: try Data(contentsOf: location.url), as: UTF8.self)
            try assertParses(back, format: location.format)
            try assertMembership(back, location: location, op: op)
        } catch {
            if let originalData { try? originalData.write(to: location.url) }
            throw WriteError(message: "post-write verification failed; restored \(location.url.lastPathComponent)")
        }
    }

    // MARK: - Atomic write

    private static func atomicWrite(_ data: Data, to url: URL, perms: NSNumber?) throws {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).skillz-\(UUID().uuidString)")
        do {
            try data.write(to: tmp, options: .atomic)
            if let fh = try? FileHandle(forWritingTo: tmp) {
                try? fh.synchronize() // fsync the bytes before the rename
                try? fh.close()
            }
            if let perms { try? fm.setAttributes([.posixPermissions: perms], ofItemAtPath: tmp.path) }
            // Atomic, same-filesystem replace.
            if rename(tmp.path, url.path) != 0 {
                throw WriteError(message: "atomic rename failed (errno \(errno))")
            }
        } catch {
            try? fm.removeItem(at: tmp)
            throw error is WriteError ? error : WriteError(message: "write failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Schema / key path

    private static func effectiveKeyPath(_ loc: McpConfigLocation, schema: OpencodeSchema) -> [String] {
        if loc.harness == .opencode, schema == .v2 { return loc.keyPath + ["servers"] }
        return loc.keyPath
    }

    private static func detectSchema(_ text: String, location: McpConfigLocation) -> OpencodeSchema {
        guard location.harness == .opencode,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let top = jsonObject(text, format: location.format),
              let mcp = navigate(top, location.keyPath),
              mcp["servers"] is [String: Any] else { return .v1 }
        return .v2
    }

    // MARK: - Verification

    private static func assertParses(_ text: String, format: McpConfigFormat) throws {
        switch format {
        case .json, .jsonc:
            if jsonObject(text, format: format) == nil {
                throw WriteError(message: "config is not valid JSON")
            }
        case .toml:
            if (try? TomlMiniReader.parse(text)) == nil {
                throw WriteError(message: "config is not valid TOML")
            }
        }
    }

    /// Confirm the op actually took: the server is present after upsert, absent after remove.
    private static func assertMembership(_ text: String, location: McpConfigLocation, op: Op) throws {
        let map: [String: Any]?
        switch location.format {
        case .json, .jsonc:
            let schema = detectSchema(text, location: location)
            map = jsonObject(text, format: location.format)
                .flatMap { navigate($0, effectiveKeyPath(location, schema: schema)) }
        case .toml:
            map = (try? TomlMiniReader.parse(text))?["mcp_servers"] as? [String: Any]
        }
        switch op {
        case let .upsert(name, _, _):
            if map?[name] == nil { throw WriteError(message: "server '\(name)' missing from patched config") }
        case let .remove(name):
            if map?[name] != nil { throw WriteError(message: "server '\(name)' still present after removal") }
        }
    }

    // MARK: - JSON helpers

    private static func jsonObject(_ text: String, format: McpConfigFormat) -> [String: Any]? {
        // Strip comments/trailing commas for BOTH json and jsonc: the surgeon edits
        // comment-bearing files fine, so verification must accept them too (and real
        // `.mcp.json` files do sometimes carry comments).
        let src = McpConfigCodec.stripJsonc(text)
        return (try? JSONSerialization.jsonObject(with: Data(src.utf8))) as? [String: Any]
    }

    private static func navigate(_ top: [String: Any], _ keyPath: [String]) -> [String: Any]? {
        var cur = top
        for key in keyPath {
            guard let next = cur[key] as? [String: Any] else { return nil }
            cur = next
        }
        return cur
    }
}
