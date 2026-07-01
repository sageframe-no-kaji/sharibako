# Sharibako — Project Seed

_Kamae 1: Seed. Drafted 2026-06-30 from `sharibako-pre-seed.md` plus a seed-conversation pass. Revised 2026-07-01: injection non-goal loosened (see kamae-2.1); PassStore, PX Secrets, 1Password `op run`, and dotenvx added to landscape; threat model expanded to include AI agents as workspace actors; "made by a user, for users" framing and robustness bar added to Project Nature and Intent. This remains a build-phase document — the tool's shape, not its go-to-market. The pre-seed remains as the working dump it was; this is the parti the project will be evaluated against from here forward._

_The injection loosening is specified in detail in `kamae-2.1-sharibako-injection-decision.md`, which is authoritative for that decision._

---

## The Problem

My secrets scatter because no storage I have is shaped like how I actually work.

API keys, infrastructure credentials, and project secrets currently live across iCloud Keychain, scattered `.env` files, shell config, Vaultwarden, hardcoded scripts in `~/bin/`, and — worst — pasted into Claude conversations because retrieval from anywhere else is too slow at the moment I need them. Every storage system is shaped wrong: my password manager is built for "logins to websites," but I work in *repos* and on *machines*. The shape mismatch produces the scatter.

The friction that produces, day to day:

- I paste a key into a Claude conversation because I can't quickly retrieve it any other way. Then I have to rotate that key. Then I don't, because rotation means hunting down every place it lives.
- "Where is the key for X?" requires checking three or four storage systems.
- No canonical "add a new key" workflow, so each new key lands wherever was convenient at the moment. The scatter compounds.
- No audit trail of when things were last rotated. No `git log` for keys.
- No "what keys does this repo need?" view. I read `.env.example` and go fishing.

Underneath all of that is the real problem: **hygiene**. The friction of doing it right is higher than the friction of doing it wrong. Reusing one OpenAI key across eight projects is easier than generating eight scoped keys. Pasting into Claude is easier than retrieving from Keychain. Leaving a leaked key un-rotated is easier than rotating it. Every tool I have makes the wrong path the easier path.

---

## The Landscape

Engaged and evaluated. Comp table preserved in `sharibako-pre-seed.md`. Summarized here:

- **Apple Passwords / iCloud Keychain.** Good UI, things already in it, but: data model is for website logins, not env vars; no per-project organization beyond ad-hoc naming; not CLI-readable.
- **macOS login keychain.** CLI works. GUI is dated enough that I won't actually use it.
- **Vaultwarden / Bitwarden.** I already run Vaultwarden. The data shape is wrong — Login / Card / Identity / Note / SSH Key. None of those are "a bag of env vars for a project." Forcing it through Secure Notes is a textarea wall; forcing it through Login records misuses the record type. Both lose per-project hygiene support.
- **PassStore.** The nearest thing in market — a polished local Mac app for developer secrets, workspaces + environments + secret types, Touch ID, Keychain integration. The right shape for *its* pitch; the wrong shape for *this* one. PassStore is a proprietary local vault-in-a-database; the DB is opaque and not `git`-native. Sharibako's vault IS a directory of encrypted files that any age-capable client can inspect, back up, and recover independent of the app. PassStore is also Mac-only and doesn't model runtime injection or reference-based project files. Fights on GUI polish; loses on substrate honesty and CLI-first ergonomics.
- **PX Secrets.** Closest in technical direction — claims SOPS + age, local GUI + CLI. Less mature than PassStore, less visible, appears to be one developer's early product. Validates that the "SOPS/age-based local GUI" thought is in the air. Not a reason to stop; a reason to move.
- **1Password `op` CLI + `op run`.** The reference-and-inject pattern proven in market. `op://vault/item/field` in `.env`; `op run` resolves and injects. Sharibako learns from the *shape* of the pattern (secrets in memory, no plaintext at rest when possible) but rejects the cloud-account substrate and the subscription model. Ships the injection verb without the account/vault-server dependency.
- **Infisical.** Closest in spirit for developer-secret framing: self-hostable, env-var-shaped, per-project. But Postgres-backed, a full new service to deploy and maintain alongside Vaultwarden, and team-tool DNA throughout.
- **sops + age (CLI only).** Right substrate for other tools. Wrong UX for humans. Sharibako uses age directly, drops sops as an intermediate layer (see kamae-2 §5), and sits on top of a plain filesystem instead.
- **dotenvx.** Encrypts `.env` files and decrypts at runtime. Solves one narrow shape (this one file, encrypted); does not solve inventory, linking, rotation, cross-project reuse, GUI management, or agent-safe workflows. Adjacent; not competing head-on.
- **chezmoi + age.** Dotfile *manager*. Encrypts as a feature, but it's about symlinking and template materialization — wrong abstraction for "browse and edit my secrets." Possibly a downstream consumer, not part of sharibako's storage layer.
- **git-crypt, pass, ejson, chamber.** Each gives up one of: GUI, per-project shape, modern encryption, single-user simplicity.
- **Doppler, EnvKey, similar SaaS.** Not self-hosted. Off the table.
- **HashiCorp Vault.** Enterprise scale, massive overkill.

