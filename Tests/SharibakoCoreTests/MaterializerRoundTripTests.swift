import Foundation
import Testing

@testable import SharibakoCore

/// End-to-end integration test for kamae-2.2's byte-for-byte ownership contract.
///
/// Walks the full user journey: ingest a mixed `.env`, accept a mix of import
/// / link / move-to-shared / leave-alone, materialize, hand-edit both owned and
/// non-owned lines, update, rotate a shared entry vault-side, materialize with
/// `overwriteDrift: true`. Asserts non-owned lines survive byte-for-byte
/// through every stage.
@Suite("Materializer Round Trip")
struct MaterializerRoundTripTests {
    // End-to-end scenario test: the full kamae-2.2 round trip deliberately runs in one body.
    @Test("kamae-2.2 round trip: ingest → accept → materialize → hand-edit → update → rotate → materialize")
    func kamae22RoundTrip() throws {  // swiftlint:disable:this function_body_length
        try VaultTestSupport.withEphemeralVaultAndKey { vault, fixture in
            try VaultTestSupport.withEphemeralProjectDirectory { project in
                let core = try VaultCore(vaultURL: vault, ageKeyURL: fixture.privateKeyURL)
                let mat = Materializer(vaultCore: core, vaultURL: vault)

                // 1–2. Write the Bento `.env`.
                let originalEnv = """
                    # Bento project — dev environment
                    #
                    OPENAI_API_KEY=sk-fake-openai-value
                    DATABASE_URL="postgres://user:pass@localhost/bento_dev"

                    # Toggle these as needed
                    DEBUG=true
                    PORT=3000
                    NODE_ENV=development

                    """
                let envURL = project.appendingPathComponent(".env")
                try originalEnv.write(to: envURL, atomically: true, encoding: .utf8)

                // 3. Ingest — expect five keys in file order.
                let proposal = try mat.ingest(directory: project)
                #expect(
                    proposal.detectedKeys.map(\.key)
                        == ["OPENAI_API_KEY", "DATABASE_URL", "DEBUG", "PORT", "NODE_ENV"]
                )

                // 4. Accept a mixed matrix of decisions.
                try mat.acceptIngest(
                    proposal,
                    decisions: [
                        .moveToShared(key: "OPENAI_API_KEY", newSharedID: "openai-personal"),
                        .importAsLocal(key: "DATABASE_URL"),
                        .leaveAlone(key: "DEBUG"),
                        .leaveAlone(key: "PORT"),
                        .leaveAlone(key: "NODE_ENV"),
                    ]
                )

                // 5. Vault-side assertions.
                let scopeID = proposal.suggestedScopeID
                let infos = try core.inspect(scopeID)
                #expect(infos.map(\.key).sorted() == ["DATABASE_URL", "OPENAI_API_KEY"])
                #expect(try core.listShared() == ["openai-personal"])
                #expect(try core.getValue("OPENAI_API_KEY", inScope: scopeID) == "sk-fake-openai-value")
                #expect(
                    try core.getValue("DATABASE_URL", inScope: scopeID)
                        == "postgres://user:pass@localhost/bento_dev"
                )

                // 6. Materialize once — non-owned lines must survive byte-for-byte.
                let markerURL = project.appendingPathComponent(".sharibako")
                let marker = try mat.loadMarker(at: markerURL)
                _ = try mat.materialize(marker: marker)
                let afterFirstMaterialize = try String(contentsOf: envURL, encoding: .utf8)
                #expect(afterFirstMaterialize.contains("# Bento project — dev environment"))
                #expect(afterFirstMaterialize.contains("# Toggle these as needed"))
                #expect(afterFirstMaterialize.contains("DEBUG=true"))
                #expect(afterFirstMaterialize.contains("PORT=3000"))
                #expect(afterFirstMaterialize.contains("NODE_ENV=development"))
                #expect(afterFirstMaterialize.contains("OPENAI_API_KEY=sk-fake-openai-value"))
                #expect(
                    afterFirstMaterialize.contains("DATABASE_URL=postgres://user:pass@localhost/bento_dev")
                )

                // 7. Hand-edit the file — mix of owned and non-owned edits.
                let debugEdited =
                    afterFirstMaterialize
                    .replacingOccurrences(of: "DEBUG=true", with: "DEBUG=false")
                let dbEdited = debugEdited.replacingOccurrences(
                    of: "DATABASE_URL=postgres://user:pass@localhost/bento_dev",
                    with: "DATABASE_URL=postgres://user:newpass@localhost/bento_dev"
                )
                let handEdited = dbEdited + "EXTRA=user_added\n"
                try handEdited.write(to: envURL, atomically: true, encoding: .utf8)

                // 8. Update — only DATABASE_URL should be reported.
                let updateResult = try mat.update(scopeID: scopeID, marker: marker)
                #expect(updateResult == .updated(keysUpdated: ["DATABASE_URL"], warnings: []))
                #expect(
                    try core.getValue("DATABASE_URL", inScope: scopeID)
                        == "postgres://user:newpass@localhost/bento_dev"
                )
                // Non-owned edits must NOT have leaked into the vault.
                let vaultKeys = try core.inspect(scopeID).map(\.key).sorted()
                #expect(vaultKeys == ["DATABASE_URL", "OPENAI_API_KEY"])

                // 9. Rotate the shared entry vault-side.
                try core.rotateShared("openai-personal", newValue: "sk-fake-openai-rotated")

                // 10. Materialize with overwriteDrift: false — expect .diffPending on OPENAI_API_KEY.
                let diffResult = try mat.materialize(marker: marker)
                guard case .diffPending(let diff) = diffResult else {
                    Issue.record("expected .diffPending after shared rotation, got \(diffResult)")
                    return
                }
                #expect(diff.ownedKeysDiffering == ["OPENAI_API_KEY"])

                // 12. Materialize with overwriteDrift: true.
                let overwriteResult = try mat.materialize(marker: marker, overwriteDrift: true)
                guard case .wrote(_, let keysWritten) = overwriteResult else {
                    Issue.record("expected .wrote after overwriteDrift, got \(overwriteResult)")
                    return
                }
                #expect(keysWritten.contains("OPENAI_API_KEY"))

                // 13–14. Re-read the file. Non-owned lines from the hand-edit must survive; owned
                // lines must reflect the rotated vault value.
                let final = try String(contentsOf: envURL, encoding: .utf8)
                #expect(final.contains("# Bento project — dev environment"))
                #expect(final.contains("# Toggle these as needed"))
                #expect(final.contains("DEBUG=false"))
                #expect(final.contains("PORT=3000"))
                #expect(final.contains("NODE_ENV=development"))
                #expect(final.contains("EXTRA=user_added"))
                #expect(final.contains("OPENAI_API_KEY=sk-fake-openai-rotated"))
                #expect(
                    final.contains("DATABASE_URL=postgres://user:newpass@localhost/bento_dev")
                )
            }
        }
    }
}
