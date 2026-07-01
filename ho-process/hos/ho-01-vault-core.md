---
created: 2026-06-30
status: draft
type: ho-document
project: sharibako
ho: "01"
kamae: 5
shape: ha
builds-on:
  - kamae-1-sharibako-seed.md
  - kamae-2-sharibako-system-design.md
  - README.md
  - docs/architecture.md
  - kamae-4-sharibako-ho-overview.md
  - ho-process/hos/ho-00-orientation.md
agent-tasks:
  - Ho-01-AT-01.md
  - Ho-01-AT-02.md
---

# ho-01 — The Vault Core: schema, age, link resolution

The vault's complete data model in code. `SharibakoCore` gets the nine operations the system design specifies — every vault read and write — with thorough tests and no user-facing surface attached. By the end of this ho, an ephemeral vault can be created, populated with linked and unlinked secrets, round-trip encrypted with a real age key, and read back cleanly.

**Out of scope:** git operations (ho-02), Touch ID / Keychain integration (ho-04), the `.sharibako` marker (ho-03), any CLI or GUI surface.

**Resolves deferred decisions** (from the ho-overview and CLAUDE.md):
- `age` binary acquisition for tests
- Age key location during development

---

## Phase 1 — Think

### Decision 1 — Shared-entry ID representation: plaintext slug

Committed. The system design uses slugs throughout (`openai-personal`, `cloudflare-dns-token`). `SharibakoCore` treats the shared entry ID as an opaque non-empty string — it becomes both the filename (`vault/shared/<id>.age`) and the content of any `.link` file referencing it. No character restrictions beyond what the filesystem permits (Unix: anything except `/` and null byte).

### Decision 2 — YAML library: Yams + Codable

`scope.yaml` and decrypted `.age` content are both fixed-schema YAML. Yams (`github.com/jpsim/Yams`) provides the parser; Swift's `Codable` protocol provides the schema binding. Define typed structs that match each file's shape and let `YAMLDecoder` fill them in:

```swift
struct ScopeMetadata: Codable {
    let identity: String
    let type: ScopeType
    let displayName: String?
}
// Decode: try YAMLDecoder().decode(ScopeMetadata.self, from: yamlString)
```

Raw YAML node traversal is reserved for dynamic schemas. Sharibako's schema is fixed by the system design. Yams is added as a `Package.swift` dependency.

### Decision 3 — Process wrapper: Shell.run() internal utility

Every call to `age` (this ho) and `git` (Conduit, ho-02) uses `Foundation.Process`. One internal function in `SharibakoCore` abstracts the setup rather than repeating it at each call site:

```swift
// Internal to SharibakoCore
enum Shell {
    static func findExecutable(_ name: String) throws -> URL
    static func run(_ executableURL: URL, _ arguments: [String]) throws -> ShellResult
}
struct ShellResult { let exitCode: Int32; let stdout: String; let stderr: String }
```

`findExecutable` probes known Homebrew and system paths (`/opt/homebrew/bin/`, `/usr/local/bin/`, `/home/linuxbrew/.linuxbrew/bin/`, `/usr/bin/`) in order, returning the first hit. Throws `VaultError.shellNotFound(name:)` if the binary is absent. `Shell.run` throws on `Process` launch failure; callers inspect `ShellResult.exitCode` and `ShellResult.stderr` for non-zero exits.

### Decision 4 — Error type: single VaultError enum

One typed enum for all `SharibakoCore` failures. The CLI and GUI switch over it to produce user-facing messages without string parsing:

```swift
public enum VaultError: Error {
    case vaultNotFound(path: URL)
    case scopeNotFound(id: String)
    case secretNotFound(scope: String, key: String)
    case scopeAlreadyExists(id: String)
    case sharedEntryNotFound(id: String)
    case linkTargetMissing(id: String)
    case ageInvocationFailed(exitCode: Int32, stderr: String)
    case yamlEncodeError(path: URL, underlying: Error)
    case yamlDecodeError(path: URL, underlying: Error)
    case fileSystemError(path: URL, underlying: Error)
    case shellNotFound(name: String)
}
```

Eleven cases for the v1 library. Not burdensome to maintain; surfaces all the failure modes the surfaces need to handle.

### Decision 5 — `age` binary acquisition: require on PATH, document, CI installs

`age` and `age-keygen` must be on PATH to run the encryption tests (`VaultCoreEncryptionTests`). Pure-filesystem tests (`VaultCoreFilesystemTests`) need no external binaries.

Two documentation points, both mandatory:

