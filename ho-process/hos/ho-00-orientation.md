---
created: 2026-06-30
status: draft
type: ho-document
project: sharibako
ho: "00"
kamae: 5
shape: orientation
builds-on:
  - kamae-1-sharibako-seed.md
  - kamae-2-sharibako-system-design.md
  - README.md
  - docs/architecture.md
  - kamae-4-sharibako-ho-overview.md
agent-tasks:
  - Ho-00-AT-01.md
---

# ho-00 — Orientation and Swift environment baseline

The first session in the build. Two things happen here. One — the scaffold landed. The Swift package compiles, the lint stack runs clean, the smoke suite passes, the public repo is live, the project CLAUDE.md points subsequent sessions at the right modules. Two — this document orients me to Swift territory before ho-01 starts cutting Vault Core code. Most of what's below is concept primers. They exist because this is my first Swift project and the build sequence assumes a working mental model of SwiftPM, Swift Concurrency, swift-argument-parser, SwiftUI, and the Xcode notarization workflow.

No shipping feature lands here. The next ho (ho-01) is where Vault Core implementation begins.

---

## 1. Pre-conditions

Verified at session end (this document is partly the retrospective of what's now true):

**Toolchain:**
- Swift 6.2.4 on macOS 26 (Tahoe), arm64
- swift-format 602.0.0 (Apple's official formatter)
- swiftlint 0.65.0
- pre-commit 4.6.0 (hooks installed at `.git/hooks/pre-commit`)

**Repo state:**
- Public on GitHub at `https://github.com/sageframe-no-kaji/sharibako` (GPL-3.0)
- Two commits on `main`: `e39f376` (initial scaffold) and `43901ce` (polish: doc comments, lint baseline fixes, CLI entry pattern)
- Remote configured for SSH via `github-no-kaji` alias (uses `~/.ssh/id_ed25519_no_kaji`)
- Default branch `main`

**Scaffold:**
- Multi-product Swift package — one library (`SharibakoCore`) + one SwiftUI app target (`Sharibako`) + one CLI executable (`sharibako`). Declared in `Package.swift`; macOS 14+ platform; Swift language mode 6; strict concurrency enabled on every target.
- Two dependencies pinned: `swift-argument-parser` (1.8.2) and `swift-log` (1.14.0). `Package.resolved` committed.
- Source layout: `Sources/SharibakoCore/SharibakoCore.swift`, `Sources/Sharibako/App.swift`, `Sources/SharibakoCLI/main.swift`.
- Test layout: `Tests/SharibakoCoreTests/SharibakoCoreTests.swift` — swift-testing `@Test` smoke suite (2/2 passing).
- Lint configs at root: `.swift-format` (strict, ~30 rules opt-in), `.swiftlint.yml` (strict, ~70 opt-in rules, `warning_threshold: 50` for onboarding).
- Pre-commit config at `.pre-commit-config.yaml` runs: trailing-whitespace, end-of-file-fixer, check-yaml, large-files, merge-conflict, private-key detect, swift-format lint, swiftlint --strict, swift build.

**Verification at session end:**
```
swift-format lint --recursive --strict Sources Tests   →  exit 0
swiftlint lint --strict --quiet                         →  0 violations
swift build                                             →  clean (all 3 targets)
swift test                                              →  2/2 pass (swift-testing)
```

**Kamae chain committed at `ho-process/`:**
- `kamae-1-sharibako-seed.md` — parti
- `kamae-2-sharibako-system-design.md` — architecture (Vault Core, Surfaces, Materializer, Conduit)
- `README.md` (repo root) — canonical public document
- `docs/architecture.md` — public architecture extract
- `kamae-4-sharibako-ho-overview.md` — 10 hos across 7 phases

**Project CLAUDE.md** at repo root imports `@~/.claude/modules/languages-swift.md` (which the personal-environment work filled in this session, replacing its prior placeholder). Project-specific rules and conventions are recorded there.

---

## 2. New concepts

The project introduces tech that is new territory. Each primer below is paragraph-level — enough mental model to direct work, not a tutorial. Classification:

- **Pick-up-in-flight** — read primer, learn while using.
- **Pre-read** — read the resource before opening the relevant ho.
- **Its-own-ho** — promoted to a separate learning ho.

Concepts are ordered by which ho first uses them.

### Swift Package Manager (SwiftPM) — *pre-read* (used: ho-00 onwards)

The `Package.swift` you're looking at is SwiftPM's declarative manifest — equivalent to `pyproject.toml` for Python. The key vocabulary: a **target** is a unit that gets compiled (a library target, an executable target, a test target); a **product** is something the package exposes for consumption (`.library(...)` for things other packages can import, `.executable(...)` for runnable binaries). One target can be referenced by multiple products, and one product can contain multiple targets. Sharibako has three targets (`SharibakoCore`, `Sharibako`, `SharibakoCLI`) bundled into three products (one library, two executables). The `swiftLanguageModes: [.v6]` line opts the whole package into Swift 6's strict concurrency rules; `enableExperimentalFeature("StrictConcurrency")` per-target reinforces it. Operations: `swift build` (compile), `swift test` (run tests), `swift run <executable>` (compile-and-run an executable target). The `swift package resolve` step pulls dependencies and writes `Package.resolved`; `swift package clean` blows away `.build/` when incremental state goes bad.

Resource: <https://www.swift.org/documentation/package-manager/>

### Swift language overview — *pre-read* (used: ho-00 onwards)

Swift's mental model is closer to Rust than Python. **Optionals** (`String?`) make absence a type-level concern — there is no `None` lurking inside non-optional types. **Value types** (`struct`, `enum`) copy on assignment; **reference types** (`class`, `actor`) share identity. **ARC** (automatic reference counting) handles class memory; structs and enums don't need it. **Protocols** are Swift's interface mechanism — closer to traits than to abstract base classes — and protocol extensions let you add default implementations without subclassing. **Generics** are first-class and constrained by protocol conformance (`func foo<T: Hashable>(_ x: T)`). What this means in practice for a Vault Core mostly-data-and-functions library: prefer `struct` and `enum` for types that carry data, prefer `protocol` for the interfaces the surfaces consume, use `class` only when you genuinely need reference semantics (rare), use `actor` when you need synchronized state across threads (also rare in Vault Core; the library is largely synchronous file I/O).

Resource: <https://docs.swift.org/swift-book/documentation/the-swift-programming-language/> (the "A Swift Tour" page is a good 30-minute primer)

### swift-format and SwiftLint — *pick-up-in-flight* (used: ho-00 onwards)

Two complementary tools running on every commit. **swift-format** is Apple's official formatter — opinionated, configurable via `.swift-format` (JSON), enforces Apple's style conventions plus a strict ruleset including `NeverForceUnwrap`, `NeverUseForceTry`, `NeverUseImplicitlyUnwrappedOptionals`, `OrderedImports`, `ValidateDocumentationComments`. It both formats (rewriting code) and lints (reporting). The pre-commit hook runs `swift-format lint --strict` (report-only); manual format is `swift-format format --in-place --recursive Sources Tests`. **SwiftLint** is older, has a broader rule library, configurable via `.swiftlint.yml` (YAML). The two overlap in places; canonical division is "swift-format owns formatting and DocC rules; SwiftLint owns Swift-specific lint rules (force unwraps, missing access modifiers, file length, etc.)." Conflicts get disabled in the SwiftLint config — already done for `sorted_imports` (conflicts with swift-format's `OrderedImports`) and `line_length` (swift-format owns it).

Resource: <https://github.com/apple/swift-format> and <https://github.com/realm/SwiftLint>

### Swift Concurrency — *pre-read* (used: ho-01 onwards)

Swift's async story is its own paradigm. **async/await** marks functions as asynchronous; the call site uses `await` to suspend. **Actors** are reference types that serialize access to their state — read like `class` but only one task touches the actor's properties at a time, so data races are compile-time impossible. **@MainActor** is a special actor for UI work; SwiftUI views are implicitly `@MainActor`. **Sendable** is a protocol marking types as safe to cross actor boundaries — value types are usually `Sendable` automatically; reference types need explicit conformance. **Strict concurrency** (enabled in `Package.swift`) makes Sendable violations compile errors instead of warnings, which catches a class of data-race bugs at build time. For Vault Core: most operations are synchronous file I/O wrapped in `try` (not `async`); the surfaces wrap calls in `async`/`Task` if they need to not block the UI. Keep `actor` usage rare; prefer pure structs + functions where possible. The `swift-argument-parser` integration is via `AsyncParsableCommand`, which makes the CLI's `run()` async — fine for shelling out to `age`/`git`.

Resource: <https://docs.swift.org/swift-book/documentation/the-swift-programming-language/concurrency> (a real chapter — set aside 45 minutes)

### Process — Swift's subprocess — *pre-read* (used: ho-01 onwards)

`Foundation.Process` is Swift's equivalent of Python's `subprocess.run`. The pattern: set `executableURL` (path to the binary), set `arguments` (array of strings), pipe stdin/stdout/stderr through `Pipe()` objects, call `try process.run()`, read the result. The standard library doesn't have a one-liner like `subprocess.run(..., capture_output=True, check=True)` — you build it. The Vault Core uses Process to invoke `age` (for encrypt/decrypt operations); the Conduit uses it to invoke `git`. A small wrapper that takes `(binary, args)` and returns `(exitCode, stdout, stderr)` is going to land early in ho-01 and get reused everywhere. Note: `Process` is `Sendable`-hostile in strict concurrency mode unless you wrap the call site carefully; expect to either annotate the wrapper as `nonisolated` or run it inside an `actor`.

Resource: <https://developer.apple.com/documentation/foundation/process>

### Foundation FileManager and file I/O — *pick-up-in-flight* (used: ho-01 onwards)

`Foundation.FileManager` is the directory/file API. `URL` is the file-path type (Swift prefers `URL` over `String` for paths). `Data` is the bytes type — read with `Data(contentsOf: url)`, write with `data.write(to: url)`. For YAML serialization of scope.yaml and the encrypted-secret contents, you'll need a YAML parser — Yams is the de-facto Swift YAML library (`https://github.com/jpsim/Yams`). For JSON Sharibako doesn't need (the schema is YAML throughout), but `JSONSerialization` and `JSONEncoder`/`JSONDecoder` are the built-in options.

Resource: <https://developer.apple.com/documentation/foundation/filemanager>

### XCTest and swift-testing — *pick-up-in-flight* (used: ho-01 onwards)

Two test frameworks coexist in the same `swift test` invocation. **XCTest** is the legacy framework — class-based (`final class FooTests: XCTestCase`), `func testFoo()` naming convention, assertions via `XCTAssertEqual` / `XCTAssertTrue`. Still required for `XCUITest` UI testing. **swift-testing** is Apple's new framework (Swift 6+) — declarative `@Test` macros, parameterized tests (`@Test(arguments: [...])`), async-native, better failure messages. `#expect(...)` instead of `XCTAssert...`. The smoke suite at `Tests/SharibakoCoreTests/SharibakoCoreTests.swift` is swift-testing. New unit tests go in swift-testing; XCTest stays available for any UI-testing or legacy interop. Both run automatically when you `swift test`.

Resource: <https://developer.apple.com/documentation/testing>

### DocC and `///` documentation — *pick-up-in-flight* (used: ho-01 onwards)

Swift's documentation system. `///` is the doc-comment prefix (single line) and convention: first sentence is a one-line summary, then a blank `///`, then the rest. Both swift-format's `BeginDocumentationCommentWithOneLineSummary` and SwiftLint's `missing_docs` rule enforce that public declarations have doc comments. `swift package generate-documentation` (with the `swift-docc-plugin`) builds a documentation site; `xcrun docc preview` serves it. Inline code in doc comments uses backticks; cross-references use `\`\`SymbolName\`\``. For Sharibako: every `public` declaration in `SharibakoCore` needs a doc comment per the lint stack; the polish commit (`43901ce`) added them for the `SharibakoCore` namespace and `version` property as the example.

Resource: <https://www.swift.org/documentation/docc/>

### swift-argument-parser — *pre-read* (used: ho-04 onwards)

Apple's CLI library. The pattern: define a `struct` conforming to `ParsableCommand` (or `AsyncParsableCommand` for async work), use property wrappers (`@Argument`, `@Option`, `@Flag`) to declare arguments, populate `static let configuration: CommandConfiguration` with command name + abstract + subcommands. The `@main` attribute on the type makes it the executable entry point — except when SwiftPM's test runner needs to alias executable main symbols (the linker bug below), in which case you use `main.swift` + `await Cmd.main()` at the top level. Subcommands compose: a parent command's `CommandConfiguration` has a `subcommands:` array of nested `ParsableCommand` types. The Sharibako CLI in ho-04 will have ~10 subcommands (`init`, `add`, `get`, `rotate`, `link`, `materialize`, `sync`, `scan`, `status`); each is its own type with its own arguments.

Resource: <https://swiftpackageindex.com/apple/swift-argument-parser/documentation/argumentparser>

### os.Logger and swift-log — *pick-up-in-flight* (used: ho-04 onwards)

Two logging libraries, each in its right place. **os.Logger** is Apple's unified logging — `import os` then `let log = Logger(subsystem: "net.sageframe.sharibako", category: "vault")`. Output goes to Apple's system log (visible in Console.app, queryable via `log stream` / `log show`, captured by Instruments). Best for the Mac app target. **swift-log** is `apple/swift-log` — a cross-platform logging API with pluggable `LogHandler` backends. Use for the CLI (which targets both Mac and Linux). Configure once at startup, use `logger.info("...")` / `logger.error("...")` throughout. For libraries like `SharibakoCore` that both surfaces use: emit through `swift-log`; let each binary configure the backend (the Mac app target can install a `swift-log` handler that bridges to `os.Logger`; the Linux CLI uses the default stdout handler).

Resource: <https://developer.apple.com/documentation/os/logger> and <https://github.com/apple/swift-log>

### macOS Keychain + LocalAuthentication — *pre-read* (used: ho-04 onwards)

The macOS Keychain stores the age private key. Access is gated by Touch ID via the `LocalAuthentication` framework. The flow: create a `SecAccessControl` with `.biometryCurrentSet` or `.userPresence` flags (`SecAccessControlCreateWithFlags(...)`); store the key as a generic password item using `SecItemAdd` with the access control attached; retrieve via `SecItemCopyMatching`, which triggers the Touch ID prompt. The whole API is C-flavored — pre-Swift Security framework. Expect to write a small Swift wrapper that hides the `CFDictionary` ceremony. The threat model is the same as SSH keys: the key lives in Keychain, biometric unlock per access, FileVault is an additional layer. On Linux (CLI only), the equivalent is a passphrase-protected age key at `~/.config/sharibako/age-key`.

Resource: <https://developer.apple.com/documentation/security/keychain_services> and <https://developer.apple.com/documentation/localauthentication>

### SwiftUI — App, Scene, View — *pre-read* (used: ho-05 onwards)

Apple's declarative UI framework. The mental model is React-like. **App protocol** is the entry point (`@main struct SharibakoApp: App { var body: some Scene { WindowGroup { ... } } }`). **Scenes** are the top-level containers — `WindowGroup` for ordinary windows, `Window` for single windows, `MenuBarExtra` for menu bar utilities. **Views** compose into the UI; the `body` property returns `some View` (an opaque protocol type — the concrete type is whatever expression you return). **Modifiers** chain on views (`.padding()`, `.frame(...)`, `.foregroundStyle(...)`) — each returns a new view wrapping the original. **State**: `@State` for view-local mutable values, `@Binding` for two-way connections to parent state, `@Observable` (Swift 5.9+) for observable model objects. Views are recomputed when their inputs change; SwiftUI diffs and updates the rendered UI. For Sharibako: the placeholder `Sources/Sharibako/App.swift` is the minimum App + ContentView pair. ho-05 builds the real three-pane Workshop on top.

Resource: <https://developer.apple.com/tutorials/swiftui>

### NavigationSplitView for three-pane layouts — *pick-up-in-flight* (used: ho-05 onwards)

A specific SwiftUI view for sidebar-list-detail layouts on macOS 14+. Replaces the older `NavigationView` with cleaner two-and-three-column behavior. Pattern: `NavigationSplitView { sidebar } content: { list } detail: { detail }`. The sidebar holds scopes, the content holds the selected scope's secrets, the detail holds the selected secret's editor. Selection is bound state passed through `@Binding`. macOS-specific behavior (toggle visibility, column widths) is configurable via `.navigationSplitViewStyle(...)`. The Workshop's three-pane layout (the system design's GUI spec) is exactly this.

Resource: <https://developer.apple.com/documentation/swiftui/navigationsplitview>

### Xcode notarization workflow — *pre-read* (used: ho-08)

Different from M4Bookmaker's PyInstaller path. The native Xcode flow: build the `.app` bundle with `xcodebuild archive`, export it with `xcodebuild -exportArchive` (using an `ExportOptions.plist` that specifies the Developer ID Application cert), upload to Apple's notary service with `xcrun notarytool submit --apple-id ... --team-id ... --keychain-profile sharibako --wait`, and staple the notarization ticket with `xcrun stapler staple Sharibako.app`. The `.dmg` packaging is separate (typically `create-dmg` or hdiutil); the `.dmg` itself can also be notarized (and should be). **Hardened Runtime** is a Gatekeeper requirement enabled via Xcode's Signing & Capabilities tab or a `.entitlements` file — it restricts what the app can do (no library injection, no executable memory pages without explicit entitlement) and is mandatory for notarization. The Apple Developer Program subscription, certificate, and `notarytool` credentials all carry over from M4Bookmaker.

Resource: <https://developer.apple.com/documentation/security/notarizing_macos_software_before_distribution>

---

## 3. Project ho shape

Decisions and conventions for the build going forward. Most are already documented in CLAUDE.md or the ho-overview; this section gathers what matters for the next several sessions.

### Shape distribution across the build

- **Orientation** (this shape): ho-00, plus the three replan checkpoints in the ho-overview (after ho-04, ho-06, ho-07). Decision-only sessions; no execution; no agent task children.
- **Ha** (Think → Execute → Reflect): ho-01 through ho-07, ho-09. The bulk of the build. Each ho's Think phase resolves architectural decisions; the Execute phase decomposes into agent tasks (typically 2-5 per ho); the Reflect phase fills in post-execution.
- **Ri** (Problem → Solution → Changes → Results): ho-08 leans this way. Bundling, signing, notarization is procedural work once the pipeline is configured. May still spawn agent tasks for the configuration step.

### Per-ho document and agent task locations

- Per-ho documents: `ho-process/hos/ho-NN-<slug>.md` (e.g., `ho-process/hos/ho-01-vault-core.md`).
- Agent task specs: `ho-process/agent-tasks/Ho-NN-AT-MM.md` (e.g., `ho-process/agent-tasks/Ho-01-AT-01.md`).
- Standalone agent tasks (no parent ho): same directory, `Standalone-AT-<slug>.md` or `Exploration-AT-<slug>.md` prefix.
- This ho has one child agent task: `ho-process/agent-tasks/Ho-00-AT-01.md` for the CI workflow (see Handoff).

### Verification rhythm

Per the operating discipline: **LINT. PRODUCE TESTS. EVALUATE TESTS. LINT. COMMIT.** Concrete for Swift:

```
swift-format lint --recursive --strict Sources Tests
swiftlint lint --strict
swift build
swift test
git commit
```

The first three run automatically at commit time via `.pre-commit-config.yaml`. `swift test` runs on demand and in CI (slow enough that it's not in the commit gate by default — pattern matches the Rust module's posture). Coverage measurement via `swift test --enable-code-coverage` + `xcrun llvm-cov report -instr-profile=.build/debug/codecov/default.profdata <test-binary>`. CI enforces the 90% floor.

### Numbering scheme

- Splits: ho-N becomes ho-N.1, ho-N.2 when scope grows too large for one focused session.
- Insertions: new work between ho-N and ho-N+1 goes as ho-N.5.
- Abandonment: closed-and-then-not-needed numbers stay dead; the address space is immutable once committed to the overview.
- Forward-only: closed hos stay closed. New work surfacing later goes in a new ho that references and supersedes the relevant earlier piece.

### Deferred decisions visible at session end

The ho-overview's deferred-decisions table folded most decisions inline with their resolving ho. One that originates here and propagates forward:

- **age binary acquisition pattern for tests** — ho-01 decides. Options: bundle the binary in test resources (`Package.swift` `.resource(...)`); require `age` on PATH and let CI install it; have a CI step that downloads + caches the binary. Affects how external contributors and CI runners reach `age` for the round-trip encryption tests.

---

## 4. Handoff

### Operational followup for this ho

**CI workflow** is the one operational item ho-00 commits to per the ho-overview. Executed as a standalone agent task:

- **Spec:** `ho-process/agent-tasks/Ho-00-AT-01.md`
- **Output:** `.github/workflows/ci.yml`
- **What it runs:** swift-format lint, swiftlint, swift build, swift test on `push` to `main` and on PR
- **When to execute:** before opening ho-01, so the first real tests have CI as a backstop

The CI workflow against an `assert true` smoke suite is ceremonial; the moment ho-01 lands real Vault Core tests, CI becomes load-bearing. Don't defer past that.

### Reading order before opening ho-01

ho-01 (Vault Core — schema, age, link resolution) is ha-shaped. The Think phase resolves: shared-entry ID representation (slug, already decided in the overview but confirmed in code), age binary acquisition for tests, age key location during development, structured-result handling for `Process` invocations. Read in this order before opening Kamae 5 for ho-01:

1. The **Swift Concurrency** primer (Section 2) — Vault Core's Process wrappers will touch this.
2. The **Process** primer (Section 2) — every age invocation is a Process call.
3. The **XCTest vs swift-testing** primer (Section 2) — round-trip encryption tests are the first real test surface.
4. The **DocC** primer (Section 2) — public Vault Core API gets doc comments.
5. **`kamae-2-sharibako-system-design.md` §2 The Vault Core** — the operations Vault Core exposes (`list_scopes`, `get_value`, `add_secret`, `link`, `unlink`, `rotate`, `inspect`).
6. **`kamae-4-sharibako-ho-overview.md` ho-01 entry** — what's in scope, what's out, what done means.

### Known gotcha for ho-01 and ho-05

The `@main` attribute on an `executableTarget` interacts badly with `swift test`'s incremental linker on Swift 6.2 + macOS 26 (Tahoe). After any edit to a target the test bundle links against, `swift test` may fail with `Undefined symbols ... "_<TargetName>_main", referenced from: _main in command-line-aliases-file`. Two workarounds:

1. **Clean rebuild clears it:** `swift package clean && swift test`. Reliable but slow on cold builds.
2. **Use `main.swift` + top-level `await Cmd.main()`** for executables that don't strictly need `@main`. The SharibakoCLI target already does this (after the polish commit). The Sharibako SwiftUI app target still uses `@main` (the `App` protocol requires it); if the bug surfaces there during ho-05, the workaround is option 1.

ho-01 doesn't add new executable targets, so the bug shouldn't appear there often — but it will recur whenever an executable target's source changes between test runs. Document the workaround in CLAUDE.md if it becomes a frequent annoyance.

### What's deferred to ho-01

- The age binary acquisition decision (named above).
- The age key location convention for development (likely `~/.config/sharibako/dev-age-key` for integration tests; ephemeral per-test for unit tests).
- The `Process` wrapper signature for shelling out to `age` (returns structured `(exitCode, stdout, stderr)`).

### Practical actions between now and ho-01

1. Execute `ho-process/agent-tasks/Ho-00-AT-01.md` to land the CI workflow.
2. Open Kamae 5 with argument `ho-01` when ready to author the Vault Core per-ho document.
3. Optional: skim the Swift Concurrency and Process primers above if Swift territory still feels opaque.

---

_Authored: 2026-06-30._
_Execution: N/A for orientation. Operational followup tracked via `Ho-00-AT-01.md`._
