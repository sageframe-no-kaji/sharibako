---
created: 2026-07-01
status: decided
type: decision
project: sharibako
stage: kamae-2.1
kamae-chain: seed → system-design → **injection-decision** → readme → ho-overview
supersedes: kamae-2 §7 (partial — the "no runtime injection" architectural commitment)
builds-on: kamae-1-sharibako-seed, kamae-2-sharibako-system-design
next: reflected in kamae-1 seed (parti), kamae-4 (ho sequence, adds ho-04.5), README, SECURITY.md, docs/architecture.md
---

# Sharibako — Injection Decision (Kamae 2.1)

_A forward-only decision document. Kamae 2 committed "no runtime injection" as an architectural boundary. This document reopens that decision, records the new threat-model input that motivated the reopening, and commits the revised architecture: **materialize and inject as peer output verbs**._

_This document is authoritative for anything the injection decision touches. Kamae 2 §7's line "No runtime injection... The Materializer's only output verb is `materialize`" is superseded here. All other Kamae 2 commitments (age-per-secret, file-per-secret, filesystem-as-schema, git-backed, four-component slice) stand unchanged._

---

## What Kamae 2 originally decided

Kamae 2 §7 (MVP Architectural Commitments):

> **No runtime injection.** The Materializer's only output verb is `materialize` (write `.env` file). It exposes no API for injecting env vars into running processes.

Kamae 1 Scope Boundaries mirrored this:

> **NOT a runtime secret injector.** Sharibako materializes files at known paths; consumers (docker-compose, direnv, app loaders) read those files. Sharibako does not inject env vars into running processes.

The reasoning was scope discipline: a first-Swift project, ~1,500–3,000 LOC, deliberate limits.

## What changed

The threat model needs an addition.

Kamae 1 stated the threat model as:

> "Laptop gets stolen and someone reads the disk" — covered by age encryption — not "someone gains code execution on my machine."

That model considered offline disk-read attacks. It did not consider **AI agents as workspace actors** — a category that sits between "laptop stolen offline" and "code execution / malware." An AI coding agent running in the practitioner's workspace has file-read access to the same tree as the practitioner. It is not RCE; there is no exploit. The agent reads `.env` because it can read files.

Under the current materialize architecture, a project's `.env` is plaintext at rest. FileVault protects it against offline disk theft. Nothing protects it against an in-workspace agent that lists project files and reads one named `.env`. The transcript-leak problem Kamae 1 named as the top pain point ("I paste keys into Claude conversations") reasserts itself the moment the agent reads a materialized file — the leak is upstream of the paste.

This is not a hypothetical. It is the daily working reality of every persona named in Kamae 1 (indie developers, vibe coders, homelabbers — all using AI agents in their workspaces). Building a robust tool for those users means addressing the class, not skirting it. The threat-model gap alone justifies the reopening; no other argument is required.

## The decision

**Both materialize and inject are first-class output verbs.** Sharibako exposes:

- **`sharibako materialize <scope>`** — writes a plaintext `.env` at the scope's marker target. Same behavior as Kamae 2 originally specified. Values persist on disk until overwritten or cleaned.
- **`sharibako run [--scope <id>] -- <command>`** — decrypts the scope's secrets into memory, spawns the given command with those values set in its environment, forwards stdio and signals, waits, exits with the child's status. No file is written; values live only in the wrapper's and child's process memory.

Both verbs share the same age-decrypt path, the same Vault Core, the same Touch ID gating. The only difference is where the decrypted value ends up — a file on disk (materialize) or an environment variable in a child process (run).

**Neither verb is deprecated. Neither is a fallback.** Users pick the right verb per situation. The rule to teach is one sentence:

> Use `run` for interactive dev. Use `materialize` for anything that starts on its own — docker-compose services, systemd units, cron jobs.

## Why not the alternative shapes

Three architectures were on the table. Sharibako commits to materialize + run as peers. The other two are declined, and the reasons matter for future readers.

### Declined: reference-in-`.env` with a Sharibako-aware loader

The shape the opposition-research memo proposed: project files contain `OPENAI_API_KEY=shari://shared/openai-personal`; a Sharibako-specific loader replaces the standard `dotenv` and resolves references at process start.

Rejected because:

