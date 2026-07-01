import Foundation
import Testing

@testable import SharibakoCore

/// Tests for `Materializer.clean`, `Materializer.heal`, and end-to-end round-trip.
///
/// Split from `MaterializerMergeTests.swift` so each test struct stays under the
/// type-body-length linter's ceiling.
@Suite("Materializer Clean/Heal")
struct MaterializerCleanHealTests {
    // MARK: - Clean

    @Test("clean returns .fileMissing when no file exists at the target")
    func cleanFileMissing() throws {
        try VaultTestSupport.withEphemeralVault { vault in
            try VaultTestSupport.writeScope("kanyo-dev", type: .projectDev, in: vault)
            try VaultTestSupport.withEphemeralProjectDirectory { project in
                let markerURL = project.appendingPathComponent(".sharibako")
                let core = try VaultCore(vaultURL: vault)
                let mat = Materializer(vaultCore: core, vaultURL: vault)
                let marker = ScopeMarker(scope: "kanyo-dev", materializeTo: "./.env", markerURL: markerURL)
                let result = try mat.clean(marker: marker)
                guard case .fileMissing = result else {
                    Issue.record("expected .fileMissing")
                    return
                }
            }
        }
    }

    @Test("clean deletes the file when only owned keys remain")
    func cleanDeletesFileWhenOnlyOwnedKeysRemain() throws {
        try VaultTestSupport.withEphemeralVault { vault in
            try VaultTestSupport.writeScope("kanyo-dev", type: .projectDev, in: vault)
            try VaultTestSupport.writePlaceholderAge("API_KEY", inScope: "kanyo-dev", in: vault)

            try VaultTestSupport.withEphemeralProjectDirectory { project in
                let markerURL = project.appendingPathComponent(".sharibako")
                let targetURL = project.appendingPathComponent(".env")
                try "API_KEY=whatever\n".write(to: targetURL, atomically: true, encoding: .utf8)
                let core = try VaultCore(vaultURL: vault)
                let mat = Materializer(vaultCore: core, vaultURL: vault)
                let marker = ScopeMarker(scope: "kanyo-dev", materializeTo: "./.env", markerURL: markerURL)
                let result = try mat.clean(marker: marker)
                // swiftlint:disable:next pattern_matching_keywords
                guard case .cleaned(_, let removed, let stillExists) = result else {
                    Issue.record("expected .cleaned")
                    return
                }
                #expect(removed == ["API_KEY"])
                #expect(stillExists == false)
                #expect(!FileManager.default.fileExists(atPath: targetURL.path))
            }
        }
    }

    @Test("clean preserves non-owned lines and keeps the file")
    func cleanPreservesNonOwnedLines() throws {
        try VaultTestSupport.withEphemeralVault { vault in
            try VaultTestSupport.writeScope("kanyo-dev", type: .projectDev, in: vault)
            try VaultTestSupport.writePlaceholderAge("API_KEY", inScope: "kanyo-dev", in: vault)

            try VaultTestSupport.withEphemeralProjectDirectory { project in
                let markerURL = project.appendingPathComponent(".sharibako")
                let targetURL = project.appendingPathComponent(".env")
                try "# keep me\nAPI_KEY=whatever\nDEBUG=true\n"
                    .write(to: targetURL, atomically: true, encoding: .utf8)
                let core = try VaultCore(vaultURL: vault)
                let mat = Materializer(vaultCore: core, vaultURL: vault)
                let marker = ScopeMarker(scope: "kanyo-dev", materializeTo: "./.env", markerURL: markerURL)
                let result = try mat.clean(marker: marker)
                guard case .cleaned(_, _, let stillExists) = result else {
                    Issue.record("expected .cleaned")
                    return
                }
                #expect(stillExists == true)
                let after = try String(contentsOf: targetURL, encoding: .utf8)
                #expect(after.contains("# keep me"))
                #expect(after.contains("DEBUG=true"))
                #expect(!after.contains("API_KEY"))
            }
        }
    }

    // MARK: - Heal

