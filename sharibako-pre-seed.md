# Sharibako — Pre-Seed Notes

_Captured from conversation 2026-06-30. This is a pre-seed dump, not a seed: it gathers the want, the reasons, the rejected alternatives, the full tool landscape, the build options, and the open questions in one place so a proper Kamae 1 seed conversation has something to work from. Do not treat any architectural sketch in here as decided._

---

## The name

**Sharibako** (舎利箱) — Buddhist reliquary. The ornamental container used in Buddhist temples to lock away the most precious items imaginable: *sarira* (the sacred crystalline beads found among the ashes of cremated Buddhist masters) or holy sutras. Sacred mini-safes, often made of precious metals, crystal, or lacquered wood.

The metaphor is literal. A personal secrets manager, taken seriously, is a secure ornamental container for the most precious things kept in the place of practice. The API keys that grant access to my models, my infrastructure, my services — these are the sarira of the practice. They deserve a reliquary, not a junk drawer scattered across iCloud Keychain entries, `.env` files, and shell history.

(There is a secondary reading — *shari* as the prepared sushi rice in a sushi-bako, a container the chef reaches into constantly throughout service. It works as a workshop metaphor, but the reliquary framing is the one that lands.)

The name fits the existing naming convention alongside koan, jodo, chumon, tenzo, kura, kanyo.

---

## In one line

**A reliquary for personal API keys.** Encrypted files in a git repo I own, edited through a native cross-platform desktop app, fed directly into process environments via first-class CLI integration — so secrets never have to pass through clipboard, plaintext disk, or chat transcript.

## What sharibako is, in one paragraph

A small tool that lets me manage my personal API keys and secrets through a clean per-repo / per-machine browsing UI, with the underlying data stored as encrypted files in a private git repo. The UI is the friendly editing layer; the git repo is the source of truth; the CLI is the runtime integration — `sharibako run -- python app.py` or `sharibako env kanyo | source` puts secrets into a process's environment without them ever landing in a plaintext file on disk. My existing chezmoi flow can be a secondary consumer on machines where running the app isn't worth it. The likely encryption stack is sops + age. The organizing axes are *repo* and *machine*. The scale is single-user.

**The shape of "tool" is genuinely open**: it could be a native cross-platform desktop app (Python + GUI + CLI, in the same shape as m4bmaker), or a self-hosted web app on the homelab, or both. The native desktop shape is the current lean. See the architectural-shape section below.

---

## The actual problem

My API keys currently live in too many places, none consistently:

- **iCloud Keychain via Apple Passwords** — some as passwords, some as secure notes, no per-project organization, not CLI-readable
- **Project `.env` files** scattered across repos
- **Shell config** (fish, bash history, exported env vars from old setups)
- **Probably hardcoded in scripts** in `~/bin/` and `~/scripts/`
- **Some in Vaultwarden**, inconsistently
- **Some that have been pasted into Claude conversations** and therefore live in transcripts and need rotation but I haven't gotten to it

The friction this causes:

- I paste a key into a Claude conversation because I can't quickly retrieve it any other way, then I'm told (correctly) to rotate it because the transcript now contains the literal value
- "Where is the key for X?" requires checking three or four storage systems
- There is no canonical "add a new key" workflow, so each new key lands wherever was convenient at that moment, compounding the scatter
- No audit trail of when things were last changed or rotated
- No "what keys does this repo need?" view

The deeper issue: **my secret storage has no shape that matches how I actually work.** I work in repos and on machines. My password manager has a shape designed for "logins to websites." The mismatch produces the scatter. Sharibako exists to give the storage a shape that fits the practice.

---

## What I want (initial sketch — not decided)

A tool that lets me:

