# Secrets, `.env` Files, and Sharibako—The Source Document

This is the canonical plain-English explanation of what Sharibako does and why.
It is the source material for the website landing page, the site FAQ, and the
in-app help—each of those is a cut of this document at a different depth, so
when the story changes, change it here first.

Structure follows the `*, Actually` ethos: organized by what a person arrives
*wondering*, not by product surface; layered so a reader can stop at a name, a
definition, or the full theory; and built around **"actually" corrections**—the places where the naive model everyone carries is wrong, named and fixed.

---

## Part 1—Secrets and `.env`, explained from zero

### What is a secret?

A secret is a value that *grants a capability*. An API key that lets code send
email as you. A database password. A token that posts to your Slack. If someone
else had the value, they could do the thing—that's what makes it a secret.

The litmus test: **if this value leaked, would you have to change it?** If yes,
it's a secret. If no—a port number, a feature flag, a public URL, a model
name—it's just configuration. Configuration wants to be visible and in git.
Secrets are the part that can't be.

### How `.env` files work

Nearly every modern project keeps its secrets in a file called `.env` at the
project root—plain text, one `KEY=value` per line:

```
MAILCHIMP_API_KEY=a1b2c3...
DATABASE_URL=postgres://admin:hunter2@db.example.com/prod
```

When the app starts, a small library (dotenv and its hundred cousins) reads the
file and turns each line into an *environment variable*—a named value the
running program can read with `os.environ["MAILCHIMP_API_KEY"]` or
`process.env.MAILCHIMP_API_KEY`. The app never knows the file existed; it just
sees the variables. By convention `.env` is listed in `.gitignore`, so the
secrets stay out of version control while the code goes in.

This is a genuinely good convention. Secrets stay out of source code, each
machine can have its own values, and every language and framework understands
it. Sharibako does not replace it—it keeps it, and fixes what's wrong with
it.

### What's actually wrong with `.env` files

The naive model says: *my secrets are in a gitignored file, so they're
handled.* Actually, four problems are quietly accumulating:

**1. Each `.env` is the only copy.** Gitignored means unversioned, and
unversioned means unbackable-up—deliberately. If your laptop dies, every
`.env` on it dies too, and rebuilding them is a scavenger hunt through provider
dashboards, password-manager notes, and old Slack messages. The file that
matters most is the one thing your careful backup discipline is explicitly told
to skip.

**2. Backing them up creates the leak.** The obvious fix—let Dropbox or Time
Machine or a private "dotfiles" repo have them—copies plaintext secrets into
systems you don't control and can't audit. Now the secret exists in your cloud
sync history, on a backup drive in a drawer, in a repo you'll one day make
public without remembering what's in it.

**3. Git is one mistake away.** One `git add .` before the `.gitignore` entry
exists, one `.env.production` that didn't match the ignore pattern, and the
secret is in history—where deleting the file does not remove it. Scrubbing
git history is genuinely painful, and every fork and clone made in the
meantime keeps the old value forever. This is not a rare accident; leaked-key
scanners on GitHub stay busy.

**4. Sprawl and drift.** The same `OPENAI_API_KEY` gets pasted into eight
projects. When it's time to rotate it, you get to find all eight—and you
won't, because nothing tracks where it went. There is no answer to "what was
the old value," "when did this change," or "which projects use this key."

### The part everyone gets wrong: encrypting your `.env` is theater

Here is the correction that shapes Sharibako's whole design.

The instinctive fix for "plaintext secrets on disk" is to encrypt the `.env`
itself. **Actually, that protects almost nothing**—because your tools need
the plaintext to run. Whatever encrypts the file must decrypt it every time
`npm start` runs, which means the plaintext (or the means to produce it) is
always present and reachable on a live machine. And anyone who can act as you
on your live machine—malware running in your session, a person at your
unlocked keyboard—can read *everything you can read*: your SSH keys, your
browser cookies, your password manager while it's unlocked, and yes, your
secrets, encrypted file or not. Encryption at that layer inconveniences you
daily and an attacker not at all. That's the definition of security theater.