1. **CLAUDE.md** gets a "Development prerequisites" section listing `age` alongside swift-format and swiftlint. If it's missing, contributors hit obscure test failures — not acceptable.
2. **CI workflow** (`ci.yml`) adds `age` to the `brew install` step so CI never silently fails on the encryption tests.

`Shell.findExecutable`'s behavior prevents silent failures locally: a missing binary surfaces `VaultError.shellNotFound(name: "age")` immediately as a clear test error, not a confusing downstream assertion.

Ephemeral key generation for tests uses `age-keygen` (ships in the same Homebrew `age` package). Each test session generates a fresh key pair into a temp directory.

### Deferred to execution — age binary path probe edge cases

`Shell.findExecutable`'s probe list covers the common Mac and Linux Homebrew paths. Non-standard environments may need additional paths. AT-02 tests will surface any gaps; the probe strategy can be expanded without changing the function signature.

---

## Phase 2 — Execute

Two tasks with a clean seam at the encryption boundary.

### Ho-01-AT-01 — Filesystem primitives and pure-filesystem operations

`Shell.run()` utility, `VaultError` enum, `ScopeMetadata` and `SecretInfo` models (Yams + Codable), vault directory layout helpers, and the five operations that don't require decryption: `listScopes`, `listShared`, `getScope`, `inspect`, `link`. Plus link graph resolution and orphan detection (walking `scopes/*/*.link`). All tests use ephemeral temp directories; no `age` on PATH required.

→ `ho-process/agent-tasks/Ho-01-AT-01.md`

### Ho-01-AT-02 — age invocation and encryption operations

`SecretContent` model, `AgeKeyFixture` test helper (generates ephemeral age key pairs via `age-keygen`), age encrypt/decrypt wiring through `Shell.run()`, and the four operations that require decryption: `getValue`, `addSecret`, `rotate`/`rotateShared`, `unlink`. Round-trip tests. Orphan detection verified with real encrypted content. CI and CLAUDE.md documentation for the `age` PATH requirement.

→ `ho-process/agent-tasks/Ho-01-AT-02.md`

### Testing and iteration approach

AT-01 completes and passes before AT-02 opens. AT-02's tests build directly on AT-01's filesystem primitives — no parallel execution.

Coverage after AT-02:

```bash
swift test --enable-code-coverage
xcrun llvm-cov report \
  -instr-profile=.build/debug/codecov/default.profdata \
  .build/debug/SharibakoCorePackageTests.xctest/Contents/MacOS/SharibakoCorePackageTests \
  --ignore-filename-regex=".build|Tests"
```

90% floor. Identify any uncovered lines before marking done.

### Done means

- All nine vault operations have passing tests including link-graph resolution and orphan detection
- Round-trip verified: `addSecret` then `getValue` returns the same value
- An ephemeral vault can be created, populated with linked and unlinked secrets, encrypted and decrypted
- `VaultError` is the sole error type surfaced from `SharibakoCore`'s public API — no untyped errors
- `age` documented in `CLAUDE.md` as a development prerequisite
- CI runs clean with `age` on the runner
- Coverage at or above 90%

---

## Phase 3 — Reflect

Executed 2026-06-30. Two commits — filesystem primitives (AT-01), then encryption operations (AT-02). 47 tests, 96.02% line coverage across `SharibakoCore`.

### Filesystem layout held

