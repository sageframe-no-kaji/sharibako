import Foundation
import Testing

@testable import SharibakoCLI
@testable import SharibakoCore

@Suite("ErrorReporter")
struct ErrorReporterTests {
    // MARK: - VaultError mappings

    @Test("vaultNotFound maps to filesystem exit code")
    func vaultNotFound() {
        let url = URL(fileURLWithPath: "/nonexistent/vault")
        let report = ErrorReporter.makeReport(for: VaultError.vaultNotFound(path: url))
        #expect(report.code == .filesystem)
        #expect(report.message.contains("/nonexistent/vault"))
        #expect(report.remediation != nil)
    }

    @Test("scopeNotFound maps to userError exit code")
    func scopeNotFound() {
        let report = ErrorReporter.makeReport(for: VaultError.scopeNotFound(id: "kanyo-dev"))
        #expect(report.code == .userError)
        #expect(report.message.contains("kanyo-dev"))
    }

    @Test("secretNotFound maps to userError exit code")
    func secretNotFound() {
        let report = ErrorReporter.makeReport(for: VaultError.secretNotFound(scope: "s", key: "k"))
        #expect(report.code == .userError)
    }

    @Test("scopeAlreadyExists maps to userError exit code")
    func scopeAlreadyExists() {
        let report = ErrorReporter.makeReport(for: VaultError.scopeAlreadyExists(id: "dup"))
        #expect(report.code == .userError)
    }

    @Test("sharedEntryNotFound maps to userError exit code")
    func sharedEntryNotFound() {
        let report = ErrorReporter.makeReport(for: VaultError.sharedEntryNotFound(id: "SHARED_SECRET"))
        #expect(report.code == .userError)
    }

    @Test("linkTargetMissing maps to userError exit code")
    func linkTargetMissing() {
        let report = ErrorReporter.makeReport(for: VaultError.linkTargetMissing(id: "gone"))
        #expect(report.code == .userError)
    }

    @Test("ageInvocationFailed maps to age exit code")
    func ageInvocationFailed() {
        let report = ErrorReporter.makeReport(
            for: VaultError.ageInvocationFailed(exitCode: 1, stderr: "bad decrypt")
        )
        #expect(report.code == .age)
        #expect(report.message.contains("bad decrypt"))
    }

    @Test("shellNotFound with age name maps to age exit code")
    func shellNotFoundAgeName() {
        let report = ErrorReporter.makeReport(for: VaultError.shellNotFound(name: "age"))
        #expect(report.code == .age)
        #expect(report.message.contains("age"))
    }

    @Test("shellNotFound with age-keygen name maps to age exit code")
    func shellNotFoundAgeKeygenName() {
        let report = ErrorReporter.makeReport(for: VaultError.shellNotFound(name: "age-keygen"))
        #expect(report.code == .age)
    }

    @Test("shellNotFound with git name maps to git exit code")
    func shellNotFoundGitName() {
        let report = ErrorReporter.makeReport(for: VaultError.shellNotFound(name: "git"))
        #expect(report.code == .git)
    }

    @Test("gitInvocationFailed maps to git exit code")
    func gitInvocationFailed() {
        let report = ErrorReporter.makeReport(
            for: VaultError.gitInvocationFailed(exitCode: 128, stderr: "not a git repo")
        )
        #expect(report.code == .git)
        #expect(report.message.contains("not a git repo"))
    }

    @Test("markerNotFound maps to userError exit code")
    func markerNotFound() {
        let url = URL(fileURLWithPath: "/some/project")
        let report = ErrorReporter.makeReport(for: VaultError.markerNotFound(startingFrom: url))
        #expect(report.code == .userError)
        #expect(report.remediation?.contains("init") == true)
    }

    @Test("markerMalformed maps to userError exit code")
    func markerMalformed() {
        let url = URL(fileURLWithPath: "/some/.sharibako")
        let report = ErrorReporter.makeReport(
            for: VaultError.markerMalformed(path: url, reason: "scope is empty")
        )
        #expect(report.code == .userError)
    }

    @Test("fileSystemError maps to filesystem exit code")
    func fileSystemError() {
        let url = URL(fileURLWithPath: "/tmp/x")
        struct FakeIO: Error {}
        let report = ErrorReporter.makeReport(
            for: VaultError.fileSystemError(path: url, underlying: FakeIO())
        )
        #expect(report.code == .filesystem)
    }

    // MARK: - CLIError mappings

    @Test("ageKeyFileNotFound maps to filesystem exit code")
    func ageKeyFileNotFound() {
        let url = URL(fileURLWithPath: "/no/key.txt")
        let report = ErrorReporter.makeReport(for: CLIError.ageKeyFileNotFound(path: url))
        #expect(report.code == .filesystem)
        #expect(report.remediation != nil)
    }

