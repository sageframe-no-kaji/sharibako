import Foundation
import Testing

@testable import SharibakoCore

/// Tests for `VaultCore.createScope` — the AT-02 addition that lets the
/// Materializer create empty scopes without going through file-level layout code.
@Suite("VaultCore Create Scope")
struct VaultCoreCreateScopeTests {
    @Test("createScope creates the directory and a valid scope.yaml")
    func writesLayout() throws {
        try VaultTestSupport.withEphemeralVault { vault in
            let core = try VaultCore(vaultURL: vault)
            try core.createScope("bento", type: .projectDev, displayName: "Bento")
            let scopes = try core.listScopes()
            #expect(scopes.count == 1)
            #expect(scopes[0].identity == "bento")
            #expect(scopes[0].type == .projectDev)
            #expect(scopes[0].displayName == "Bento")
        }
    }

    @Test("createScope throws scopeAlreadyExists when the scope is already present")
    func rejectsDuplicate() throws {
        try VaultTestSupport.withEphemeralVault { vault in
            let core = try VaultCore(vaultURL: vault)
            try core.createScope("bento", type: .projectDev)
            #expect(throws: VaultError.self) {
                try core.createScope("bento", type: .projectDev)
            }
        }
    }
}
