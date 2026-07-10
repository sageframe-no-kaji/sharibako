---
created: 2026-06-30
updated: 2026-07-08
status: draft
type: ho-overview
project: sharibako
stage: kamae-4
kamae-chain: seed → system-design → injection-decision → readme → **ho-overview**
builds-on: kamae-2-sharibako-system-design, kamae-2.1-sharibako-injection-decision, kamae-3-sharibako-readme
next: per-ho dandori specs authored via ho-kamae-5
---

# Sharibako — Ho Overview

Seven phases (v1.0 target). Phase 0 sets up the project. Phases 1–2 build the vault substrate and the bridge to the user's filesystem with no UI at all. Phase 3 puts a CLI on top of that and earns the first real dogfooding, then ho-04.5 adds runtime injection (`sharibako run`) as a peer output verb alongside materialize; the phase then grew a run of small CLI-polish inserts as dogfooding surfaced work, and is now complete. Phases 4–5 add the Workshop and the linking UX that the parti is built around. Phase 6 ships v1.0 through signing, notarization, website, and release.

_Revision 2026-07-01: ho-04.5 inserted after the injection decision (kamae-2.1). Ho-03 entry updated to reflect the ownership decision (kamae-2.2) — per-key ownership, `.env` merge-not-overwrite, `update` verb, four-way ingest matrix. This is a build-phase document; ship/commercial concerns sit in ho-09 as they always did — not elevated to Kamae content._

_Revision 2026-07-03: Phase 3 closed. The CLI phase grew four inserts beyond ho-04/ho-04.5 as dogfooding surfaced work — ho-04.2 (interactive `init`), ho-04.4 (ingest dashboard, later superseded), ho-04.6 (plain-prompt `init` replacing the dashboard), and ho-04.7 (`run` feedback) — all complete, alongside ho-04.3 (sign the binary; unblock Keychain biometry) and ho-04.5 (`sharibako run`). Two as-built notes worth carrying forward: signing shipped via a signed `.app` bundle with `keychain-access-groups` + an embedded provisioning profile (not the raw-binary/empty-entitlements approach ho-04.3 first drafted — that entitlement is restricted, honoured only inside a bundle), and ho-04.5 shipped without `memset_s` scrubbing of decrypted values (kamae-2.1 Decision 7; SECURITY.md reconciled to match). Replan Checkpoint 1 fired — outcome recorded below. The per-ho documents under `hos/` hold the detail; those inserts are not back-filled as full overview entries. No phase restructure; no ship/commercial elevation._