- **Language sprawl.** Every language ecosystem (Python, Node, Go, Rust, Ruby, PHP…) has its own dotenv-shaped loader. Replacing them requires a shim per language. That surface is larger than the rest of the v1 build combined.
- **Consumer coupling.** The project can no longer run without the Sharibako loader. The whole ergonomic of "the project's `.env` works the same way it always has" — which the memo praised — is lost.
- **The AI-agent benefit is partial.** The agent still sees references, and can still enumerate what secrets exist (reference names are readable). That's a smaller win than injection, which shows the agent nothing at all in the run case.

Runtime injection dominates reference-loaders on both simplicity and threat-model coverage.

### Declined: materialize-only (the original Kamae 2 commitment)

Rejected because:

- **Plaintext-on-disk is the whole exposure.** Every materialized `.env` is a file an agent, a leaked backup, a misconfigured cloud sync, or an over-broad IDE indexer can read.
- **A robust tool for others needs both verbs.** Interactive dev (the majority of user workflows) benefits from injection; boot-time consumers (docker-compose services, systemd, cron) need materialize. Shipping only one leaves users to work around the missing verb — copying secrets by hand, or accepting exposure they could have avoided.
- **The implementation cost is small.** Injection adds one CLI verb, one Vault Core helper (`get_all_secrets_for_scope`), signal forwarding, and stdio pass-through. Roughly 150–250 lines of Swift including tests.

### Committed: materialize + run as peers

Materialize handles consumers that can't be wrapped (docker-compose on a homelab host restarting on boot, systemd units, cron jobs). Run handles everything a developer launches at the terminal.

Both use the same age-decrypt path and the same Keychain unlock. Neither is second-class in the CLI, the GUI, or the docs.

## Implementation shape

### `sharibako run` — the CLI verb

Signature:

```sh
sharibako run [--scope <id>] [--] <command> [args...]
```

Behavior:

1. Determine scope. If `--scope` given, use that. Else look up from `.sharibako` marker in cwd (walking up to find one, matching materialize's scope resolution).
2. Unlock the age key via Keychain (Touch ID or password) or Linux passphrase. Same code path as `get`.
3. Load all secrets for the scope from the Vault Core. Decrypt each into memory (looping the existing per-secret decrypt, or a new bulk helper). Resolve `.link` files to their shared targets.
4. Compose an environment dict: parent process env merged with scope secrets (scope wins on conflict).
5. `fork()` + `exec()` the child with that environment. Inherit stdin/stdout/stderr. Register signal handlers that forward SIGINT, SIGTERM, SIGHUP to the child's PID.
6. `wait()` on the child. Return the child's exit status.
7. On any exit path (normal, signal, error), zero the decrypted values in the wrapper's memory before returning. Best-effort — Swift's memory model does not guarantee wiping, but explicit `withUnsafeMutableBytes` + `memset_s` for each string reduces the window.

In Swift, this is `Foundation.Process` with `.environment` set to the composed dict, `.standardInput/Output/Error = FileHandle.standard*`, plus signal handlers registered via `signal()` or `DispatchSourceSignal`.

Ho-04.5 (see Kamae 4) owns the implementation. See that ho for scoped-in edge cases (empty scope, missing marker, unknown scope, mid-flight Keychain relock).

### The Vault Core addition

One new function:

```swift
func get_all_secrets(scopeID: String) throws -> [String: String]
```

Loops `list_scope(id)` for keys, calls `get_value` on each, resolves `.link` targets, returns a dictionary. Reuses existing single-secret decrypt code — no new crypto path.

### The GUI

The Workshop does not add a "Run" button in ho-05 or ho-06 — the injection use case is CLI-native. If GUI-side "launch a terminal with the scope's secrets loaded" turns out to be a user request, it lands post-v1. The Workshop's role remains: browse, edit, materialize, sync, manage links.

### Touch ID frequency

`run` requires one Touch ID at the start of each invocation. If the wrapper survives long enough for a rerun (dev server restart, watch mode), the values are still in memory — but launching a new `sharibako run` invocation re-prompts. Same friction pattern as `get`. The `sharibako-agent` daemon (post-MVP) remains the escape hatch if this friction is felt.

## Threat model — the addition

Kamae 1's threat model gets one new class:

**Class 4: AI agents and other workspace actors with file-read access.**

_Adversary._ A benign or semi-benign process — an AI coding agent, an IDE indexer, a language server, a search tool, a backup daemon — that has legitimate read access to the practitioner's project directories.

_Attack surface._ Anything on disk in a scanned directory. Specifically:

- Plaintext `.env` files (materialized or written by hand).
- Shell history files (`.bash_history`, `.zsh_history`).
- Editor swap files, undo history, LSP caches.
- Cloud-sync staging areas (iCloud Drive, Dropbox) if the project lives there.

_Coverage._

- **`sharibako run`** — closes this class entirely for wrapped invocations. Values never touch disk. `/proc/<pid>/environ` on Linux and process inspection on Mac remain readable by privileged tools, but that is the "code execution on my machine" class (Class 3), not this one.
- **`sharibako materialize`** — remains fully exposed to this class. This is a known cost of the materialize verb and is documented as such in SECURITY.md. Users on the injection path avoid it; users who need file-based consumers accept it.

_Mitigations for materialize users._

- Prefer `run` when the consumer can be wrapped.
- Use `sharibako clean` (see below) to remove materialized files after the session.
- Configure `.gitignore` to exclude materialized files (already conventional).
- Optionally on Linux, materialize to a `tmpfs`-backed path (`/dev/shm/…`) so files vanish on reboot. Not automated in v1; documented as a technique.

### New CLI helpers

Two additions justified by the threat-model update:

- **`sharibako clean [<scope>]`** — remove materialized files at each scope's target path (or one scope's, if named). Idempotent. Confirms before deleting unless `--force` is passed. Ho-04.5 or ho-03 (Materializer). Currently the Materializer only writes files; making it also honestly retract them is a small extension.
- **`sharibako run --dry-run -- <command>`** — print the names of the secrets that would be set, without their values, then exit. Useful for verifying scope resolution before running a real command. Also gives users a "safe summary" they can share with an agent or paste into a bug report.

