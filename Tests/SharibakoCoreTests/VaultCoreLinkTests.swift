import Foundation
import Testing

@testable import SharibakoCore

/// Tests for `VaultCore.link` — file writes, `.age` replacement, and the
/// existing-target requirement (ho-04.10).
///
/// Moved out of `VaultCoreFilesystemTests` to keep each test struct under the
/// type-body-length ceiling. Like that suite, nothing here needs `age`.
@Suite("VaultCore Link")
struct VaultCoreLinkTests {
    @Test("link creates the .link file with correct content")
    func linkWritesFile() throws {
        try VaultTestSupport.withEphemeralVault { vault in
            try VaultTestSupport.writeScope("kanyo-dev", type: .projectDev, in: vault)
            try VaultTestSupport.writeSharedPlaceholderAge("openai-personal", in: vault)
            let core = try VaultCore(vaultURL: vault)
            try core.link("OPENAI_API_KEY", inScope: "kanyo-dev", toShared: "openai-personal")

            let linkURL = try VaultLayout.linkURL("OPENAI_API_KEY", inScope: "kanyo-dev", in: vault)
            let contents = try String(contentsOf: linkURL, encoding: .utf8)
            #expect(contents == "openai-personal")
        }
    }

    @Test("link deletes a pre-existing .age file for the same key")
    func linkReplacesAge() throws {
        try VaultTestSupport.withEphemeralVault { vault in
            try VaultTestSupport.writeScope("kanyo-dev", type: .projectDev, in: vault)
            try VaultTestSupport.writeSharedPlaceholderAge("openai-personal", in: vault)
            try VaultTestSupport.writePlaceholderAge("OPENAI_API_KEY", inScope: "kanyo-dev", in: vault)
            let ageURL = try VaultLayout.secretURL("OPENAI_API_KEY", inScope: "kanyo-dev", in: vault)
            #expect(FileManager.default.fileExists(atPath: ageURL.path))

            let core = try VaultCore(vaultURL: vault)
            try core.link("OPENAI_API_KEY", inScope: "kanyo-dev", toShared: "openai-personal")

            #expect(!FileManager.default.fileExists(atPath: ageURL.path))
            let infos = try core.inspect("kanyo-dev")
            #expect(infos == [SecretInfo(key: "OPENAI_API_KEY", kind: .link(sharedID: "openai-personal"))])
        }
    }

    @Test("link throws scopeNotFound for an absent scope")
    func linkMissingScope() throws {
        try VaultTestSupport.withEphemeralVault { vault in
            let core = try VaultCore(vaultURL: vault)
            #expect(throws: VaultError.self) {
                try core.link("K", inScope: "ghost", toShared: "openai-personal")
            }
        }
    }

    @Test("link throws sharedEntryNotFound when the target shared entry does not exist (ho-04.10)")
    func linkRejectsDanglingTarget() throws {
        try VaultTestSupport.withEphemeralVault { vault in
            try VaultTestSupport.writeScope("kanyo-dev", type: .projectDev, in: vault)
            let core = try VaultCore(vaultURL: vault)
            let error = #expect(throws: VaultError.self) {
                try core.link("OPENAI_API_KEY", inScope: "kanyo-dev", toShared: "nonexistent")
            }
            guard case .sharedEntryNotFound(let id) = error else {
                Issue.record("expected sharedEntryNotFound, got \(String(describing: error))")
                return
            }
            #expect(id == "nonexistent")
            // No .link file left behind.
            let linkURL = try VaultLayout.linkURL("OPENAI_API_KEY", inScope: "kanyo-dev", in: vault)
            #expect(!FileManager.default.fileExists(atPath: linkURL.path))
        }
    }
}