**The gap, named directly:** no tool combines (a) native local app on disk, (b) git-backed source of truth (encrypted files, not opaque DB), (c) age-encrypted, (d) shaped to projects and machines as primary, (e) opinionated about per-project hygiene, (f) single-user scale, (g) both materialize-to-file and inject-into-process as first-class output verbs. PassStore is closest but misses (b), (c), and (g); PX Secrets attempts (b) and (c) but is immature and misses (g). Sharibako sits in the empty quadrant.

---

## The Vision

### The Soul

A small, trustworthy workshop for the keys that power our tools — not a terminal ritual, not a corporate vault, but a calm local place where secrets can be kept, understood, backed up, used, and **handled cleanly**. Opinionated about hygiene: the path of least friction is the path of good practice. Isolating keys per project is the easy default; sharing across projects is possible but visible and one click away from feeling intentional.

### The Body

A native Mac app (Apple Silicon, SwiftUI) with a first-class CLI, that wraps `sops` to store project secrets as `age`-encrypted files in a Git-backed folder on disk. Each project owns its own secrets. Two secrets can be explicitly *linked* across projects when a credential is genuinely shared (rotate one, both move). The vault is a local directory the user controls. A remote git host is supported for backup and multi-machine sync but not required.

---

## Audience

Three personas, all real, the tool serves the union of their needs without bending to satisfy any one of them more than the others:

- **Indie developers.** Solo or small-team developers shipping projects, juggling 5–20 repos each with `.env` files. Currently using Vaultwarden-with-discipline, scattered `.env` files, or a 1Password subscription they're not happy with. Want something cleaner, faster, more honestly shaped.
- **Vibe coders.** Non-experts using AI APIs across multiple projects, often via cursor/Claude Code/etc. Don't have an opinion about sops vs. age vs. git internals. Need to be responsible with their secrets without a PhD in CS. Frictionless retrieval matters more than understanding the substrate.
- **Homelabbers.** Running self-hosted services on home infrastructure (Docker on Proxmox, Tailscale, Caddy, dnsmasq, the whole pattern). Manage credentials across multiple machines and containers. Some credentials (Tailscale auth keys, Cloudflare DNS API tokens, wireguard private keys) are genuinely cross-cutting — sharing isn't bad hygiene, it's the nature of the credential.

**Not:** enterprise teams, anyone needing RBAC / SSO / per-user audit compliance, anyone managing thousands of secrets.

A note on sharing across humans: the architecture supports it for free — share the git remote, share the age key, both humans have the same vault. A married couple sharing homelab credentials, two co-founders sharing API keys, a parent helping a kid manage their OpenAI key — all work without sharibako knowing anything about it. What sharibako does *not* model is multiple users as distinct identities: no per-user permissions, no audit log of who edited what, no "user accounts." The vault has one identity (the age key). Multiple humans can possess that identity if they choose to.

---

## Identity

**Sharibako** (舎利箱) — *reliquary box.* A small container for sacred Buddhist relics, especially śarīra: the remaining fragments associated with an awakened teacher.

Why it fits: the project is a reliquary box for digital secrets. API keys, tokens, certificates, and environment variables are tiny fragments, but they carry real power — access, authority, cost, risk, and continuity. Sharibako fits because the tool is not a giant enterprise vault and not a bare command-line ritual. It is a right-sized, local, careful container for the small charged things that make your systems come alive.

A second reading lands just as cleanly. **shari** (シャリ) is also the prepared sushi rice — the container the chef reaches into for every single dish, the underlying of all preparation. Secrets play exactly that role in software: nothing ships without them, every project reaches into them, the box sits within arm's reach of the workstation. Both readings hold and both are intended. Reliquary names the *preciousness* of what's inside. Shari names the *constancy* of the reaching.