## What stays the same

Everything in Kamae 2 not listed above stands:

- Four components: Surfaces, Vault Core, Materializer, Conduit.
- Filesystem-as-schema. File-per-secret. `.age` and `.link` files. `scope.yaml`.
- age over sops. Bundled `age` binary, invoked via `Process`.
- macOS Keychain for the age key, Touch ID gating.
- Git-backed vault, Conduit as thin wrapper.
- Distribution as signed DMG + Homebrew tap + `.tar.gz`.
- Everything in §6 (Deployment Model) unchanged.

## Reflected in

- **Kamae 1** — Scope Boundaries "NOT a runtime secret injector" line rewritten; threat model expanded to name the workspace-file-reader class; landscape section broadened with PassStore, PX Secrets, 1Password `op run`, and dotenvx; robustness-bar language added to Project Nature and Intent. See `kamae-1-sharibako-seed.md`.
- **Kamae 4** — new ho-04.5 (`sharibako run` + threat-model docs + SECURITY.md draft), dependency summary updated. See `kamae-4-sharibako-ho-overview.md`.
- **README** — `sharibako run` added to Usage; "What Sharibako Is Not" updated; PassStore + PX Secrets differentiators added; link to SECURITY.md. See `README.md`.
- **SECURITY.md** — full trust document reflecting the four-class threat model and the materialize/run exposure difference. See `SECURITY.md`.
- **docs/architecture.md** — Scope Boundaries updated to remove the "No runtime injection" line; components section notes `run` as a peer verb. See `docs/architecture.md`.
- **Kamae 2** — a pointer at the top of the document naming this file as the superseding decision for §7's injection non-goal. Kamae 2's body remains as it was written, as a record of what was decided at that time.

## Open items handed to downstream hos

None blocking. Ho-04.5 owns:

- Signal-forwarding specifics (which signals, in what order, with what timeouts).
- The `--dry-run` and `--scope` flag surface.
- Linux passphrase caching for `run` (currently prompt-per-invocation; may want a shorter-lived cache).
- Test harness for injection (integration tests that run a shell subcommand and assert env vars land).

Ho-09 (website + release) owns (if and when ship-phase site work justifies it):

- Site copy explaining "materialize vs. run" — not a build-phase concern; deferred to whatever ship-phase content lands.

---

_Decision committed. Downstream documents updated in the same session. This file is a permanent record; not to be edited except for typographical fixes._
