import Foundation

// Herdr speaks newline-delimited JSON-RPC over its Unix socket. A request is one
// JSON object per line:
//     {"id":"req_1","method":"ping","params":{}}
// and a successful response echoes the id:
//     {"id":"req_1","result":{"type":"pong"}}
// Subscriptions keep the connection open and push further messages (events).

/// A client → server request.
public struct RPCRequest: Codable, Sendable {
    public let id: String
    public let method: String
    public let params: JSONValue

    public init(id: String, method: String, params: JSONValue = .object([:])) {
        self.id = id
        self.method = method
        self.params = params
    }
}

/// An error object returned in place of a result. Herdr sends string codes
/// (e.g. `"invalid_request"`); we also tolerate numeric codes (JSON-RPC style).
public struct RPCError: Codable, Hashable, Sendable, Error {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let s = try? c.decode(String.self, forKey: .code) {
            code = s
        } else if let i = try? c.decode(Int.self, forKey: .code) {
            code = String(i)
        } else {
            code = ""
        }
        message = (try? c.decode(String.self, forKey: .message)) ?? ""
    }
}

/// A server → client reply correlated to a request by `id`.
public struct RPCResponse: Sendable {
    public let id: String?
    public let result: JSONValue?
    public let error: RPCError?

    public init(id: String?, result: JSONValue?, error: RPCError?) {
        self.id = id
        self.result = result
        self.error = error
    }
}

/// A server-pushed event (from a subscription) that carries no request id.
public struct RPCEvent: Sendable {
    public let method: String
    public let params: JSONValue

    public init(method: String, params: JSONValue) {
        self.method = method
        self.params = params
    }
}

/// One decoded line from the socket: either a reply or an event.
public enum IncomingMessage: Sendable {
    case response(RPCResponse)
    case event(RPCEvent)

    /// Decode a single NDJSON line.
    ///
    /// Herdr pushes events as `{"event":"<name>","data":{…}}` (no id/result);
    /// replies carry `result`/`error` and echo the request `id`. The legacy
    /// `{"method":…}` form (no id) is still treated as an event for the Mock.
    public static func decode(line: Data) throws -> IncomingMessage {
        let raw = try JSONDecoder().decode(RawMessage.self, from: line)
        if let event = raw.event {
            return .event(RPCEvent(method: event, params: raw.data ?? .object([:])))
        }
        if raw.result != nil || raw.error != nil {
            return .response(RPCResponse(id: raw.id, result: raw.result, error: raw.error))
        }
        if let method = raw.method, raw.id == nil {
            return .event(RPCEvent(method: method, params: raw.params ?? .object([:])))
        }
        // Bare ack: an id with no result body.
        return .response(RPCResponse(id: raw.id, result: raw.params, error: nil))
    }

    private struct RawMessage: Decodable {
        let id: String?
        let method: String?
        let params: JSONValue?
        let result: JSONValue?
        let error: RPCError?
        /// Pushed-event name and payload (`{"event":…,"data":…}`).
        let event: String?
        let data: JSONValue?
    }
}