Fits the existing Sageframe sushi-house naming convention alongside koan, jodo, chumon, tenzo, kura, kanyo.

---

## Project Nature and Intent

- **Open source.** GPL-3.0 (matching M4Bookmaker). Hosted on the `sageframe-no-kaji` GitHub org.
- **Two distribution paths (m4bookmaker lineage):**
  - **Free if you build it yourself.** Clone the repo, `swift build`, run. The Swift toolchain handles everything; no external build complexity.
  - **Signed binary.** A signed and notarized `.dmg` distributed via `sharibako.sageframe.net` (Cloudflare Pages). The signed download is the paid convenience; build-from-source is always the free path. Pricing and purchase mechanics are ship-phase concerns, not build-phase concerns — this document commits to the distribution shape only.
- **First Swift project.** Deliberately small as a learning vehicle for the Swift toolchain before larger Swift work (Sutra eventually).
- **Made by a user, for users.** Sharibako serves indie developers, vibe coders, and homelabbers — including me. My own daily use is the primary validation loop *because* I am one of the users the tool is for. Design decisions are shaped by what the audience actually needs, tested against my own workflow first because it is the workflow I know deepest. Feature requests from outside the parti are declined; feature requests inside the parti are taken seriously.
- **Robustness bar.** This is a tool for others, not a personal script that happens to be public. Error paths matter. Documentation matters. Safe defaults matter. Edge cases surface honestly. The build discipline is the same as any tool intended for real use by real people.

---

## Architecture Direction

_First-pass thinking. Opinions, not commitments. System Design will turn these into decided architecture._

**Stack:**
- **Swift + SwiftUI** for the Mac app (Apple Silicon)
- **Swift `ArgumentParser`** for the CLI
- **One Swift Package, two products** (`Sharibako.app`, `sharibako` CLI), shared core library — single source of truth for vault logic across both surfaces
- **`sops` binary bundled,** invoked as subprocess (the way M4Bookmaker bundles `ffmpeg`)
- **`age`** for encryption (sops native; no PGP, no KMS)
- **`git`** invoked as subprocess for vault sync operations

**Storage shape:**
- Vault is a local git repository at a user-configured path. Default likely `~/Library/Application Support/Sharibako/vault/` — provisional.
- A single `vault.yaml` file with **sops value-encryption** — keys plaintext, values encrypted. `git diff` shows what changed without leaking secret content.
- Each project owns its own secrets: `projects.<name>.secrets.<KEY>`.
- Linked secrets share a `value-id`. Multiple secrets pointing at the same `value-id` share value. Rotate any one → underlying value updates → all linkers see it. Break a link → secret keeps current value, allocates a new `value-id`.
- Machines section (`machines.<name>.secrets.<KEY>`) deferred to a post-MVP ho but the schema reserves room.

**Materialization:**
- Each project declares a `materialize_to` filesystem path
- `sharibako materialize <project>` writes a decrypted `.env` to that path
- `sharibako sync` runs `git pull` + `git push` (no-op if no remote configured)
- v1 materialization format is `.env` only. Raw config files / container secret injection are later hos.

**Distribution (mirrors M4Bookmaker pattern, ported native to Swift):**
- Mac app signed and notarized via Xcode
- `.dmg` built with `create-dmg` or similar
- CLI bundled inside the app (`Contents/Resources/`) with a setup step that symlinks it onto the user's `PATH` — or alternative: separate Homebrew tap. Open.
- Website on `sharibako.sageframe.net` (Cloudflare Pages, matching M4B pattern)

**Marked provisional:**
- Default vault location
- CLI bundling strategy (in-app vs. separate Homebrew install)
- Pricing model for the signed binary
- `value-id` representation (UUID? content hash? user-chosen slug?)
- Whether the CLI is built into the same Mac-only product or builds as a cross-platform Swift product (relevant only if Linux CLI ever comes back into scope)

---

## Constraints

