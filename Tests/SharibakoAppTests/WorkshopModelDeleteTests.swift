import Foundation
import Testing

@testable import Sharibako
@testable import SharibakoCore

/// `WorkshopModel` scope-deletion intent tests (ho-06.7).
///
/// Deletion is keyless — no Keychain, no age key, no Touch ID — so most of these
/// use plain temp vaults; only the secret-count leg seeds a secret through the
/// file-key fixture.
@MainActor
@Suite("WorkshopModel Delete")
struct WorkshopModelDeleteTests {
    private func model(vault: URL, ageKey: URL? = nil) -> WorkshopModel {
        var environment = ["SHARIBAKO_VAULT": vault.path]
        if let ageKey { environment["SHARIBAKO_AGE_KEY"] = ageKey.path }
        return WorkshopModel(environment: environment, home: URL(fileURLWithPath: "/Users/nobody"))
    }

    @Test("requestDeleteSelectedScope stages a pending deletion for the selected scope")
    func requestStagesPending() throws {
        try WorkshopTestSupport.withTempVault { vault in
            try WorkshopTestSupport.writeScope("alpha", type: .other, in: vault)
            let model = model(vault: vault)
            model.selectedScopeID = "alpha"

            model.requestDeleteSelectedScope()

            #expect(
                model.pendingScopeDeletion
                    == WorkshopModel.ScopeDeletion(scopeID: "alpha", secretCount: 0))
        }
    }

    @Test("requestDeleteSelectedScope is a no-op when nothing is selected")
    func requestNoOpWithoutSelection() throws {
        try WorkshopTestSupport.withTempVault { vault in
            try WorkshopTestSupport.writeScope("alpha", type: .other, in: vault)
            let model = model(vault: vault)

            model.requestDeleteSelectedScope()

            #expect(model.pendingScopeDeletion == nil)
        }
    }

    @Test("confirmDeleteScope deletes the scope, clears selection, and refreshes")
    func confirmDeletes() throws {
        try WorkshopTestSupport.withTempVault { vault in
            try WorkshopTestSupport.writeScope("alpha", type: .other, in: vault)
            try WorkshopTestSupport.writeScope("beta", type: .other, in: vault)
            let model = model(vault: vault)
            model.selectedScopeID = "alpha"
            model.requestDeleteSelectedScope()

            model.confirmDeleteScope()

            #expect(model.pendingScopeDeletion == nil)
            #expect(model.scopes.map(\.identity) == ["beta"])
            #expect(model.selectedScopeID == nil)
            #expect(model.statusMessage?.hasPrefix("Deleted scope alpha") == true)
            #expect(model.errorMessage == nil)
        }
    }

    @Test("dismissScopeDeletion clears the pending deletion without deleting")
    func dismissClears() throws {
        try WorkshopTestSupport.withTempVault { vault in
            try WorkshopTestSupport.writeScope("alpha", type: .other, in: vault)
            let model = model(vault: vault)
            model.selectedScopeID = "alpha"
            model.requestDeleteSelectedScope()

            model.dismissScopeDeletion()

            #expect(model.pendingScopeDeletion == nil)
            #expect(model.scopes.map(\.identity) == ["alpha"])
        }
    }

    @Test("confirmDeleteScope surfaces an error and stays consistent on an absent scope")
    func confirmAbsentSurfacesError() throws {
        try WorkshopTestSupport.withTempVault { vault in
            let model = model(vault: vault)
            // Stage a deletion for a scope that isn't there, then confirm.
            model.pendingScopeDeletion = WorkshopModel.ScopeDeletion(scopeID: "ghost", secretCount: 0)

            model.confirmDeleteScope()

            #expect(model.pendingScopeDeletion == nil)
            #expect(model.errorMessage != nil)
        }
    }

    @Test("the staged deletion's secret count reflects the scope's secrets")
    func stagedCountReflectsSecrets() throws {
        try AppAgeKeyFixture.withEphemeralKey { fixture in
            try WorkshopTestSupport.withTempVault { vault in
                try WorkshopTestSupport.writeScope("alpha", type: .projectDev, in: vault)
                let core = try VaultCore(vaultURL: vault, ageKeyURL: fixture.privateKeyURL)
                try core.addSecret("K1", value: "v1", inScope: "alpha")
                try core.addSecret("K2", value: "v2", inScope: "alpha")
                let model = model(vault: vault, ageKey: fixture.privateKeyURL)
                model.selectedScopeID = "alpha"

                model.requestDeleteSelectedScope()
                #expect(model.pendingScopeDeletion?.secretCount == 2)

                model.confirmDeleteScope()
                #expect(try VaultCore(vaultURL: vault).listScopes().isEmpty)
            }
        }
    }
}
