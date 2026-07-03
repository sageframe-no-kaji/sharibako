import Foundation
import Testing

@testable import SharibakoCLI
@testable import SharibakoCore

@Suite("StatusCommand")
struct StatusCommandTests {
    // MARK: - fetchEntries

    @Test("fetchEntries returns empty array for a vault with no scopes")
    func fetchEntriesEmpty() throws {
        try CLITestSupport.withEphemeralVaultAndFileKey { vaultURL, _ in
            let vault = try VaultCore(vaultURL: vaultURL)
            let cmd = try StatusCommand.parse([])
            let entries = try cmd.fetchEntries(vault: vault)
            #expect(entries.isEmpty)
        }
    }

    @Test("fetchEntries returns one entry per scope")
    func fetchEntriesMultipleScopes() throws {
        try CLITestSupport.withEphemeralVaultAndFileKey { vaultURL, _ in
            try CLITestSupport.writeScope("scope-a", type: .projectDev, in: vaultURL)
            try CLITestSupport.writeScope("scope-b", type: .projectProd, in: vaultURL)

            let vault = try VaultCore(vaultURL: vaultURL)
            let cmd = try StatusCommand.parse([])
            let entries = try cmd.fetchEntries(vault: vault)
            #expect(entries.count == 2)
            #expect(entries.map(\.identity).sorted() == ["scope-a", "scope-b"])
        }
    }

    @Test("fetchEntries reflects the scope's type")
    func fetchEntriesType() throws {
        try CLITestSupport.withEphemeralVaultAndFileKey { vaultURL, _ in
            try CLITestSupport.writeScope("svc", type: .service, in: vaultURL)
            let vault = try VaultCore(vaultURL: vaultURL)
            let cmd = try StatusCommand.parse([])
            let entries = try cmd.fetchEntries(vault: vault)
            #expect(entries.first?.type == "service")
        }
    }

    @Test("fetchEntries includes secret count")
    func fetchEntriesSecretCount() throws {
        try CLITestSupport.withEphemeralVaultAndFileKey { vaultURL, _ in
            try CLITestSupport.writeScope("kanyo", type: .projectDev, in: vaultURL)
            // Plant two placeholder .age files.
            let scopeDir = try VaultLayout.scopeDirectoryURL("kanyo", in: vaultURL)
            try Data([0]).write(to: scopeDir.appendingPathComponent("KEY_A.age"))
            try Data([0]).write(to: scopeDir.appendingPathComponent("KEY_B.age"))

            let vault = try VaultCore(vaultURL: vaultURL)
            let cmd = try StatusCommand.parse([])
            let entries = try cmd.fetchEntries(vault: vault)
            #expect(entries.first?.secretCount == 2)
        }
    }

    // MARK: - JSON round-trip

    @Test("status --json emits a JSON array that decodes correctly (empty vault)")
    func jsonRoundTripEmpty() throws {
        let entries: [ScopeStatusEntry] = []
        let renderer = OutputRenderer(json: true, color: false)
        let json = try renderer.encodeJSON(entries)
        let decoded = try JSONDecoder().decode([ScopeStatusEntry].self, from: Data(json.utf8))
        #expect(decoded.isEmpty)
    }

    @Test("status --json emits a JSON array that round-trips scope data")
    func jsonRoundTripWithScopes() throws {
        try CLITestSupport.withEphemeralVaultAndFileKey { vaultURL, _ in
            try CLITestSupport.writeScope("alpha", type: .machine, in: vaultURL)
            let vault = try VaultCore(vaultURL: vaultURL)
            let cmd = try StatusCommand.parse([])
            let entries = try cmd.fetchEntries(vault: vault)

            let renderer = OutputRenderer(json: true, color: false)
            let json = try renderer.encodeJSON(entries)
            let decoded = try JSONDecoder().decode([ScopeStatusEntry].self, from: Data(json.utf8))
            #expect(decoded.count == 1)
            #expect(decoded.first?.identity == "alpha")
            #expect(decoded.first?.type == "machine")
        }
    }

    // MARK: - Table rendering

    @Test("status table shows two rows for two scopes")
    func tableShowsTwoRows() throws {
        try CLITestSupport.withEphemeralVaultAndFileKey { vaultURL, _ in
            try CLITestSupport.writeScope("scope-x", type: .projectDev, in: vaultURL)
            try CLITestSupport.writeScope("scope-y", type: .projectProd, in: vaultURL)

            let vault = try VaultCore(vaultURL: vaultURL)
            let cmd = try StatusCommand.parse([])
            let entries = try cmd.fetchEntries(vault: vault)

            let renderer = OutputRenderer(json: false, color: false)
            let table = renderer.table(
                headers: ["SCOPE", "TYPE", "SECRETS"],
                rows: entries.map { [$0.identity, $0.type, String($0.secretCount)] }
            )
            #expect(table.contains("scope-x"))
            #expect(table.contains("scope-y"))
        }
    }

    // MARK: - composeOutput (scope filter vs. JSON branch)

    @Test("status <scope> --json returns only the requested scope")
    func scopeArgumentFiltersJSON() throws {
        try CLITestSupport.withEphemeralVaultAndFileKey { vaultURL, _ in
            try CLITestSupport.writeScope("wanted", type: .projectDev, in: vaultURL)
            try CLITestSupport.writeScope("other", type: .projectDev, in: vaultURL)

            let vault = try VaultCore(vaultURL: vaultURL)
            let cmd = try StatusCommand.parse(["wanted", "--json"])
            let output = try cmd.composeOutput(
                vault: vault, renderer: OutputRenderer(json: true, color: false))

            let decoded = try JSONDecoder().decode(
                [ScopeStatusEntry].self, from: Data(output.utf8))
            #expect(decoded.map(\.identity) == ["wanted"])
        }
    }