- **Browse** secrets organized by **repo** and **machine** — the two axes that match how I work
- **Add, edit, remove** secrets through a clean form, comparable in friendliness to Apple Passwords or 1Password (not Keychain Access.app)
- **Reveal, copy, and audit** with the affordances people expect from a real password manager — click/keystroke to unmask, auto-mask on blur, clipboard with auto-clear after N seconds, "this secret last changed N days ago, rotate?" prompts surfaced from git history
- **Inject into process environments** as a first-class operation, not an afterthought. Patterns I want to work out of the box:
  - `sharibako run --repo kanyo -- python app.py` — wraps a process with the repo's secrets in its environment
  - `sharibako env kanyo` — emits export statements; `sharibako env kanyo | source` for fish, `eval (sharibako env kanyo)` etc.
  - `sharibako get kanyo/openai` — single-value retrieval for use in scripts and `.envrc` files
  - Direnv-friendly: a `.envrc` snippet that calls sharibako resolves the whole repo's secrets without any plaintext landing on disk
- **Store** the underlying data as encrypted files committed to a private git repo I own
- **Sync** to other machines via git — desktop app on each editing machine, or chezmoi-managed materialization as a fallback for machines that don't run the app
- **See history** — because the storage is git-backed, "when did I last rotate this" and "what changed" are queryable

The split that matters: **git repo of encrypted files is the source of truth; UI is a friendly editor over that data; CLI is the runtime integration.** Not a database with git as an export target. Not a file format with git as an afterthought. Git-first by design, env-injection-first in use.

---

## Why the existing tools don't fit

Evaluated and rejected (or partially rejected) as a complete solution:

- **Apple Passwords / iCloud Keychain.** UI is good, I have things there already, but: not CLI-readable (iCloud Keychain is separate from login keychain), no project organization beyond ad-hoc naming, data model is for website logins not env vars.
- **macOS login keychain + Keychain Access.app.** CLI works (`security find-generic-password`), GUI is dated and clunky enough that I won't actually use it daily. No native concept of "this group of secrets belongs to this repo."
- **Vaultwarden / Bitwarden CLI.** Already running. Data model (folders of password records) doesn't fit env-var-shaped data cleanly. No git history. Unlock-session friction adds drag to a tool I want frictionless. Feels like overhead for what should be a near-invisible utility.
- **Infisical.** Closest in spirit — self-hostable, env-var-shaped UI, per-project organization. But Postgres-backed (not git-backed) and a full new service to deploy and maintain alongside Vaultwarden.
- **sops + age, chezmoi + age, git-crypt, others (CLI only).** Right storage model, no friendly UI. (See full landscape below.)
- **Doppler, EnvKey, similar SaaS.** Not self-hosted. Off the table.
- **HashiCorp Vault.** Enterprise scale, massive overkill for single-user personal homelab.

---

## The gap, named directly

No tool I can find combines:

- Self-hosted (I own the data and the service)
- Web UI organized by project and machine
- Git-backed source of truth (not DB-backed with optional git export)
- Modern encryption (age or comparable)
- Single-user scale — no team / RBAC / SSO / audit-compliance overhead

Existing tools give up either the web UI (sops, chezmoi, git-crypt, ejson, pass, gopass) or the git storage (Vaultwarden, Infisical, Vault, Bitwarden, 1Password, Doppler, EnvKey). Sharibako sits in the empty quadrant.

---

## Comprehensive tool landscape

The full ecosystem, with encryption primitives separated from the workflow tools that compose them.

### Encryption primitives

- **age** (github.com/FiloSottile/age) — modern replacement for GPG, by Filippo Valsorda. Small, well-designed, SSH-key compatible, multiple-recipient support. Go library + CLI. BSD-3. Python binding: `pyrage`. Rust port: `rage`. This is what every modern tool builds on (chezmoi, sops, gopass all support it).
- **GPG** — the legacy primitive. Mature but heavy and crusty key management. Used by older tools (git-crypt, pass, blackbox).
- **NaCl box** — used by ejson; clean modern crypto but narrow adoption in this space.

### The workflow tools

