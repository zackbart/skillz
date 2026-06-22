import XCTest
@testable import HerdrKit

final class TerminalTextTests: XCTestCase {
    func testStripANSIRemovesColor() {
        let colored = "\u{1B}[32mgreen\u{1B}[0m"
        XCTAssertEqual(TerminalText.stripANSI(colored), "green")
    }

    func testIsFramingLine() {
        XCTAssertTrue(TerminalText.isFramingLine("┌──────────┐"))
        XCTAssertTrue(TerminalText.isFramingLine("──────────"))
        XCTAssertTrue(TerminalText.isFramingLine("----"))
        XCTAssertFalse(TerminalText.isFramingLine("> commit v1 to a branch"))
        XCTAssertFalse(TerminalText.isFramingLine("context 25%"))
        XCTAssertFalse(TerminalText.isFramingLine("-")) // too short to be a rule
    }

    func testCleanDropsFramesAndUnwrapsSides() {
        let input = [
            "┌────────────────────┐",
            "│ hello world        │",
            "│ second line        │",
            "└────────────────────┘",
        ]
        XCTAssertEqual(TerminalText.clean(input), ["hello world", "second line"])
    }

    func testCleanCollapsesBlankRunsAndTrimsEdges() {
        let input = ["", "", "alpha", "", "", "beta", "", ""]
        XCTAssertEqual(TerminalText.clean(input), ["alpha", "", "beta"])
    }

    func testCleanPreservesInnerANSI() {
        let cleaned = TerminalText.clean(["│ \u{1B}[36mctx\u{1B}[0m │"])
        XCTAssertEqual(cleaned, ["\u{1B}[36mctx\u{1B}[0m"])
    }
}