    @Test("status <unknown-scope> --json throws scopeNotFound instead of listing everything")
    func unknownScopeThrowsUnderJSON() throws {
        try CLITestSupport.withEphemeralVaultAndFileKey { vaultURL, _ in
            try CLITestSupport.writeScope("real", type: .projectDev, in: vaultURL)
            let vault = try VaultCore(vaultURL: vaultURL)
            let cmd = try StatusCommand.parse(["ghost", "--json"])
            let error = #expect(throws: VaultError.self) {
                _ = try cmd.composeOutput(
                    vault: vault, renderer: OutputRenderer(json: true, color: false))
            }
            guard case .scopeNotFound(let id) = error else {
                Issue.record("expected scopeNotFound, got \(String(describing: error))")
                return
            }
            #expect(id == "ghost")
        }
    }

    @Test("status <unknown-scope> on an empty vault throws instead of exiting 0")
    func unknownScopeOnEmptyVaultThrows() throws {
        try CLITestSupport.withEphemeralVaultAndFileKey { vaultURL, _ in
            let vault = try VaultCore(vaultURL: vaultURL)
            let cmd = try StatusCommand.parse(["ghost"])
            #expect(throws: VaultError.self) {
                _ = try cmd.composeOutput(
                    vault: vault, renderer: OutputRenderer(json: false, color: false))
            }
        }
    }
}

/// `composeOutput` plain-mode branches and the end-to-end `run()` path, split
/// out of `StatusCommandTests` to respect the `type_body_length` limit.
@Suite("StatusCommand — output composition")
struct StatusCommandOutputTests {
    @Test("composeOutput reports an empty vault in plain mode")
    func plainEmptyVault() throws {
        try CLITestSupport.withEphemeralVaultAndFileKey { vaultURL, _ in
            let vault = try VaultCore(vaultURL: vaultURL)
            let cmd = try StatusCommand.parse([])
            let output = try cmd.composeOutput(
                vault: vault, renderer: OutputRenderer(json: false, color: false))
            #expect(output == "No scopes in vault.")
        }
    }

    @Test("composeOutput renders the SCOPE/TYPE/SECRETS table in plain mode")
    func plainTable() throws {
        try CLITestSupport.withEphemeralVaultAndFileKey { vaultURL, _ in
            try CLITestSupport.writeScope("kanyo", type: .projectDev, in: vaultURL)
            let scopeDir = try VaultLayout.scopeDirectoryURL("kanyo", in: vaultURL)
            try Data([0]).write(to: scopeDir.appendingPathComponent("API_KEY.age"))

            let vault = try VaultCore(vaultURL: vaultURL)
            let cmd = try StatusCommand.parse([])
            let output = try cmd.composeOutput(
                vault: vault, renderer: OutputRenderer(json: false, color: false))
            #expect(output.contains("SCOPE"))
            #expect(output.contains("kanyo"))
            #expect(output.contains("project-dev"))
            #expect(output.contains("1"))
        }
    }

    @Test("composeOutput --json without a scope argument lists every scope")
    func jsonAllScopes() throws {
        try CLITestSupport.withEphemeralVaultAndFileKey { vaultURL, _ in
            try CLITestSupport.writeScope("scope-a", type: .projectDev, in: vaultURL)
            try CLITestSupport.writeScope("scope-b", type: .service, in: vaultURL)

            let vault = try VaultCore(vaultURL: vaultURL)
            let cmd = try StatusCommand.parse(["--json"])
            let output = try cmd.composeOutput(
                vault: vault, renderer: OutputRenderer(json: true, color: false))
            let decoded = try JSONDecoder().decode([ScopeStatusEntry].self, from: Data(output.utf8))
            #expect(decoded.map(\.identity).sorted() == ["scope-a", "scope-b"])
        }
    }

    @Test("status <scope> table shows local values and link targets by kind")
    func scopeTableShowsKinds() throws {
        try CLITestSupport.withEphemeralVaultAndFileKey { vaultURL, _ in
            try CLITestSupport.writeScope("kanyo", type: .projectDev, in: vaultURL)
            let scopeDir = try VaultLayout.scopeDirectoryURL("kanyo", in: vaultURL)
            try Data([0]).write(to: scopeDir.appendingPathComponent("LOCAL_KEY.age"))
            // link() requires an existing target (ho-04.10) — placeholder suffices.
            try Data([0]).write(to: VaultLayout.sharedEntryURL("OPENAI_API_KEY", in: vaultURL))
            let vault = try VaultCore(vaultURL: vaultURL)
            try vault.link("LINKED_KEY", inScope: "kanyo", toShared: "OPENAI_API_KEY")

            let cmd = try StatusCommand.parse(["kanyo"])
            let output = try cmd.composeOutput(
                vault: vault, renderer: OutputRenderer(json: false, color: false))
            #expect(output.contains("LOCAL_KEY"))
            #expect(output.contains("local"))
            #expect(output.contains("LINKED_KEY"))
            #expect(output.contains("→ OPENAI_API_KEY"))
        }
    }

    @Test("status runs end-to-end against an ephemeral vault")
    func statusEndToEnd() async throws {
        try await CLITestSupport.withEphemeralVaultAndFileKeyAsync { vaultURL, _ in
            try CLITestSupport.writeScope("e2e", type: .projectDev, in: vaultURL)
            try await CLITestSupport.runCommand(["status", "--vault", vaultURL.path])
        }
    }
}