No edge cases in scope directory scanning or link file format. One deliberate behavior worth naming: `listScopes` silently skips scope subdirectories missing a `scope.yaml` rather than throwing. Half-written scope directories (which the Materializer's ingest flow in ho-03 will produce mid-operation) don't crash enumeration. Same tolerance in `inspect` for files other than `.age` / `.link` / `scope.yaml`.

### age invocation matched the spec exactly

- Encrypt: `age --encrypt --recipient <public-key> -o <output.age> <plaintext-input-file>` — exit 0 on success.
- Decrypt: `age --decrypt --identity <private-key-file> <input.age>` — plaintext on stdout, exit 0 on success.
- `age-keygen -o <path>` **refuses to overwrite an existing file** (surfaced in an ad-hoc test during execution). `AgeKeyFixture.generate` gives it a fresh UUID-named path in a freshly-created temp directory and never pre-touches the file. Worth carrying forward: any code that shells out to `age-keygen` must own the destination path from creation.
- Private-key file header matched: `# public key: age1...` on line 2 of the three-line file (`created`, `public key`, secret-key body).
- Local `age` version tested: 1.3.1 (Homebrew).

### YAML parsing: Yams + Codable worked without ceremony

Snake-case mapping via explicit `CodingKeys` (`display_name`, `rotated_at`) — no `KeyEncodingStrategy` needed. Raw-string decoding for `ScopeType` (`"project-dev"` → `.projectDev`) worked directly through the synthesized `Codable` conformance. The Stop Condition in AT-01 (Yams failing to decode kebab-case raw strings) never fired.

`YAMLDecoder` throws for malformed input; `getValueRejectsCorruptPayload` in the encryption suite confirms the failure path wraps to `VaultError.yamlDecodeError` cleanly.

### VaultError: eleven cases were exactly right

Every AT-02 throw site fit an existing case — no gap surfaced, no new case needed. `linkTargetMissing` (dangling `.link`) and `sharedEntryNotFound` (`rotateShared` on a missing entry) are both used and genuinely distinct.

### Coverage: 96.02%

Final numbers after two rounds of test additions:

| File | Line cover |
|---|---:|
| Models/SecretContent.swift | 100.00% |
| Models/SecretInfo.swift | 100.00% |
| Models/ScopeMetadata.swift | 100.00% |
| VaultLayout.swift | 97.22% |
| VaultCore.swift | 96.52% |
| VaultCore+Encryption.swift | 94.93% |
| Shell.swift | 94.12% |
| **TOTAL** | **96.02%** |

The 18 remaining uncovered lines are wrapped `catch` arms around FileManager operations — `throw VaultError.fileSystemError(path:underlying:)` inside `do { … } catch { throw … }` around `contentsOfDirectory`, `createDirectory`, `String(contentsOf:)`, and item removal. Reaching them requires forcing the underlying `Foundation` call to fail: `chmod 0000` on files or directories mid-test. One such test does exist (`linkFailsOnReadOnlyScopeDir` uses `chmod 0555`), and it hit the write path — but the read/enumerate paths need the file to exist AND be unreadable, which is fragile enough that further chmod tricks aren't earning their weight. Similarly the `ageInvocationFailed(exitCode: -1, stderr: …)` arms around `Shell.run` throwing require making `Process.run()` itself fail. Left as-is; the wrapping pattern is uniform, so behavior of one covered arm generalizes to the rest.

Nothing hit the 90% floor as a real challenge. The initial run landed at 92.26%, and the follow-up round (targeted at reachable-without-chmod paths) brought it to 96.02% with 11 new tests. Everything from that round was genuinely spec-worthy: shared-vs-non-existent scope errors, missing `ageKeyURL` at encrypt/decrypt time, dangling links on `unlink`, corrupt YAML in the decrypted payload, and empty-directory return paths for `listScopes` / `listShared` / `linkGraph`.

### ho-01.1/01.2 split: NOT warranted

The age work was not "fussier than expected." AT-02 completed on the first pass. The AT-01/AT-02 seam (pure-FS vs. encryption) matched the actual work cleanly. One structural refactor happened during AT-02 — encryption ops moved into `VaultCore+Encryption.swift` because SwiftLint's `type_body_length` fired at 352 lines. Mechanical response, not a scope surprise. Same pattern with the tests: `VaultCoreFilesystemTests.swift` and `VaultCoreEncryptionTests.swift` share fixture helpers that got hoisted to `Tests/SharibakoCoreTests/Fixtures/VaultTestSupport.swift` once the filesystem test file crossed 300 lines.

### Followups for ho-02 (Conduit)

- **`Shell.run()` is ready for `git` as-is.** The signature accommodates any binary; the caller's job is to check `exitCode` and interpret `stderr`.
- **`Shell.findExecutable` probe list may need `git`-specific paths.** Current list is `/opt/homebrew/bin`, `/usr/local/bin`, `/home/linuxbrew/.linuxbrew/bin`, `/usr/bin`. `git` is at `/usr/bin/git` on macOS (Xcode Command Line Tools) — covered. If ho-02 surfaces a machine where `git` lives elsewhere, extend the list.
- **`VaultCore` has no dirty/clean concept.** The Conduit will invoke `git status --porcelain` itself; the vault-level API doesn't need to expose that surface.
- **Two lint-config alignments landed in ho-01 as friction.** `.swiftlint.yml` gained `trailing_comma: mandatory_comma: true` (aligns with swift-format's `multiElementCollectionTrailingCommas: true`); the encryption code moved to a `+Encryption.swift` file to duck `type_body_length`. Both are project conventions worth carrying forward — expect similar tugs when Conduit code lands.
- **`age-keygen` PATH surprise.** It ships in the same Homebrew formula as `age` (verified: local install has both after `brew install age`), but is a separate binary. AT-02 shells out to both. Documented in `CLAUDE.md` alongside `age`. No parallel concern for `git` (single binary).

---

_Authored: 2026-06-30 (Think phase)._
_Executed and Reflected: 2026-06-30._