| Tool | What it does | Encryption shape | Backend(s) | Lang | License | Notes |
|---|---|---|---|---|---|---|
| **sops** (getsops) | Encrypts values inside YAML/JSON/ENV/INI files, leaves keys plaintext | Value-level | age, GPG, AWS/GCP/Azure KMS, Vault | Go | MPL-2 | De facto standard. Diff-friendly — you can see *which* key changed in git history. Used in production at scale. |
| **age** | Just encrypts files | Whole-file | n/a | Go | BSD-3 | The primitive that others compose with |
| **git-crypt** | Transparent file encryption via git smudge/clean filters | Whole-file | GPG | C++ | GPL-3 | "Clone the repo, decrypted files just appear in your working tree." Single maintainer, less active. |
| **chezmoi** | Dotfile manager with encrypted-file support | Whole-file | age, GPG | Go | MIT | I already use it for dotfiles. Encryption is one feature among many. Possible consumer for sharibako. |
| **dotenvx** | Encrypted `.env` files, runtime decryption at process startup | Value-level | Public-key (custom) | Node | BSD-3 | Newer (2024), by the creator of dotenv. Purpose-built for env vars. Most relevant UX-wise to sharibako. Worth studying. |
| **ejson** (Shopify) | Encrypted JSON | Value-level | NaCl box | Ruby/Go | MIT | Narrow, simple, less adoption than sops |
| **pass** | Tree of GPG-encrypted files, optional git backend | Whole-file (one secret per file) | GPG | Bash | GPL-2 | Standard UNIX tool. Many third-party GUIs (qtpass, browserpass, gopass) |
| **gopass** | Go reimplementation of pass, more features | Whole-file | age, GPG | Go | MIT | Modern pass, single binary |
| **transcrypt** | Bash wrapper, smudge/clean filters | Whole-file | OpenSSL | Bash | MIT | Less popular alternative to git-crypt |
| **blackbox** (StackExchange) | Bash scripts wrapping GPG | Whole-file | GPG | Bash | MIT | Legacy. Mostly superseded by sops. |

### Adjacent / non-git tools (for completeness)

- **Vaultwarden / Bitwarden** — DB-backed password manager. Already running. Best comp for "self-hosted with web UI" but wrong data shape.
- **Infisical** — DB-backed env-var manager. Best comp for "self-hosted with env-var-shaped web UI" but not git-backed.
- **HashiCorp Vault** — enterprise secrets infrastructure. DB-backed.
- **Doppler, EnvKey, AWS Secrets Manager, GCP Secret Manager** — SaaS. Off the table for self-hosted reasons.
- **teller** (Spectral / SentinelOne) — CLI for fetching secrets from multiple backends. Orchestration, not storage.
- **chamber** (Segment) — wraps AWS Parameter Store. Not git-backed.

---

## Build options

Four ways to build sharibako on top of existing work:

### 1. Library use (recommended for MVP)

- Use `pyrage` (Python bindings for age) for encryption/decryption in-process
- Use `GitPython` or subprocess for git operations
- Use sops via subprocess if value-level encryption is wanted (no Python bindings — subprocess is standard pattern)
- Build the FastAPI + Jinja2 + HTMX + Tailwind layer ourselves

**Pros**: smallest surface area, well-maintained dependencies, sharibako stays focused.
**Cons**: writing the storage logic, web UI, and integration glue ourselves — but that IS sharibako; that's not work being avoided, that's the project.

### 2. Wrap a binary

- For sops: subprocess is the only option from Python. Standard pattern.
- For age: choice between `pyrage` library and `age` binary subprocess. Library is cleaner for in-process use.

**Pros**: zero coupling to wrapped tool's internals; upgrade-by-replacing-binary.
**Cons**: slower (process spawn per op); error handling via stderr parsing.

### 3. Fork

- Forking sops: large active Go codebase, web UI is the actual value-add we'd be adding, diverging from upstream loses security fixes. Wasteful.
- Forking dotenvx: smaller and env-var-shaped, more tempting — but Node codebase we don't otherwise want to maintain.
- Forking chezmoi: makes no sense — does many things we don't need.

**Verdict**: don't fork. Compose.

### 4. Roll the encryption ourselves

Don't. Use age (or sops over age). Custom crypto in personal tools is how people get burned.

