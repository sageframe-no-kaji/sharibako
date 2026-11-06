import Foundation
import Testing

@testable import SharibakoCLI
@testable import SharibakoCore

/// `ErrorReporter.makeReport` cases the main suite does not reach: the two
/// shared-entry conflicts (ho-06.7's delete guard among them) and the two
/// validation rejections (ho-04.9 identifiers, ho-04.11 remote URLs).
///
/// Each asserts the exit code, that the offending value is named in the
/// message, and that the remediation points at the verb that resolves it — the
/// three things the CLI's error contract promises.
@Suite("ErrorReporter shared-entry and validation cases")
struct ErrorReporterSharedAndValidationTests {
    // MARK: - Shared-entry conflicts

    @Test("sharedEntryExists names the entry and points at link or rotate")
    func sharedEntryExists() {
        let report = ErrorReporter.makeReport(for: VaultError.sharedEntryExists(id: "ANTHROPIC"))
        #expect(report.code == .userError)
        #expect(report.message.contains("ANTHROPIC"))
        #expect(report.remediation?.contains("rotate --shared ANTHROPIC") == true)
    }

    @Test("sharedEntryLinked lists every linker as scope/key and offers --force")
    func sharedEntryLinkedListsLinkers() {
        let error = VaultError.sharedEntryLinked(
            id: "ANTHROPIC",
            linkers: [("kanyo-dev", "ANTHROPIC_API_KEY"), ("nest-cam", "ANTHROPIC_API_KEY")]
        )
        let report = ErrorReporter.makeReport(for: error)
        #expect(report.code == .userError)
        #expect(report.message.contains("kanyo-dev/ANTHROPIC_API_KEY"))
        #expect(report.message.contains("nest-cam/ANTHROPIC_API_KEY"))
        #expect(report.remediation?.contains("unlink") == true)
        #expect(report.remediation?.contains("--force") == true)
    }

    @Test("sharedEntryLinked renders a single linker without a separator")
    func sharedEntryLinkedSingleLinker() {
        let error = VaultError.sharedEntryLinked(
            id: "OPENAI", linkers: [("solo", "OPENAI_API_KEY")])
        let report = ErrorReporter.makeReport(for: error)
        #expect(report.message.contains("solo/OPENAI_API_KEY"))
        #expect(report.message.contains(", ") == false)
    }

    // MARK: - Validation rejections

    @Test("invalidIdentifier names the kind and the offending value")
    func invalidIdentifierWithoutSource() {
        let error = VaultError.invalidIdentifier(kind: .scope, value: "../escape", source: nil)
        let report = ErrorReporter.makeReport(for: error)
        #expect(report.code == .userError)
        #expect(report.message.contains("../escape"))
        #expect(report.message.contains(IdentifierKind.scope.rawValue))
        #expect(report.message.contains("read from") == false)
        #expect(report.remediation?.contains("path separators") == true)
    }

    @Test("invalidIdentifier names the source file when the value came from one")
    func invalidIdentifierWithSource() {
        let marker = URL(fileURLWithPath: "/projects/kanyo/.sharibako")
        let error = VaultError.invalidIdentifier(kind: .key, value: "BAD/KEY", source: marker)
        let report = ErrorReporter.makeReport(for: error)
        #expect(report.message.contains("BAD/KEY"))
        #expect(report.message.contains("read from /projects/kanyo/.sharibako"))
    }

    @Test("remoteURLRejected names the URL, the reason, and the accepted forms")
    func remoteURLRejected() {
        let error = VaultError.remoteURLRejected(
            url: "ftp://example.invalid/vault.git", reason: "unsupported scheme")
        let report = ErrorReporter.makeReport(for: error)
        #expect(report.code == .userError)
        #expect(report.message.contains("ftp://example.invalid/vault.git"))
        #expect(report.message.contains("unsupported scheme"))
        #expect(report.remediation?.contains("scp-style") == true)
    }
}