    @Test("keychainStoreFailed maps to keychain exit code")
    func keychainStoreFailed() {
        let report = ErrorReporter.makeReport(for: CLIError.keychainStoreFailed(osStatus: -25300))
        #expect(report.code == .keychain)
    }

    @Test("keychainLoadFailed maps to keychain exit code")
    func keychainLoadFailed() {
        let report = ErrorReporter.makeReport(for: CLIError.keychainLoadFailed(osStatus: -25308))
        #expect(report.code == .keychain)
    }

    @Test("invalidAgeKeyFile maps to userError exit code")
    func invalidAgeKeyFile() {
        let url = URL(fileURLWithPath: "/tmp/bad.txt")
        let report = ErrorReporter.makeReport(for: CLIError.invalidAgeKeyFile(path: url))
        #expect(report.code == .userError)
    }

    @Test("ageKeyAlreadyExists maps to userError exit code")
    func ageKeyAlreadyExists() {
        let report = ErrorReporter.makeReport(for: CLIError.ageKeyAlreadyExists)
        #expect(report.code == .userError)
        #expect(report.remediation?.contains("--force") == true)
    }

    @Test("exportRequiresPlaintextAcknowledgement maps to userError exit code")
    func exportRequiresPlaintextAcknowledgement() {
        let report = ErrorReporter.makeReport(for: CLIError.exportRequiresPlaintextAcknowledgement)
        #expect(report.code == .userError)
    }

    @Test("publicKeyHeaderMissing maps to age exit code")
    func publicKeyHeaderMissing() {
        let report = ErrorReporter.makeReport(for: CLIError.publicKeyHeaderMissing)
        #expect(report.code == .age)
    }

    // MARK: - Unknown error fallback

    @Test("unknown error type falls back to generic exit code")
    func unknownErrorFallback() {
        struct UnknownError: Error {}
        let report = ErrorReporter.makeReport(for: UnknownError())
        #expect(report.code == .generic)
    }

    // MARK: - New VaultError cases

    @Test("ageIdentityNotConfigured maps to age exit code with key-setup remediation")
    func ageIdentityNotConfigured() {
        let report = ErrorReporter.makeReport(for: VaultError.ageIdentityNotConfigured)
        #expect(report.code == .age)
        #expect(report.remediation?.contains("--age-key") == true)
        #expect(report.message.contains("age identity"))
    }

    // MARK: - Keychain OSStatus branching

    @Test("keychainLoadFailed item-not-found suggests generating or importing a key")
    func keychainLoadItemNotFound() {
        let report = ErrorReporter.makeReport(for: CLIError.keychainLoadFailed(osStatus: -25300))
        #expect(report.code == .keychain)
        #expect(report.message.contains("No age key found"))
        #expect(report.remediation?.contains("key generate") == true)
    }

    @Test("keychainLoadFailed user-cancelled does NOT advise key generate")
    func keychainLoadUserCancelled() {
        let report = ErrorReporter.makeReport(for: CLIError.keychainLoadFailed(osStatus: -128))
        #expect(report.code == .keychain)
        #expect(report.message.contains("cancelled"))
        // `key generate --force` after a cancelled prompt would destroy vault
        // access — the remediation must never point there.
        #expect(report.remediation?.contains("key generate") != true)
    }

    @Test("keychainLoadFailed unknown status surfaces the OSStatus for decoding")
    func keychainLoadUnknownStatus() {
        let report = ErrorReporter.makeReport(for: CLIError.keychainLoadFailed(osStatus: -25293))
        #expect(report.code == .keychain)
        #expect(report.message.contains("-25293"))
        #expect(report.remediation?.contains("security error") == true)
    }

    // MARK: - JSON payload encoding

    @Test("jsonPayload stays valid JSON when the message contains quotes and newlines")
    func jsonPayloadEscapesSpecialCharacters() throws {
        // gitInvocationFailed passes raw subprocess stderr straight through —
        // quotes, backslashes, and newlines included.
        let hostile = "fatal: \"branch\" rejected\nhint: use \\force maybe"
        let report = ErrorReporter.makeReport(
            for: VaultError.gitInvocationFailed(exitCode: 128, stderr: hostile))
        let payload = ErrorReporter.jsonPayload(for: report)

        let parsed = try JSONSerialization.jsonObject(with: Data(payload.utf8))
        let object = try #require(parsed as? [String: Any])
        let message = try #require(object["error"] as? String)
        #expect(message.contains("\"branch\" rejected"))
        #expect(object["code"] as? Int == Int(SharibakoExitCode.git.rawValue))
    }

    @Test("jsonPayload stays valid JSON for a scope name containing quotes")
    func jsonPayloadEscapesScopeQuotes() throws {
        let report = ErrorReporter.makeReport(for: VaultError.scopeNotFound(id: "we\"ird"))
        let payload = ErrorReporter.jsonPayload(for: report)
        let parsed = try JSONSerialization.jsonObject(with: Data(payload.utf8))
        #expect(parsed is [String: Any])
    }
}
