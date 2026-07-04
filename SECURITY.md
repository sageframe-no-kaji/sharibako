# Sharibako — Security

_Sharibako holds secrets. This document says what it protects, what it doesn't, and how the two verbs — `materialize` and `run` — differ in exposure. Written as if v1.0 is done; revised as the software lands. Last revision: 2026-07-01._

If you find a security issue, see [Reporting a vulnerability](#reporting-a-vulnerability) at the bottom of this document.

---

## Design posture

**Local-first.** Your secrets live on your machine, in files you can inspect and back up. Sharibako is not a service. There is no server that stores your secrets. There is no telemetry.

**Filesystem is the schema.** No proprietary database. The vault is a directory of encrypted files. If Sharibako disappeared tomorrow, an `age` binary and standard shell tools would let you recover every secret.

**Two output verbs, two exposure profiles.** `materialize` writes plaintext values on disk (for consumers that can't be wrapped). `run` puts values in a child process's environment (nothing on disk). Users pick per situation. This document explains the difference honestly.

**Per-key ownership.** Sharibako owns only the keys you selected at ingest — the specific `<KEY>.age` and `<KEY>.link` files under `vault/scopes/<id>/`. Every other line in your `.env` (comments, blank lines, non-owned key/value pairs like `DEBUG=true` or `PORT=3000`) is your territory. Sharibako doesn't read those values into decisions; doesn't include them in drift reports; doesn't rewrite or delete them. See "What Sharibako doesn't touch" below.

**We do not defend against code execution on your machine.** If an attacker gets a shell as you, or malware runs with your privileges, they can read the same files Sharibako reads and inspect the same process memory. Nothing in this document changes that. Full-disk encryption, OS security updates, and not running untrusted binaries are your job.

---

## Threat model

Four classes. The first two are cleanly covered. The third is out of scope. The fourth is new in 2026 and is the reason `sharibako run` exists.

### Class 1 — Offline disk theft

_"Someone stole the laptop and is reading the SSD."_

**Coverage: complete on macOS.** The vault is a directory of age-encrypted files. Each `.age` file is opaque ciphertext. The age private key is stored in the macOS Keychain; the Keychain is not accessible without an OS login. FileVault on top is an additional layer, not a substitute. On Linux the key is a `0600` plaintext file — passphrase protection is not yet implemented, so Class 1 coverage there rests on file permissions plus full-disk encryption (see "Where keys live").

**Caveats.** If you have written down or exported the age private key and stored it insecurely (a sticky note, a plaintext file on the same disk, iCloud Drive with no encryption at rest), the attacker also gets the key. See [Recovery](#recovery) for the backup story.

### Class 2 — Git history and remote-repository leaks

_"The vault's git remote was misconfigured and became public. Or a backup ended up somewhere it shouldn't."_

**Coverage: complete.** Every `.age` file in git is ciphertext from git's perspective. `git diff` on a rotated secret shows two blobs of ciphertext, no plaintext. A leaked git remote leaks encrypted files — the attacker still needs the age private key to decrypt.

**Caveats.** Filenames in the vault reveal *structure*, not values. An attacker with only the ciphertext knows you have a scope called `kanyo-prod`, a shared entry called `openai-personal`, and a linked secret named `OPENAI_API_KEY`. If your scope and secret names themselves are sensitive (rare, but possible in specific environments), consider naming conventions that don't leak information.

### Class 3 — Code execution on your machine (OUT OF SCOPE)

_"Malware, a compromised dev dependency, or someone who has a shell as you."_

**Coverage: none.** Sharibako cannot defend against an adversary who runs code with your privileges. Such an adversary can:

- Trigger Touch ID prompts you'll approve out of habit
- Attach a debugger to the sharibako or child process and read decrypted values from memory
- Read `~/.config/sharibako/age-key` if you're on Linux (a plaintext `0600` file)
- Install a keylogger and capture your Keychain password
- Modify the `sharibako` binary and re-sign it locally

**Your defenses at this layer.** Full-disk encryption. OS security updates. Not running binaries you don't trust. `age` and `sharibako` come from known sources; verify signatures on the DMG and the Homebrew formula. FileVault. Firewall.

### Class 4 — Workspace file-readers (NEW in 2026)

_"An AI coding agent, an IDE indexer, a language server, a search tool, a backup daemon, or an editor plugin reads files in my project directory."_

**Coverage: depends on the verb you use.**

This class did not exist cleanly in the pre-AI-agent working environment. It sits between "offline disk theft" and "code execution." The reader is not an exploit — it has legitimate file-read access to your project tree. It is a *benign* actor whose behavior surfaces an *exposure*.

- **`sharibako run` — complete coverage.** Secrets are decrypted into memory and passed to the child process via its environment. No file exists. The agent can read every file in your project and see no secret values. What it can see: the `.sharibako` marker (which names the scope and materialize target, but contains no values) and any git-tracked references. Values enter memory and exit with the process.

- **`sharibako materialize` — no coverage.** The materialized `.env` is plaintext at rest. Any process with read access to the file has read access to the values. The mitigation is *not to use `materialize` for wrappable consumers*. Use `run` for `npm run dev`, `python app.py`, `docker-compose up`, `cargo run`, and anything else you launch interactively.

**Materialize is not deprecated.** It exists because some consumers cannot be wrapped: a docker-compose service on a homelab host that restarts on boot, a systemd unit that runs a daemon, a cron job. These need an `.env` on disk because there is no interactive process to attach `sharibako run` to.

**Mitigations for materialize users.**

- Use `sharibako clean [<scope>]` to remove materialized files after a session ends.
- Add materialized `.env` files to `.gitignore`. This is conventional; verify it's true for your projects.
- On Linux, materialize to a `tmpfs`-backed path (`/dev/shm/<scope>/.env` or similar). The file is real to consumers but never touches physical disk and vanishes on reboot. Not automated in v1 — configure per project.
- Restrict directory permissions where feasible: `chmod 700` on the project directory, `chmod 600` on the materialized `.env`.
- Assume an AI agent will read the file if it can. Treat materialization as a deliberate "I am accepting this exposure because the consumer needs it" decision.

---

## The encryption story

### age

Sharibako uses [age](https://github.com/FiloSottile/age), a modern encryption library and command-line tool developed by Filippo Valsorda (formerly Google security team). age is:

- **Small and focused.** One purpose: encrypt files. No key management, no cloud accounts, no protocol negotiation.
- **Well-audited.** BSD-2-Clause licensed, widely reviewed, deployed at scale by SOPS (which uses age internally), Mozilla, and many others.
- **Modern cryptography.** X25519 key agreement, ChaCha20-Poly1305 authenticated encryption, scrypt for passphrase-protected identities.

Sharibako does not implement its own cryptography. It shells out to the bundled `age` binary for every encryption and decryption operation. The `age` binary in the signed DMG is verified as part of Apple notarization; on Homebrew installs, `depends_on "age"` uses the tap's or Homebrew-core's `age` formula.

### age over sops

Sops earned consideration during system design (kamae-2). It provides *value-encryption* — keys plaintext in YAML, only values encrypted — which gives readable `git diff` on rotated secrets.

Sharibako uses `age` directly and does not use sops, because the file-per-secret model makes sops's job disappear. Each secret is its own opaque ciphertext file. Different secrets are different files. Renames are `mv`. Deletes are `rm`. `git log <file>` is per-secret history. There is no structured file for sops to add value to.

### Where keys live

- **macOS.** The age private key is stored in the macOS Keychain with `SecAccessControl` requiring biometry-or-password on every access. This is the same access pattern SSH keys use in `ssh-agent`. Touch ID prompts appear per access; there is no session cache in v1.
- **Linux / `--age-key`.** The age private key is a plaintext file at `~/.config/sharibako/age-key` (or the path given via `--age-key` / `SHARIBAKO_AGE_KEY`), written with `0600` permissions. **Passphrase protection of this file is not yet implemented** — at-rest protection for the key on this path is file permissions plus full-disk encryption. age supports passphrase-protected identities; wiring them in is tracked as follow-on work.
- **The vault's git remote.** The remote never sees the age private key. The remote only receives encrypted `.age` files and plaintext `.link` files.

### What's plaintext, what's not

Inside the vault directory:

| File | Content | Encrypted? |
|---|---|---|
| `vault/scopes/<id>/scope.yaml` | Scope identity, type, display name | Plaintext |
| `vault/scopes/<id>/<KEY>.age` | Secret value + notes + rotated_at | Encrypted with age |
| `vault/scopes/<id>/<KEY>.link` | Shared-entry ID (name only) | Plaintext |
| `vault/shared/<id>.age` | Shared secret value + metadata | Encrypted with age |

**Scope and secret names are plaintext.** An attacker who obtains the vault directory (but not the age key) knows the *shape* of your secret landscape: which projects exist, which secrets they use, and what's shared. They cannot read any values.

Outside the vault:

- `.sharibako` markers (in your project directories) — plaintext, names the scope and materialize target only, no values. Marker fields are validated on load: the scope must satisfy the identifier grammar, and the materialize target must be a relative path contained within the marker's own directory — a marker arriving via git cannot aim `materialize`'s writes or `clean`'s deletions anywhere else.
- Materialized `.env` files — plaintext values on disk. This is the whole point of the materialize verb, and the whole exposure of Class 4 for materialize users.
- There is no app configuration file today. The vault location resolves from `--vault`, then `SHARIBAKO_VAULT`, then the default `~/.sharibako/vault/`; the age key from `--age-key`, then `SHARIBAKO_AGE_KEY`, then the Keychain (macOS) or `~/.config/sharibako/age-key`. None of these mechanisms store secret values — paths and environment variable names only.

---

## Verb-by-verb exposure

### `sharibako add` / `sharibako rotate` — how values enter

**Where the value lives:** depends on which entry form you use, and the three forms have different exposure profiles.

- **Echo-off prompt (the default on a terminal).** Run `add`/`rotate` with no value flag and Sharibako prompts for the value with input hidden — the way password prompts work. Nothing lands on your command line, in shell history, or on screen. This is the hygienic default.
- **`--from-stdin`.** The value transits a pipe (`op read ... | sharibako add ...`). Nothing in argv or history; exposure is whatever produced the pipe.
- **`--value <v>`.** The value is on your command line: it lands in **shell history** (a plaintext file in your home directory) and is visible in **`ps` output** to other processes for the duration of the run. Use it in scripts that already handle the value, not interactively.

**Who can read it:** for the prompt and stdin forms, effectively nobody beyond the process itself. For `--value`: anything that reads your shell history file, and any process listing running commands while the command runs.

**Mitigations:** prefer the prompt interactively; prefer `--from-stdin` in pipelines. If you have used `--value` with a real secret interactively, treat the shell history entry as an exposure — delete the line (`history -d` or edit the history file) or rotate the value.

### `sharibako materialize <scope>`

**Where the value lives:** in the plaintext `.env` file at the marker's target path — but *only the lines whose keys are sharibako-owned* carry sharibako's exposure. Non-owned lines are the user's; sharibako neither writes them nor reads them. Owned-line values persist on disk until overwritten by another materialize, cleaned by `sharibako clean`, or rotated in place by a user's editor.

**Who can read it:** any process with read access to that file. This includes your own code (intended), your loader (dotenv, docker-compose, direnv), AI agents that read your workspace (Class 4), backups that include your project tree, cloud sync clients (iCloud Drive, Dropbox) if the project is in a synced folder, and any user with read permissions on the file. Sharibako writes the file with `0600` (owner-only) permissions on every materialize — including re-tightening a target that was loosened by hand — so "any user with read permissions" means the file's owner unless you widen it yourself.

**When to use it:** when a consumer cannot be wrapped. docker-compose services, systemd units, cron jobs, anything that starts on boot or on a schedule.

**Mitigations:** `sharibako clean` (removes owned lines only), `.gitignore` entries, `tmpfs` targets on Linux, restrictive filesystem permissions.

### `sharibako run [--scope <id>] -- <command>`

**Where the value lives:** in the memory of the sharibako wrapper process and the memory of the child process it spawns. Set as environment variables in the child. Exits with the process.

**Who can read it:** the wrapper process and the child process (intended). On Linux, `/proc/<pid>/environ` is readable by the same user; on macOS, `ps -E` shows env vars for processes owned by the user. A privileged debugger attached to the child process can read memory. These are all Class 3 (code execution) concerns, not Class 4.

**When to use it:** for anything you launch interactively. `sharibako run -- npm run dev`, `sharibako run -- python app.py`, `sharibako run -- docker-compose up`, `sharibako run -- cargo run`.

**Mitigations:** the temporary age-key file is scrubbed and deleted as soon as decryption completes — before the child is spawned, so it does not persist for the child's lifetime. Decrypted values themselves are not wiped from the wrapper's memory in v1 — they go out of scope and exit with the process (see Known limits).

### `sharibako get <scope> <KEY>`

**Where the value lives:** printed to stdout. If stdout is a terminal, the value is visible on your screen. If stdout is redirected or piped, the value goes wherever the pipe goes.

**Who can read it:** whoever can read the stdout stream. Terminal scrollback captures this. Shell history does not (the value is not on your command line unless you paste it there).

**When to use it:** when you need to copy a value to paste somewhere Sharibako doesn't natively integrate — a web form, a partner's chat, a browser field.

**Mitigations:** clear terminal scrollback (`Cmd+K` on macOS Terminal / iTerm) after use. Do not pipe `get` output into files you don't intend to clean up.

### `sharibako run --dry-run -- <command>`

**Where the value lives:** nowhere. Prints only the *names* of the secrets that would be set. Values are neither decrypted nor displayed.

**When to use it:** to verify scope resolution before running a real command, and to produce a safe summary for an AI agent that needs to know what secrets exist without needing the values.

### `sharibako update <scope>`

**Where the value lives:** the vault, after the operation. Sharibako reads the `.env` file at the marker's target, extracts values for keys the scope owns, and rewrites the corresponding `<KEY>.age` files if the values differ. Non-owned lines in `.env` are ignored entirely — sharibako doesn't read them.

**Who can read the file being read:** anyone with read access to the `.env`. This is the user's file at rest; the same exposure it has always had. `update` doesn't change that exposure — it just picks up hand-edits.

**When to use it:** after hand-editing `.env` in your editor. Also useful for "git-track the whole `.env`" workflows where sharibako owns every key, and the practitioner edits `.env` as the working surface with sharibako as the versioned store.

**What it doesn't do:** it does not touch non-owned lines and does not report on them. If you hand-edit `DEBUG=false` and sharibako doesn't own `DEBUG`, `update` sees nothing about `DEBUG`.

### `sharibako clean [<scope>]`

**Where the value lives:** nowhere, after the operation. Sharibako removes only the lines whose keys the scope owns from `.env`. Non-owned lines are preserved. If the resulting file is empty or contains only whitespace and comments, sharibako deletes the file; otherwise it leaves the file with the user's remaining content intact.

**When to use it:** after a session ends, when the materialized owned values should not persist on disk. Also as a hygiene action before committing a project's changes if `.env` accidentally ended up staged.

**Mitigations built in:** confirms before deleting unless `--yes` is passed. Never touches non-owned user content.

---

## Git, sync, and backup

### What git sees

Git tracks the vault directory. Every commit is a set of file changes. Because each `.age` file is opaque ciphertext, a rotation appears as:

```
- OPENAI_API_KEY.age (old ciphertext blob)
+ OPENAI_API_KEY.age (new ciphertext blob)
```

Git cannot read either. The remote sees only ciphertext.

### The link graph in git

`.link` files are plaintext. Git tracks them as text files. Diffs on link files are meaningful: "this scope was previously linked to X, now linked to Y." This is intentional — the linking topology is not sensitive information; the values are.

### Backup story

The primary backup is the git remote. If the remote is a private repo on GitHub or GitLab, you have off-machine backup for free. Sharibako does not implement its own backup mechanism.

**If you have no remote,** the vault directory on disk is your only copy. Losing the disk loses the vault. Add a remote or use a filesystem backup (Time Machine, restic, borg).

**The age private key is not backed up by any of this.** The age key lives in Keychain (Mac) or `~/.config/sharibako/age-key` (Linux). Losing the age key means every encrypted file in the vault is unrecoverable. See [Recovery](#recovery).

---

## Recovery

### If you lose the vault (but still have the age key)

Clone the vault git remote to a new machine. Sharibako recognizes it. First-run reads the existing vault; nothing is regenerated destructively.

### If you lose the age key (but still have the vault)

The vault is unrecoverable. This is by design — Sharibako has no escrow, no recovery service, no cloud-hosted backup key. Rotate every secret at its provider (OpenAI, Cloudflare, etc.); create a fresh vault; re-enter them.

**This is why the first-run age-key backup nudge exists.** The Workshop's first-run flow (ho-06) prompts you to save the age key somewhere durable *outside the machine that holds the vault*. Options that are correct:

- A password manager (Apple Passwords, Vaultwarden, 1Password) — the key is a short text string; this is a valid secure-note use.
- A printed sheet in a physical safe.
- A hardware key backup written to an encrypted USB drive stored elsewhere.

Options that are *not* correct:

- A plaintext file in iCloud Drive or Dropbox that syncs to the same machine.
- A screenshot in your Photos library.
- An email to yourself.

### If you lose both

Nothing sharibako can do. Rotate every secret at its provider.

---

## Rotation

`sharibako rotate <scope> <KEY> --value <new_value>` (or `--from-stdin`) re-encrypts a secret with a new value. Rotating a linked key rotates the shared entry it points at, so every scope with a `.link` file pointing at that entry will materialize (or `run` with) the new value on next invocation. There is no propagation delay — the link graph is resolved at read time.

**Rotation frequency is your policy, not ours.** Sharibako does not enforce rotation schedules or nag on stale secrets in v1. The `rotated_at` metadata field is written on every rotation and can drive future UX (post-v1).

**When to rotate.**

- Any time you suspect a secret has leaked (transcript paste, plaintext commit, misconfigured share).
- Periodically for high-value credentials (production API keys, deploy tokens) — quarterly or as your provider recommends.
- Immediately after any Class 3 event (device compromise, malware discovery).

---

## Auditing the vault manually

Sharibako's file format is not proprietary. You can inspect the vault without the app.

```sh
# List the vault structure
ls -la vault/scopes/
ls -la vault/shared/

# Check what a scope contains (no decryption)
ls vault/scopes/kanyo-dev/
cat vault/scopes/kanyo-dev/scope.yaml
cat vault/scopes/kanyo-dev/OPENAI_API_KEY.link

# Decrypt one secret directly (Sharibako not involved)
age --decrypt --identity ~/path/to/age-key vault/shared/openai-personal.age

# Check git history for a specific secret
cd vault && git log --follow shared/openai-personal.age
```

If Sharibako has a bug in encryption or link resolution, you can verify it against the raw files. If Sharibako disappears, you can recover with just the `age` binary.

---

## What Sharibako doesn't touch

Per-key ownership means sharibako has a specific list of things it interacts with and a specific list of things it treats as user territory. Naming both explicitly:

**Sharibako reads and writes:**

- `.age` and `.link` files inside the vault directory (`vault/scopes/<id>/*.age`, `vault/scopes/<id>/*.link`, `vault/shared/*.age`)
- `scope.yaml` files inside scope directories
- `.sharibako` marker files at project roots that the user has run `sharibako init` in
- The single line for each owned key inside a project's `.env` file (on `materialize`), read-only inspection of those same lines (on `update`), and removal of only those lines (on `clean`)
- The scope's assigned target path (default `./.env`; overridable in the marker)

**Sharibako does not touch:**

- Non-owned lines in the user's `.env` (comments, blank lines, non-secret config like `DEBUG=true`, `PORT=3000`, `NODE_ENV=development`)
- The user's `.env.example`, `.env.local`, `.env.production`, or any other `.env.<suffix>` unless the marker explicitly points at one
- Any file outside the vault directory and the marker-declared target path
- The user's shell config, dotfiles, or global git config
- The user's global age keys or SSH keys (except for using them read-only through the OS to authenticate git operations)
- Any file the user has not opted in to through `sharibako init`

**Sharibako does not "observe":**

- Non-owned line values are read by the parser during `update` and `materialize` only to preserve them byte-for-byte in the file. Their values are not decoded, not compared, not surfaced in drift reports, not logged, not sent anywhere. They pass through the parser like blank lines do: preserved, not inspected.

---

## What Sharibako does not do

- **No telemetry.** No usage metrics, no crash reports, no analytics sent anywhere. The Cloudflare Pages site has whatever Cloudflare provides by default; the app sends nothing.
- **No cloud accounts.** No sign-in, no email required to run the app or use the CLI.
- **No key escrow.** Sharibako cannot recover a lost age key. No support process, no override.
- **No password-manager features.** No autofill, no browser extension, no card storage, no identity records. Website logins belong in a password manager.
- **No team features.** No RBAC, no per-user audit log, no shared-vault permission model. Multiple humans CAN share a vault by sharing the age key, but they are not distinguished by Sharibako.
- **No runtime process attachment.** Sharibako does not inject env vars into already-running processes. `sharibako run` spawns a fresh process with values set at fork time.

---

## Known limits

These are honest constraints of the design, not TODOs.

- **A signal at the wrong moment can leave the temporary age-key file behind.** On macOS the Keychain-retrieved key is written to a `0600` file in the per-user temp directory for the duration of one operation. Cleanup runs on normal completion and on thrown errors, but not when the process is killed by a signal's default action (Ctrl-C during a Touch ID prompt, `kill -9`). The file is unreadable by other users and macOS sweeps the temp directory periodically, but until then the key is on disk. Signal-safe cleanup is tracked as follow-on work.
- **Decrypted values are not scrubbed from memory in v1.** Swift's `String` storage is immutable and copy-on-write, so there is no reliable in-place wipe without restructuring the decrypt pipeline onto raw byte buffers — and for `run` the values must live in the child's environment for its whole lifetime regardless. Sharibako scrubs and deletes the temporary age-key file on exit, but decrypted secret values are simply released. A privileged forensic examiner with physical memory access after a crash could recover recently-decrypted values.
- **Touch ID is prompted per operation.** No session cache in v1. The `sharibako-agent` daemon (post-MVP) is the escape hatch if this becomes intolerable.
- **The bundled `age` binary is trusted transitively.** You are trusting Apple's notarization + your OS updates + upstream `age` releases.
- **Homebrew and `.tar.gz` distributions rely on the tap and download-site integrity.** Verify checksums or signatures where published.
- **The `.sharibako` marker is public.** Committing it to your project's git repo reveals scope name and materialize target. This is intended (the marker exists to be committed) — do not name scopes with information you would not want in the project's history.
- **Materialize is exposed by design.** As discussed above. This is the cost of a verb that exists specifically to interoperate with consumers that cannot be wrapped.

---

## Vulnerability disclosure

### Reporting a vulnerability

If you have found a security issue in Sharibako, please report it privately. Do not open a public GitHub issue.

- Email: `andrew@sageframe.net`
- Include: what you found, how to reproduce it, what version you're on (`sharibako --version`), and what you think the impact is.
- Please give a reasonable window (14 days) for triage and a fix before public disclosure. We will confirm receipt within 3 business days.

### What warrants a private report

- Any bug that lets an attacker read secret values without the age key
- Any bug that lets an attacker bypass Touch ID / Keychain on the age key
- Any bug that writes decrypted values to disk unintentionally
- Any bug in `sharibako run` that leaks values to unintended file descriptors, log streams, or child processes
- Any bug in the update mechanism that would allow substitution of a malicious binary

### What does not warrant a private report

- Feature requests, UX complaints, missing conveniences
- Documentation errors
- "This tool cannot defend against Class 3" — that's stated in this document

For non-security bugs, open a normal GitHub issue at `github.com/sageframe-no-kaji/sharibako/issues`.

---

_Sharibako is a [Sageframe](https://atmarcus.net) project by [Andrew Marcus](https://atmarcus.net), built with the [Ho System](https://github.com/sageframe-no-kaji/ho-system). This document is revised whenever the security posture changes. See git history on this file for the audit trail._