    @Test("heal on missing file reports every owned key as fileMissing")
    func healMissingFile() throws {
        try VaultTestSupport.withEphemeralVault { vault in
            try VaultTestSupport.writeScope("kanyo-dev", type: .projectDev, in: vault)
            try VaultTestSupport.writePlaceholderAge("A", inScope: "kanyo-dev", in: vault)
            try VaultTestSupport.writePlaceholderAge("B", inScope: "kanyo-dev", in: vault)

            try VaultTestSupport.withEphemeralProjectDirectory { project in
                let markerURL = project.appendingPathComponent(".sharibako")
                let core = try VaultCore(vaultURL: vault)
                let mat = Materializer(vaultCore: core, vaultURL: vault)
                let marker = ScopeMarker(scope: "kanyo-dev", materializeTo: "./.env", markerURL: markerURL)
                let report = try mat.heal(marker: marker)
                #expect(report.owned == [.fileMissing(key: "A"), .fileMissing(key: "B")])
            }
        }
    }

    @Test("heal on file with all owned keys matching reports every one as .match")
    func healAllMatching() throws {
        try VaultTestSupport.withEphemeralVaultAndKey { vault, fixture in
            try VaultTestSupport.writeScope("kanyo-dev", type: .projectDev, in: vault)
            let core = try VaultCore(vaultURL: vault, ageKeyURL: fixture.privateKeyURL)
            try core.addSecret("A", value: "alpha", inScope: "kanyo-dev")
            try core.addSecret("B", value: "beta", inScope: "kanyo-dev")

            try VaultTestSupport.withEphemeralProjectDirectory { project in
                let markerURL = project.appendingPathComponent(".sharibako")
                let targetURL = project.appendingPathComponent(".env")
                try "A=alpha\nB=beta\n".write(to: targetURL, atomically: true, encoding: .utf8)
                let mat = Materializer(vaultCore: core, vaultURL: vault)
                let marker = ScopeMarker(scope: "kanyo-dev", materializeTo: "./.env", markerURL: markerURL)
                let report = try mat.heal(marker: marker)
                #expect(report.owned == [.match(key: "A"), .match(key: "B")])
            }
        }
    }

    @Test("heal on drifted file reports fileValueDiffers with SHA-256 hex digests")
    func healDriftedFile() throws {
        try VaultTestSupport.withEphemeralVaultAndKey { vault, fixture in
            try VaultTestSupport.writeScope("kanyo-dev", type: .projectDev, in: vault)
            let core = try VaultCore(vaultURL: vault, ageKeyURL: fixture.privateKeyURL)
            try core.addSecret("API_KEY", value: "vault-value", inScope: "kanyo-dev")

            try VaultTestSupport.withEphemeralProjectDirectory { project in
                let markerURL = project.appendingPathComponent(".sharibako")
                let targetURL = project.appendingPathComponent(".env")
                try "API_KEY=file-value\n".write(to: targetURL, atomically: true, encoding: .utf8)
                let mat = Materializer(vaultCore: core, vaultURL: vault)
                let marker = ScopeMarker(scope: "kanyo-dev", materializeTo: "./.env", markerURL: markerURL)
                let report = try mat.heal(marker: marker)
                #expect(report.owned.count == 1)
                // swiftlint:disable:next pattern_matching_keywords
                guard case .fileValueDiffers(let key, let vaultSha, let fileSha) = report.owned[0] else {
                    Issue.record("expected .fileValueDiffers")
                    return
                }
                #expect(key == "API_KEY")
                #expect(vaultSha.count == 64)
                #expect(fileSha.count == 64)
                #expect(vaultSha != fileSha)
                #expect(vaultSha == vaultSha.lowercased())
                #expect(vaultSha.allSatisfy { $0.isHexDigit })
            }
        }
    }

