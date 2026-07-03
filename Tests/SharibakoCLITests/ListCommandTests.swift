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

    // MARK: - composeOutput

    @Test("composeOutput lists one scope ID per line in plain mode")
    func composeOutputScopesPlain() throws {
        try CLITestSupport.withEphemeralVaultAndFileKey { vaultURL, _ in
            try CLITestSupport.writeScope("zebra", in: vaultURL)
            try CLITestSupport.writeScope("alpha", in: vaultURL)
            let vault = try VaultCore(vaultURL: vaultURL)
            let cmd = try ListCommand.parse([])
            let output = try cmd.composeOutput(
                vault: vault, renderer: OutputRenderer(json: false, color: false))
            #expect(output == "alpha\nzebra")
        }
    }

    @Test("composeOutput reports an empty vault in plain mode")
    func composeOutputScopesEmpty() throws {
        try CLITestSupport.withEphemeralVaultAndFileKey { vaultURL, _ in
            let vault = try VaultCore(vaultURL: vaultURL)
            let cmd = try ListCommand.parse([])
            let output = try cmd.composeOutput(
                vault: vault, renderer: OutputRenderer(json: false, color: false))
            #expect(output == "No scopes.")
        }
    }

    @Test("composeOutput --json emits a decodable array of scope IDs")
    func composeOutputScopesJSON() throws {
        try CLITestSupport.withEphemeralVaultAndFileKey { vaultURL, _ in
            try CLITestSupport.writeScope("myapp", in: vaultURL)
            let vault = try VaultCore(vaultURL: vaultURL)
            let cmd = try ListCommand.parse(["--json"])
            let output = try cmd.composeOutput(
                vault: vault, renderer: OutputRenderer(json: true, color: false))
            let decoded = try JSONDecoder().decode([String].self, from: Data(output.utf8))
            #expect(decoded == ["myapp"])
        }
    }

    @Test("composeOutput --shared lists one shared ID per line in plain mode")
    func composeOutputSharedPlain() throws {
        try CLITestSupport.withEphemeralVaultAndFileKey { vaultURL, _ in
            let sharedDir = VaultLayout.sharedDirectoryURL(in: vaultURL)
            try FileManager.default.createDirectory(at: sharedDir, withIntermediateDirectories: true)
            try Data([0]).write(to: sharedDir.appendingPathComponent("OPENAI_API_KEY.age"))
            try Data([0]).write(to: sharedDir.appendingPathComponent("DATABASE_URL.age"))

            let vault = try VaultCore(vaultURL: vaultURL)
            let cmd = try ListCommand.parse(["--shared"])
            let output = try cmd.composeOutput(
                vault: vault, renderer: OutputRenderer(json: false, color: false))
            #expect(output == "DATABASE_URL\nOPENAI_API_KEY")
        }
    }

    @Test("composeOutput --shared reports an empty shared directory in plain mode")
    func composeOutputSharedEmpty() throws {
        try CLITestSupport.withEphemeralVaultAndFileKey { vaultURL, _ in
            let vault = try VaultCore(vaultURL: vaultURL)
            let cmd = try ListCommand.parse(["--shared"])
            let output = try cmd.composeOutput(
                vault: vault, renderer: OutputRenderer(json: false, color: false))
            #expect(output == "No shared entries.")
        }
    }

    @Test("composeOutput --shared --json emits a decodable array of shared IDs")
    func composeOutputSharedJSON() throws {
        try CLITestSupport.withEphemeralVaultAndFileKey { vaultURL, _ in
            let sharedDir = VaultLayout.sharedDirectoryURL(in: vaultURL)
            try FileManager.default.createDirectory(at: sharedDir, withIntermediateDirectories: true)
            try Data([0]).write(to: sharedDir.appendingPathComponent("TOKEN.age"))

            let vault = try VaultCore(vaultURL: vaultURL)
            let cmd = try ListCommand.parse(["--shared", "--json"])
            let output = try cmd.composeOutput(
                vault: vault, renderer: OutputRenderer(json: true, color: false))
            let decoded = try JSONDecoder().decode([String].self, from: Data(output.utf8))
            #expect(decoded == ["TOKEN"])
        }
    }

    // MARK: - End to end

    @Test("list runs end-to-end against an ephemeral vault")
    func listEndToEnd() async throws {
        try await CLITestSupport.withEphemeralVaultAndFileKeyAsync { vaultURL, _ in
            try CLITestSupport.writeScope("e2e", in: vaultURL)
            try await CLITestSupport.runCommand(["list", "--vault", vaultURL.path])
        }
    }
}
