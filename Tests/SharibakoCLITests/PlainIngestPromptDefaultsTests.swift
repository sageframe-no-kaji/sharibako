import Foundation
import Testing

@testable import SharibakoCLI
@testable import SharibakoCore

/// `PlainIngestPrompt` as the CLI actually constructs it — every seam left at
/// its default rather than injected.
///
/// The rest of the prompt's suite injects all three seams to drive the
/// branching logic, which means the production defaults themselves
/// (`readLine`, `Swift.print`, `TerminalDetector.isInteractiveInput`) are never
/// built. Under a test harness there is no controlling terminal, so a
/// default-constructed prompt must refuse rather than block forever on stdin —
/// which is exactly the ho-04.11 contract.
@Suite("PlainIngestPrompt defaults")
struct PlainIngestPromptDefaultsTests {
    @Test("a default-constructed prompt refuses without a terminal instead of blocking")
    func defaultsRefuseWithoutTTY() throws {
        let prompt = PlainIngestPrompt()
        let detected = DetectedKey(
            key: "API_KEY",
            value: "sk-test",
            sourceFile: URL(fileURLWithPath: "/projects/kanyo/.env"),
            nameMatchedSharedID: nil
        )
        let proposal = ProposedScope(
            directory: URL(fileURLWithPath: "/projects/kanyo"),
            suggestedScopeID: "kanyo-dev",
            suggestedScopeType: .projectDev,
            detectedKeys: [detected],
            suggestedKeysNeedingValues: [],
            parseWarnings: []
        )

        let error = #expect(throws: CLIError.self) {
            _ = try prompt.decisions(for: proposal, sharedIDs: [])
        }
        #expect(error == .notInteractiveTerminal)
    }
}
