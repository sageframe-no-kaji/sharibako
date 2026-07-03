import Foundation
import Testing

@testable import SharibakoCore

/// ho-04.10 Materializer contract specs.
///
/// Per-line CRLF preservation through the write paths, last-wins duplicate-key
/// reads, corrupted-owned-line drift, and empty-value ingest routing. Each test
/// fails on the pre-ho-04.10 behavior. Separate file from the merge/clean-heal
/// suites to keep each test struct under the type-body-length ceiling.
@Suite("Materializer Contract (ho-04.10)")
struct MaterializerContractTests {
    // MARK: - CRLF preservation (D1)

    @Test("materialize on a CRLF file preserves every line ending and rewrites owned lines CRLF")
    func materializeCRLFPreserved() throws {
        try VaultTestSupport.withEphemeralVaultAndKey { vault, fixture in
            try VaultTestSupport.writeScope("kanyo-dev", type: .projectDev, in: vault)
            let core = try VaultCore(vaultURL: vault, ageKeyURL: fixture.privateKeyURL)
            try core.addSecret("API_KEY", value: "sk-live", inScope: "kanyo-dev")
            try core.addSecret("EXTRA", value: "added", inScope: "kanyo-dev")

            try VaultTestSupport.withEphemeralProjectDirectory { project in
                let markerURL = project.appendingPathComponent(".sharibako")
                let targetURL = project.appendingPathComponent(".env")
                let original = "# top\r\nDEBUG=true\r\nAPI_KEY=stale\r\n"
                try original.write(to: targetURL, atomically: true, encoding: .utf8)

                let marker = ScopeMarker(scope: "kanyo-dev", materializeTo: "./.env", markerURL: markerURL)
                let mat = Materializer(vaultCore: core, vaultURL: vault)
                guard case .wrote = try mat.materialize(marker: marker, overwriteDrift: true) else {
                    Issue.record("expected .wrote")
                    return
                }
                let after = try String(contentsOf: targetURL, encoding: .utf8)
                #expect(
                    after == "# top\r\nDEBUG=true\r\nAPI_KEY=sk-live\r\n\r\nEXTRA=added\r\n"
                )
            }
        }
    }

    @Test("clean on a CRLF file preserves the surviving lines' endings")
    func cleanCRLFPreserved() throws {
        try VaultTestSupport.withEphemeralVaultAndKey { vault, fixture in
            try VaultTestSupport.writeScope("kanyo-dev", type: .projectDev, in: vault)
            let core = try VaultCore(vaultURL: vault, ageKeyURL: fixture.privateKeyURL)
            try core.addSecret("API_KEY", value: "sk-live", inScope: "kanyo-dev")

            try VaultTestSupport.withEphemeralProjectDirectory { project in
                let markerURL = project.appendingPathComponent(".sharibako")
                let targetURL = project.appendingPathComponent(".env")
                let original = "# keep\r\nDEBUG=true\r\nAPI_KEY=sk-live\r\n"
                try original.write(to: targetURL, atomically: true, encoding: .utf8)

                let marker = ScopeMarker(scope: "kanyo-dev", materializeTo: "./.env", markerURL: markerURL)
                let mat = Materializer(vaultCore: core, vaultURL: vault)
                guard case .cleaned(_, _, true) = try mat.clean(marker: marker) else {
                    Issue.record("expected .cleaned with surviving file")
                    return
                }
                let after = try String(contentsOf: targetURL, encoding: .utf8)
                #expect(after == "# keep\r\nDEBUG=true\r\n")
            }
        }
    }

    // MARK: - Last-wins duplicate keys (D3)

    @Test("update pushes the LAST occurrence's value into the vault")
    func updateLastWins() throws {
        try VaultTestSupport.withEphemeralVaultAndKey { vault, fixture in
            try VaultTestSupport.writeScope("kanyo-dev", type: .projectDev, in: vault)
            let core = try VaultCore(vaultURL: vault, ageKeyURL: fixture.privateKeyURL)
            try core.addSecret("API_KEY", value: "original", inScope: "kanyo-dev")

            try VaultTestSupport.withEphemeralProjectDirectory { project in
                let markerURL = project.appendingPathComponent(".sharibako")
                let targetURL = project.appendingPathComponent(".env")
                try "API_KEY=stale\nAPI_KEY=corrected\n"
                    .write(to: targetURL, atomically: true, encoding: .utf8)

                let marker = ScopeMarker(scope: "kanyo-dev", materializeTo: "./.env", markerURL: markerURL)
                let mat = Materializer(vaultCore: core, vaultURL: vault)
                guard case .updated(let keys, _) = try mat.update(scopeID: "kanyo-dev", marker: marker)
                else {
                    Issue.record("expected .updated")
                    return
                }
                #expect(keys == ["API_KEY"])
                #expect(try core.getValue("API_KEY", inScope: "kanyo-dev") == "corrected")
            }
        }
    }

    @Test("heal compares against the LAST occurrence: duplicate whose last value matches is a match")
    func healLastWins() throws {
        try VaultTestSupport.withEphemeralVaultAndKey { vault, fixture in
            try VaultTestSupport.writeScope("kanyo-dev", type: .projectDev, in: vault)
            let core = try VaultCore(vaultURL: vault, ageKeyURL: fixture.privateKeyURL)
            try core.addSecret("API_KEY", value: "current", inScope: "kanyo-dev")

            try VaultTestSupport.withEphemeralProjectDirectory { project in
                let markerURL = project.appendingPathComponent(".sharibako")
                let targetURL = project.appendingPathComponent(".env")
                try "API_KEY=stale\nAPI_KEY=current\n"
                    .write(to: targetURL, atomically: true, encoding: .utf8)

                let marker = ScopeMarker(scope: "kanyo-dev", materializeTo: "./.env", markerURL: markerURL)
                let mat = Materializer(vaultCore: core, vaultURL: vault)
                let report = try mat.heal(marker: marker)
                #expect(report.owned == [.match(key: "API_KEY")])
            }
        }
    }

    @Test("materialize collapses duplicates into the first occurrence's position with the vault value")
    func materializeCollapsesDuplicates() throws {
        try VaultTestSupport.withEphemeralVaultAndKey { vault, fixture in
            try VaultTestSupport.writeScope("kanyo-dev", type: .projectDev, in: vault)
            let core = try VaultCore(vaultURL: vault, ageKeyURL: fixture.privateKeyURL)
            try core.addSecret("API_KEY", value: "current", inScope: "kanyo-dev")

            try VaultTestSupport.withEphemeralProjectDirectory { project in
                let markerURL = project.appendingPathComponent(".sharibako")
                let targetURL = project.appendingPathComponent(".env")
                try "API_KEY=stale\nMIDDLE=keep\nAPI_KEY=current\n"
                    .write(to: targetURL, atomically: true, encoding: .utf8)

                let marker = ScopeMarker(scope: "kanyo-dev", materializeTo: "./.env", markerURL: markerURL)
                let mat = Materializer(vaultCore: core, vaultURL: vault)
                guard case .wrote = try mat.materialize(marker: marker) else {
                    Issue.record("expected .wrote")
                    return
                }
                let after = try String(contentsOf: targetURL, encoding: .utf8)
                #expect(after == "API_KEY=current\nMIDDLE=keep\n")
            }
        }
    }

    // MARK: - Corrupted owned lines (D4)

    @Test("a corrupted owned line counts as drift — materialize without overwrite returns diffPending")
    func corruptedOwnedLineIsDrift() throws {
        try VaultTestSupport.withEphemeralVaultAndKey { vault, fixture in
            try VaultTestSupport.writeScope("kanyo-dev", type: .projectDev, in: vault)
            let core = try VaultCore(vaultURL: vault, ageKeyURL: fixture.privateKeyURL)
            try core.addSecret("API_KEY", value: "sk-live", inScope: "kanyo-dev")

            try VaultTestSupport.withEphemeralProjectDirectory { project in
                let markerURL = project.appendingPathComponent(".sharibako")
                let targetURL = project.appendingPathComponent(".env")
                try "API_KEY=\"unterminated\n".write(to: targetURL, atomically: true, encoding: .utf8)

                let marker = ScopeMarker(scope: "kanyo-dev", materializeTo: "./.env", markerURL: markerURL)
                let mat = Materializer(vaultCore: core, vaultURL: vault)
                guard case .diffPending(let diff) = try mat.materialize(marker: marker) else {
                    Issue.record("expected .diffPending")
                    return
                }
                #expect(diff.ownedKeysDiffering == ["API_KEY"])
                #expect(diff.ownedKeysMissingFromFile.isEmpty)
            }
        }
    }

    @Test("materialize --overwrite rewrites a corrupted owned line in place, never duplicating the key")
    func corruptedOwnedLineRewrittenInPlace() throws {
        try VaultTestSupport.withEphemeralVaultAndKey { vault, fixture in
            try VaultTestSupport.writeScope("kanyo-dev", type: .projectDev, in: vault)
            let core = try VaultCore(vaultURL: vault, ageKeyURL: fixture.privateKeyURL)
            try core.addSecret("API_KEY", value: "sk-live", inScope: "kanyo-dev")

            try VaultTestSupport.withEphemeralProjectDirectory { project in
                let markerURL = project.appendingPathComponent(".sharibako")
                let targetURL = project.appendingPathComponent(".env")
                try "# top\nAPI_KEY=\"unterminated\nDEBUG=true\n"
                    .write(to: targetURL, atomically: true, encoding: .utf8)

                let marker = ScopeMarker(scope: "kanyo-dev", materializeTo: "./.env", markerURL: markerURL)
                let mat = Materializer(vaultCore: core, vaultURL: vault)
                guard case .wrote = try mat.materialize(marker: marker, overwriteDrift: true) else {
                    Issue.record("expected .wrote")
                    return
                }
                let after = try String(contentsOf: targetURL, encoding: .utf8)
                #expect(after == "# top\nAPI_KEY=sk-live\nDEBUG=true\n")
            }
        }
    }

    @Test("clean removes a corrupted owned line — corruption doesn't transfer ownership")
    func cleanRemovesCorruptedOwnedLine() throws {
        try VaultTestSupport.withEphemeralVaultAndKey { vault, fixture in
            try VaultTestSupport.writeScope("kanyo-dev", type: .projectDev, in: vault)
            let core = try VaultCore(vaultURL: vault, ageKeyURL: fixture.privateKeyURL)
            try core.addSecret("API_KEY", value: "sk-live", inScope: "kanyo-dev")

            try VaultTestSupport.withEphemeralProjectDirectory { project in
                let markerURL = project.appendingPathComponent(".sharibako")
                let targetURL = project.appendingPathComponent(".env")
                try "DEBUG=true\nAPI_KEY='unterminated\n"
                    .write(to: targetURL, atomically: true, encoding: .utf8)

                let marker = ScopeMarker(scope: "kanyo-dev", materializeTo: "./.env", markerURL: markerURL)
                let mat = Materializer(vaultCore: core, vaultURL: vault)
                guard case .cleaned(_, let removed, true) = try mat.clean(marker: marker) else {
                    Issue.record("expected .cleaned with surviving file")
                    return
                }
                #expect(removed == ["API_KEY"])
                let after = try String(contentsOf: targetURL, encoding: .utf8)
                #expect(after == "DEBUG=true\n")
            }
        }
    }

    @Test("heal reports a corrupted owned line as fileLineCorrupted, not fileMissing")
    func healReportsCorruptedLine() throws {
        try VaultTestSupport.withEphemeralVaultAndKey { vault, fixture in
            try VaultTestSupport.writeScope("kanyo-dev", type: .projectDev, in: vault)
            let core = try VaultCore(vaultURL: vault, ageKeyURL: fixture.privateKeyURL)
            try core.addSecret("API_KEY", value: "sk-live", inScope: "kanyo-dev")

            try VaultTestSupport.withEphemeralProjectDirectory { project in
                let markerURL = project.appendingPathComponent(".sharibako")
                let targetURL = project.appendingPathComponent(".env")
                try "API_KEY=\"unterminated\n".write(to: targetURL, atomically: true, encoding: .utf8)

                let marker = ScopeMarker(scope: "kanyo-dev", materializeTo: "./.env", markerURL: markerURL)
                let mat = Materializer(vaultCore: core, vaultURL: vault)
                let report = try mat.heal(marker: marker)
                #expect(report.owned == [.fileLineCorrupted(key: "API_KEY")])
                #expect(!report.parseWarnings.isEmpty)
            }
        }
    }

    // MARK: - Empty-valued ingest keys (D6)

    @Test("ingest routes KEY= (empty value) to suggestedKeysNeedingValues, not detectedKeys")
    func ingestRoutesEmptyValues() throws {
        try VaultTestSupport.withEphemeralVaultAndKey { vault, fixture in
            let core = try VaultCore(vaultURL: vault, ageKeyURL: fixture.privateKeyURL)
            try VaultTestSupport.withEphemeralProjectDirectory { project in
                try "FILLED=value\nEMPTY=\n".write(
                    to: project.appendingPathComponent(".env"), atomically: true, encoding: .utf8
                )
                let mat = Materializer(vaultCore: core, vaultURL: vault)
                let proposal = try mat.ingest(directory: project)
                #expect(proposal.detectedKeys.map(\.key) == ["FILLED"])
                #expect(proposal.suggestedKeysNeedingValues == ["EMPTY"])
            }
        }
    }

    @Test("a key empty in .env but filled in .env.local is detected with the merged value")
    func ingestEmptyThenFilledMerges() throws {
        try VaultTestSupport.withEphemeralVaultAndKey { vault, fixture in
            let core = try VaultCore(vaultURL: vault, ageKeyURL: fixture.privateKeyURL)
            try VaultTestSupport.withEphemeralProjectDirectory { project in
                try "KEY=\n".write(
                    to: project.appendingPathComponent(".env"), atomically: true, encoding: .utf8
                )
                try "KEY=filled\n".write(
                    to: project.appendingPathComponent(".env.local"), atomically: true, encoding: .utf8
                )
                let mat = Materializer(vaultCore: core, vaultURL: vault)
                let proposal = try mat.ingest(directory: project)
                #expect(proposal.detectedKeys.map(\.key) == ["KEY"])
                #expect(proposal.detectedKeys.first?.value == "filled")
                #expect(proposal.suggestedKeysNeedingValues.isEmpty)
            }
        }
    }
}
