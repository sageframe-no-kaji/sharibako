import Foundation
import Testing

@testable import SharibakoCLI
@testable import SharibakoCore

@Suite("ListCommand")
struct ListCommandTests {
    // MARK: - list (scopes)

    @Test("list returns empty when vault has no scopes")
    func listEmpty() throws {
        try CLITestSupport.withEphemeralVaultAndFileKey { vaultURL, _ in
            let vault = try VaultCore(vaultURL: vaultURL)
            let ids = try vault.listScopes().map(\.identity)
            #expect(ids.isEmpty)
        }
    }

    @Test("list returns scope IDs sorted alphabetically")
    func listScopes() throws {
        try CLITestSupport.withEphemeralVaultAndFileKey { vaultURL, _ in
            try CLITestSupport.writeScope("zebra", in: vaultURL)
            try CLITestSupport.writeScope("alpha", in: vaultURL)
            let vault = try VaultCore(vaultURL: vaultURL)
            let ids = try vault.listScopes().map(\.identity)
            #expect(ids == ["alpha", "zebra"])
        }
    }

    @Test("list --json emits a JSON array of scope IDs")
    func listScopesJSON() throws {
        try CLITestSupport.withEphemeralVaultAndFileKey { vaultURL, _ in
            try CLITestSupport.writeScope("myapp", in: vaultURL)
            let vault = try VaultCore(vaultURL: vaultURL)
            let ids = try vault.listScopes().map(\.identity)

            let renderer = OutputRenderer(json: true, color: false)
            let json = try renderer.encodeJSON(ids)
            let decoded = try JSONDecoder().decode([String].self, from: Data(json.utf8))
            #expect(decoded == ["myapp"])
        }
    }

    // MARK: - list --shared

    @Test("list --shared returns empty when vault has no shared entries")
    func listSharedEmpty() throws {
        try CLITestSupport.withEphemeralVaultAndFileKey { vaultURL, _ in
            let vault = try VaultCore(vaultURL: vaultURL)
            let ids = try vault.listShared()
            #expect(ids.isEmpty)
        }
    }

    @Test("list --shared returns shared entry IDs sorted alphabetically")
    func listSharedEntries() throws {
        try CLITestSupport.withEphemeralVaultAndFileKey { vaultURL, _ in
            // Plant placeholder .age files in shared/.
            let sharedDir = VaultLayout.sharedDirectoryURL(in: vaultURL)
            try FileManager.default.createDirectory(at: sharedDir, withIntermediateDirectories: true)
            try Data([0]).write(to: sharedDir.appendingPathComponent("OPENAI_API_KEY.age"))
            try Data([0]).write(to: sharedDir.appendingPathComponent("DATABASE_URL.age"))

            let vault = try VaultCore(vaultURL: vaultURL)
            let ids = try vault.listShared()
            #expect(ids == ["DATABASE_URL", "OPENAI_API_KEY"])
        }
    }

    @Test("list --shared --json emits a JSON array of shared entry IDs")
    func listSharedJSON() throws {
        try CLITestSupport.withEphemeralVaultAndFileKey { vaultURL, _ in
            let sharedDir = VaultLayout.sharedDirectoryURL(in: vaultURL)
            try FileManager.default.createDirectory(at: sharedDir, withIntermediateDirectories: true)
            try Data([0]).write(to: sharedDir.appendingPathComponent("TOKEN.age"))

            let vault = try VaultCore(vaultURL: vaultURL)
            let ids = try vault.listShared()

            let renderer = OutputRenderer(json: true, color: false)
            let json = try renderer.encodeJSON(ids)
            let decoded = try JSONDecoder().decode([String].self, from: Data(json.utf8))
            #expect(decoded == ["TOKEN"])
        }
    }
}