---

## Architectural shape: hosted web vs native desktop vs both

A new option surfaced after the first draft of this doc: sharibako does not have to be a hosted web service. It could be a **native cross-platform desktop app** in the same shape as m4bmaker — Python + a GUI toolkit + a full CLI, packaged via PyInstaller, signed and notarized for macOS, with Windows and Linux builds for free. This changes the architecture meaningfully and should be a top question for the seed conversation.

### Option A — Self-hosted web service

- Runs as a Docker container on chumon or jodo, behind LAN-only Caddy + tailnet
- Accessed from any device on the tailnet via browser
- Server holds the age private key (or browser holds it in a zero-knowledge variant)
- Git operations happen on the server
- **Pros**: editable from any device (phone, other laptops); single source of truth for editing; matches the "homelab service" pattern I already use
- **Cons**: server to deploy and maintain; key custody question is harder; attack surface includes anyone on the tailnet; backup of the key needs explicit thought; web UI in Python (HTMX + Tailwind) is in my stack but is more wiring than a native window

### Option B — Native cross-platform desktop app

- Python + a GUI toolkit (PySide6, Toga, or whatever m4bmaker uses) + full CLI surface
- Packaged via PyInstaller into a signed `.app` for macOS, installer for Windows, AppImage or similar for Linux
- Distributed via GitHub Releases on the sharibako repo
- Age key lives on the machine where the app runs — never crosses a network
- Git operations from the local machine, pushing to a private GitHub repo
- The git repo is the sync layer between machines
- **Pros**: no server to maintain; no network attack surface at all; age key never leaves the device it's used on; native UI feels good and is faster than web; macOS Keychain integration possible for key unlock; same distribution pattern as m4bmaker (known, working); no Docker, no Caddy, no tailnet exposure needed; CLI naturally falls out of the same codebase
- **Cons**: editing requires the app installed locally on the editing machine; multi-machine editing means installing on each machine (but that's cheap); no phone access for editing (but I don't actually want to edit API keys on my phone)

### Option C — Both

The same Python codebase, with the core (encryption + git + storage logic) as a library, and two frontends: a desktop GUI built on the library, and a FastAPI web app also built on the library. Possible but a clear scope expansion — defer unless both surfaces are genuinely needed.

### My honest read

**Option B (native desktop) is probably the right answer**, and I should have surfaced it before Option A.

Reasons:
- The actual scale is single-user-on-known-machines. The "browse from anywhere on the tailnet" capability of the web version is theoretical — I edit secrets at my desk, period.
- Self-hosted web means server maintenance, container orchestration, reverse proxy config, backup of the server's key store, and an attack surface that exists 24/7. The native app has none of that.
- M4bmaker proves the distribution and packaging story works. PyInstaller-based Python apps with GUI + CLI are a pattern I've shipped before.
- The git repo is already the right sync layer between machines. The native app on each editing machine is just a friendly editor over the same repo.
- Honest threat model: I am the only attacker who can plausibly reach my homelab tailnet AND has reason to target my secrets. Reducing surface to "my Mac that already has all the secrets in unencrypted form when I'm using them" is the right move.

The seed conversation should resolve this and not assume Option A.

---

## Recommended architecture (sketch only, not decided)

Treating Option B (native desktop) as the leading candidate. For an MVP that fits the practice:

**Stack — native desktop variant (Option B, leading)**, matches the m4bmaker pattern:
```
Python 3.12 + uv + ruff + mypy strict + pytest (standard verification)
PySide6 or Toga for the GUI (match what m4bmaker uses for consistency)
Typer or Click for the CLI (same codebase, shared core)
pyrage (age encryption, in-process)
sops binary as subprocess (value-level encryption for readable diffs)
GitPython or subprocess (git ops — pull before read, commit + push after write)
Pydantic for the data model
PyInstaller for packaging (signed .app on macOS, installer on Windows, AppImage on Linux)
```

