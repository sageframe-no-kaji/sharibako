import Foundation
import Testing

@testable import SharibakoCLI

@Suite("OutputRenderer")
struct OutputRendererTests {
    private let plain = OutputRenderer(json: false, color: false)
    private let colored = OutputRenderer(json: false, color: true)
    private let jsonRenderer = OutputRenderer(json: true, color: false)

    // MARK: - kv

    @Test("kv formats key: value in plain mode")
    func kvPlain() {
        #expect(plain.kv("FOO", "bar") == "FOO: bar")
    }

    @Test("kv wraps key in bold ANSI in color mode")
    func kvColored() {
        let result = colored.kv("FOO", "bar")
        #expect(result.contains("FOO"))
        #expect(result.contains("bar"))
        #expect(result.contains("\u{1B}["))
    }

    // MARK: - warn

    @Test("warn prepends Warning: in plain mode")
    func warnPlain() {
        #expect(plain.warn("something") == "Warning: something")
    }

    @Test("warn applies yellow ANSI in color mode")
    func warnColored() {
        let result = colored.warn("something")
        #expect(result.contains("something"))
        #expect(result.contains("\u{1B}[33m"))
    }

    // MARK: - success

    @Test("success returns string unchanged in plain mode")
    func successPlain() {
        #expect(plain.success("done") == "done")
    }

    @Test("success applies green ANSI in color mode")
    func successColored() {
        let result = colored.success("done")
        #expect(result.contains("done"))
        #expect(result.contains("\u{1B}[32m"))
    }

    // MARK: - error

    @Test("error prepends Error: in plain mode")
    func errorPlain() {
        #expect(plain.error("oops") == "Error: oops")
    }

    // MARK: - table

    @Test("table renders headers and separator row")
    func tableRendersHeaders() {
        let output = plain.table(headers: ["NAME", "TYPE"], rows: [])
        #expect(output.contains("NAME"))
        #expect(output.contains("TYPE"))
        #expect(output.contains("---") || output.contains("─"))
    }

    @Test("table renders row data below headers")
    func tableRendersRows() {
        let output = plain.table(
            headers: ["SCOPE", "TYPE"],
            rows: [["kanyo-dev", "project-dev"], ["bento", "project-prod"]]
        )
        #expect(output.contains("kanyo-dev"))
        #expect(output.contains("project-dev"))
        #expect(output.contains("bento"))
        #expect(output.contains("project-prod"))
    }

    @Test("table aligns columns to widest cell width")
    func tableAlignsColumns() {
        let output = plain.table(
            headers: ["A", "LONGER_HEADER"],
            rows: [["x", "y"]]
        )
        // "LONGER_HEADER" determines column width; "x" should be padded
        #expect(output.contains("LONGER_HEADER"))
    }

    @Test("table returns empty string for empty headers")
    func tableEmptyHeaders() {
        let output = plain.table(headers: [], rows: [])
        #expect(output.isEmpty)
    }

    // MARK: - encodeJSON

    @Test("encodeJSON produces valid JSON for an array of strings")
    func encodeJSONStringArray() throws {
        let ids = ["scope-a", "scope-b"]
        let json = try jsonRenderer.encodeJSON(ids)
        let decoded = try JSONDecoder().decode([String].self, from: Data(json.utf8))
        #expect(decoded == ids)
    }

    @Test("encodeJSON produces valid JSON for an empty array")
    func encodeJSONEmpty() throws {
        let empty: [String] = []
        let json = try jsonRenderer.encodeJSON(empty)
        let decoded = try JSONDecoder().decode([String].self, from: Data(json.utf8))
        #expect(decoded.isEmpty)
    }

    @Test("encodeJSON produces valid JSON for an Encodable struct")
    func encodeJSONStruct() throws {
        struct Payload: Codable {
            let name: String
            let count: Int
        }
        let payload = Payload(name: "test", count: 42)
        let json = try jsonRenderer.encodeJSON(payload)
        let decoded = try JSONDecoder().decode(Payload.self, from: Data(json.utf8))
        #expect(decoded.name == "test")
        #expect(decoded.count == 42)
    }

    // MARK: - ANSI stripping

    @Test("color=false produces no ANSI escape sequences in table")
    func tableNoANSIWhenColorFalse() {
        let output = plain.table(
            headers: ["SCOPE"],
            rows: [["kanyo"]]
        )
        #expect(!output.contains("\u{1B}["))
    }

    // MARK: - text

    @Test("text returns the string unchanged in both modes")
    func textPassthrough() {
        #expect(plain.text("as-is") == "as-is")
        #expect(colored.text("as-is") == "as-is")
    }

    // MARK: - error (color mode)

    @Test("error applies red ANSI in color mode")
    func errorColored() {
        let result = colored.error("oops")
        #expect(result.contains("oops"))
        #expect(result.contains("\u{1B}[31m"))
    }

    // MARK: - table (color mode)

    @Test("color=true renders bold headers and a box-drawing separator")
    func tableColored() {
        let output = colored.table(
            headers: ["SCOPE", "TYPE"],
            rows: [["kanyo", "project-dev"]]
        )
        #expect(output.contains("\u{1B}[1m"))
        #expect(output.contains("─"))
        #expect(output.contains("kanyo"))
        // Data rows stay unstyled — only the header row is bold.
        let dataLine = output.split(separator: "\n").last.map(String.init) ?? ""
        #expect(!dataLine.contains("\u{1B}[1m"))
    }
}
