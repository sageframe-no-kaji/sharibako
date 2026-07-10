---
created: 2026-07-09
type: state-memory
project: sharibako
kamae: 6
status: living
---

# Sharibako — State Memory (Kamae 6)

This file is the build's living cross-session memory. It is hot and non-canonical: mutable, written raw, and always subordinate to the cold canonical record (git history, per-ho Reflect sections, the K4 ho overview). When this file and the cold record disagree, the cold record wins and this file is corrected to match.

---

**STATE-SUMMARY**
- **COMPLETED** — ho-06 split ratified and ho-06.1 AUTHORED (2026-07-10, planning session — no code): three-way split (ho-06.1 responsiveness + honest feedback = the full ho-05 Reflect list; ho-06.2 provisional = three-state glyphs + heal, depends on 06.1's scan cache; ho-06.3 provisional = first-run + age key + backup nudge + ingest flow). ho-06.1 Think ratified — six decisions: VaultWorker actor (async rescan/materialize/sync, WorkshopModel stays @MainActor; sync moves too — git push is network I/O), in-memory scan cache populated at launch, waymarking (sidebar footer + `Conduit.remoteURL()` Core addition, detail-pane marker target, jump-to-directory left of Sync), status pulse + visible labels + honest Rescan icon, 5-minute LAContext reuse window (system cap, ratified over ~2 min) + .env preview sheet (`Materializer.preview` Core addition) + eye toggle + prefill-only-when-revealed, creation announces + Add dialogs as auxiliary windows. Deliverables: `hos/ho-06.1-workshop-responsiveness.md`, agent tasks Ho-06.1-AT-01 (Opus 4.8) / AT-02 / AT-03 (Sonnet 4.6), driver `prompts/ho-06.1-fable-driver.md`.
- **NEXT** — Execute ho-06.1 via `prompts/ho-06.1-fable-driver.md`: AT-01 → AT-02 → AT-03 sequential, signed-install + Touch-ID dogfood gate closes the ho. Relief valve if it spills: AT-03 moves whole to the front of ho-06.2.
- **ACTION ITEMS / BLOCKS** — K4's ho-06 entry needs the three-way split recorded (overview-collaborator pass; flagged, not edited from the authoring session). Still owed, non-gating: the CLI ho (scriptable `init`, unconditional `git init` in vault scaffolding, non-atomic `ingest`); the per-entry "plain/not-secret" flag schema Think (parked, Kamae-2-level). Machine gotcha stands: GitHub remotes on this machine must spell `git@github-<account>:` explicitly (`Host *` sets `User atmarcus`, first-match wins).
- **PROJECT LIFECYCLE** — `dev`

_Updated 2026-07-10 at ho-06.1 authoring close (planning session; split + six decisions ratified live). Previous entry: ho-05 close 2026-07-10 — ho-05 executed same day, PR #11 merged (`7376885`), gate passed, 641 tests / 94.02% coverage; detail now lives in ho-05's Reflect and K4's 2026-07-10 revision._
