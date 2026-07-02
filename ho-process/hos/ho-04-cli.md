---
created: 2026-07-02
status: complete
type: ho-document
project: sharibako
ho: "04"
kamae: 5
shape: ha
builds-on:
  - kamae-1-sharibako-seed.md
  - kamae-2-sharibako-system-design.md
  - kamae-2.1-sharibako-injection-decision.md
  - kamae-2.2-sharibako-ownership-decision.md
  - README.md
  - docs/architecture.md
  - SECURITY.md
  - kamae-4-sharibako-ho-overview.md
  - ho-process/hos/ho-00-orientation.md
  - ho-process/hos/ho-01-vault-core.md
  - ho-process/hos/ho-02-conduit.md
  - ho-process/hos/ho-03-materializer.md
agent-tasks:
  - Ho-04-AT-01.md
  - Ho-04-AT-02.md
---

# ho-04 — The Tool: CLI MVP wired to the core

The first practitioner-visible surface. `SharibakoCLI` grows a Swift ArgumentParser subcommand tree that binds `SharibakoCore` to the terminal: macOS Keychain-gated age key with Touch ID, all the non-interactive verbs (`status`, `scan`, `list`, `get`, `heal`, `add`, `rotate`, `link`, `unlink`, `materialize`, `update`, `sync`, `clean`), plus key management (`key generate`, `key import`, `key export`). Human-readable output by default, `--json` on inspection verbs, exit code taxonomy for scripting. When this ho lands, the practitioner can use sharibako against real secrets from the terminal — dogfooding begins.

**Out of scope:**
- Interactive `sharibako init` flow — that's ho-04.2 (split off per Decision 1 below)
- `sharibako run` and SECURITY.md polish — that's ho-04.5
- The `sharibako-agent` daemon for cross-invocation key holding (post-MVP; explicit followup for the phase-boundary replan checkpoint — see Followups)
- Workshop / GUI (ho-05 / ho-06)
- Multi-vault support (single vault per machine in v1)
- Linux fprintd/PAM fingerprint integration (no clean age integration for v1)
- Bundling / signing / notarization / Homebrew tap (Phase 6)

**Resolves deferred decisions** (from the ho-overview):
- Touch ID prompt frequency (Decision 4 — per command in v1)
- Linux fallback UX (Decision 3 — passphrase-encrypted file by default; age plugins pass through transparently)
- Distribution path during dogfooding (Decision 5 — `scripts/install.sh`)
- `clean` command's home (Decision 2 — moved from ho-04.5 to ho-04; belongs with the Materializer triad)

