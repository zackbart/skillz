import Foundation

/// Newline-delimited JSON framing helpers.
public enum NDJSON {
    public static let newline: UInt8 = 0x0A

    /// Encode a value to a single JSON line terminated by `\n`.
    public static func frame<T: Encodable>(_ value: T) throws -> Data {
        var data = try JSONEncoder().encode(value)
        data.append(newline)
        return data
    }
}

/// Accumulates incoming bytes and yields complete `\n`-terminated lines as they
/// arrive. Used by stream transports (e.g. the SSH channel bridge) to turn a
/// byte stream into discrete JSON messages.
public struct LineBuffer {
    private var buffer = Data()
    public init() {}

    /// Append a chunk and return any complete lines now available (without their
    /// trailing newline). Partial trailing data is retained for the next call.
    public mutating func append(_ chunk: Data) -> [Data] {
        buffer.append(chunk)
        var lines: [Data] = []
        while let newlineIndex = buffer.firstIndex(of: NDJSON.newline) {
            let line = buffer[buffer.startIndex..<newlineIndex]
            if !line.isEmpty { lines.append(Data(line)) }
            buffer.removeSubrange(buffer.startIndex...newlineIndex)
        }
        return lines
    }
}