- **First Swift project.** I have not written Swift before. This is the dominant time constraint. The project's scope is deliberately tuned to fit a first-Swift effort — likely 1,000–3,000 LOC.
- **Single developer.** No team. Time is spare-cycles, not full-time.
- **Apple Silicon Mac only.** My development machines, my test machines, my personal use case — all Apple Silicon. Intel Mac support would double the test matrix without serving anyone I know.
- **Threat model.** Single user, trusted machine, trusted homelab. Sharibako does not defend against state actors, hostile users on the same machine, or code execution / malware. The threats Sharibako *does* address:
  - **Offline disk theft.** "Laptop gets stolen and someone reads the disk." Covered by age encryption of the vault + Keychain gating of the age key. FileVault on top is an additional layer, not a substitute.
  - **AI agents and workspace-file readers.** AI coding agents in the practitioner's workspace — Claude Code, Cursor, Codex, IDE indexers, LSPs, search tools, backup daemons — legitimately read files. A materialized plaintext `.env` is exposure to this class. Sharibako's answer: `sharibako run` for interactive dev (values in child-process memory, never on disk), materialize only where consumers cannot be wrapped (docker-compose services, systemd units, cron jobs). This class is new in the 2026 workspace — added in the 2026-07-01 revision. See `kamae-2.1-sharibako-injection-decision.md` for the full architecture and `SECURITY.md` for the trust-document articulation.
  - **Transcript leak.** "I pasted the key into a Claude conversation." The friction fix (fast retrieval + `sharibako run` for wrapping the command) removes the need to paste at all.

---

## Scope Boundaries

**This is:**
- A native Mac app + first-class CLI for personal / small-scale secrets management
- A tool that handles project secrets, deployed Docker container secrets, homelab machine secrets, and dev-environment secrets — all sharing the same model
- **Two output verbs.** `sharibako materialize` writes an `.env` at a marker's target (for consumers that can't be wrapped). `sharibako run -- <cmd>` decrypts to memory and spawns the command with values in its environment (for interactive dev; nothing on disk). Both are first-class; users pick per situation. See `kamae-2.1-sharibako-injection-decision.md`.
- Opinionated about per-project hygiene through interface design, not configuration

**This is NOT:**
- **NOT a password manager.** No website logins, no card storage, no identity records, no SSH-key store. Vaultwarden and Apple Passwords keep their jobs.
- **NOT a team tool.** No RBAC, no SSO, no multi-user model, no audit compliance.
- **NOT a reference-based-`.env` loader.** Sharibako does not require project files to contain `shari://` references and does not ship a Sharibako-aware `dotenv` shim per language. Consumers see either a materialized `.env` (their choice, their exposure) or an already-populated environment (from `sharibako run`). Per-language loader shims are declined — the surface is larger than the rest of v1 combined, and injection covers the same ground with less coupling. See kamae-2.1 §"Declined alternatives" for the full reasoning.
- **NOT cross-platform GUI.** Mac only for the GUI, Apple Silicon only. No Windows. No Linux GUI. No Intel Mac. The CLI (including `run`) builds for Mac + Linux.
- **NOT a key issuer.** Sharibako stores what you put in it. It does not call provider APIs to mint Stripe secrets, register OAuth apps, or generate API tokens.
- **NOT shaped for high-secret-count use.** The mental model assumes tens to low hundreds of secrets, not thousands.

**MVP line:**

A working Mac app that can:
1. Create a vault (local git repo) at a chosen path
2. Generate an age key with a backup nudge flow strong enough that a vibe coder doesn't lose it
3. Add / edit / delete projects and their secrets through the GUI
4. **Link two project secrets** (the rotation-propagation feature — this is parti-defining and ships in MVP)
5. Materialize a project's secrets to a `.env` file at a configured path
6. **`sharibako run -- <cmd>`** — spawn a command with the current scope's secrets in its environment, values never written to disk (added 2026-07-01; ships in MVP via ho-04.5)
7. `sharibako sync` (git pull + push when a remote is configured)
8. CLI parity for adding / showing / materializing / running / syncing — no GUI required for the developer path

Deferred to post-MVP hos:
- Machines section
- Multiple materialization formats beyond `.env`
- Conflict resolution UI (last-write-wins is fine for v1)
- Rotation reminders / date tracking UI
- Import flows from Vaultwarden, iCloud Keychain, scattered `.env` files

---

## Success Criteria

Observable, testable by someone other than me.

