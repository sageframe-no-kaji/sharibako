import Foundation
import Testing

@testable import SharibakoCore

/// Tests for `VaultCore.deleteScope` and `VaultCore.deleteSharedEntry` — the
/// ho-06.7 destructive verbs.
///
/// Like the other filesystem suites, nothing here needs `age`: deletion removes
/// files, it never decrypts them.
@Suite("VaultCore Delete")
struct VaultCoreDeleteTests {
    // MARK: - deleteScope

    @Test("deleteScope removes the scope directory and only it")
    func deleteScopeRemovesTree() throws {
        try VaultTestSupport.withEphemeralVault { vault in
            try VaultTestSupport.writeScope("kanyo-dev", type: .projectDev, in: vault)
            try VaultTestSupport.writeScope("glassroom", type: .projectDev, in: vault)
            try VaultTestSupport.writePlaceholderAge("OPENAI_API_KEY", inScope: "kanyo-dev", in: vault)
            try VaultTestSupport.writeSharedPlaceholderAge("openai-personal", in: vault)
            let core = try VaultCore(vaultURL: vault)

            try core.deleteScope("kanyo-dev")

            let scopeDir = try VaultLayout.scopeDirectoryURL("kanyo-dev", in: vault)
            #expect(!FileManager.default.fileExists(atPath: scopeDir.path))
            // The sibling scope and the shared pool are untouched.
            #expect(try core.listScopes().map(\.identity) == ["glassroom"])
            let sharedURL = try VaultLayout.sharedEntryURL("openai-personal", in: vault)
            #expect(FileManager.default.fileExists(atPath: sharedURL.path))
        }
    }

    @Test("deleteScope throws scopeNotFound for an absent scope")
    func deleteScopeAbsent() throws {
        try VaultTestSupport.withEphemeralVault { vault in
            let core = try VaultCore(vaultURL: vault)
            let error = #expect(throws: VaultError.self) {
                try core.deleteScope("ghost")
            }
            guard case .scopeNotFound(let id) = error else {
                Issue.record("expected scopeNotFound, got \(String(describing: error))")
                return
            }
            #expect(id == "ghost")
        }
    }

    @Test("deleteScope throws invalidIdentifier for an out-of-grammar id")
    func deleteScopeInvalidID() throws {
        try VaultTestSupport.withEphemeralVault { vault in
            let core = try VaultCore(vaultURL: vault)
            let error = #expect(throws: VaultError.self) {
                try core.deleteScope("../escape")
            }
            guard case .invalidIdentifier(let kind, _, _) = error else {
                Issue.record("expected invalidIdentifier, got \(String(describing: error))")
                return
            }
            #expect(kind == .scope)
        }
    }

    // MARK: - deleteSharedEntry

    @Test("deleteSharedEntry removes an unlinked entry")
    func deleteSharedUnlinked() throws {
        try VaultTestSupport.withEphemeralVault { vault in
            try VaultTestSupport.writeSharedPlaceholderAge("openai-personal", in: vault)
            let core = try VaultCore(vaultURL: vault)

            try core.deleteSharedEntry("openai-personal")

            let sharedURL = try VaultLayout.sharedEntryURL("openai-personal", in: vault)
            #expect(!FileManager.default.fileExists(atPath: sharedURL.path))
        }
    }

    @Test("deleteSharedEntry refuses a linked entry and names the linkers")
    func deleteSharedLinkedRefused() throws {
        try VaultTestSupport.withEphemeralVault { vault in
            try VaultTestSupport.writeScope("kanyo-dev", type: .projectDev, in: vault)
            try VaultTestSupport.writeSharedPlaceholderAge("openai-personal", in: vault)
            let core = try VaultCore(vaultURL: vault)
            try core.link("OPENAI_API_KEY", inScope: "kanyo-dev", toShared: "openai-personal")

            let error = #expect(throws: VaultError.self) {
                try core.deleteSharedEntry("openai-personal")
            }
            guard case .sharedEntryLinked(let id, let linkers) = error else {
                Issue.record("expected sharedEntryLinked, got \(String(describing: error))")
                return
            }
            #expect(id == "openai-personal")
            #expect(linkers.count == 1)
            #expect(linkers.first?.scopeID == "kanyo-dev")
            #expect(linkers.first?.key == "OPENAI_API_KEY")
            // Refused means nothing removed.
            let sharedURL = try VaultLayout.sharedEntryURL("openai-personal", in: vault)
            #expect(FileManager.default.fileExists(atPath: sharedURL.path))
        }
    }

    @Test("deleteSharedEntry with force orphans the linkers")
    func deleteSharedForcedOrphans() throws {
        try VaultTestSupport.withEphemeralVault { vault in
            try VaultTestSupport.writeScope("kanyo-dev", type: .projectDev, in: vault)
            try VaultTestSupport.writeSharedPlaceholderAge("openai-personal", in: vault)
            let core = try VaultCore(vaultURL: vault)
            try core.link("OPENAI_API_KEY", inScope: "kanyo-dev", toShared: "openai-personal")

            try core.deleteSharedEntry("openai-personal", force: true)

            let sharedURL = try VaultLayout.sharedEntryURL("openai-personal", in: vault)
            #expect(!FileManager.default.fileExists(atPath: sharedURL.path))
            // The link is deliberately left dangling for the orphan/heal surfaces.
            let linkURL = try VaultLayout.linkURL("OPENAI_API_KEY", inScope: "kanyo-dev", in: vault)
            #expect(FileManager.default.fileExists(atPath: linkURL.path))
        }
    }

    @Test("deleteSharedEntry throws sharedEntryNotFound for an absent entry")
    func deleteSharedAbsent() throws {
        try VaultTestSupport.withEphemeralVault { vault in
            let core = try VaultCore(vaultURL: vault)
            let error = #expect(throws: VaultError.self) {
                try core.deleteSharedEntry("ghost")
            }
            guard case .sharedEntryNotFound(let id) = error else {
                Issue.record("expected sharedEntryNotFound, got \(String(describing: error))")
                return
            }
            #expect(id == "ghost")
        }
    }
}