What encryption *genuinely* protects is every copy that leaves your live
session: the synced copy, the backed-up copy, the pushed copy, the historical
copy, the copy on the drive in a stolen laptop (alongside full-disk
encryption, which is the real answer to theft). Those copies sit in places
where an attacker doesn't need your live session—and those are exactly the
copies that leak in practice.

So the honest architecture is:

> **Let the working copy be plain. Make every other copy safe.**

That single sentence is Sharibako.

### What Sharibako actually does

Sharibako keeps **one canonical, encrypted copy** of every secret in a single
place—the vault, a folder in your home directory where each secret is a
small file encrypted with [age](https://age-encryption.org), and the whole
folder is a git repository. From that one copy:

- **Materialize** writes a project's `.env`—a plain, disposable, regenerable
  file. Lose it, delete it, wipe the machine: `materialize` brings it back.
- **Run** (`sharibako run npm start`) skips the file entirely—secrets are
  decrypted in memory, handed to your process as environment variables, and
  gone when it exits. Nothing touches disk.
- **Sync** pushes the vault to a git remote. The remote only ever sees
  ciphertext—so a private GitHub repo becomes a legitimate, auditable backup
  of your secrets, with history.
- A `.sharibako` marker file in each project binds that directory to its
  *scope*—its slice of the vault—so the tools always know which secrets
  belong where.
- A secret used by many projects lives once as a **shared** secret; projects
  **link** to it. Rotate it in one place; every project gets the new value on
  the next materialize.
- The decryption key lives in your Mac's Keychain behind **Touch ID**, so
  *reading* a secret costs a fingerprint—and everything is recoverable on a
  new machine from just two things: the vault repo and your backed-up key.

Your projects don't change at all. They keep reading environment variables the
way they always have. The `.env` just stops being the only copy of anything.

---

## Part 2—Landing page copy

Succinct, honest, no invented claims. Hero, subhead, three value blocks, and
the honesty blurb—because the theater argument, stated plainly, is the most
credible thing on the page.

### Hero

> **Sharibako**
> One encrypted box for every API key you own.
>
> Your `.env` files keep working exactly as they do today. They just stop
> being the only copy of your secrets.

*(Sharibako—舎利箱—is a reliquary: a small box for keeping precious
things.)*

### Subhead

> A native Mac app and CLI for the developer with fifteen projects and one
> drawer of API keys. Every secret lives once, encrypted with `age`, in a
> git-backed vault behind Touch ID. Your projects' `.env` files become
> disposable—regenerate any of them with one click, on any machine, forever.

### Three value blocks

> **Never lose a key again.**
> The vault is a git repo. Push it to a private remote and your secrets are
> backed up, versioned, and recoverable—as ciphertext, so the remote learns
> nothing. New laptop? Clone the vault, restore your key, materialize. Done in
> minutes.

> **Rotate once, not eight times.**
> A key shared across projects lives in the vault exactly once; projects link
> to it. Change it in one place and every project picks up the new value.
> Sharibako can also tell you which `.env` files have drifted from the vault—> and fix them.

> **Or skip the file entirely.**
> `sharibako run npm start` decrypts your secrets in memory, injects them into
> your process's environment, and leaves nothing on disk. Your code can't tell
> the difference—it's just environment variables.

### The honesty blurb (footer of the landing page)

> **What Sharibako doesn't do:** it doesn't encrypt the `.env` your tools
> read, and it never will—your tools need the plaintext, and anyone who
> controls your live session can read what your tools can read. Encrypting the
> working copy is theater. Sharibako protects every *other* copy: the backup,
> the sync, the remote, the history, the new machine. The working file is
> plain—and disposable.

---

## Part 3—FAQ

Question-shaped, in the order people actually arrive at them. Each answer
leads with the correction if the question carries a naive model.

**Is my `.env` encrypted after I import it into Sharibako?**
No—and that's deliberate. Your tools need to read that file; encrypting it
would break them or require decrypting it constantly, which protects nothing
on a live machine. Importing makes an *encrypted copy* in the vault. The
`.env` in your project stays exactly as it was—except now it's disposable,
because the vault can regenerate it.

**Then what's the point?**
Before Sharibako, each `.env` was the only copy of its secrets—unbackable,
unversioned, unrotatable, one `git add .` from disaster. After, the canonical
copy is encrypted, versioned, backed up to a remote that only sees ciphertext,
and shared keys live once instead of eight times. The working file goes from
*single point of failure* to *cache*.

**What if someone steals my laptop?**
FileVault (Mac full-disk encryption, on by default) is your protection there—for everything on the disk, `.env` files included. Sharibako adds that the
vault's contents are ciphertext even *inside* the disk image, and your
decryption key is in the Keychain, which the thief can't open without your
fingerprint or password.

**What if someone is sitting at my unlocked machine?**
Then they are you, as far as the machine is concerned—they can read your
browser sessions, your SSH keys, and any `.env` file. No dev-secret tool can
protect a live, unlocked session, and any that claims to is selling theater.
What Sharibako gates behind Touch ID is the *vault*: revealing a stored
secret's value, decrypting for materialize or run. The blast radius of an
unlocked machine is your working files, not your whole vault.

**Is it really safe to push my secrets to GitHub?**
The remote only ever receives `age`-encrypted files—ciphertext. Without
your private key (which never leaves your machine and Keychain), the repo's
contents are noise. Use a private repo anyway: defense in depth, and the
*names* of your scopes and keys are metadata you may not want public. One
honest caveat: git history retains old ciphertext forever, so treat "delete
from vault" as "stop using," not "erase from time."

**What happens if I lose my key?**
You lose the vault. That is the deal with real encryption—there is no
recovery email. This is why first-run makes you save a backup copy of the key
and verifies you actually did. Keep that backup somewhere durable (iCloud
Drive, a printed copy, a password manager). Vault + key = everything;
vault − key = nothing.

**What happens if I lose the vault?**
If you configured a remote: `git clone`, restore your key, materialize—you're back. If you never set a remote and the disk is gone, the vault is
gone. Set the remote. It's one field in first-run.

**Where does my key live day-to-day?**
In the macOS Keychain, stored so that reading it requires user presence—Touch ID or your password. When Sharibako needs it, it asks, uses it, and
scrubs the temporary copy. A successful Touch ID is reused for five minutes so
bulk operations don't prompt you per secret.

**What counts as a secret? Should I put *everything* from my `.env` in?**
Put in anything you'd have to rotate if it leaked. Skip pure configuration
(ports, hostnames, flags)—that belongs in git, visibly. Sharibako's import
lets you decide per key: import it, mark it shared, leave it alone, or skip
it.

**Two of us share a project. Can we share the vault?**
Two humans who trust each other can share the vault repo and the key—it works fine. What Sharibako doesn't have is *team features*: no per-person
access, no audit log of who read what, no revoking one person. When you need
those, you've outgrown the tool—use a team secret manager.

**What about my servers / CI / production?**
Out of scope, honestly. `run` and `materialize` are for humans at dev
machines. Production secrets belong in your platform's secret manager (AWS
Secrets Manager, Vault, your PaaS's env config)—those exist precisely for
unattended machines. Sharibako is for the laptop end of the pipeline.

**How is this different from 1Password?**
A password manager stores secrets; it doesn't know what a project is. Sharibako
is project-shaped: it knows which directory maps to which secrets, writes and
regenerates `.env` files, detects when they drift from the vault, injects
into processes, and de-duplicates keys across projects. Keep your logins in
the password manager; keep your project secrets somewhere that understands
projects. (Keep your key *backup* in the password manager—good pairing.)

**What's a "scope"?**
One project's slice of the vault—usually one repo ↔ one scope. The
`.sharibako` marker file in your project directory records which scope it
binds to and where the `.env` should be written.

**What does "drift" mean?**
Your `.env` says one thing, the vault says another—usually because you
hand-edited the file. Check Drift shows exactly which keys differ, and you
choose the winner: reconcile from the vault, or re-import the file's value.

---

## Part 4—Minimal in-app help (proposal)

The constraint: a user with no internet and no manual should be able to learn
what Sharibako is *from inside the app*. The proposal is layered, smallest
first, and reuses surfaces that already exist:

**1. The first-run wizard is the primer (exists—keep sharpening).** The
welcome page already carries the depth-1 explanation ("Sharibako keeps your
projects' API keys in one encrypted, git-backed box"). Each page's one-line
explainer carries the *why* of its own step ("the remote is the vault's real
backup"). This is where the theater argument earns one plain sentence: *"Your
`.env` files stay readable—your tools need them. Sharibako protects every
other copy."*

**2. The tour is the refresher (exists).** Help → "Welcome to Sharibako…"
replays the same pages against live state. No new work; it's the re-entry
point for "wait, how does this work again?"

**3. Add one static Help window: "How Sharibako Works" (new, small).** A
single scrollable view under the Help menu—no web dependency—carrying
roughly Part 1 of this document at depth 2: five short sections (What a secret
is · What the vault is · Materialize vs Run · Why your `.env` stays plain ·
Losing things: key, vault, laptop). Static text in one SwiftUI view;
CI-excluded like every other view. This is the only genuinely new surface.

**4. Empty states teach (mostly exists).** Every empty pane states what would
fill it and which verb does it ("No scopes yet—Ingest Project… brings your
first `.env` into the vault"). Empty states are the app's most-read
documentation; each should name its verb.

**5. A glossary as tooltips, not a page.** The five terms of art—scope,
marker, materialize, drift, shared/link—each get one consistent
plain-English sentence, used as help-tooltips wherever the term appears in a
label. Single source: define the five sentences once (in this document, Part
5) and reuse them verbatim.

Deliberately *not* proposed: in-app FAQ browsers, embedded web views, or
contextual help popovers on every control—chrome that competes with the
calm. Five terms, one static window, teaching empty states.

---

## Part 5—The reference: secrets, storage options, and where Sharibako sits

The exhaustive layer, for the reader who wants the full model.

### What is and isn't a secret

| Value | Secret? | Why |
|---|---|---|
| API key, access token | **Yes** | Grants capability; rotate on leak |
| Database URL with password | **Yes** | Contains a credential |
| Private signing/deploy key | **Yes** | Identity-granting |
| Webhook *signing* secret | **Yes** | Forgery-preventing |
| OAuth client secret | **Yes** | Half of an identity |
| Publishable/public API key | No | Designed to be visible client-side |
| Hostnames, ports, URLs | No | Configuration; belongs in git |
| Feature flags, model names | No | Configuration |
| `.env.example` contents | No | Names without values—commit it |

Gray zones: OAuth *client IDs* (usually fine to expose, sometimes paired-risk);
internal hostnames (not credentials, but reconnaissance value—your call);
anything with "test" in it (test keys still often bill or leak data—treat as
secrets). When unsure, apply the rotation test.

### The `.env` ecosystem, precisely

`.env` is a convention, not a standard—which is why parsers disagree on
edge cases (quoting, multiline values, `export` prefixes, comments). The
common family:

- **`.env`**—the real values, gitignored, machine-local.
- **`.env.local`**—same idea; some frameworks load it *over* `.env` for
  per-machine overrides. Also plaintext, also gitignored.
- **`.env.example`**—the keys with values stripped, committed, serving as
  documentation of what the project needs.
- **`.env.production` / `.env.development`**—per-environment variants;
  historically the single most common way real secrets end up in git, because
  ignore patterns miss them.

Environment variables themselves are the actual interface: a process inherits
a set of named strings from whatever launched it. `.env` files are just one
way to populate them; a shell `export`, a launcher like direnv, a container
runtime, or `sharibako run` are others. Programs can't tell which was used—that neutrality is why Sharibako can slot in without any project changes.

### The options for storing developer secrets

Every approach is a different answer to "where does the canonical copy live,
and what protects it?"

**Plaintext `.env` only (the default).** Canonical copy: the file itself.
Protection: `.gitignore` and hope. Zero setup, universally understood—and
unbackable, unversioned, sprawling, one mistake from history. Fine for a
throwaway; a liability by the second project.

**direnv / shell exports.** Same properties as `.env` with different
ergonomics—the secrets are still plaintext files on one machine. Solves
loading, not custody.

**Password manager (1Password, Bitwarden, …).** Canonical copy: their
encrypted store; protection: their security model, which is excellent.
Project-blind: no scopes, no `.env` generation, no drift detection; CLI
bridges (`op run`) exist but per-project wiring is manual. Ideal for logins
and as the *backup home for your Sharibako key*.

**Cloud secret managers (AWS Secrets Manager, GCP Secret Manager, HashiCorp
Vault, PaaS env config).** Canonical copy: a server; protection: IAM and audit
logs. Built for *unattended machines and teams*—access control, rotation
policy, auditability. Overkill and friction for a personal laptop (network
dependency, auth ceremony, cost), and exactly right for production. Sharibako
deliberately does not compete here.

**Encrypted-in-repo (SOPS, git-crypt, raw `age` by hand).** Closest cousin:
ciphertext in git, plaintext at use. This is the right *architecture*—Sharibako shares it—delivered as composable primitives: no project binding,
no materialize/regenerate loop, no drift detection, no shared-key
deduplication, no GUI, key custody is on you. If you'd enjoy assembling that
from parts, you'd enjoy those tools; Sharibako is that architecture with the
plumbing done and Touch ID on the door.

**OS keychain directly.** Great custody (hardware-backed, biometric-gated),
no project model, no files, no sync story for a *set* of project secrets.
It's a component, not a solution—Sharibako uses it as exactly that, for the
one secret that can't protect itself: the age key.

### Where Sharibako sits, stated as constraints

Sharibako is deliberately narrow: **local-first custody of development
secrets, for one human (or two who share everything), on machines they sit
at.** The canonical copy is files on your disk (the filesystem *is* the
database—every secret is a `.age` file you can see, copy, and understand);
protection is `age` encryption with the key in your Keychain; backup and
history are git, because you already trust git. It ends where unattended
machines and teams begin—by design, those problems belong to the
server-shaped tools above.

### The threat model, stated fully

Protected against: loss of the working file (regenerable), loss of the
machine (remote + key backup), leakage through backup/sync channels (only
ciphertext leaves), git accidents involving the *vault* (contents are
ciphertext), stolen powered-off hardware (FileVault + ciphertext + Keychain),
shoulder-surfing casual value exposure (masked until Touch ID).

Explicitly *not* protected against: an attacker with your live, unlocked
session (they are you; nothing at this layer can help); a compromised tool
that legitimately receives the secret (it needs the secret to work); leaked
plaintext `.env` files you copy around by hand outside Sharibako's flows; and
"delete from history"—git retains old ciphertext, so revoke-and-rotate is
the real remediation for a compromised key, everywhere and always.

The design's honest sentence, one more time: **the working copy is plain
because it has to be; every other copy is safe because it doesn't have to be
plain.**

---

*Source document for: website landing page (Part 2), site FAQ (Part 3),
in-app help (Part 4), and any future docs page (Parts 1 and 5). Written
2026-07-18 during the ho-06.3 gate; the in-app help proposal in Part 4 is
owed a placement decision in the K4 pass (likely ho-08/09 ship work, except
the "How Sharibako Works" Help window, which could ride any GUI ho).*