_Revision 2026-07-08: Phase 3 grew a second hardening arc after Checkpoint 1 — a security/robustness sweep plus the Keychain and signal work — before Phase 4 opens. **ho-04.8–04.11** (the "Fable" cleanup sweep, Tier B: encrypt-path hygiene, coverage exclusions, identifier/path validation, EnvParser contract, ingest/link collision, CLI trust-boundary + scan resilience; Linux scoped out, macOS only), **ho-04.12** (`run`-signal semantics + Keychain modernization + `-warnings-as-errors`; the signed-install dogfood reverted its D2 and fixed a key-clobber bug D5), and **ho-04.13** (run signal ownership → **exec-replace**: `run` now execs into the child, the whole `SignalForwarder` subsystem deleted; the broker/handler + output-redaction model parked to a post-ship Kamae-2 pivot, GitHub issue #7, code pinned at tag `parked/run-signal-forwarder`). All complete; per-ho docs under `hos/` hold the detail — not back-filled as full overview entries, per the established pattern. **Two Phase-3 bugs remain owed their own hos** (dogfood-surfaced; tracked under "Anticipated splits and insertions"): a non-atomic `ingest` leaving a zombie scope on interruption, and `createVaultLayout` never being called on the production `init` path. No phase restructure._

_Revision 2026-07-10: **ho-05 executed and closed same-day** (PR #11 merged) — the Workshop shell shipped as planned: three-pane `NavigationSplitView`, Touch-ID reveal through a GUI-owned Keychain adapter (Decision 1 held; zero CLI files changed), full mutation surface, materialize with drift gate, sync, rescan; `Conduit.log` + `VaultCore.updateNotes` added to Core. The signed-install dogfood gate caught four defects the green suite missed (notes never displayed, tests leaking into the live user config, silent action outcomes, and the practitioner's pre-ho-04.14 vault lacking a git repo) — all fixed in-ho except the scaffold `git init`, folded into the owed scriptable-`init` ho. **One ratified premise failed:** synchronous-on-MainActor beach-balls on scan-heavy actions; async scan/materialize heads ho-06's list, which lives in ho-05's Reflect. Per-ho doc under `hos/` holds the detail._

The overview commits to the sequence, names the decisions each ho is responsible for resolving, and marks the three pause points where real evidence is supposed to revise the plan.

---

## What this is, and what it is not

This document is the build's directional plan. Each ho is sized to fit a single focused session; combined hos are flagged as candidates to split when the work turns out larger than the line predicts. The numbering scheme (ho-N.1, ho-N.5) exists for that reality — the plan is supposed to evolve as the build proceeds.

The system design's first-pass ho sequence is welcomed as starting material; this overview reorganizes it into phases and surfaces the splits and checkpoints the system design did not. The system design's deferred-decisions table is dissolved into per-ho decision callouts, so the decisions a given ho is responsible for resolving are right there in the ho.

This is not a contract. It is the map. Per-ho dandori specs are the territory.

---

## Phase structure

| Phase | Hos | What it produces |
|---|---|---|
| 0. Foundation | ho-00 | Swift package, GitHub repo, signing reused from M4Bookmaker, CI, baseline tests |
| 1. The vault substrate | ho-01, ho-02 | Encrypted vault on disk with git sync. End-to-end vault operations, no user surface |
| 2. The bridge | ho-03 | Markers, `.env` ingest, materialize, drift detection. Vault meets the user's filesystem |
| 3. The Tool **(complete; hardened through ho-04.13)** | ho-04, ho-04.2, ho-04.3, ho-04.4, **ho-04.5**, ho-04.6, ho-04.7, **ho-04.8–04.13** | CLI usable for real personal work. First dogfooding moment. Ho-04.5 adds `sharibako run` (injection), `sharibako clean`, and the SECURITY.md draft; ho-04.2/04.4/04.6 build and rework interactive `init`; ho-04.3 signs the binary (Keychain biometry); ho-04.7 adds `run` feedback. Post-Checkpoint-1 hardening: ho-04.8–04.11 (Fable security/robustness sweep), ho-04.12 (Keychain + signal semantics), ho-04.13 (run → exec-replace). Two bugs owed hos (see below) |
| 4. The Workshop | ho-05, ho-06 | SwiftUI app with three-state UI, first-run wizard, ingest decision matrix |
| 5. Linking UX | ho-07 | The parti-defining feature surfaced across both CLI and GUI |
| 6. Release | ho-08, ho-09 | Bundling, notarization, Homebrew tap, website, v1.0 |

---

## Phase 0 — Foundation

The project scaffolds itself. A single Swift package with two products (`Sharibako.app`, `sharibako` CLI) over a shared core library. The GitHub repo lives at `github.com/sageframe-no-kaji/sharibako`, GPL-3.0. Signing infrastructure reuses the existing Apple Developer Program from M4Bookmaker — same Developer ID cert, adapted from PyInstaller's notarization shape to native Xcode. CI runs `swift build` and `swift test` on every push so the verification stack exists from commit one. Nothing user-facing is built here; this is the encoded environment that downstream hos read.

*Release on phase complete: v0.0 (private — scaffolding only)*

### ho-00 — Project scaffolding

The first session. Initialize the Swift package with the multi-product layout, create the GitHub repo, wire CI, add baseline tests that prove the package builds and runs, set up the per-project `CLAUDE.md` that points subsequent agent sessions at the operating discipline and the kamae chain. The age binary is *not* bundled yet — Phase 1 figures out how tests reach it.

**Depends on:** Nothing (this is the start)

**What's in scope:**
- Swift package with `SharibakoCore` library, `Sharibako` (GUI) executable target, `sharibako` (CLI) executable target
- GitHub repo on `sageframe-no-kaji`, GPL-3.0, README + LICENSE seeded from the canonical files
- GitHub Actions: `swift build -c release`, `swift test`, lint (SwiftLint or SwiftFormat)
- `.gitignore` covering `.build/`, Xcode user data, `.env`, materialized files
- One trivial test per target proving the harness works
- Project `CLAUDE.md` importing `~/.claude/modules/` (Swift module placeholder — to be filled in this ho or ho-01)
- First commit on `main`; default branch protected

**What "done" means:**
- `swift build` succeeds locally and on CI
- `swift test` passes (trivial tests)
- Repository is browsable on GitHub
- Project `CLAUDE.md` exists and the next dandori session has a complete read order

**What's out of scope:**
- Bundling `age` (Phase 1's problem)
- Xcode project file for the Mac app — defer until ho-05; CLI builds with `swift build` alone
- Signing/notarization wiring — defer to ho-08

**Decisions required:**
- **CI provider**: GitHub Actions (default — matches other Sageframe projects)
- **Lint stack for Swift**: SwiftLint vs. SwiftFormat vs. both. Pick the one that runs cleanly in CI without per-developer Xcode config.
- **Swift module under `~/.claude/modules/`**: the practitioner profile flags this as a placeholder ("Swift filled in when first Swift project starts") — Sharibako is that first Swift project. Either fill it in here or defer to a sidecar moment; the dandori spec for this ho should decide.

---

## Phase 1 — The vault substrate

The bottom half of the architecture, built before any user-facing surface exists. The Vault Core owns the vault directory on disk: filesystem-as-schema, age encryption per secret, link resolution at runtime. The Conduit wraps `git` for vault sync — pull, push, commit, status — and knows nothing about secrets. By the end of the phase, an integration test creates a vault, writes encrypted scopes and secrets, commits them, pushes to a local bare remote, pulls them back, and decrypts cleanly. The data engine works end-to-end with no human interface attached.

*Release on phase complete: v0.1 (library only; not yet useful to a user)*

### ho-01 — The Vault Core: schema, age, link resolution

The vault's complete data model in code. Implements the `vault/`, `shared/`, `scopes/<id>/` filesystem layout; reads and writes `scope.yaml`, `<KEY>.age`, and `<KEY>.link` files; shells out to the `age` binary for encryption and decryption; resolves the implicit link graph by walking `.link` files at runtime. Operations: `list_scopes`, `list_shared`, `get_scope`, `get_value`, `add_secret`, `link`, `unlink`, `rotate`, `inspect`. No CLI, no GUI — these are library functions with thorough tests. The age key story is decided here: how tests get an ephemeral age key, how the production code expects to find the real one (the Keychain integration may stub here and concretize in ho-04).

**Depends on:** ho-00

**What's in scope:**
- Filesystem layout creation and parsing
- `age` invocation (shell out via `Process`)
- The nine vault operations listed above
- Plaintext slug for shared-entry IDs (e.g., `openai-personal`) — confirmed as the chosen representation
- Test fixtures: ephemeral age key, temp vault directory, round-trip encrypt/decrypt tests, link/unlink behavior
- Bundle or locate the `age` binary for tests (one of: bundle in test resources, require `age` on PATH, install via CI step)

**What "done" means:**
- All nine operations have passing tests, including link-graph resolution
- Round-trip encryption/decryption verified
- An ephemeral vault can be created, populated with linked and unlinked secrets, and read back
- Link graph orphan detection (a `shared/<id>.age` no scope references) works
- Code coverage at or above the project's 90% floor

**What's out of scope:**
- Any user-facing surface (CLI, GUI)
- Git operations (that's ho-02)
- Touch ID / Keychain integration for the production age key — stub it; concretize in ho-04
- The `.sharibako` marker file (that's ho-03)

**Decisions required:**
- **Shared-entry ID representation**: user-chosen slug (resolved — the seed's UUID/hash/slug question; the system design uses slugs in examples; this ho commits)
- **`age` binary acquisition during test runs**: bundle in test resources, require on PATH, or CI install step. Affects how external contributors run tests.
- **Age key location during development**: ephemeral per-test for unit tests; for integration tests against a real vault, document the developer-machine convention (likely `~/.config/sharibako/dev-age-key`) so the dandori spec for ho-04 has a clean handoff

**Possible split:** if age invocation and error handling turn out fussier than expected (binary discovery, exit code parsing, stdin/stdout streaming), split into ho-01.1 (filesystem layout + read/write + tests) and ho-01.2 (age invocation + encryption operations + round-trip tests).

### ho-02 — The Conduit: git wrapping

The thin layer over `git`. Operations: `commit(message)`, `push()`, `pull()`, `status()`. The Conduit knows nothing about secrets — every change is just a file change in the vault directory. The file-per-secret structure makes most conflicts impossible by construction; the cases that *do* conflict (same secret rotated on two machines between syncs) need to surface clearly without the Conduit pretending it can resolve them. v1 surfaces the conflict; UI polish for conflict resolution is deferred until conflicts happen in practice.

**Depends on:** ho-01

**What's in scope:**
- `Process`-based `git` invocation (no libgit2)
- `commit`, `push`, `pull`, `status` with clear return types
- Conflict detection: pull returns a structured "conflict" state naming the files involved
- No-op `push`/`pull` when no remote is configured
- Integration test: bare-remote round trip (init local vault, commit a scope, push to local bare repo, clone elsewhere, pull, decrypt)

**What "done" means:**
- All four operations have passing tests including the bare-remote round trip
- Conflict surface is structured (not just stderr) and the test simulates a forced conflict
- No-remote case works for every operation without errors

**What's out of scope:**
- Conflict resolution UI (deferred per system design Deferred Decision #7 — basic surfacing here; polish only if real-use conflicts demand it)
- Background / scheduled sync (manual `sync` only in v1)
- Authentication: the Conduit assumes the user's git config (SSH keys, credential helper) already works; no auth wrapper

**Decisions required:**
- **Conflict surfacing depth in v1**: structured return type naming conflicting files. Resolution is "user runs `git mergetool` outside Sharibako or restores from a known-good state." Document this clearly; the UX investment lands only if Andrew or a user hits this in real use.

---

## Phase 2 — The bridge

The Vault Core knows about the vault; the user's filesystem knows about `.env` files. The Materializer is the bridge — it owns `.sharibako` marker files at project roots, walks configured scan roots to find them, ingests existing `.env` files into proposed scope schemas for user review, writes materialized `.env` files at marker-relative paths, and detects drift between materialized files and current vault state. By the end of this phase, the data flow runs end-to-end through a test that simulates a project directory, ingests its `.env`, writes a marker, and materializes the secret back out — all without a CLI or GUI.

*Release on phase complete: v0.2 (library + materializer; programmatically usable)*

### ho-03 — The Materializer: markers, ingest, materialize, update, heal

The bridge's full responsibility set. Reads and writes `.sharibako` marker YAML; walks `scan_roots` to find markers; parses `.env` files; proposes scope schemas for user review through a four-way decision matrix (per kamae-2.2); merges owned keys into `.env` on `materialize` while preserving all non-owned lines exactly; reads `.env` back into the vault on `update` (bidirectional flow); computes the three-state model (`live_here`, `live_elsewhere`, `orphaned`); reports per-key drift via `heal`; retracts owned lines via `clean`. Nothing in this layer ever deletes a scope automatically — deletion is always an explicit user action against the Vault Core.

**Depends on:** ho-01, ho-02

**Reflects:** kamae-2.2 ownership decision — per-key ownership; `.env` merge-not-overwrite; `update` verb; four-way ingest matrix (import-local / link-shared / move-to-shared / leave-alone).

**What's in scope:**
- `.sharibako` marker read/write
- `scan(roots) → [ScopeMarker]`
- `.env` / `.env.local` / `.env.example` parsing (KEY=value, quoted values, comments, blank lines, `export` prefix, malformed-line warnings)
- Line-preserving merge: composed materialize output replaces only owned-key lines, preserving comments / blank lines / non-owned pairs / user quote style
- `ingest(directory) → ProposedScope` returning a structured proposal with four decision types per detected key
- `acceptIngest(proposal, decisions)` writing the vault-side result of an ingest decision matrix
- `materialize(scope_id, overwriteDrift: Bool)` composing the merged `.env` at the marker's target; returns `.diffPending` when drift would be overwritten and `overwriteDrift == false`
- `update(scope_id)` reading `.env`, updating vault values for owned keys that differ (bidirectional close)
- `clean(scope_id)` removing only owned lines; deletes the file if the result is empty/whitespace
- `status(scope_id) → live_here | live_elsewhere | orphaned`
- `heal(scope_id)` returning a structured `DriftReport` for owned keys only
- Integration test: simulated project dir, ingest with mixed decisions (some owned, some left-alone), materialize, hand-edit non-owned line + owned line, run `update`, assert vault picked up owned change but non-owned edit was preserved

**What "done" means:**
- All operations pass tests
- Merge preserves non-owned lines byte-for-byte across a full round-trip (materialize → hand-edit non-owned → update → materialize)
- Ingest presents all four decision types; each resolves to the correct vault-side action
- Update correctly rewrites `<KEY>.age` for keys whose file value differs from vault value; leaves non-owned lines and matching-value owned keys untouched
- Materialize composes owned lines in a stable order (alphabetical for new files; preserves user's existing order when the file already had those keys)
- Three-state computation matches reality across a multi-machine simulation
- Drift report never surfaces non-owned keys

**What's out of scope:**
- Multi-root scanning UI (config field is `[String]`; v1 exposes single root — Deferred Decision #4, post-MVP)
- Additional materialization formats beyond `.env` (Deferred Decision #5, post-MVP)
- Remote-host materialization (Deferred Decision #6, post-MVP)
- Background filesystem watching (FSEvents) — manual `scan` only in v1
- CLI subcommands (`sharibako materialize`, `sharibako update`, `sharibako ingest`) — ho-04
- Any GUI surface — ho-05/ho-06

**Decisions required:**
- **`.env` parser strictness**: accept `export FOO=bar` and strip the `export`; reject multi-line values in v1 with a warning; skip malformed lines with warnings collected in a `ParseWarnings` return, do not fail ingest (Q4 from ownership-decision conversation)
- **Default `materialize_to`**: `./.env` when the marker omits it (matches system design)
- **Materialize behavior on drift**: return `.diffPending(diff:)` from `materialize` when owned-key values differ; surfaces re-invoke with `overwriteDrift: true` (Q1 from ownership-decision conversation)
- **Ingest fallback when only `.env.example` exists**: surface keys via `suggestedKeysNeedingValues` — a checklist, not vault entries with empty values (Q2 from ownership-decision conversation)
- **Ingest name-matching for shared entries**: exact match only, no fuzzy, no case-insensitive (Q3 from ownership-decision conversation)
- **Materializer public type shape**: `public struct Materializer`, extended across files for the write path and read path (matches `Conduit` + `Conduit+Remote` precedent)
- **DriftReport shape**: contains SHA-256 of vault value and file value per owned key, not plaintext; plaintext retrieval via `VaultCore.get_value` on demand
- **Whether "leave alone" is persistent**: ephemeral in v1 (not recorded in `scope.yaml`); persistent-if-needed is a post-v1 refinement

**Not splitting into ho-03.1 / ho-03.2.** The original ho-overview speculated a split. Ho-03 stays a single ho; the two-agent-task decomposition (write path + read path) carries the density without needing a ho-level split.

---

## Phase 3 — The Tool

A CLI built on top of the substrate. The Tool exposes the operations the Vault Core, Conduit, and Materializer already implement. Commands: `init`, `add`, `get`, `rotate`, `link`, `materialize`, `sync`, `scan`, `status`. Touch ID gating concretizes here — `get` requires authentication; other commands either do (rotation, linking) or don't (read-only inspection). By the end of this phase, Andrew can use sharibako for real personal secrets work without the GUI existing yet. **This is the first dogfooding moment.**

*Release on phase complete: v0.3 (CLI usable for personal dogfooding)*

**Phase 3 as-built (complete, 2026-07-03).** The phase closed as ho-04 (CLI MVP) plus six inserts. The two spelled out in full below are ho-04 and ho-04.5. The others landed as dogfooding surfaced the need and are recorded in their own per-ho documents under `hos/`: **ho-04.2** (interactive `init` — the per-secret decision flow split out of ho-04), **ho-04.3** (sign the release binary so Keychain biometry works — shipped as a signed `.app` bundle with `keychain-access-groups` + an embedded provisioning profile, since that entitlement is honoured only inside a bundle), **ho-04.4** (an ingest dashboard, later superseded), **ho-04.6** (plain-prompt `init` replacing the dashboard), and **ho-04.7** (`run` feedback — a startup status line and a signal-shutdown countdown; see below). Replan Checkpoint 1 fired at the end of the phase; its outcome is recorded under "Replan checkpoints."

### ho-04 — The Tool: CLI MVP wired to the core

Swift ArgumentParser implementation of every CLI command listed in the system design. The init flow follows the system design's step-by-step interaction: detect existing marker, propose scope identity, request Touch ID, scan for existing secrets, present the per-secret decision (import / link / move to shared / skip), write through the Vault Core, write the marker, materialize, commit + push. `get` prints to stdout with Touch ID gating. `rotate` and `link` work end-to-end. The CLI is the first surface that talks to macOS Keychain for the production age key.

**Depends on:** ho-01, ho-02, ho-03

**What's in scope:**
- `init`, `add`, `get`, `rotate`, `link`, `unlink`, `materialize`, `sync`, `scan`, `status` commands
- Interactive prompts where the system design's init flow requires them (per-secret decision matrix as a terminal interaction)
- Touch ID via macOS Keychain for the age key (`SecAccessControl` with biometry-or-password)
- Linux fallback: passphrase-protected age key file at `~/.config/sharibako/age-key`
- Output formatting: human-readable by default; `--json` flag for scripting (status, scan, list)
- End-to-end CLI test: create vault, init a fake project dir, add secrets, materialize, sync to bare remote

**What "done" means:**
- Every command works against a real vault
- Touch ID is enforced for value-reveal operations
- Andrew can run the CLI against his actual scattered secrets and start consolidating
- A clear error message replaces every silent failure (missing vault, no age key, locked Keychain, etc.)

**What's out of scope:**
- The Workshop (GUI) — that's Phase 4
- The `sharibako-agent` Touch-ID-friction daemon (Deferred Decision #3, post-MVP — wait until friction is felt in real use)
- `--json` output for every command — start with the inspection commands and expand as needed
- Multi-vault support (single vault per machine in v1)

**Decisions required:**
- **Touch ID prompt frequency**: per command versus per CLI invocation. v1 default: per command (mirrors Apple Passwords). If friction is unbearable, the `sharibako-agent` daemon (post-MVP) is the answer — *not* loosening the per-command default.
- **Linux passphrase prompt UX**: prompt on each command, or cache via a Linux equivalent of Keychain (e.g., the kernel keyring via `keyctl`, gnome-keyring D-Bus). v1 default: prompt on each command; concretize a cache only if Linux use shows it's needed.
- **Init flow output verbosity**: by default show each step (scanning, found N secrets, proposing scope `kanyo-dev`, ...), or run quiet by default with `--verbose`. v1 default: verbose; it builds trust during first use.
- **CLI binary distribution path during dogfooding**: `swift build -c release` then `cp .build/release/sharibako /usr/local/bin/`, or a `make install` target. Choose whichever lands fastest; bundling and signing are Phase 6.

**Possible split:** if the init flow's interactive UX (decision matrix per secret, Touch ID interleaving, diff display) turns out to be a substantial UX problem in terminal form, split into ho-04.1 (non-interactive commands — `add`, `get`, `rotate`, `link`, `materialize`, `sync`, `scan`, `status`) and ho-04.2 (`init` with its full interactive flow).

**Phase boundary — replan checkpoint.** Andrew uses the CLI for real secrets work. The questions that surface here drive the next phase: what's awkward, what's missing, what's actually fine, and — critically — whether the SwiftUI investment in Phase 4 is the right next move or whether further CLI polish should come first. See "Replan checkpoints" below for the explicit checkpoint structure.

### ho-04.5 — Runtime injection (`sharibako run`), `clean`, and SECURITY.md draft

**Status: complete (2026-07-03).** `sharibako run` shipped and was dogfooded end-to-end against the real vault through the Keychain and Touch ID. As-built divergence from the scope below: no `memset_s` scrub of decrypted values (kamae-2.1 Decision 7 — the only scrub is the temp age-key file wipe; SECURITY.md reconciled to match). `clean` was already built by its Materializer siblings; this ho was `run` alone.

The injection verb specified in kamae-2.1. `sharibako run [--scope <id>] -- <command>` decrypts the current scope's secrets into memory, spawns the child with those values set in its environment, forwards stdio and signals, waits, exits with the child's status. No file is written; values live only in wrapper and child process memory. Pair verb `sharibako clean [<scope>]` retracts materialized files. `sharibako run --dry-run` prints secret names without values for pre-flight verification and safe agent-summarization. And this ho drafts `SECURITY.md` — the trust document that reflects the four-class threat model and the materialize/run exposure difference. The doc is written *as if the software is done*; it will be revised as v1 lands but its skeleton exists here.

**Depends on:** ho-01 (Vault Core), ho-03 (scope resolution from marker), ho-04 (CLI base + Keychain integration)

**What's in scope:**
- `sharibako run [--scope <id>] [--dry-run] [--] <command> [args...]` — full implementation
- Signal forwarding: SIGINT, SIGTERM, SIGHUP (at minimum) forwarded from wrapper to child's PID with a short grace timeout before SIGKILL
- stdio pass-through (inherited FDs, not piped)
- Environment merge: parent env + scope secrets, scope wins on conflict
- Vault Core addition: `get_all_secrets(scopeID:) throws -> [String: String]` — loops the existing per-secret decrypt, resolves links, returns dict
- Best-effort in-memory scrub on exit paths (`memset_s` over the decrypted string bytes where the language allows)
- `sharibako clean [<scope>]` — remove materialized files at each scope's target path, idempotent, confirms unless `--force`
- `sharibako run --dry-run` — print secret names without values, exit 0
- Integration tests: spawn a shell subcommand, assert env vars land, assert exit codes propagate, assert signals forward
- SECURITY.md draft covering: four-class threat model, what age protects, materialize vs. run exposure, keychain story, git store, backups, recovery, rotation, known risks, vulnerability disclosure

**What "done" means:**
- `sharibako run -- npm run dev` (or equivalent) works against a real vault
- `sharibako run -- docker-compose up` works and secrets land in the containers via `environment:` block references to inherited env vars
- Signal forwarding works: Ctrl-C on the wrapper terminates the child cleanly
- SECURITY.md exists, is honest, links from README, and covers every documented item
- Andrew can run his actual dev workflows via `run` and stop materializing plaintext `.env` files for wrappable consumers

**What's out of scope:**
- GUI "Run" button — CLI-native use case in v1; revisit post-v1 if user requests surface
- The `sharibako-agent` daemon for cross-invocation key holding (post-MVP; Deferred Decision #3)
- Reference-based `.env` with a Sharibako-aware loader (declined categorically in kamae-2.1)
- Linux passphrase caching for `run` (v1: prompt per invocation; concretize a cache only if Linux use shows friction)
- Materialize-to-tmpfs helper (documented in SECURITY.md as a manual technique; not automated in v1)

**Decisions required:**
- **Signal set to forward**: SIGINT + SIGTERM + SIGHUP at minimum. SIGQUIT and SIGUSR1/2 as follow-ons if the dandori session finds a real use case.
- **Grace period before SIGKILL**: on wrapper receiving a signal, forward to child, wait N seconds, then SIGKILL. v1 default: 5 seconds. Tune based on real dev-server behavior (Node HMR, Python dev servers, etc.).
- **`--dry-run` output format**: one line per secret name, or JSON with `--json`. v1 default: one line per secret; add JSON when a real user needs it.
- **`sharibako clean` scope**: `clean <scope>` cleans one scope's materialized file; `clean` with no arg cleans every scope with a marker on this machine. v1 default: require an explicit scope name; add `--all` as an opt-in flag.
- **SECURITY.md location**: top-level `SECURITY.md` (GitHub-conventional, appears in the Security tab) vs. `docs/security.md` (matches `docs/architecture.md`). v1 default: top-level. GitHub renders it in the Security tab and vulnerability reporters expect to find it there; robust-tool-for-others practice wants that path. Cross-linked from README and from `docs/architecture.md`.

**Possible split:**
- ho-04.5a: `sharibako run` + `sharibako clean` + `--dry-run` (the code work)
- ho-04.5b: SECURITY.md drafting (the writing work)

Split only if the ho spills a session. The pairing is deliberate — writing SECURITY.md while injection is fresh in mind produces a stronger document than either could produce alone.

### ho-04.7 — `sharibako run` feedback

**Status: complete (2026-07-03).** Inserted at Replan Checkpoint 1: driving `run` on real secrets surfaced feedback friction — a blank startup and a silent five-second Ctrl-C grace — and this ho closes it before the Workshop rather than carrying it in. `run` gains two stderr-only feedback surfaces, TTY-gated (suppressed under `--json`, forced on under `--verbose`): a startup status line naming the scope, the count of secrets injected, and the command; and, on SIGINT/SIGTERM/SIGHUP, a `forwarding…` line plus a plain-integer countdown across the existing grace, then a SIGKILL line if the child outlives it. No behavior change — spawn, env merge, exit-code mapping, signal forwarding, and grace→SIGKILL are byte-identical to ho-04.5. Scope was `run` only; the same terseness in `materialize`/`ingest`/`sync` is noted as a followup, not built. Detail in `hos/ho-04.7-run-feedback.md`.

**Depends on:** ho-04.5 (the `run` verb and its `SignalForwarder`).

---

## Phase 4 — The Workshop

The native Mac app. SwiftUI, Apple Silicon only, three-pane window (scopes / secrets / detail). ho-05 is the shell — window structure, scope navigation, secret editing, materialize and sync buttons. ho-06 is the polish that makes the GUI usable for non-experts — the three-state UI glyphs, the ingest decision matrix as a real flow, first-run experience, age key generation with backup nudge, heal surface. By the end of the phase, the vibe-coder success criterion (15-minute install-to-first-materialized-`.env`) is achievable in tests against a fresh user persona.

*Release on phase complete: v0.4 (GUI + CLI, full primary workflow)*

### ho-05 — The Workshop: SwiftUI shell

Xcode project for `Sharibako.app`, SwiftUI window with the three-pane layout, scope sidebar driven by the Vault Core's `list_scopes`, secret center pane with name and link/value/materialize-target columns, detail slide-in with value toggle, notes, link target, rotation history (driven by `git log`). Top-level actions: Add Scope, Add Shared Secret, Rescan, Sync. Touch ID flows through `LocalAuthentication`. The shell is wired to the same shared core library the CLI uses — no duplication of vault logic.

**Depends on:** ho-01, ho-02, ho-03, ho-04 (the CLI's Keychain integration is the pattern to follow)

**What's in scope:**
- Xcode project, app target, asset catalog, Info.plist with Keychain access entitlements
- Three-pane SwiftUI window
- Scope list and selection
- Secret list per scope (name + link/value indicator + materialize_to + last rotated)
- Secret detail slide-in (value reveal, notes editing, link target display, git log of the file)
- Add Scope, Add Shared Secret, Rescan, Sync top-level actions
- Materialize button per scope
- Touch ID on value reveal

**What "done" means:**
- The Workshop opens, lists vault contents, lets a user view and edit secrets, materialize a scope, and sync
- All operations route through the same shared core library as the CLI
- The three-pane layout matches the system design's specification
- An existing dogfooded vault (from Phase 3) opens cleanly in the GUI

**What's out of scope:**
- Three-state glyphs in the sidebar (that's ho-06's polish)
- Ingest decision matrix in the GUI (ho-06)
- First-run wizard (ho-06)
- Age key generation flow (ho-06)
- Linking UI (Phase 5)
- App icon and final visual polish — placeholder icon is fine for v0.4

**Decisions required:**
- **macOS deployment target**: 14+ (matches README). Resolved here for the Xcode project.
- **SwiftUI navigation idiom**: `NavigationSplitView` (modern, 14+) vs. `HSplitView` (older). Pick `NavigationSplitView` unless its layout fights the three-pane spec.
- **Secret value reveal idiom**: tap-to-reveal-then-auto-hide (timer), reveal-on-Touch-ID-and-stay-revealed-until-selection-changes, or click-to-toggle. v1 default: Touch ID to reveal, stays revealed until you click away. Refine in ho-06.
- **Git log rendering for rotation history**: shell out to `git log --follow <file>` and parse, or use a Swift git library. v1 default: shell out; Conduit already does this.

### ho-06 — The Workshop polish: first-run, ingest, three-state UI, age key

The polish ho. Three-state glyphs in the sidebar (live here / live elsewhere / orphaned), the ingest decision matrix as a real SwiftUI flow (not a terminal prompt), first-run experience (vault location, scan root, optional remote, age key generation with backup nudge), and the heal surface for drift. This is the densest single ho in the project; the practitioner's stage with SwiftUI also informs how it splits.

**Depends on:** ho-05

**What's in scope:**
- Three-state glyphs in the scope sidebar (computed from Materializer's `status`)
- Ingest flow as a SwiftUI sheet: scan a directory, present per-secret decisions, commit the choices
- First-run wizard: where do you keep code, where should the vault live, optional remote git URL, age key (generate new vs. import existing), backup-nudge screen
- Age key generation with a designed backup-nudge screen that vibe coders can succeed at
- Heal surface: drift indicator on materialized scopes, "Materialize" button to reconcile
- "Materialize all stale" action (referenced in the README's first-session vignette)

**What "done" means:**
- A vibe-coder persona can install the app, complete first-run, ingest a `.env`, materialize, and use it in a real project within 15 minutes (Success Criterion #3) — verified with a real non-Andrew test user
- The three-state UI accurately reflects vault and filesystem reality
- Drift is visible and one-click reconcilable

**What's out of scope:**
- Linking UX (Phase 5)
- Conflict resolution UI for git pulls (Deferred Decision #7, post-MVP unless real-use conflicts force it)
- Import flows from Vaultwarden / iCloud Keychain (Deferred Decision #10, post-MVP)
- Rotation reminders / date-tracking UI (post-MVP)

**Decisions required:**
- **Backup nudge UX** (Deferred Decision #2): the design itself. Options to consider: print-to-PDF with a recovery code, "copy to clipboard with confirmation," "save to a chosen location with a guided picker," or "show the key and require typing it back to confirm captured." v1 design lands here. Test against the 15-minute vibe-coder criterion.
- **First-run experience full design** (Deferred Decision #9): the exact flow. "Where do you keep code?" + "Where should the vault live?" + "Optional remote" + "Age key: generate or import?" — mockup in hand before the dandori session opens.
- **Vault location default**: the seed flagged `~/Library/Application Support/Sharibako/vault/` vs. `~/sharibako-vault/`. The system design's example uses `/Users/<user>/Vaults/sageframe-no-kaji-dev/sharibako-vault`. Choose between Mac-conventional (hidden under Library, app-managed) and user-visible (in the home directory, user-managed). v1 default: present both as choices in the first-run wizard, default to the user-visible one because the project's audience expects to back the vault up themselves.
- **Default scan root suggestion**: `~/` is too broad; the first-run wizard should suggest something like `~/Projects` or `~/Vaults` and accept user input. The suggestion logic is itself a small design choice.

**Possible split:** this is the densest single ho in the project. Realistic split candidates:
- ho-06.1: three-state UI + heal surface + drift indicators
- ho-06.2: ingest decision matrix as a SwiftUI flow
- ho-06.3: first-run wizard + age key generation + backup nudge

If the dandori-spec author can fit all three into one focused session, leave as ho-06. If not, split before opening the session.

**Phase boundary — replan checkpoint.** First-run + ingest + backup nudge are the moments vibe-coder usability succeeds or fails. Test with a real non-Andrew user *before* opening Phase 5. If the first-run flow needs another pass, insert ho-06.5 rather than carrying the weakness into the linking work.

---

## Phase 5 — Linking UX

The parti-defining feature, made visible. Linking-the-capability already exists in the Vault Core from ho-01 — `.link` files and resolution are part of the data model. What this phase adds is the user-facing experience: link/unlink as first-class CLI commands surfaced with the right ergonomics, the GUI link target picker, a shared-secret browser ("what's in `shared/`? what links to it?"), and the rotation propagation surface (when a shared value rotates, the linking scopes should show "stale" until materialized). Success Criterion #4 ("Rotation is one action") closes here.

*Release on phase complete: v0.5 (full MVP behavior; feature-complete for v1)*

### ho-07 — Linking semantics across both surfaces

The linking UX in both the CLI and the GUI. CLI: `link`, `unlink` work as first-class commands (they exist as Vault Core operations from ho-01; this ho adds the CLI surface and the affordances around them — name-match suggestions, "what would change?" preview). GUI: a link target picker modal (browse shared entries, search by name, see what already links to each), a shared-secret browser pane or sheet showing the full link graph at a glance, a "stale" indicator on linking scopes when a shared value rotates, and the "Materialize all stale" action the README's first-session vignette references.

**Depends on:** ho-04 (CLI base), ho-06 (GUI polish base)

**What's in scope:**
- CLI: `link <scope> <KEY> <shared_id>`, `unlink <scope> <KEY>`, both with name-match suggestion when the shared_id is omitted
- GUI: link target picker (modal sheet)
- GUI: shared-secret browser showing every shared entry and what scopes link to it
- GUI: "stale" indicator on scopes that link to a recently-rotated shared value
- GUI: "Materialize all stale" action
- Rotation propagation surface: rotating `shared/openai-personal` in the GUI updates every linking scope's stale indicator immediately

**What "done" means:**
- Success Criterion #4 verifiable: rotating a linked secret takes one edit, propagates to every project that references it, and the materialized `.env` files in all referencing projects show the new value after one materialize action
- The shared-secret browser shows accurate link counts
- Stale indication is real-time after rotation

**What's out of scope:**
- Conflict resolution for linking races (linking the same key in two scopes simultaneously across machines) — punt to v1.x
- Cross-vault linking (Deferred Decision: post-v1, listed in system design as "Architecturally Prepared For")

**Decisions required:**
- **Link target picker UX**: a modal sheet over the secret detail pane, or a slide-out inspector. v1 default: modal sheet (less ambient state, easier to dismiss).
- **Shared-secret browser placement**: a dedicated "Shared" item in the scope sidebar (treating `shared/` as a virtual scope), or a separate menu / sheet. v1 default: virtual sidebar entry. It matches the user's mental model — `shared/` is a scope of its own.
- **"Materialize all stale" scope**: every stale linker across the vault, or just the visible scope. v1 default: every stale linker across the vault, with a confirmation listing what will be materialized.

**Possible split:**
- ho-07.1: CLI link/unlink + name-match suggestions
- ho-07.2: GUI link picker + shared-secret browser
- ho-07.3: rotation propagation surface (stale indicator + Materialize all stale)

If GUI work in particular sprawls (the shared-secret browser is non-trivial UX), splitting along these lines is the natural cut.

**Phase boundary — replan checkpoint.** This is the "are we ready to ship?" gate. The MVP feature set is complete. Before investing in Phase 6's signing/notarization/website work — which is real time and has Apple-side latency — confirm that the v1 promise is delivered. If it isn't, insert another polish ho rather than locking in a release that doesn't honor the parti.

---

## Phase 6 — Release

Distribution machinery and v1.0. ho-08 builds the Mac app bundle (Xcode notarization, DMG with bundled `age`, "Install CLI" first-run action) and the CLI distribution (Homebrew tap formula, Linux `.tar.gz`). ho-09 stands up the website, the release manifest, the in-app update check, and ships v1.0. The pricing model, shared-vault documentation, and auto-update mechanism specifics all resolve here.

*Release on phase complete: v1.0 (public)*

### ho-08 — Bundling, signing, installer

Xcode notarization workflow adapted from M4Bookmaker's PyInstaller-shaped pipeline. The `.app` bundles the Swift GUI binary, the CLI binary, the `age` binary, and license notices. `create-dmg` or equivalent produces the `.dmg`. First-run "Install CLI" symlinks the bundled CLI to `/usr/local/bin/sharibako` (or `/opt/homebrew/bin/sharibako`). CLI distribution: Homebrew tap at `sageframe-no-kaji/tap` with `depends_on "age"`, plus a direct `.tar.gz` for non-Homebrew users that bundles `age` inside.

**Depends on:** ho-05, ho-06 (Mac app builds and runs cleanly before signing matters)

**What's in scope:**
- Xcode notarization workflow (`notarytool`, stapling, hardened runtime, entitlements)
- Bundled `age` binary in `Sharibako.app/Contents/Resources/`
- DMG build (signed, notarized, stapled)
- First-run "Install CLI" action with symlink logic
- Homebrew tap repo (`github.com/sageframe-no-kaji/homebrew-tap`) with the `sharibako.rb` formula
- Linux `.tar.gz` build script (bundles `age` for x86_64 and arm64)
- Release-build verification: install the DMG on a clean Mac (or VM), verify Gatekeeper accepts, run, verify Touch ID works

**What "done" means:**
- A signed and notarized `.dmg` exists and installs cleanly on a fresh Mac
- The CLI installs via `brew install sageframe-no-kaji/tap/sharibako` on Mac
- The CLI installs via `brew install sageframe-no-kaji/tap/sharibako` on Linux (homebrew-on-linux)
- The `.tar.gz` runs on Linux without Homebrew

**What's out of scope:**
- Website (that's ho-09)
- Release announcement / marketing (that's ho-09)
- Sparkle vs. custom auto-updater (Deferred Decision #11, lands in ho-09)
- App Store distribution (categorically out per system design)

**Decisions required:**
- **CLI bundling: in-app symlink vs. Homebrew-only** (seed Open Question): the system design commits to both. Confirmed here.
- **Homebrew formula maintenance flow**: hand-edit per release, or generate from a release script. v1 default: hand-edit (low frequency); automate if release cadence picks up post-v1.
- **CLI universal binary on Mac**: build for Apple Silicon only (matches the GUI) or universal? CLI is cross-platform; Linux x86_64 is supported, so why not Intel Mac CLI? v1 default: Apple Silicon only for the Mac CLI (matches the GUI's posture); Linux x86_64 + arm64 for Linux.
- **Test matrix for the notarized build**: which macOS versions, which Mac models. v1 default: macOS 14 + 15 on Apple Silicon (M1 + M3 if available).

**Possible split:**
- ho-08.1: Mac DMG build, signing, notarization, first-run CLI install action
- ho-08.2: Homebrew tap formula + Linux `.tar.gz`

These have different infrastructure (Xcode + Apple ecosystem vs. Homebrew + Linux build) and different verification surfaces. Splitting is reasonable if one half hits friction.

### ho-09 — Website, release, v1.0

Cloudflare Pages site at `sharibako.sageframe.net` (matches the M4Bookmaker pattern), release manifest endpoint, in-app update check, GitHub release for v1.0 with both the `.dmg` and the CLI `.tar.gz` attached, README and architecture.md and SECURITY.md final pass against actual shipped behavior, and resolution of the remaining deferred decisions (pricing, shared-vault doc, auto-update specifics).

**Depends on:** ho-08

**What's in scope:**
- Cloudflare Pages site (Eleventy or similar static stack — matches Sageframe convention)
- Download page with the DMG, Homebrew install command, `.tar.gz` link
- Prominent link from the site to `SECURITY.md` — non-optional for a tool that holds secrets
- Release manifest at a stable URL (e.g., `sharibako.sageframe.net/release.json`) that the app fetches on launch
- In-app update check (manifest version vs. running version → notification with download link)
- GitHub release for v1.0 with attached binaries
- README, `docs/architecture.md`, and `SECURITY.md` final pass against actual shipped behavior
- Pricing decision, applied to the website's purchase flow

**What "done" means:**
- The site is live at `sharibako.sageframe.net`
- A first-time user can land on the site, understand what Sharibako is, download the right thing, install, and complete first-run
- The in-app update check works against the live manifest
- v1.0 is tagged and released on GitHub

**What's out of scope:**
- Marketing beyond the project site (Hacker News post, blog announcement) — handle separately; not a v1.0 blocker
- Extensive commercial-site design work (differentiator copy, purchase-funnel analysis) — this is a build-phase ho for a working release; commercial polish lands in ship-phase work if and when it earns the scope
- Telemetry (categorically out per README)
- Analytics on the download site beyond what Cloudflare Pages provides by default

**Decisions required:**
- **Pricing for the signed DMG** (Deferred Decision #1): one-time / donation / patron / per-major-version. Whatever fits; the ho executes what's decided.
- **Shared-vault use documentation** (Deferred Decision #8): silent vs. explicit. Default plan: brief explicit mention ("two humans sharing one age key works fine; no team features"). Confirm or override here.
- **Auto-update mechanism specifics** (Deferred Decision #11): simple manifest-on-Cloudflare check on launch vs. Sparkle. v1 default: simple manifest check (no auto-download). Sparkle is the obvious post-v1 upgrade if the simple version becomes annoying.
- **Site stack**: Eleventy (matches `atmarcus.net`), Astro, or hand-rolled HTML. v1 default: Eleventy.

---

## What's NOT in this sequence

Tracked for v1.5 / post-v1; explicitly out of v1:

- **The `sharibako-agent` daemon** for Touch-ID-per-CLI-invocation friction. Defer until friction is felt in real CLI use. Architecturally prepared for.
- **Multi-root scanning UI.** Config field already accepts `[String]`; UI exposes only one in v1. Add when Andrew or a user has two trees.
- **Additional materialization formats** beyond `.env`. Wait for a concrete user request with a non-`.env` consumer.
- **Remote-host materialization** (SSH/SCP push). `sageframe-config-sync` and equivalents cover this externally for the homelabber use case; revisit if the vibe-coder audience surfaces a need.
- **Import flows from Vaultwarden / iCloud Keychain.** `.env` ingest is the v1 import story.
- **Conflict resolution UI for git pulls.** v1 surfaces conflicts; UI polish only if conflicts happen in real use.
- **Rotation reminders / date tracking UI.** `rotated_at` is in the schema; surfacing it as reminders is post-v1.
- **Background filesystem watching** (FSEvents). Manual `scan` only in v1.
- **A web frontend wrapping the CLI** (Tauri-shaped). Fallback only if Linux GUI or Windows demand surfaces.
- **Cross-vault sharing.** Architecturally possible; not modeled in v1.

---

## Replan checkpoints

Three explicit pause points. At each one, the practitioner stops, evaluates progress against real evidence, and decides whether to continue as planned, insert a polish ho, or replan.

### Checkpoint 1 — After ho-04.5 (CLI + injection usable)

**What's true:** the substrate works end-to-end, the CLI is usable, and both output verbs (`materialize` and `run`) are wired. Andrew has been consolidating real personal secrets into the vault and running his actual dev workflows via `sharibako run`. SECURITY.md exists in draft form.

**What to evaluate:** is the CLI awkward in ways the GUI won't fix on its own? Is Touch ID frequency on `run` tolerable, or does the `sharibako-agent` daemon need to move forward from post-MVP? Is signal forwarding robust against real dev-server behavior? Does SECURITY.md pass an outside-eye reading, or does it need another pass before Phase 6? Are there missing CLI commands real use surfaced?

**Why this is a checkpoint:** Phase 4 is a substantial investment (SwiftUI from scratch is half the project). Reality from Phase 3 should shape what Phase 4 actually needs to be — not the other way around. Injection specifically carries the threat-model coverage for Class 4 (workspace file-readers); if it's rough, Phase 4 shouldn't paper over it.

**Outcome (fired 2026-07-03).** The CLI was used on real secrets. Touch ID frequency on `run` was tolerable ("a security app; no problem with it") — the `sharibako-agent` daemon stays post-MVP. `Foundation.Process` propagated exit codes and signal-death faithfully; signal forwarding held (Ctrl-C terminated the child cleanly, no orphan) — no `posix_spawn` fallback needed. SECURITY.md's `run`/`--dry-run` sections were reconciled against shipped behavior (the `memset_s` claim was drift; corrected). One friction surfaced: `run` was silent at startup and across the Ctrl-C grace. That became **ho-04.7** (`run` feedback), built and closed here rather than carried into Phase 4. **Decision: proceed to Phase 4 (ho-05, the Workshop).** The CLI is solid enough; no further CLI polish is gating.

### Checkpoint 2 — After ho-06 (GUI polish complete)

**What's true:** the GUI is usable for primary workflows. First-run, ingest, and backup nudge exist as designed.

**What to evaluate:** can a real non-Andrew vibe-coder complete first-run-to-first-materialized-`.env` in 15 minutes (Success Criterion #3)? If not, the failure is here, not in Phase 5. Test with a real user before opening Phase 5.

**Why this is a checkpoint:** the linking UX in Phase 5 depends on the GUI's established idiom. If that idiom is weak, the linking UX will be weak on top of weakness. Insert ho-06.5 (first-run polish based on user testing) if needed.

### Checkpoint 3 — After ho-07 (linking UX complete)

**What's true:** the MVP feature set is delivered. The parti — including the rotation-propagation feature — is visible everywhere it needs to be.

**What to evaluate:** does the project, used end-to-end, deliver every success criterion? Transcript leak stopped (1)? Scatter consolidated (2)? Vibe-coder unassisted success (3)? Rotation one action (4)? If any of these fail, an additional polish ho is the answer — not committing to Apple notarization on a v1 that doesn't actually work.

**Why this is a checkpoint:** Phase 6's signing/notarization work has Apple-side latency and binds the project to a public commitment. Confirm the v1 promise is delivered before locking in a release.

---

## Numbering and insertion

The numbering scheme exists because plans evolve.

- **Splits:** ho-N becomes ho-N.1, ho-N.2, ho-N.3 when its scope turns out larger than one focused session can hold. The original ho-N stops being authored; its split successors carry the work.
- **Insertions:** new work between ho-N and ho-N+1 gets a decimal — ho-N.5. Insertions usually appear at replan checkpoints (a polish ho after a reality check) or when real-world friction surfaces an unplanned dependency.
- **Abandonment:** if a ho's number has been published in an overview and the plan changes such that it's no longer needed, the number stays dead. ho-N skips to ho-N+1 with no replacement; the address space is immutable once committed to the overview.

---

## Anticipated splits and insertions

Candidates surfaced during the overview, by pattern:

**Combined-scope hos likely to split:**

- **ho-03 (Materializer)** → ho-03.1 (write path: markers + materialize + status + heal) and ho-03.2 (read path: ingest + `.env` parsing + name-matching) if ingest's decision matrix or `.env` parsing edge cases sprawl.
- **ho-06 (GUI polish)** → ho-06.1 (three-state UI + heal), ho-06.2 (ingest flow in SwiftUI), ho-06.3 (first-run wizard + age key + backup nudge). This is the densest ho in the project; splitting is the default expectation unless one focused session can carry all three.
- **ho-07 (Linking UX)** → ho-07.1 (CLI link/unlink), ho-07.2 (GUI link picker + shared-secret browser), ho-07.3 (rotation propagation surface). Splits naturally along surface lines.
- **ho-08 (Bundling + signing)** → ho-08.1 (Mac DMG + notarization + Install CLI) and ho-08.2 (Homebrew tap + Linux `.tar.gz`). Different infrastructure, different verification.

**Insertions likely after replan checkpoints:**

- **ho-04.5** was originally speculative here; it shipped as a committed ho carrying `sharibako run` (see Phase 3). The post-Checkpoint-1 inserts that were speculative here have since landed: **ho-04.6** (plain-prompt `init`, superseding the ho-04.4 dashboard) and **ho-04.7** (`run` feedback). The `sharibako-agent` daemon was *not* moved forward — Touch ID friction proved tolerable in real use.
- **ho-06.5** after Checkpoint 2: first-run UX polish if vibe-coder testing fails the 15-minute criterion.
- **ho-07.5** after Checkpoint 3: any final polish needed before locking in the v1 promise.

**Insertions likely from real-world data:**

- **A small benchmarking or perf ho** if the vault grows large enough during dogfooding that scan / list / status operations feel slow. Inserts wherever the friction surfaces.

**Owed from Phase 3 dogfooding (bugs awaiting their own hos):**

- ~~**`createVaultLayout` never called on the production path**~~ — **FIXED in ho-04.14.** Root cause was an access level: the scaffolding was `internal`, reachable only by `@testable` tests, never by the CLI module. Fixed by exposing `VaultCore.createVault(at:)` (public) and wiring it into `key generate` (the command the "vault not found" hint names), which now scaffolds `scopes/`+`shared/` before writing the key. Fresh-install bootstrap verified end to end. Followup surfaced: `init` is interactive-only (no scriptable `--scope-id/--type`), so the `init` half of a bootstrap can't be unattended/tested — a small scriptable-init ho would close that.
- **Non-atomic `ingest`** — an interrupted ingest can leave a zombie scope (partial vault-side write, no clean rollback). Robustness, not correctness-blocking; can defer past the GUI. **Still owed.**

---

## Other deferred decisions

Decisions that don't tie to a specific v1 ho. Tracked here so they don't get lost.

- **Visual identity for the website and app icon.** Beyond the project name and a basic mark, no visual design work is committed in v1. If a designed identity feels necessary before v1.0, insert a ho before ho-09 — but this is the kind of thing a v1.x "Ship-phase" pass usually handles better than the build itself.
- **Sageframe-wide design system application** (per `atm-brand-system` skill). The website in ho-09 should follow Andrew's personal brand system; the application of that is a content decision at ho-09 time, not an architectural decision.
- **GPL-3.0 vs. dual-license for paid binary clarity.** The seed and system design both commit to GPL-3.0. The "free source / paid binary" pattern works fine under GPL — the binary is a derivative work and is still GPL-licensed; what the user buys is the convenience of not building it. No license re-evaluation in v1 unless legal counsel surfaces a reason.
- **First-class import support for tools beyond `.env`.** The architecture is prepared; v1 ships `.env` ingest only. Real-user requests after v1.0 drive what comes next.
- **Telemetry or anonymous usage metrics.** Categorically out per the README's posture. No re-evaluation.

---

## Dependency summary

```
Phase 0 — Foundation
└── ho-00 ──────────────────────────────────────────── v0.0 (private)

Phase 1 — The vault substrate
├── ho-01 (Vault Core)
└── ho-02 (Conduit) ──────────────────────────────────  v0.1

Phase 2 — The bridge
└── ho-03 (Materializer) ────────────────────────────── v0.2

Phase 3 — The Tool  (complete; hardened post-Checkpoint-1 through ho-04.13)
├── ho-04   (CLI MVP)
├── ho-04.2 (interactive init)
├── ho-04.3 (sign binary; Keychain biometry)
├── ho-04.4 (ingest dashboard — superseded)
├── ho-04.5 (sharibako run, clean, SECURITY.md draft)
├── ho-04.6 (plain-prompt init — replaces the dashboard)
├── ho-04.7 (run feedback)
│       ◆ Replan Checkpoint 1 — FIRED: proceed to Phase 4
├── ho-04.8–04.11 (Fable cleanup sweep — Tier B security/robustness)
├── ho-04.12 (run-signal semantics + Keychain modernization)
├── ho-04.13 (run signal ownership → exec-replace)
└── ho-04.14 (fresh-install vault scaffold — createVaultLayout fix) ── v0.3
        · owed ho: non-atomic ingest (deferrable); scriptable-init (followup)

Phase 4 — The Workshop
├── ho-05 (SwiftUI shell)
└── ho-06 (GUI polish, first-run, ingest, backup nudge)
        ▲
        │  ◆ Replan Checkpoint 2 (vibe-coder test) ── v0.4

Phase 5 — Linking UX
└── ho-07 (link UX across CLI + GUI)
        ▲
        │  ◆ Replan Checkpoint 3 (v1 promise) ─────── v0.5

Phase 6 — Release
├── ho-08 (Bundling, signing, installer)
└── ho-09 (Website + v1.0) ──────────────────────────── v1.0
```

Dependencies:
- ho-01 depends on ho-00.
- ho-02 depends on ho-01.
- ho-03 depends on ho-01 and ho-02.
- ho-04 depends on ho-01, ho-02, ho-03.
- ho-04.5 depends on ho-01 (Vault Core), ho-03 (scope resolution), ho-04 (CLI base + Keychain integration).
- ho-04.7 depends on ho-04.5 (the `run` verb and its `SignalForwarder`).
- ho-05 depends on the substrate (ho-01..ho-04) — ho-04's Keychain pattern is the model the GUI follows. The ho-04.x CLI-polish inserts (04.2/04.3/04.5/04.6/04.7) have no GUI counterpart in v1, so ho-05 does not depend on them.
- ho-06 depends on ho-05.
- ho-07 depends on ho-04 (CLI base) and ho-06 (GUI polish base).
- ho-08 depends on ho-05, ho-06 (the Mac app must build and run cleanly before signing matters).
- ho-09 depends on ho-08.

---

## What to do with this document

The overview is the map. Each ho is the destination for a Kamae 5 (`ho-kamae-5-authoring-collaborator`) session, which produces a per-ho dandori spec — the surgical, command-verifiable instruction the executing agent runs against. Open one ho at a time; do not write all the dandori specs in advance.

Update this overview as the build proceeds. A ho that splits gets its successors named here (ho-03 → ho-03.1, ho-03.2). A ho that surfaces a new decision gets the decision recorded against it. A replan checkpoint that fires gets its outcome noted, including any inserted hos. The overview is a living document; small frequent updates beat large rare ones.

When in doubt about a ho's scope: the overview's job is the spine (heading, narrative, dependencies, decisions, light scope, possible-split flag). The per-ho dandori spec's job is the operational depth (files to touch, exact tests, verification commands, commit format). If a question is about *what* the ho is, it belongs here. If a question is about *how* the ho gets executed, it belongs in the dandori spec.

The next *planned* dandori session is **ho-05 — The Workshop: SwiftUI shell** (Phase 4) — the GUI. Phases 0–3 are complete and hardened through ho-04.13; ho-05's first work is scaffolding `xcode/Sharibako.xcodeproj` against the Swift package (deferred to exactly this point).

**Gate status before ho-05.** The fresh-install correctness bug (**`createVaultLayout`**) is **fixed in ho-04.14** — a clean bootstrap now works, so it no longer gates Phase 4. **Non-atomic ingest** remains owed but is robustness, not correctness-blocking, and can defer past the GUI. A **scriptable-`init`** followup (surfaced in ho-04.14) would let a full bootstrap be tested/unattended — nice-to-have, non-gating. Nothing now blocks ho-05.

_Phases 0–3 dandori specs live under `agent-tasks/` and their per-ho documents under `hos/`; the closed ones are the historical record and do not get reopened. Phase 4 begins fresh at ho-05 once the gate call above is made._
