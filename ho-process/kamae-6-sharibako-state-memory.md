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
- **COMPLETED** — ho-06.2 (three-state glyphs + heal surface) EXECUTED, GATED, MERGED 2026-07-11 (**PR #13 merged to main, `63564e5`**; ho-06.2 branch deleted). Commits `3503cbb` glyphs → `bc6c18a` heal → `6f72240` Settings+footer → `4139c32`/`e090981`/`4c3625a` gate fixes. Shipped: AT-01 glyphs computed from the 06.1 scan cache (`glyphState`, no re-walk) + "Unlinked markers" section for orphaned/failed markers; AT-02 the heal surface (`driftReports` session cache, Check-drift sweep behind one Touch ID via the 06.1 reuse window, per-key drift + red drifted labels, reconcile through the existing `materialize(force:)` flow, Materialize-all-stale); AT-03 native Settings scene (appearance override, `@AppStorage` → `.preferredColorScheme`) + read-only scan-root footer. 727 tests, coverage 94.74%, warnings-as-errors clean, zero `SharibakoCLI/` files touched. **Gate (signed install, real Keychain) passed** for glyphs, one-Touch-ID drift sweep, reconcile, all-stale, Settings-persists, footer. Two gate fixes landed in-ho: reconcile no longer blanks the detail pane (`markScopeInSync` refreshes to all-in-sync instead of clearing), and drifted per-key labels read red.
- **NEXT** — The **right-side chrome/panel ho** — the 06.2 gate proved the native-toolbar + overflow `»` menu unacceptable ("NOT an acceptable UI"); Decision 1's rail-revisit criterion is MET. Forward-only: a new chrome ho (reconsiders appearance-control placement there too — operator floated a top-bar light/dark/system toggle), not a reopening of 06.2. Needs a Kamae-5 authoring pass (or a K4 overview pass first to place it alongside the multi-root and 06.3 hos).
- **ACTION ITEMS / BLOCKS** — **Owed followup hos, for the K4 overview-collaborator pass to place:** (1) **right-side chrome/panel** — elevated by the 06.2 gate, operator wants it, overflow menu is a stopgap; (2) **multi-root scan-MANAGEMENT UI** (add/remove/reconfigure) — still owed, 06.2 shipped read-only footer visibility only; (3) **ho-06.3** — first-run wizard, age-key generation + backup nudge, GUI ingest journey (CLI-only `init` is the current front door; GUI has no import affordance — premise gate-validated at 06.1). K4's ho-06 section body STILL needs the three-way split reconciled (same overview pass, now also placing the chrome + multi-root hos). Unlinked-markers rows are unit-tested but UI-UNVERIFIED (no orphan on the dogfood vault) — verify at the next gate with a stray `.sharibako`. Owed, non-gating: the CLI ho (scriptable `init`, unconditional `git init`, non-atomic `ingest`); the "plain/not-secret" flag schema Think (parked, Kamae-2-level). Gate procedure: launch from `/Applications` explicitly — Spotlight resurfaces stale DerivedData Debug builds.
- **PROJECT LIFECYCLE** — `dev`

_Updated 2026-07-11 after ho-06.2 MERGED (PR #13, `63564e5`); NEXT is the owed right-side chrome/panel ho. Previous entry: ho-06.2 close (PR pending). Before that: ho-06.1 close (merged 2026-07-10)._