1. **The transcript leak stops.** I no longer paste API keys into Claude conversations because retrieval from sharibako is faster than typing the key by hand.
2. **The scatter is consolidated.** Within 30 days of v1 personal use, every API key currently in iCloud Keychain, Vaultwarden, `.env` files, shell config, or scattered scripts is either in sharibako or deliberately *not* — moved to where it actually belongs (a website login goes to Apple Passwords; it doesn't get put in sharibako).
3. **A vibe coder can succeed unassisted.** A non-expert friend who codes with AI can install sharibako, set up a vault, add an OpenAI key, materialize it to a project `.env`, and use it in their app within 15 minutes, with no help and no terminal use beyond what the GUI prompts.
4. **Rotation is one action.** Rotating a linked secret takes one edit in the GUI or one CLI command, and propagates to every project that references it — verified by checking that materialized `.env` files in all referencing projects show the new value.

---

## Where I'm Starting From

**Known:**
- Software architecture and systems thinking — strong, the dominant tool I bring
- Cross-platform desktop app distribution: signing, notarizing, installer building — known from M4Bookmaker (PyInstaller-shaped, but the broader signing/distribution pattern transfers)
- sops, age, git as CLI tools — known from chezmoi dotfile use
- The threat model for personal / homelab use cases — well understood
- Python web stack (FastAPI, Jinja2, HTMX, Tailwind) — *not* relevant for this project

**New:**
- **Swift, SwiftUI, Swift Package Manager** — never used in anger. The language is the headline new thing.
- **ArgumentParser** for CLI
- **Native Xcode workflow** — Xcode signing/notarization replacing PyInstaller in the M4B distribution pattern
- **Cryptographic primitives at the API/library level** (vs. just shelling out to sops) — depth here is new even though sops use is familiar
- **Secrets management as a domain** — I've been doing personal practice ad-hoc; engaging with the literature on threat models, custody, rotation patterns, and recovery flows as a domain is new

---

## What I Want to Learn

- **Swift, end-to-end.** A first project in the language, from `swift build` through SwiftUI views through Xcode signing and notarization. Small enough that Swift's harder corners (advanced concurrency, ownership/borrowing in the upcoming evolution, opaque return types beyond the obvious) don't have to be solved on the first project.
- **Secrets management as a domain.** Threat models, key rotation patterns, custody, recovery flows, hygiene. I have ad-hoc instincts; I want a real practitioner's understanding by the end of this.

---

## Open Questions

Deferred to System Design or first hos. Not blocking the seed.

- **Pricing model for the signed binary.** One-time purchase ($X)? Donation-based? Patron tier? Per-major-version? Not seed-shaping; defer to a Ship-phase ho.
- **Vault path default.** `~/Library/Application Support/Sharibako/vault/` (Mac-conventional, hidden by default) or `~/sharibako-vault/` (more visible, easier for users to back up themselves)?
- **CLI distribution.** Bundled inside the app with a "install CLI" step that symlinks to `/usr/local/bin/` or `/opt/homebrew/bin/`? Or a separate Homebrew formula? First is one download to manage, second is more conventional.
- **Age key generation flow.** Built-in generation with a backup nudge? Or BYOK from an existing setup (chezmoi, manual)? Probably both, but defaults matter.
- **Backup nudge UX.** "Save this key somewhere" — but where? The reasonable answers (Apple Notes, a USB stick, a printed page, a second sharibako-managed file) all have failure modes. UX for this needs design work.
- **Conflict resolution.** GUI edits + CLI edits + remote pulls. v1 punts to "GUI re-reads on focus, last-write-wins"; what does v1.x do that's better?
- **Materialization side effects.** When a project's secret changes, does the materialized `.env` get rewritten automatically (frictionless, surprising), or only on explicit `sharibako materialize` (safer, more steps)? Or auto-rewrite with an opt-out per project?
- **Schema for linked secrets.** `value-id` as UUID, content hash, or user-chosen slug? UUID is simplest; content hash gives free deduplication; slug is human-readable in the YAML.
- **First-run experience.** Empty vault, no remote, no keys. What does the user see? Vault setup wizard, or land them in a populated example vault they can clear?
- **Import paths.** From Vaultwarden (API), iCloud Keychain (read-only via `security`), `.env` files (sweep tool). Which of these belongs in v1 vs. later hos?
- **Signing infrastructure.** Apple Developer Program subscription is already in place from M4Bookmaker. Reuse the cert? New cert per product?
- **Shared-vault use: documented or undocumented?** The architecture supports two humans sharing one vault (same git remote, same age key) for free. Do the README and website document this as a supported pattern (a household / two-co-founder use case), or stay silent on it (works for those who figure it out)? Documenting it changes the implicit audience and the support burden without changing any code.

---

## Next: System Design (Kamae 2)

The seed is the parti. System Design commits the architecture: storage schema fully specified, sops invocation patterns chosen, CLI command surface drafted, GUI screen flow mapped, MVP hos identified, signing pipeline planned. This seed feeds it.
