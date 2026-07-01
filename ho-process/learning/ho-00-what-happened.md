---
created: 2026-06-30
type: teaching-note
project: sharibako
about-ho: "00"
audience: practitioner
---

# ho-00 — what actually happened

A plain-language walkthrough of what the first Sharibako session built and why. ho-00 is called "orientation" because it doesn't ship a feature — it puts the scaffolding, tooling, and mental model in place so that ho-01 (the Vault Core) can be built quickly and cleanly.

Think of it like the site prep and utilities for a building: nothing here is what you'll live in, but everything after depends on it being level, connected, and up to code.

---

## What we set up, at a glance

Four things landed in ho-00:

1. **A Swift Package** — the project's build system, wired up so `swift build` compiles three things at once: a library, a GUI app, and a CLI.
2. **A lint stack** — two tools, running at every commit, that catch style violations and code-smell errors before they enter the repo.
3. **A pre-commit hook** — the plumbing that runs the lint stack automatically when you `git commit`, so you can't accidentally commit broken code.
4. **A CI workflow** — the same lint stack runs on GitHub every time you push to `main` or open a PR. So even if a commit slips through locally, CI catches it before it hits anyone else.

That's it. No Sharibako-the-vault functionality was built. But everything from ho-01 forward depends on this frame being in place.

---

## 1. The Swift Package — `Package.swift`

Swift Package Manager (SwiftPM) is Swift's equivalent of Python's `pyproject.toml` + `uv`. A single file, `Package.swift`, declares:

- What the package **is** (name, supported platforms).
- What **targets** compile inside it (units of source code — a target compiles as a library, an executable, or a test bundle).
- What **products** the package exposes (a target becomes a product when we let it be imported or run from outside).
- What **dependencies** it pulls in from GitHub, with version pins.

Sharibako's `Package.swift` declares three targets:

| Target | What it is | Where the code lives |
|---|---|---|
| `SharibakoCore` | The library. Owns vault logic. | `Sources/SharibakoCore/` |
| `Sharibako` | The SwiftUI Mac app (GUI). | `Sources/Sharibako/` |
| `SharibakoCLI` | The `sharibako` CLI binary. | `Sources/SharibakoCLI/` |

Plus one test target: `SharibakoCoreTests` at `Tests/SharibakoCoreTests/`.

### Why multi-product from the start?

The system design (Kamae 2) said: one library carries the vault logic; both the GUI and CLI are thin surfaces on top of it. That's an architectural commitment. Declaring it in `Package.swift` on day one means:

- The library can't accidentally depend on GUI code (SwiftUI won't compile on Linux; the CLI has to be portable).
- The GUI and CLI can't accidentally reimplement vault logic — they have to import `SharibakoCore` and call its public API.
- Tests only need to be written once, against `SharibakoCore`. The surfaces don't need their own test infrastructure.

You could imagine a lazier version where we build a single "app" target, then split it later. That would work, but it lets the architecture drift while nothing forces the seam. The seam is in the file structure from commit one.

### Dependencies pinned

Two dependencies from Apple:

- `swift-argument-parser` (1.8.2) — the CLI's command-line parser. Same idea as Python's `argparse` or Rust's `clap`, but Apple's version and idiomatic in Swift.
- `swift-log` (1.14.0) — a logging abstraction. Cross-platform (works on macOS and Linux). Doesn't do the logging itself; you plug in a backend at startup.

Both are pinned via `Package.resolved` — a file SwiftPM writes that records the exact version resolved, so every clone builds the same thing.

### Language mode

`swiftLanguageModes: [.v6]` in `Package.swift` tells the compiler: use Swift 6's rules. The important one is **strict concurrency** — if your code has a data race the compiler can prove, it's a compile error, not a runtime crash later. This is why every target also has `.enableExperimentalFeature("StrictConcurrency")` — belt and suspenders.

---

## 2. The lint stack — swift-format + SwiftLint

Two tools running at every commit. They overlap in places, but each catches things the other misses.

### `swift-format` — Apple's official formatter