    @Test("heal ignores non-owned lines entirely (never surfaces them)")
    func healIgnoresNonOwnedLines() throws {
        try VaultTestSupport.withEphemeralVaultAndKey { vault, fixture in
            try VaultTestSupport.writeScope("kanyo-dev", type: .projectDev, in: vault)
            let core = try VaultCore(vaultURL: vault, ageKeyURL: fixture.privateKeyURL)
            try core.addSecret("A", value: "alpha", inScope: "kanyo-dev")

            try VaultTestSupport.withEphemeralProjectDirectory { project in
                let markerURL = project.appendingPathComponent(".sharibako")
                let targetURL = project.appendingPathComponent(".env")
                try "A=alpha\nDEBUG=true\nPORT=3000\n"
                    .write(to: targetURL, atomically: true, encoding: .utf8)
                let mat = Materializer(vaultCore: core, vaultURL: vault)
                let marker = ScopeMarker(scope: "kanyo-dev", materializeTo: "./.env", markerURL: markerURL)
                let report = try mat.heal(marker: marker)
                #expect(report.owned == [.match(key: "A")])
            }
        }
    }

    // MARK: - Round-trip integrity (integration-style)

    @Test("full round-trip: mixed .env survives materialize byte-for-byte for non-owned lines")
    func fullRoundTripPreservesNonOwnedBytes() throws {
        try VaultTestSupport.withEphemeralVaultAndKey { vault, fixture in
            try VaultTestSupport.writeScope("kanyo-dev", type: .projectDev, in: vault)
            let core = try VaultCore(vaultURL: vault, ageKeyURL: fixture.privateKeyURL)
            try core.addSecret("A", value: "one", inScope: "kanyo-dev")
            try core.addSecret("B", value: "two", inScope: "kanyo-dev")

            try VaultTestSupport.withEphemeralProjectDirectory { project in
                let markerURL = project.appendingPathComponent(".sharibako")
                let targetURL = project.appendingPathComponent(".env")
                // Mixed: two owned (A, B) + three non-owned + two comments
                let original = """
                    # header comment
                    A=one
                    DEBUG=true

                    # section
                    B=two
                    PORT=3000
                    NODE_ENV=development

                    """
                try original.write(to: targetURL, atomically: true, encoding: .utf8)

                let mat = Materializer(vaultCore: core, vaultURL: vault)
                let marker = ScopeMarker(scope: "kanyo-dev", materializeTo: "./.env", markerURL: markerURL)
                _ = try mat.materialize(marker: marker)

                let after = try String(contentsOf: targetURL, encoding: .utf8)
                #expect(after == original)
            }
        }
    }

    @Test("heal reports .fileMissing alongside .match / .fileValueDiffers when file is partial")
    func healMixedPresentAndMissing() throws {
        try VaultTestSupport.withEphemeralVaultAndKey { vault, fixture in
            try VaultTestSupport.writeScope("kanyo-dev", type: .projectDev, in: vault)
            let core = try VaultCore(vaultURL: vault, ageKeyURL: fixture.privateKeyURL)
            try core.addSecret("A", value: "alpha", inScope: "kanyo-dev")
            try core.addSecret("B", value: "beta", inScope: "kanyo-dev")
            try core.addSecret("C", value: "gamma", inScope: "kanyo-dev")

            try VaultTestSupport.withEphemeralProjectDirectory { project in
                let markerURL = project.appendingPathComponent(".sharibako")
                let targetURL = project.appendingPathComponent(".env")
                // A matches vault; B drifts (file value differs); C is absent from the file.
                try "A=alpha\nB=drifted\n".write(to: targetURL, atomically: true, encoding: .utf8)
                let mat = Materializer(vaultCore: core, vaultURL: vault)
                let marker = ScopeMarker(scope: "kanyo-dev", materializeTo: "./.env", markerURL: markerURL)
                let report = try mat.heal(marker: marker)

                #expect(report.owned.count == 3)
                #expect(report.owned[0] == .match(key: "A"))
                if case .fileValueDiffers(let key, _, _) = report.owned[1] {
                    #expect(key == "B")
                } else {
                    Issue.record("expected B to be .fileValueDiffers")
                }
                #expect(report.owned[2] == .fileMissing(key: "C"))
            }
        }
    }
}
