import XCTest
@testable import HerdrKit

final class CodecTests: XCTestCase {
    func testRequestFramingMatchesDocumentedShape() throws {
        let request = RPCRequest(id: "req_1", method: "ping", params: .object([:]))
        let line = try NDJSON.frame(request)

        XCTAssertEqual(line.last, NDJSON.newline, "frames must be newline-terminated")

        let object = try JSONSerialization.jsonObject(with: line.dropLast()) as? [String: Any]
        XCTAssertEqual(object?["id"] as? String, "req_1")
        XCTAssertEqual(object?["method"] as? String, "ping")
    }

    func testDecodeResponseMessage() throws {
        let line = Data(#"{"id":"req_1","result":{"type":"pong"}}"#.utf8)
        guard case .response(let response) = try IncomingMessage.decode(line: line) else {
            return XCTFail("expected a response")
        }
        XCTAssertEqual(response.id, "req_1")
        XCTAssertEqual(response.result?["type"]?.stringValue, "pong")
        XCTAssertNil(response.error)
    }

    /// Herdr pushes events as `{"event":"…","data":{…}}` (real wire sample).
    func testDecodePushedStatusEvent() throws {
        let line = Data(#"{"event":"pane_agent_status_changed","data":{"type":"pane_agent_status_changed","pane_id":"w4:p1","agent_status":"working"}}"#.utf8)
        guard case .event(let event) = try IncomingMessage.decode(line: line) else {
            return XCTFail("expected an event")
        }
        XCTAssertEqual(event.method, "pane_agent_status_changed")
        XCTAssertEqual(HerdrEvent(event).map(String.init(describing:)),
                       String(describing: HerdrEvent.agentStatus(pane: "w4:p1", status: .working)))
    }

    /// The real server is dot-namespaced (`pane.agent_status_changed`); the Mock
    /// uses underscores. `HerdrEvent` normalizes dots→underscores, so the
    /// dot-spelled pushed event must still map to `.agentStatus` — else live
    /// status updates silently stop on a real host.
    func testDecodeDotNamespacedStatusEvent() throws {
        let line = Data(#"{"event":"pane.agent_status_changed","data":{"pane_id":"w4:p1","agent_status":"blocked"}}"#.utf8)
        guard case .event(let event) = try IncomingMessage.decode(line: line) else {
            return XCTFail("expected an event")
        }
        XCTAssertEqual(HerdrEvent(event).map(String.init(describing:)),
                       String(describing: HerdrEvent.agentStatus(pane: "w4:p1", status: .blocked)))
    }

    /// A topology event maps to `.topologyChanged` — in both the Mock's
    /// underscore form and the real server's dot form.
    func testDecodeTopologyEvent() throws {
        for name in ["tab_closed", "tab.closed"] {
            let line = Data(#"{"event":"\#(name)","data":{"tab_id":"w4:t2","workspace_id":"w4"}}"#.utf8)
            guard case .event(let event) = try IncomingMessage.decode(line: line),
                  case .topologyChanged? = HerdrEvent(event) else {
                return XCTFail("expected a topologyChanged event for \(name)")
            }
        }
    }

    /// Herdr returns string error codes; decoding must not drop the message.
    func testDecodeErrorResponseWithStringCode() throws {
        let line = Data(#"{"id":"r","error":{"code":"invalid_request","message":"missing field `pane_id`"}}"#.utf8)
        guard case .response(let response) = try IncomingMessage.decode(line: line) else {
            return XCTFail("expected a response")
        }
        XCTAssertEqual(response.error?.code, "invalid_request")
        XCTAssertEqual(response.error?.message, "missing field `pane_id`")
    }

    // MARK: Real wire fixtures (captured from a live server, protocol 14)

    func testWorkspaceListDecodesRealShape() throws {
        let line = Data(#"{"type":"workspace_list","workspaces":[{"workspace_id":"w4","number":1,"label":"~","focused":true,"pane_count":1,"tab_count":1,"active_tab_id":"w4:t1","agent_status":"unknown"}]}"#.utf8)
        let value = try JSONDecoder().decode(JSONValue.self, from: line)
        let result = try value.decodedSnake(WorkspaceListResult.self)
        XCTAssertEqual(result.workspaces.count, 1)
        XCTAssertEqual(result.workspaces[0].workspaceId, "w4")
        XCTAssertEqual(result.workspaces[0].activeTabId, "w4:t1")
        XCTAssertEqual(result.workspaces[0].agentStatus, "unknown")
    }

    func testPaneReadDecodesRealShape() throws {
        let line = Data(#"{"type":"pane_read","read":{"pane_id":"w4:p1","source":"recent","format":"text","text":"line a\nline b\n","truncated":false}}"#.utf8)
        let value = try JSONDecoder().decode(JSONValue.self, from: line)
        let read = try value.decodedSnake(PaneReadResult.self).read
        XCTAssertEqual(read.text, "line a\nline b\n")
    }

    func testLineBufferSplitsAndRetainsPartials() {
        var buffer = LineBuffer()
        XCTAssertEqual(buffer.append(Data(#"{"a":1}"#.utf8)).count, 0, "no newline yet → no lines")
        let lines = buffer.append(Data("\n{\"b\":2}\n{\"c\"".utf8))
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(String(data: lines[0], encoding: .utf8), #"{"a":1}"#)
        XCTAssertEqual(String(data: lines[1], encoding: .utf8), #"{"b":2}"#)
        // The trailing partial is retained until its newline arrives.
        let rest = buffer.append(Data(":3}\n".utf8))
        XCTAssertEqual(String(data: rest[0], encoding: .utf8), #"{"c":3}"#)
    }

    func testJSONValueRoundTrip() throws {
        let value = JSONValue.object([
            "s": .string("x"), "i": .int(7), "b": .bool(true),
            "a": .array([.int(1), .null]),
        ])
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        XCTAssertEqual(decoded, value)
    }
}
