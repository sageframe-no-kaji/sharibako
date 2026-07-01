---
created: 2026-07-01
status: draft
type: ho-document
project: sharibako
ho: "02"
kamae: 5
shape: ha
builds-on:
  - kamae-1-sharibako-seed.md
  - kamae-2-sharibako-system-design.md
  - README.md
  - docs/architecture.md
  - kamae-4-sharibako-ho-overview.md
  - ho-process/hos/ho-00-orientation.md
  - ho-process/hos/ho-01-vault-core.md
agent-tasks:
  - Ho-02-AT-01.md
  - Ho-02-AT-02.md
---

# ho-02 — The Conduit: git operations over the vault directory

The thin `git` wrapper that gives Sharibako sync. `SharibakoCore` grows a second public type alongside `VaultCore`: a small value type that can `commit`, `push`, `pull`, and `status` the vault directory by shelling out to `git`. The Conduit knows nothing about secrets — every change is just a file change in `vault/`. By the end of this ho, an end-to-end bare-remote round trip (init local vault, commit a scope, push to a local bare repo, pull in a second clone, decrypt) runs green in CI.

**Out of scope:**
- Conflict resolution UI (system design Deferred Decision #7 — v1 surfaces conflicts structurally; the friendly picker UX lives in the CLI / GUI surfaces starting ho-04)
- Background or scheduled sync (manual `sync` only in v1)
- Authentication (the Conduit assumes the user's git config already works — SSH keys, credential helpers, aliases in `~/.ssh/config`, etc.)
- Materializer work (markers, ingest, materialize — that's ho-03)
- The CLI `sync` subcommand itself (that's ho-04)

**Resolves deferred decisions:**
- Conflict surfacing depth in v1 (system design Deferred Decision #7 — auto-abort with structured file list, resolution UX deferred to surfaces)

---

## Phase 1 — Think

### Decision 1 — Public type shape: `public struct Conduit`

The Conduit is its own value type, parallel to `VaultCore`. Not an extension on `VaultCore`, not a namespace of static functions.

```swift
public struct Conduit: Sendable {
    public let vaultURL: URL
    public init(vaultURL: URL) throws
    // …operations…
}
```

Why: the system design says the Conduit "knows nothing about secrets." Making it a separate type keeps that seam visible at the type level — the surfaces get two objects, each representing one concern. It also means the Conduit could operate on any git repo, not just Sharibako-shaped ones. And it leaves room to cache things (resolved remote URL, last known remote-ahead count) later without refactoring an extension chain.

### Decision 2 — Init verifies the vault directory only

`Conduit(vaultURL:)` throws `VaultError.vaultNotFound(path:)` if the directory doesn't exist. It does NOT verify the directory is a git repository. A vault that hasn't been `git init`'d yet is a valid input — the caller invokes `initializeRepository()` first (see Decision 9). Missing `.git/` on later operations surfaces as `VaultError.gitInvocationFailed` with git's own error message on stderr.

Same pattern as `VaultCore(vaultURL:ageKeyURL:)`, which doesn't validate the age key file at init time.

### Decision 3 — Remote configuration source: delegate to git

Sharibako does not store a remote URL in its own config. When code needs to know "is a remote configured?" it calls the Conduit, which calls `git remote get-url origin`. The vault's `.git/config` is the single source of truth.

Two Conduit methods expose this:
- `public func remoteURL() throws -> String?` — returns the origin URL, or `nil` if no remote is set. Wraps `git remote get-url origin` (nonzero exit + specific stderr = no remote → return `nil`).
- `public func setRemote(_ url: String) throws` — sets or updates the origin. Wraps `git remote add origin <url>` or `git remote set-url origin <url>` depending on whether one already exists.

Consequence: changing the remote is a git operation, visible to any git-aware tool, and reversible outside Sharibako. This decoupling is a bonus — the Conduit could later be swapped for a Fossil or Mercurial equivalent without changing the Vault Core or the Materializer, because the "remote lives in the VCS itself" pattern is not git-specific.

Tracked as a followup for ho-06 (GUI polish): the Settings pane needs a "Remote" row with a "Change…" button that runs `setRemote` transparently, plus a note explaining "this runs `git remote set-url` under the hood." Same for the CLI in ho-04 — `sharibako remote set <url>` or similar.

### Decision 4 — Structured return types for every network / state operation

The four public operations return structured enum values, not just throw/success:

```swift
public enum CommitResult: Sendable, Equatable {
    case success(sha: String)
    case nothingToCommit
}

public enum PushResult: Sendable, Equatable {
    case success(commitsPushed: Int)
    case upToDate
    case noRemote
    case rejected(reason: String)  // non-fast-forward, auth failure, etc.
}

public enum PullResult: Sendable, Equatable {
    case success(commitsPulled: Int)
    case upToDate
    case noRemote
    case abortedConflict(conflicts: [ConflictedFile])
}

public struct StatusResult: Sendable, Equatable {
    public let dirty: Bool
    public let untrackedFiles: [URL]
    public let modifiedFiles: [URL]
    public let deletedFiles: [URL]
    public let ahead: Int
    public let behind: Int
    public let hasRemote: Bool
}

public struct ConflictedFile: Sendable, Equatable {
    public let path: URL             // absolute path to the conflicting file
    public let localSHA: String      // git object hash for the local version
    public let remoteSHA: String     // git object hash for the incoming version
}
```

Why: these operations have inherent multi-state outcomes. Throwing forces the surfaces into `try/catch` for things that aren't errors (`.upToDate` isn't a failure). Silent success makes it too easy for a CLI to print "synced!" when nothing happened. Enum returns make each surface handle every case explicitly.

Note on `ConflictedFile`: the local + remote SHAs point at the two versions of the conflicting file in the git object database. Because Sharibako has the age key, the surfaces (ho-04 CLI, ho-05 GUI) can retrieve both versions with `git show <sha>` and decrypt them to build a "here's what's on each side; which one is current?" picker UX. That UX doesn't ship in ho-02 — the Conduit just returns enough information to enable it later.

### Decision 5 — Conflict handling: auto-abort

When `pull()` produces a merge conflict, the Conduit immediately runs `git merge --abort` before returning. The vault directory always ends `pull()` in a clean state — either the pull succeeded entirely, or the vault is exactly as it was before the pull.

Consequence: after an aborted conflict, `sharibako materialize` can never write a `.env` file containing git conflict markers or a half-decrypted `.age` file. The failure mode is contained.

The friendly resolution UX (which builds on `abortedConflict(conflicts:)`) lives in the CLI / GUI, not the Conduit. Sharibako will be helpful, not scary — but the helpful part isn't ho-02's job. See Followups.

### Decision 6 — `VaultError` gains exactly one new case

```swift
case gitInvocationFailed(exitCode: Int32, stderr: String)
```

Parallel to `ageInvocationFailed`. Distinguishing which binary failed matters for the surfaces to produce useful error messages ("git couldn't fetch the remote" vs "age couldn't decrypt this key").

No other new cases. `PushResult.noRemote` / `PullResult.noRemote` are not errors, they're states. `PullResult.abortedConflict(...)` is not an error, it's a state. `PushResult.rejected(reason:)` is not an error, it's a state. Only "git itself blew up" is an error.

### Decision 7 — Commit staging: `git add -A vault/`

`commit(message:)` runs `git add -A` at the vault root, then `git commit -m "<message>"`. The vault directory is Sharibako-owned end-to-end — no user files live there — so blanket staging is exactly right. The message comes from the caller; the Conduit does not invent messages.

Rationale: the vault directory contains only Sharibako-shaped files (`shared/<id>.age`, `scopes/<id>/scope.yaml`, `scopes/<id>/<key>.age`, `scopes/<id>/<key>.link`). If some other file appears there, it's a bug or a merge remnant, and having it committed makes the anomaly visible immediately rather than hiding it.

### Decision 8 — Identity: expose mechanism, defer choice

The Conduit provides `setIdentity(name:, email:)` that writes `user.name` and `user.email` into the vault's **local** `.git/config` (not the global `~/.gitconfig`). The Conduit does not force any identity itself, and does not read from ambient config to preload one — that's git's job when `git commit` runs.

`git commit` inside the vault resolves identity in this order (git's own precedence):
1. Local repo config (what `setIdentity` writes).
2. Global `~/.gitconfig`.
3. Environment variables (`GIT_AUTHOR_NAME`, etc.).

If none of those is set, git fails and the Conduit returns `VaultError.gitInvocationFailed` with git's stderr — which is descriptive enough to guide the user. The Conduit does not try to be clever about this.

The **choice** of which identity to use happens at the surface layer — ho-04 CLI or ho-05 GUI presents a picker during vault setup. The picker can populate its options from `~/.ssh/config` parsing (SSH aliases with `HostName github.com` are candidate GitHub accounts) — but that discovery UX is a followup, not ho-02 work. See Followups.

### Decision 9 — Repository initialization is explicit

The Conduit provides `initializeRepository()` — runs `git init` in the vault directory if `.git/` is not present. Idempotent (no-op if already a repo). Callable during first-run setup by higher layers.

Why explicit: `VaultCore` operations don't need a git repo to work. Only Conduit operations do. Making initialization a separate step means someone can use Vault Core alone (e.g. in a test, or a non-synced local vault) without ever touching git.

### Deferred to execution

- Exact `git status --porcelain` format and parsing. Using `--porcelain=v2 --branch` is the current plan; if v2 output is awkward to parse in Swift, fall back to v1.
- The precise regex for "no remote configured" detection from `git remote get-url origin`'s stderr. `git version 2.40+` prints `error: No such remote 'origin'`, but older git prints different messages. Detect via exit code first (nonzero = no remote); parse stderr only if needed for disambiguation.
- Whether to use `git pull --no-ff --no-rebase` explicitly or rely on git's defaults. Explicit is safer against user's global git config changing merge behavior.

---

## Phase 2 — Execute

Two agent tasks with a clean seam at the network boundary. AT-01 completes and passes before AT-02 opens.

### Ho-02-AT-01 — Local git operations

Everything that doesn't touch a remote. The `Conduit` type, `VaultError.gitInvocationFailed` case, and the five local operations: `initializeRepository`, `setIdentity`, `setRemote`, `remoteURL`, `status`, `commit`. Plus the shared test fixture for "empty temp directory → initialized vault repo." No bare-remote setup needed.

→ `ho-process/agent-tasks/Ho-02-AT-01.md`

### Ho-02-AT-02 — Remote git operations

`push()`, `pull()`, and the bare-remote round-trip integration test. Adds a `withEphemeralBareRemote` fixture that spins up a local `git init --bare` in a temp directory, then two "clone" vaults both pointing at it. Full sync round-trip: commit in vault A → push → pull in vault B → verify content. Plus the forced-conflict test that fires the auto-abort path.

→ `ho-process/agent-tasks/Ho-02-AT-02.md`

### Testing and iteration approach

AT-01 completes and passes before AT-02 opens. AT-02's tests build on AT-01's local operations. Coverage floor is the same 90% enforced in CI. `git` is a documented development prerequisite (added to `CLAUDE.md` in AT-02) — already available on the macos-15 CI runner and on any developer machine with Xcode Command Line Tools.

### Done means

- All Conduit operations (`initializeRepository`, `setIdentity`, `setRemote`, `remoteURL`, `status`, `commit`, `push`, `pull`) have passing tests
- Bare-remote round trip test runs green
- Forced-conflict test fires the auto-abort path and confirms the vault ends clean
- No-remote case works for every operation without throwing
- `git` documented in `CLAUDE.md` as a development prerequisite
- CI runs clean
- Line coverage stays at or above 90%

---

## Phase 3 — Reflect

Executed 2026-07-01 as two subagent tasks on Sonnet with fresh context, orchestrated in-session. AT-01 (`4f85ef3`) and AT-02 (`b857bbb`) both green in CI on first push. 72 tests, 91.69% line coverage across `SharibakoCore`.

### `Shell.run()` carried over cleanly

The `workingDirectory: URL?` extension in AT-01 required no changes to any existing `age` call site — the default `nil` leaves them untouched. Same wrapper handled `age`, `age-keygen`, and every `git` invocation without modification. This is the Followup for ho-02 the ho-01 Reflect anticipated ("`Shell.run()` is ready for `git` as-is") holding up: correct.

### Conflict detection: shape held, one surprise about output stream

The `ConflictedFile(path:, localSHA:, remoteSHA:)` shape held. The auto-abort returned cleanly — `Conduit(vault).status().dirty == false` immediately after every aborted conflict, with no half-merged state.

**Surprise:** `git pull` writes the conflict marker (`CONFLICT (content): Merge conflict in <path>`) to **stdout**, not stderr. Stderr only carries the fetch line (`From /path/to/bare: main -> origin/main`). This is the opposite of `git push`, where diagnostics go to stderr. The parser handles both streams — but if we hadn't tested carefully, we'd have read the wrong stream and returned `.success` on a conflicting pull.

`git ls-files --stage <path>` produced stage 2 (ours/local) and stage 3 (theirs/remote) entries as expected on any content conflict. Format is `<mode> <sha> <stage>\t<path>` — tab separates the metadata block from the path, so parsing correctly requires splitting on tab first, then space.

### `git` binary location: no probe-list changes needed

`Shell.findExecutable("git")` found the binary at `/usr/bin/git` (Xcode Command Line Tools) on the dev machine and at `/usr/local/bin/git` on the CI runner. Both are in the existing probe list. No changes.

### `VaultError` additions: exactly one, as planned

`gitInvocationFailed(exitCode:, stderr:)` covered every real failure mode. `noRemote`, `abortedConflict`, `upToDate`, `rejected` all live as enum return values on `PushResult`/`PullResult` per Decision 4, and none of them ever wanted to be an error. The taxonomy held.

### Status parsing: `--porcelain=v2 --branch` clean

Git 2.48.1 on the dev machine and 2.51.0 on CI both emitted the documented `--porcelain=v2 --branch` format. No fallback to v1 needed. The one code path not exercised is the `2 <XY>` rename/copy branch — no test currently creates a rename, so that parsing branch is theoretically correct but untested.

### Coverage: 91.69%, with named untested paths

| File | Line cover |
|---|---:|
| Models/*.swift | 100.00% |
| VaultLayout.swift | 97.22% |
| Shell.swift | 97.37% |
| VaultCore.swift | 96.52% |
| VaultCore+Encryption.swift | 94.93% |
| Conduit.swift | 88.96% |
| Conduit+Remote.swift | 81.18% |
| ConduitTypes.swift | 100.00% |
| **TOTAL** | **91.69%** |

Down from ho-01's 96.02% because two new files landed with defensive branches the tests don't exercise. The specifically-untested paths, named:

- **`Conduit.swift` `parseStatusOutput` rename/copy branch (`2 <XY>`)** — no test creates a git-tracked rename. Correct code, no exercise.
- **`Conduit.swift` no-identity-configured commit path** — testable but required a workaround (write empty `[user]` block into local `.git/config` to override global config), which turned out to be the wrong shape once implemented. Left as a known gap for a future coverage pass.
- **`Conduit+Remote.swift` `currentBranchName()`** — defensive upstream-tracking setup that never fires because `git clone` sets tracking automatically. Would only trigger on a `git init` + manual remote + `pull()` sequence.
- **`Conduit+Remote.swift` several `noRemote` early-returns** — `push()` and `pull()`'s "no remote" paths ARE tested at the entry point, but subsequent internal helpers each re-check and their re-check paths never fire in isolation.

Above the 90% floor with no chmod tricks. If we want to push higher, targeting `Conduit+Remote.swift` specifically would gain the most — probably 2-3 tests worth.

### One Swift/extension mechanic worth naming

`Conduit.swift`'s internal `git(_:)` helper started as `private` in AT-01. AT-02's `Conduit+Remote.swift` extension file can't see private helpers from another file, so AT-02 changed it to `internal` (no modifier — the default). Worth carrying forward for ho-03: any helper the extension pattern will share across files needs to be at least `internal`. `private` and `fileprivate` don't cross the file boundary.

The `VaultCore+Encryption.swift` precedent worked because its private helpers were self-contained — the encryption code calls back into public/internal `VaultCore` methods, not shared `private` helpers. `Conduit` differs because both the local and remote halves shell out to git through the same helper.

### Default branch surprise: `master` vs `main`

Git 2.51+ still defaults to `master` when `init.defaultBranch` isn't set globally — with a deprecation hint but no behavior change. The bare-remote fixture had to be explicit: `git init --bare --initial-branch=main` for the remote, `git checkout -b main` after `git init` for the local vaults, or `git clone` (which respects the remote's default). Silent misalignment (fixture creates `master`, remote expects `main`) would produce cryptic push failures.

The Conduit itself doesn't hardcode a branch name — it uses `git push origin HEAD` and `git pull ... origin`. That's the right shape; the branch name convention is a fixture concern, not a Conduit concern.

### Followups for ho-03 (Materializer)

- **Commit message shape.** `Conduit.commit(message: String)` takes any string. The Materializer will want multi-line commit messages (subject + body) — Swift string literals with `\n` work fine. No API change needed.
- **`currentBranchName()` visibility.** Currently `private` in `Conduit+Remote.swift`. If the Materializer wants to display "on branch <name>" in status surfaces, hoist it to `public`. Small change.
- **Untracked-file protection.** `git pull` refuses to merge when untracked files would be overwritten (the Conduit surfaces this as `gitInvocationFailed`, which is correct — it's not a conflict, it's a state error). The Materializer should be aware: if it materializes into a scope that then gets pulled, and the pull would overwrite the materialized files, the pull fails with a specific error. Handling: materialize AFTER pull, not before.

---

---

## Followups tracked for future hos

Deliberate hand-offs from ho-02 to later work. Not code changes; things the later hos should read here and pick up.

### For ho-04 (The Tool / CLI)

- **Remote configuration surface.** The CLI needs commands to show and change the remote — probably `sharibako remote` and `sharibako remote set <url>`. Both delegate to `Conduit.remoteURL()` and `Conduit.setRemote(_)`. Emit a line saying "this ran `git remote set-url origin <url>`" so the user knows what changed.
- **Identity picker on first-run.** `sharibako init` (or a first-run setup command) should prompt for which identity signs commits to this vault. Populate the picker by parsing `~/.ssh/config` for `Host` blocks whose `HostName` is or resolves to `github.com`. Present them as candidate identities. Fall back to a free-text prompt if the ssh config has no GitHub hosts. Once chosen, call `Conduit.setIdentity(name:, email:)`.
- **Passive rotation info.** `sharibako status` shows each secret's `rotated_at` age (from `SecretContent`). Add a `--stale` flag to filter to secrets older than a threshold (default: 6 months). No nudging on other commands — status is passive info the user reads when they look. No push notifications, no warnings during `materialize` in v1.
- **Friendly conflict resolver.** When `Conduit.pull()` returns `.abortedConflict(conflicts:)`, the CLI presents each conflicted secret side-by-side (`git show <localSHA> | age --decrypt` vs `git show <remoteSHA> | age --decrypt`) and asks the user which value is current. Chosen value → `VaultCore.rotate` → `Conduit.commit + push`.

### For ho-05 / ho-06 (The Workshop / GUI polish)

- **Remote configuration Settings pane.** A "Sync" section with the current remote URL displayed, a "Change…" button that opens a text field, and a note "Sharibako runs `git remote set-url origin <new-url>` when you save. Take it out of Sharibako later by running the same command yourself." Same pattern for identity.
- **First-run identity picker.** Same as CLI, populated from `~/.ssh/config`. GUI version can show radio buttons with the detected aliases + "Other" for free entry.
- **Rotation-age surfacing in the sidebar.** The secret detail pane shows `rotated_at`; the scope list can badge secrets older than a threshold. Still passive — the user chooses to look.
- **Conflict resolver GUI.** Same shape as CLI but with a side-by-side diff view: local value | remote value | pick one.

### For ho-03 (The Materializer)

- **Commit messages.** The Materializer will call `Conduit.commit(message:)` after ingesting a scope or materializing. Confirm the message format: single-line? Multi-line with a body? The Conduit takes whatever string it's handed; the Materializer decides the shape.

### Post-MVP

- **SSH-config auto-detection as a library API.** If it turns out useful in ho-04, hoist the parser out of the CLI into a small helper in `SharibakoCore` (or a separate module) so the GUI can reuse it verbatim.
- **Rotation policies.** If users ask for it after v1, add `rotation_policy` to `SecretContent` — e.g. `rotate_every_days: 90`. Sharibako would then surface overdue secrets more proactively. Deliberately not in v1.

---

_Authored: 2026-07-01._
_Execute and Reflect: pending._