**Stack — self-hosted web variant (Option A, fallback)**, matches existing Python web work:
```
Python 3.12 + uv + ruff + mypy strict + pytest (standard verification)
FastAPI + Jinja2 + HTMX + Tailwind (standard web stack)
pyrage (age encryption, in-process)
sops binary as subprocess (value-level encryption for readable diffs)
GitPython or subprocess (git ops — pull before read, commit + push after write)
Pydantic for the data model
Docker for deployment behind LAN-only Caddy + tailnet
```

The core (storage logic, encryption, git ops, data model) is the same in both variants and should be structured as a library so either frontend can be added without touching it.

**Storage primitive**: sops + age.

- **sops** because value-level encryption means encrypted files show readable diffs in git. When `OPENAI_API_KEY` rotates, the diff shows that key's encrypted value changed and nothing else. With whole-file encryption (age alone, git-crypt, chezmoi), every rotation reads as "this entire file is different" — losing the audit trail that was the point of going git-backed.
- **age** as sops's backend because: modern, no GPG keyring nonsense, SSH-key compatible, already integrated with chezmoi.

**Storage layout**:
```
sharibako-vault/   (private git repo)
├── repos/
│   ├── kanyo/secrets.sops.yaml
│   ├── glassroom/secrets.sops.yaml
│   └── ...
└── machines/
    ├── chumon/secrets.sops.yaml
    ├── jodo/secrets.sops.yaml
    └── ...
```

**Runtime — desktop variant**: native app installed on each machine where I want to edit. App opens, pulls latest from git on launch, presents UI. Edits commit + push immediately. No always-on service.

**Runtime — web variant (fallback)**: Docker container on a homelab host (chumon or jodo), behind LAN-only Caddy + tailnet.

**Consumer side, primary path**: the sharibako CLI itself. Same binary as the desktop app, exposing:
- `sharibako run --repo <name> -- <command>` — execute a process with the repo's secrets injected into its environment
- `sharibako env <repo>` — emit shell export statements for the repo (per-shell adapters: fish, bash, zsh, posix)
- `sharibako get <repo>/<secret>` — single-value retrieval for scripts and `.envrc`
- `sharibako rotate <repo>/<secret>` — guided rotation: prompts for new value, commits, optionally calls a per-secret rotation hook

**Consumer side, secondary path**: chezmoi. On machines where installing the desktop app isn't worth it, `chezmoi update && chezmoi apply` pulls the vault repo and materializes secrets into project `.env` files at the right paths. Useful for headless hosts and quick laptops.