**Structurally supersedes** part of the ho-overview's ho-04 scope:
- `sharibako init` moves to a new ho-04.2 (rather than the overview's suggested ho-04.1/ho-04.2 split-if-needed language). This ho commits to that split up front.

---

## Phase 1 — Think

### Decision 1 — Scope split: pull `init` out, keep everything else

The overview's ho-04 bundled four substantive workstreams: (a) CLI scaffold + non-interactive commands, (b) interactive `init` with the four-way ingest matrix, (c) Keychain-gated age key + Touch ID, (d) Linux fallback. That's on the order of ho-01 + ho-02 + ho-03 combined.

**This ho:** (a) + (c) + (d). Non-interactive command surface + Keychain integration + Linux fallback.

**ho-04.2 (new):** (b). The interactive `init` flow with the four-way ingest decision matrix (`Materializer.ingest` → per-key prompts → `Materializer.acceptIngest`). `init`'s UX design load is qualitatively different from the other commands' — they're thin wrappers over `SharibakoCore`, `init` is a real terminal-UX design problem. Doing it inline while also getting the boring verbs working splits attention badly.

Keychain stays in ho-04. The age key story only becomes real when there's a surface, and Keychain integration is one focused unit (`SecAccessControl` with `.userPresence`, `SecItemCopyMatching`, a small key-management verb set). It belongs with the CLI that uses it.

### Decision 2 — Command surface for ho-04

Every non-interactive verb the practitioner needs to use sharibako in real work.

**Inspection** (some Touch-ID gated where they reveal plaintext):
- `sharibako status [<scope>]` — vault + scope state, no plaintext
- `sharibako scan [<root>]` — enumerate `.sharibako` markers below `<root>` (defaults to cwd)
- `sharibako list [--shared]` — list scopes; `--shared` lists shared entries
- `sharibako get <scope> <key>` — reveal one plaintext value (Touch-ID gated); prints raw value + newline on stdout for shell-substitution use
- `sharibako heal [<scope>]` — per-key drift report between vault and materialized file

**Write** (Touch-ID gated on decrypt paths):
- `sharibako add <scope> <key> [--value <v> | --from-stdin]` — encrypt and add a scope-local secret
- `sharibako rotate <scope> <key> [--value <v> | --from-stdin]` — rotate an existing secret
- `sharibako link <scope> <key> <shared-id>` — create a `<key>.link` pointing at a shared entry
- `sharibako unlink <scope> <key>` — convert a link back into a scope-local `.age` value
- `sharibako materialize [<scope>] [--force]` — write `.env` from vault (`--force` overrides drift, mapping to `overwriteDrift: true`)
- `sharibako update [<scope>]` — pull hand-edited `.env` values back into the vault
- `sharibako clean [<scope>]` — remove owned lines from `.env`, deleting the file if only blanks/comments remain
- `sharibako sync` — `commit` + `push` + `pull` in sequence, structured output on conflict

**Key management** (permanent utilities, not just dogfooding):
- `sharibako key generate` — run `age-keygen` internally, store the private key in Keychain, print the public key to stdout for backup
- `sharibako key import <path>` — take an existing age key file, move it into Keychain, offer to delete the file (with confirmation)
- `sharibako key export --public` — print the public key to stdout; `--private --i-know-this-is-plaintext` prints the private key to stdout for recovery-workflow escape hatch

**Deferred out of this ho:**
- `sharibako init` — ho-04.2 (interactive)
- `sharibako run` — ho-04.5
- Remote reconfiguration verb (`sharibako remote set-url <url>` or similar) — followup; users can edit `.git/config` for now, but this deserves a dedicated verb

`clean` moves from ho-04.5 to ho-04. Rationale: `clean` is a one-shot Materializer call with the same shape as `materialize` and `update`. Keeping the Materializer-verb-triad together makes the CLI surface easier to reason about — everything that touches `.env` in one ho. The `run`/`clean` "retract-vs-inject" pairing the overview named still works — SECURITY.md can discuss both even if the code landed a session apart.

### Decision 3 — Vault + age key location

**Vault directory.** Default `~/.sharibako/vault/`. `SHARIBAKO_VAULT` environment variable overrides. `--vault <path>` CLI flag overrides both. No YAML config file for v1 — env + flag is enough surface and adding a config file is ceremony we don't need until we do.

**Age key storage on macOS.** Keychain generic-password item, label `sharibako.age-key`, access control `SecAccessControl` with `.userPresence` (biometry-or-password fallback). Retrieval via `SecItemCopyMatching` triggers Touch ID.

**Age key storage on Linux.** Default: passphrase-encrypted age key file at `~/.config/sharibako/age-key` (via `age -p` at generate time). Passphrase prompt per command.

**Linux hardware-token support.** Comes for free through age's plugin architecture. If the user has `age-plugin-yubikey`, `age-plugin-tpm`, or `age-plugin-fido2-hmac` installed and has generated an identity via the corresponding tool, they point sharibako at the resulting identity file (env var or `--age-key <path>` flag), sharibako invokes `age --identity <file>` as normal, the plugin handles the hardware handshake, the hardware prompts (YubiKey touch, TPM PCR, FIDO2 tap). **sharibako needs no code for this beyond what already exists** — the abstraction is at the age binary layer.

Documented in SECURITY.md during ho-04.5 polish. Explicit Linux fingerprint/fprintd integration is not v1 (no clean age integration path).

**Key-management on-ramp.** `sharibako key generate` runs `age-keygen`, stores the private key in Keychain (macOS) or passphrase-encrypts to `~/.config/sharibako/age-key` (Linux), and prints the public key to stdout so the user can capture it for backup. `sharibako key import <path>` migrates an existing key file into Keychain, with confirmation before deleting the source file. `sharibako key export --public` prints the public key (safe to publish). `sharibako key export --private --i-know-this-is-plaintext` is the escape hatch for recovery workflows.

### Decision 4 — Touch ID cadence: one prompt per command, no daemon in v1

**Mechanism.** A CLI has no session — each `sharibako` invocation is a fresh process. macOS Keychain does not have a "cache unlocked state across processes" mode; the `LAContext` that holds auth state is per-process. On any command that needs the private key (decrypt path), the CLI calls `SecItemCopyMatching` once at command start. Touch ID prompt fires. Key is loaded into process memory. The command decrypts all owned keys it needs — for `materialize`, that's all owned keys in one prompt, not one prompt per key. Process exits; memory freed.

**Best-effort scrub on exit.** The plaintext buffer holding the age key gets `memset_s`'d before the CLI process exits, wrapped in a `defer` around the key-load. Not a magic bullet (Swift string internals may have made copies) but signals intent and covers the common path. SECURITY.md already commits to this pattern for `run` in ho-04.5; extending to ho-04's key handling is the same discipline.

**Which commands need the private key.** `get`, `rotate`, `unlink`, `materialize`, `update`, `heal`. Which don't: `status`, `scan`, `list`, `add` (public key sufficient for encrypt), `link` (writes a `.link` file, no crypto), `sync` (git only), `clean` (uses `inspect` which reads filenames).

**Why per-command and not a daemon.** A daemon (long-running background process holding the key across invocations via local IPC — the `ssh-agent` shape) would give proper session semantics. The overview explicitly defers this ("sharibako-agent Touch-ID-friction daemon, Deferred Decision #3, post-MVP"). Per-command friction is real UX cost, but it also means the age key lives in memory for milliseconds per invocation rather than minutes — a smaller blast radius. This ho ships per-command, feels the friction concretely during dogfooding, and the phase-boundary replan checkpoint after ho-04.5 answers whether the daemon earns its scope. See Followups for what data to bring to that conversation.

### Decision 5 — Output, errors, distribution

**Output.** Human-readable by default with ANSI color when stdout is a TTY, plain text when piped. `--json` flag on inspection verbs (`status`, `scan`, `list`, `heal`) — the surfaces where scripting is plausible. Write verbs don't get `--json`; they signal success/failure via exit code. `sharibako get` prints the raw value + trailing newline on stdout (so `$(sharibako get kanyo-dev API_KEY)` in shell scripts just works) — no `--json` for `get`, the value is the payload.

**Errors.** Every failure writes a human-readable message to stderr with actionable remediation ("Vault not found at `/Users/atmarcus/.sharibako/vault`. Run `sharibako key generate` first.") Exit code taxonomy:

- `0` — success
- `1` — generic failure
- `2` — user error (bad args, missing scope, unknown key)
- `3` — filesystem / IO
- `4` — age / decryption
- `5` — git / sync
- `6` — Keychain / auth

Small and inspectable in scripts. Every `VaultError` case maps to a specific exit code in one place. `--json` errors emit `{"error": "...", "code": N}` instead of human text on stderr.

**Distribution during dogfooding.** `scripts/install.sh` at repo root: runs `swift build -c release`, copies `.build/release/sharibako` to `/usr/local/bin/sharibako`, prints the destination path, exits nonzero on build failure. Not a Makefile — SwiftPM is the whole build system and Make for one target is ceremony. Bundling / signing / notarization / Homebrew tap deferred to Phase 6.

### Decision 6 — Testability posture

Keychain access sits behind a protocol (`AgeKeyProvider` or similar) so tests can substitute a file-based provider that doesn't require biometry. Two implementations: `KeychainAgeKeyProvider` for macOS production, `FileAgeKeyProvider` for Linux, tests, and the `--age-key <path>` flag. Everything else about internal CLI structure — per-command file organization, service-layer patterns, exact test-file layout — is execution-time detail for the agent to decide while writing.

### Decision 7 — Scope resolution when no scope arg is given

Many verbs take a scope: `materialize <scope>`, `update <scope>`, `heal <scope>`, `clean <scope>`, `get <scope> <key>`. Requiring the scope name every time when the practitioner is standing in a project directory with a `.sharibako` marker is friction.

**Behavior.** When a scope arg is omitted (where the CLI allows it — inspection verbs and Materializer-triad verbs), the CLI walks up from cwd looking for `.sharibako`, uses the scope named in that marker. Same shape as git's `.git/` discovery. `Materializer.resolveMarker(startingFrom:)` from ho-03 supplies the plumbing. Explicit `sharibako materialize kanyo-dev` still works when the practitioner is not in a project dir or wants a different scope.

**Commands that require an explicit scope even in a project dir.** `get <scope> <key>`, `add <scope> <key> ...`, `rotate <scope> <key> ...`, `link <scope> <key> <shared-id>`, `unlink <scope> <key>` — because these take a `<key>` arg that follows `<scope>` in the argument order, dropping scope would introduce ambiguity in a way the Materializer-triad verbs don't have. (An `--auto-scope` fallback for these could be added later if the friction is real.)

### Deferred to execution

- Exact directory layout inside `Sources/SharibakoCLI/` (subdirectory names, file-per-command vs grouped-by-concern) — the agent chooses while writing.
- Exact test structure for Keychain-gated code paths. Real Keychain tests won't run in CI; the agent picks a pattern (compile flag, environment guard, separate test target).
- ANSI color library choice (Rainbow, ColorizeSwift, hand-rolled ANSI escapes). Tiny surface — agent picks.
- Whether logging (via `swift-log`, already in Package.swift) is wired for the CLI in this ho or deferred. My prior: keep the CLI quiet by default and add logging when a specific need surfaces.
- Whether `sharibako remote set-url <url>` gets a dedicated verb in this ho or is punted to a followup. Prior: punt.

---

## Phase 2 — Execute

Two agent tasks with a clean seam between "how the CLI works" (structure, auth, output infrastructure, key management, inspection verbs) and "what the CLI does for encryption-touching operations" (write verbs). Same shape as ho-01/02/03's two-AT pattern.

### Ho-04-AT-01 — CLI scaffold, Keychain integration, key management, inspection verbs

`Sources/SharibakoCLI/` grows a real subcommand tree. `SharibakoCommand` (the top-level `AsyncParsableCommand`) registers all subcommands but only lands implementations for: `key generate`, `key import`, `key export`, `status`, `scan`, `list`, `heal`. The `AgeKeyProvider` protocol with both implementations, `--vault` / `--age-key` global flags, exit code taxonomy in one place, human/JSON output rendering, `scripts/install.sh`. Every Touch ID / Keychain moment is under test infrastructure that swaps in a file-based provider.

→ `ho-process/agent-tasks/Ho-04-AT-01.md`

### Ho-04-AT-02 — Write verbs

`get`, `add`, `rotate`, `link`, `unlink`, `materialize`, `update`, `sync`, `clean`. Each is a thin adapter over a `SharibakoCore` operation. Scope-resolution-from-cwd where applicable. `--force` on `materialize` mapping to `overwriteDrift: true`. `--json` on the parts of `heal`-shaped verbs where structured output makes sense. Real Touch ID prompts for the decrypt path, mocked in tests via `FileAgeKeyProvider`.

→ `ho-process/agent-tasks/Ho-04-AT-02.md`

### Testing and iteration approach

AT-01 lands and dogfoods before AT-02 opens — a CLI that can `status`, `scan`, `list`, `heal`, plus generate + manage a key, is already useful for exploring an existing vault. AT-02 builds on that foundation. Coverage floor stays 90% for the CLI target; realistically we expect around 85% because the Keychain code paths are hard to exercise headless. Integration tests use real subprocess execution against the built binary for a handful of critical paths (`key generate`, `status`, `materialize + get` round-trip); most tests are in-process against service-layer types with injected dependencies.

### Done means

- Every command in Decision 2's ho-04 surface works against a real vault
- `sharibako key generate` puts a fresh age key in the Keychain with Touch ID gating
- `sharibako materialize` prompts Touch ID once, decrypts all owned keys, writes `.env` byte-for-byte-preserving per kamae-2.2
- `sharibako update` picks up hand-edited `.env` values into the vault
- Andrew can use the CLI against his actual scattered secrets and start consolidating (kamae-1's success criterion for the dogfooding phase)
- Every error is a message he can act on, not a stack trace
- CI runs clean, coverage stays ≥ 85% overall (with Keychain paths honestly excluded)

---

## Phase 3 — Reflect

AT-01 and AT-02 committed at `ba5c1e6` and `713f252` respectively. Dogfood ran against the debug binary (`swift build` without `-c release`); see Release binary collision note below.

### What verified correctly

**AT-01 verbs** (`key`, `status`, `scan`, `list`, `heal`) verified via `--age-key` bypass during AT-01 dogfooding. `heal` drift detection and `scan` marker enumeration both correct. `list --shared` and `list` (scopes) both work; `list` does not take a positional argument (correct — flags only).

**AT-02 verbs** — full terminal run:

- `add`, `get`, `rotate`: correct round-trip. Duplicate `add` without `--force` surfaces the right error message and exit code 2. `--force` overwrites. Rotate replaces ciphertext; `get` after rotate returns the new value.
- `add --from-stdin`: pipe path works; trailing newline stripped. `--value` + `--from-stdin` conflict exits 2 with clear message. Neither flag also exits 2.
- `materialize`: wrote `.env` from a marker-resolved scope, reported key count. Second materialize on unchanged vault: "already up to date." Hand-edited `.env` → drift detection printed the differing key and exited 2 without modifying the file. `--force` overwrote and exited 0.
- `update`: pushed one hand-edited key back to the vault. Subsequent call with no further edits: "No changes." `get` after update confirmed the vault value updated.
- `clean --yes`: removed both owned keys, deleted the now-empty `.env`, exited 0. Second `clean` on the missing file: "Nothing to clean" with exit 0.
- `sync --no-push --no-pull`: initial commit on empty git repo succeeded. Subsequent call with nothing staged: printed "nothing to commit", exited 0. Custom message via `-m` included in the commit.
- Exit codes throughout: 0 on success, 2 on user errors (ValueInput, drift detection, missing target file), matching the taxonomy.

### Issues surfaced

**Release binary name collision.** `swift build -c release` writes both `Sharibako` (the SwiftUI app entry point) and `sharibako` (the CLI) into `.build/release/`. On macOS's case-insensitive APFS the names collide; the GUI binary wins and `.build/release/sharibako` hangs on any invocation (no AppKit run loop). The debug binary is unaffected — `swift build` only produces the CLI. Workaround for now: dogfood from `.build/debug/sharibako`. The real fix is in ho-05 (Xcode project), where the GUI app gets a separate Xcode-managed build output path and the CLI builds separately. Until then, `scripts/install.sh` (ho-04.3) should build the CLI with `swift build -c release --product sharibako` and verify the installed binary, not the path.

**Marker walker surfaces file-system error on home-directory boundary.** Running `materialize` from a directory with no `.sharibako` ancestor (the repo root was the test case) produces "File system error at /Users/atmarcus/.sharibako: The file couldn't be opened." rather than the cleaner "No .sharibako marker found starting from…" error that appears when the run is explicitly scoped. The walker appears to attempt opening `~/.sharibako` as a candidate and surfaces the open-failure as a filesystem error rather than a no-marker condition. This is a minor UX issue but wants a fix before ho-04.2 ships, since `init` relies heavily on the marker-resolution path.

**link / unlink not dogfooded end-to-end.** There is no `add-shared` verb — shared entries are created by `init` (ho-04.2). A manually crafted `.age` file without the `SecretContent` YAML wrapper caused a "Failed to decode YAML" error when `get` attempted to decrypt a linked key. Unit tests cover the link / unlink path correctly; end-to-end CLI dogfood will happen when ho-04.2 delivers `init`.

### Touch ID friction log

Not started. All AT-01 and AT-02 dogfooding bypassed Keychain via `--age-key`. The log called for in the ho-04.5 followup begins once ho-04.3 signs the binary and Keychain prompts are live.

### Keychain integration status

Written but not verified on a real signed binary. Deferred to ho-04.3 (see Followups). The `--age-key` bypass confirmed that every verb that touches encryption works correctly when given a key file; the biometry-gate is the only open question.

---

## Followups tracked for future hos

Deliberate hand-offs. Not code changes; things the later hos should read here and pick up.

### For ho-04.2 (`sharibako init` — interactive)

- **The four-way ingest decision matrix as a terminal interaction.** `Materializer.ingest(directory:)` returns a `ProposedScope`. The CLI presents each `DetectedKey` in order with the four decisions (import as local / link to shared / move to shared / leave alone) plus skip. Terminal UX design work — arrow-key selection vs. one-letter prompts, batch operations ("import all"), inline diff of proposed marker.
- **Touch ID interleaving during init.** `key generate` may need to run mid-init if no key exists. Or init requires a key be generated first — decide at authoring time.
- **Scope-ID collision UX.** `ProposedScope.suggestedScopeID` might collide with an existing scope; the CLI shows the suggestion and the user can override. Same "library suggests, surface can override" pattern as `scopeType`.
- **Deletion of source .env after ingest?** Kamae-2.2 says non-owned lines pass through byte-for-byte via materialize. But if the user imported every key, is the source `.env` a duplicate they want deleted? Post-v1 refinement; init v1 leaves the source alone.

### For ho-04.3 (sign the dev binary; verify Keychain biometry end-to-end)

Surfaced during AT-01 dogfooding: `sharibako key generate` on macOS hit `errSecMissingEntitlement (-34018)` when writing a Keychain item with `SecAccessControl` `.userPresence`. This is Apple's security model, not a code bug — unsigned binaries categorically cannot use biometry-gated Keychain access. The Keychain code in AT-01 is written but is not verified to work on a real device until this is resolved. AT-01 dogfooding used `--age-key <path>` bypass; AT-02 will do the same.

A small dedicated ho (well under ho-04.2 / ho-04.5 in scope):

- **`sharibako.entitlements`** at repo root or `Sources/SharibakoCLI/` — biometry-capable ("Keychain groups" + any specific entitlements Apple requires for biometry from a CLI). Reference the M4Bmaker entitlements shape for pattern.
- **`scripts/install.sh` addition**: after `swift build -c release`, run `codesign --sign "Developer ID Application: <name>" --entitlements sharibako.entitlements --options runtime --force .build/release/sharibako`. Uses the Developer ID cert already in the practitioner's keychain from M4Bmaker.
- **Verify**: signed binary running `sharibako key generate` prompts Touch ID, writes to Keychain, `sharibako key export --private --i-know-this-is-plaintext` re-prompts Touch ID and retrieves. `security find-generic-password -s sharibako` confirms the item.
- **Update `ho-04-cli.md`'s Reflect section** to record that Keychain integration verified end-to-end at this point.

Not urgent. AT-02's dogfooding proceeds on `--age-key` bypass. ho-04.3 clears the debt at whatever point real biometry is worth verifying before ho-04.2's `init` flow (which will interact heavily with Keychain during first-run).

### For ho-04.5 (`sharibako run` + SECURITY.md polish + daemon-decision replan)

- **`sharibako run [--scope <id>] -- <command>` implementation.** Kamae-2.1's injection verb. Decrypt owned keys into memory, spawn child with env vars set, forward stdio + signals (SIGINT/SIGTERM/SIGHUP), wait, exit with child's code. `--dry-run` prints key names only. Best-effort in-memory scrub on exit.
- **SECURITY.md polish.** The doc already exists (drafted during kamae-2.2, revised as ho-03 shipped). Ho-04.5 finalizes it against the real `run` semantics + the ho-04 Keychain story + the age-plugin passthrough note for Linux hardware tokens.
- **Daemon evaluation — explicit replan input.** During ho-04 dogfooding, keep a plain-text friction log of Touch ID prompt moments that felt heavy — commands run in sequence within a short window, workflows interrupted by re-prompts, times you avoided using sharibako because it was too many prompts. The log is the input to the phase-boundary replan checkpoint after ho-04.5: does the daemon earn its scope, does something smaller solve most of the pain, or does per-command turn out to be fine in practice? Don't decide from vibes; decide from the log.

### For ho-05 / ho-06 (Workshop / GUI polish)

- **`--json` output shapes established in ho-04** become the wire format the GUI can consume if it ever needs to shell out to the CLI. Ho-06 might repurpose them.
- **Exit code taxonomy** transfers to GUI error rendering — same `VaultError` cases mapping to the same categorized user messages.
- **Keychain integration is the same code path** the GUI uses. `AgeKeyProvider` protocol shared between CLI and Workshop.

### Post-MVP

- **`sharibako remote set-url <url>`** — dedicated verb for editing the vault's `origin` remote without dropping into `git`. Small addition, not urgent.
- **Config file** at `~/.config/sharibako/config.yaml` — if the env-var + flag surface turns out insufficient for real workflows. Currently unnecessary.
- **`sharibako-agent`** daemon — subject to the replan checkpoint decision above.
- **Non-macOS platforms beyond Linux** — Windows if ever needed; likely never for this project.

---

_Authored: 2026-07-02._
_Execute: complete (AT-01 `ba5c1e6`, AT-02 `713f252`)._
_Reflect: complete 2026-07-02._