Configured via `.swift-format` (a JSON file at the repo root). It does two jobs:

1. **Formats code** — rewrites source to match a canonical style. Indentation, brace placement, line breaks, trailing commas on multi-line collections, sorted imports, etc.
2. **Lints style** — with `--strict`, it treats stylistic rules as errors. Rules like `NeverForceUnwrap` (don't use `!` on optionals), `ValidateDocumentationComments` (public API must have proper doc comments), `AllPublicDeclarationsHaveDocumentation` (every `public` thing needs a `///` comment).

We use it in **lint mode** at commit time — it reports violations without rewriting. When you want it to rewrite, you run `swift-format format --in-place --recursive Sources Tests`. That happened once during ho-01 to fix line-length issues after a variable rename.

### `SwiftLint` — the broader lint tool

Configured via `.swiftlint.yml`. Older, more rules, more Swift-specific. Catches things swift-format doesn't:

- Force unwraps (redundant with swift-format, but named differently).
- Files longer than 500 lines, types with bodies longer than 300 lines.
- Access modifier hygiene (public extensions should mark members individually, not the extension itself).
- Empty `XCTest` methods, dead code patterns, cyclomatic complexity thresholds.

### Why two tools?

They partition the work by convention:

- **swift-format** owns pure formatting and documentation rules.
- **SwiftLint** owns Swift-specific code-smell rules (force unwraps, missing modifiers, length ceilings).

Where they collide, we resolve the collision in config. Two examples:

- Both had opinions about **import ordering**. SwiftLint's `sorted_imports` wants alphabetical. swift-format's `OrderedImports` wants regular imports before `@testable` imports (which SwiftLint would break). We disabled `sorted_imports` in SwiftLint. swift-format wins.
- Both had opinions about **line length**. We disabled it in SwiftLint. swift-format's `lineLength: 120` wins.
- A third collision surfaced in ho-01: **trailing commas on multi-line collections**. swift-format's config was set to `multiElementCollectionTrailingCommas: true` (require them); SwiftLint's default was to forbid them. This didn't fire until real code introduced a multi-element array literal. Fix: set SwiftLint's `trailing_comma: mandatory_comma: true` to match. Both now agree.

The pattern: when swift-format and SwiftLint disagree, swift-format is the canonical formatter and SwiftLint follows.

---

## 3. The pre-commit hook

`.pre-commit-config.yaml` at the repo root declares a list of checks that run **before every `git commit`**. If any check fails, the commit is refused. This is the local safety net.

What runs, in order:

1. **Trailing whitespace** — strips trailing spaces/tabs.
2. **End-of-file fixer** — ensures every file ends with a single newline.
3. **YAML validity** — parses `.yml` files, refuses commits that break them.
4. **Large file check** — refuses to commit files above a size threshold (accidental binary commits).
5. **Merge conflict marker check** — refuses commits containing `<<<<<<<` etc.
6. **Private key detector** — refuses commits containing anything that looks like a private key.
7. **swift-format lint** — the format check above.
8. **SwiftLint --strict** — the lint check above.
9. **swift build** — must compile.

Notably NOT in the pre-commit gate: `swift test`. Running the full test suite on every commit is too slow for local iteration. Tests run in CI (see below) and on demand (`swift test`).

The pre-commit is powered by `pre-commit` (the tool from `pre-commit.com`). It's installed once per repo via `pre-commit install`, which writes a shell script to `.git/hooks/pre-commit`. From then on, `git commit` triggers it.

You saw this fire in ho-01: every commit showed a `[WARNING] Unstaged files detected. [INFO] Stashing…` block, followed by the check list, ending in `Passed / Skipped`. Any failure would have blocked the commit.

---

## 4. The CI workflow

`.github/workflows/ci.yml` — a GitHub Actions workflow. Runs on GitHub's servers every time we push to `main` or open a PR against `main`.

What it does:

1. **Checkout** — pulls the repo into a fresh runner.
2. **Select Xcode** — picks the newest available Xcode that ships Swift 6.2+. Falls through 16.4 → 16.3 → 16.2 → 16.1 → 16 until it finds one, or reports which is being used. This was a real problem: an earlier version pinned Xcode 16.0, which shipped Swift 6.0, and the project's dependencies required 6.2+. The fix landed in commit `bcaccc7`.
3. **Install lint tooling** — `brew install swift-format swiftlint`. Then in ho-01 we added `age` to the same step.
4. **Cache the SwiftPM build directory** — `.build/` is cached by `Package.resolved`'s hash. Speeds up subsequent runs significantly (cold builds take 2+ minutes; cached builds skip most of that).
5. **Lint — swift-format** — same command as pre-commit.
6. **Lint — SwiftLint** — same command as pre-commit.
7. **Build** — `swift build`.
8. **Test** — `swift test`. This is what pre-commit doesn't run.

CI runs on `macos-15` — a specific runner image, not `macos-latest` (which drifts as new images land and would silently break the pipeline when Apple's defaults change).

### Why the concurrency setting matters

The workflow file has:

```yaml
concurrency:
  group: ci-${{ github.ref }}
  cancel-in-progress: true
```

Meaning: if you push twice in quick succession to `main`, the first CI run gets cancelled and only the second finishes. Prevents wasted compute on stale commits.

### The observable result

You can see this working in the git log. Every push to `main` triggers a run. `gh run list --repo sageframe-no-kaji/sharibako` shows the history. The AT-02 push in ho-01 was CI run `28490911537` — 55 seconds end-to-end, green.

---

## 5. What ho-00 didn't do

Explicitly deferred:

- **Coverage measurement in CI.** No 90% floor check. That lands in ho-01 when there's real code to measure against.
- **A signed/notarized release pipeline.** That's ho-08.
- **Any Vault Core code.** That's ho-01.
- **Anything about `age`.** The `age` binary isn't installed, not documented, not referenced. ho-01 handles it.

The temptation was to over-scaffold. We didn't. Every commit landed something that would be in use by the next session.

---

## 6. The other big thing: the orientation document itself

`ho-process/hos/ho-00-orientation.md` is a substantial document. Not code — a briefing. It exists because Sharibako is your first Swift project, and the build sequence assumes a working mental model of ~12 Swift-ecosystem concepts (SwiftPM, Swift Concurrency, `Process`, FileManager, XCTest vs swift-testing, DocC, swift-argument-parser, os.Logger vs swift-log, Keychain + LocalAuthentication, SwiftUI, NavigationSplitView, Xcode notarization).

Each concept in that doc gets a paragraph-level primer classified as:

- **pick-up-in-flight** — read the primer, learn while using.
- **pre-read** — read the linked resource before opening the relevant ho.
- **its-own-ho** — needs a whole session to internalize.

That document is the reference you can come back to when a Swift concept feels opaque during a later ho. It's also the reference an AI agent reads at the top of a fresh session to know what to expect from Sharibako's codebase.

---

## Where to look

If you want to touch something concrete:

- **Package structure:** `Package.swift` at repo root. Read from top to bottom — it's declarative and short.
- **Lint configs:** `.swift-format` (JSON) and `.swiftlint.yml` (YAML) at repo root. Skim the rules opted in and disabled.
- **Pre-commit config:** `.pre-commit-config.yaml`. Short.
- **CI workflow:** `.github/workflows/ci.yml`.
- **Orientation doc:** `ho-process/hos/ho-00-orientation.md` — the biggest artifact, worth returning to.

---

## The one gotcha you should know about

ho-00 documented (and ho-01 hit) a Swift 6.2 + macOS 26 linker bug: after any edit to an executable target's source, `swift test` may fail with `Undefined symbols … "_Sharibako_main"`. The fix is `swift package clean && swift test`. Reliable but slow.

The workaround for CLI executables is to use `main.swift` with top-level `await Cmd.main()` instead of `@main` on the type. `SharibakoCLI/main.swift` already does this. The SwiftUI app can't (the `App` protocol requires `@main`), so that target will still trip the bug occasionally. When it happens: clean rebuild.

---

_Written 2026-06-30, after ho-01 completed._
