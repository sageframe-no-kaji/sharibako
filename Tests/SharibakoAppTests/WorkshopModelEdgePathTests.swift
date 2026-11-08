import Foundation
import Testing

@testable import Sharibako
@testable import SharibakoCore

/// Edge paths of the Workshop model that the per-feature suites step over:
/// the two remaining dismiss intents, the drift cache's give-up branch, the
/// "nothing drifted" answer, and the `VaultError` cases the error-message
/// mapper renders through its tail arms.
///
/// All keyless except the secret-deletion staging leg, which needs a real
/// secret and so runs through the file-key fixture — no Keychain either way.
@MainActor
@Suite("WorkshopModel edge paths")
struct WorkshopModelEdgePathTests {
    private func model(vault: URL, ageKey: URL? = nil) -> WorkshopModel {
        var environment = ["SHARIBAKO_VAULT": vault.path]
        if let ageKey { environment["SHARIBAKO_AGE_KEY"] = ageKey.path }
        return WorkshopModel(environment: environment, home: URL(fileURLWithPath: "/Users/nobody"))
    }

    /// A report whose owned keys all match — drift-free by construction.
    private static func cleanReport(_ scopeID: String) -> DriftReport {
        DriftReport(
            scopeID: scopeID,
            path: URL(fileURLWithPath: "/tmp/\(scopeID)/.env"),
            owned: [.match(key: "DB")],
            parseWarnings: []
        )
    }

    // MARK: - Dismiss intents

    @Test("dismissSecretDeletion clears the pending deletion without deleting")
    func dismissSecretDeletionClears() throws {
        try AppAgeKeyFixture.withEphemeralKey { fixture in
            try WorkshopTestSupport.withTempVault { vault in
                try WorkshopTestSupport.writeScope("alpha", type: .other, in: vault)
                let core = try VaultCore(vaultURL: vault, ageKeyURL: fixture.privateKeyURL)
                try core.addSecret("DB", value: "postgres://vault", inScope: "alpha")

                let model = model(vault: vault, ageKey: fixture.privateKeyURL)
                model.selectedScopeID = "alpha"
                model.selectedSecretKey = "DB"
                model.requestDeleteSelectedSecret()
                #expect(model.pendingSecretDeletion != nil)

                model.dismissSecretDeletion()

                #expect(model.pendingSecretDeletion == nil)
                // The secret survives a dismissal.
                #expect(try core.inspect("alpha").map(\.key) == ["DB"])
            }
        }
    }

    @Test("dismissAllStale clears the staged plan without writing anything")
    func dismissAllStaleClears() throws {
        try WorkshopTestSupport.withTempVault { vault in
            try WorkshopTestSupport.writeScope("alpha", type: .other, in: vault)
            let model = model(vault: vault)
            let report = DriftReport(
                scopeID: "alpha",
                path: URL(fileURLWithPath: "/tmp/alpha/.env"),
                owned: [.fileMissing(key: "DB")],
                parseWarnings: []
            )
            model.driftReports = ["alpha": report]
            model.requestMaterializeAllStale()
            #expect(model.allStalePlan != nil)

            model.dismissAllStale()

            #expect(model.allStalePlan == nil)
        }
    }

    // MARK: - Materialize-all-stale with nothing drifted

    @Test("requestMaterializeAllStale says so when every checked scope is in sync")
    func nothingToReconcile() throws {
        try WorkshopTestSupport.withTempVault { vault in
            try WorkshopTestSupport.writeScope("alpha", type: .other, in: vault)
            let model = model(vault: vault)
            model.driftReports = ["alpha": Self.cleanReport("alpha")]

            model.requestMaterializeAllStale()

            #expect(model.allStalePlan == nil)
            #expect(model.statusMessage == "Nothing to reconcile — every checked scope is in sync.")
        }
    }

    // MARK: - Drift cache give-up branch

    @Test("markScopeInSync drops the entry when the scope can no longer be read")
    func markScopeInSyncDropsUnreadableScope() throws {
        try WorkshopTestSupport.withTempVault { vault in
            let model = model(vault: vault)
            // A cached report for a scope that does not exist in the vault:
            // `inspect` throws, so the stale entry is dropped rather than kept.
            model.driftReports = ["ghost": Self.cleanReport("ghost")]

            model.markScopeInSync("ghost")

            #expect(model.driftReports["ghost"] == nil)
        }
    }

    @Test("markScopeInSync is a no-op for a scope with no cached report")
    func markScopeInSyncNoOpWithoutReport() throws {
        try WorkshopTestSupport.withTempVault { vault in
            try WorkshopTestSupport.writeScope("alpha", type: .other, in: vault)
            let model = model(vault: vault)

            model.markScopeInSync("alpha")

            #expect(model.driftReports.isEmpty)
        }
    }

    // MARK: - Error message tail arms

    @Test("message renders an age failure with the truncated stderr")
    func messageForAgeInvocationFailed() {
        let message = WorkshopModel.message(
            for: VaultError.ageInvocationFailed(exitCode: 2, stderr: "no identity matched"))
        #expect(
            message.hasPrefix("Encryption failed:") || message.hasPrefix("Decryption failed:")
                || message.hasPrefix("This key cannot read"))
        #expect(
            WorkshopModel.ageFailureMessage(stderr: "age: error: no identity matched any of the recipients")
                .hasPrefix("This key cannot read these secrets"))
        #expect(
            WorkshopModel.ageFailureMessage(stderr: "age: error: failed to decrypt").hasPrefix("Decryption failed:"))
        #expect(WorkshopModel.ageFailureMessage(stderr: "age: error: bad recipient").hasPrefix("Encryption failed:"))
        #expect(message.contains("different key"))
    }

    @Test("message truncates a long age stderr to 120 characters")
    func messageTruncatesLongStderr() {
        let long = String(repeating: "x", count: 400)
        let message = WorkshopModel.message(
            for: VaultError.ageInvocationFailed(exitCode: 2, stderr: long))
        #expect(message.contains(String(repeating: "x", count: 120)))
        #expect(message.contains(String(repeating: "x", count: 121)) == false)
    }

    @Test("message falls through to a generic vault error for unnamed cases")
    func messageForUnnamedVaultError() {
        let message = WorkshopModel.message(for: VaultError.shellNotFound(name: "age"))
        #expect(message.hasPrefix("Vault error:"))
    }

    @Test("message names a non-VaultError as unexpected")
    func messageForForeignError() {
        struct Boom: Error {}
        #expect(WorkshopModel.message(for: Boom()).hasPrefix("Unexpected error:"))
    }
}