**Alternative worth considering: dotenvx as the storage format.** Purpose-built for env vars, clean CLI UX, data model maps 1:1 to what sharibako needs. Downsides: younger (less battle-tested), Node-based (we don't run much Node), custom encryption scheme rather than the sops/age standard. File as "study its UX, don't depend on it."

**Effort estimate**, rough:
- MVP, desktop variant: ~2-3 days focused work for the GUI + core, ~500-800 LOC core + ~300-500 LOC GUI. PyInstaller packaging adds ~half a day per platform.
- MVP, web variant: ~1-2 days focused work, ~500-800 LOC
- Hardened (either): ~2-3 days more
- Zero-knowledge web (browser-side key via age-wasm): ~3-5 days on top of web MVP. Not applicable to desktop variant — the desktop app inherently holds keys locally.

---

## Open questions (deliberately not resolving)

These all want answers before a system design but should be left open here:

- **Architectural shape: hosted web vs native desktop vs both.** The biggest open question. Native desktop (m4bmaker-style) is the current leading candidate but the seed conversation should resolve this deliberately, not by default.
- **Key custody.** For the web variant: server-side or browser-side (age-wasm)? For the desktop variant: app holds the key in process memory, unlocked from passphrase, or from macOS Keychain, or from a hardware token (YubiKey supports age)?
- **Auth model.** For the web variant: tailnet-only enough, or also passphrase / basic auth / OIDC? For the desktop variant: just the encryption-unlock step at app launch — does it ever ask again during a session?
- **Conflict handling.** If I edit via CLI (sops directly, chezmoi) AND via the web UI, what happens? Force `git pull` on every read? File-level locks?
- **Storage schema.** One aggregated `secrets.sops.yaml` per repo (cleaner UI, more diff churn), or one file per secret (more granular, more files)? sops handles either.
- **Consumer integration depth.** Does sharibako extend chezmoi's existing age support (sharibako writes chezmoi-shaped files), write a separate consumer CLI, or both? Is chezmoi the right consumer or is it an awkward fit?
- **Naming and organization model.** Just repos and machines, or a more flexible tag system? Is "this secret is used by both repo X and machine Y" common enough to need first-class support, or is duplication fine?
- **Scope creep risk.** Does sharibako stay deliberately just-for-me, or could it become public? Public means multi-user, RBAC, packaging for others' homelabs — a much bigger system. Need to decide before letting features creep that way.
- **Rotation workflow.** Does sharibako track rotation dates and prompt? Or stay agnostic and let me think about that myself?
- **History / diff UI.** Since it's git-backed, do I expose "see what changed when" in the UI, or is `git log` good enough?
- **Bootstrap and migration.** How do existing secrets in iCloud Keychain, Vaultwarden, scattered `.env` files get imported? Is there a sweep tool? Is migration a one-time chore or an ongoing workflow?
- **Env injection surface details.** Which shells get native adapters out of the box (fish is non-negotiable for me; bash/zsh/posix obvious; nushell/elvish optional)? Does `sharibako run` use a wrapping process (sees the secrets) or `exec` (cleanest, secrets in env only)? Does it support `.envrc` autoloading via a generated direnv extension?
- **Multi-machine reads.** If I work on a project from another machine, that machine needs the age key. How is the key distributed? Manual copy? Chezmoi-managed? Hardware token (YubiKey supports age)?
- **Backup.** The git repo itself is the backup, replicated wherever it's cloned. But the age private key isn't. Where does the key live such that losing my Mac doesn't lose access?

---

## Honest pushback to keep in view

Reasons sharibako might be a mistake:

- **Vaultwarden already works and I already run it.** "Use Vaultwarden properly with a disciplined folder structure" would solve maybe 80% of the actual scatter problem with zero new infrastructure. The 20% that remains is the env-injection UX — Vaultwarden has no first-class "wrap a process with secrets in env" command, no shell-eval pattern, no direnv-friendly retrieval. Everything goes through `bw get password "name"` shell substitution. That gap is sharibako's actual reason to exist; if I'm OK paying it, Vaultwarden is enough.
- **"Tools to manage my tools" have a high failure rate.** The meta-tool absorbs energy that should go into the work the tools support.
- **Security-sensitive software I write myself has a higher-risk attack surface** than software many other people look at and audit.
- **The git-history feature is appealing in the abstract** — but I should be honest about whether I'd actually use it day-to-day, or whether it's a feature I want to *have* rather than *use*.
- **The web UI I want might be a thin enough layer over chezmoi+age** that "wrap chezmoi in a small editor UI" is a much smaller project than "build a new secret management system." Worth exploring before committing to the larger shape.
- **The single-user scale of the problem may not justify the cost of any new system at all.** Cleaning up Vaultwarden organization plus a disciplined per-project `.envrc` convention might be the right move.

If sharibako survives those objections in a seed conversation, it's worth building.

---

## Next step

If pursuing: invoke `ho-kamae-1-seed-collaborator` against this document to develop a proper seed. The seed conversation should:

- Decide architectural shape: hosted web, native desktop, or both (this is the top question — everything else cascades from it)
- Sharpen the core "what is and isn't sharibako" (especially scope creep guardrails)
- Resolve key custody given the chosen shape
- Decide whether sharibako is a new system or a thin UI over chezmoi
- Decide whether the storage format is sops+age, dotenvx, or pure age
- Push hard on whether Vaultwarden-with-discipline solves enough of the problem to not need sharibako at all

If parking: this document is the artifact of having thought it through. Worth keeping for the next time the scatter problem becomes acute enough to act on.
