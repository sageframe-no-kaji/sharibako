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
- **COMPLETED** — ho-06.4 (palana palette → semantic color-token layer) EXECUTED, GATED, MERGED 2026-07-11 (**PR #14 merged to main, `60f78f2`**; `theme-palette` deleted). New `Color+Theme.swift`: nine appearance-aware tokens (`accentMoss`, `drift`, `inSync`, `ink`, `inkSecondary`, `inkTertiary`, `ground`, `groundDeep`, `panelGround`) over a pure `Palette.resolved(dark:)` seam + a dynamic `NSColor(name:dynamicProvider:)` provider — no asset catalog, no `Package.swift` change, 100% covered (no CI exclusion). Light values = palana §2; dark values a warm-dark sibling set designed here (portable back to palana; palana untouched). Migrated app `.tint` → moss on every scene root, `.accentColor`→moss, `.red`→drift, green→inSync, `.secondary`/`.tertiary`→ink tokens across all 7 views. Vibrancy materials (`.bar`/`.quaternary`) kept; the flat `ground*` tokens are defined-and-tested but UNCONSUMED — reserved for the panel ho. 731 tests, ~94.8% coverage, warnings-as-errors clean, both linters strict. **Gate (signed Xcode app in `/Applications`) passed**; one gate-tune: success/status pulse muddied to olive over the dark bar, so `inSync` decoupled to its own cleaner/brighter moss + both pulses raised 0.25→0.40. (ho-06.2 preceded — PR #13 `63564e5`; ho-06.1 PR #12.)
- **NEXT** — The **right-side chrome/panel ho** (provisional 06.5) — the 06.2 gate proved the native-toolbar + overflow `»` menu unacceptable; Decision 1's rail-revisit criterion is MET. Forward-only: a new chrome ho (reconsiders appearance-control placement — operator floated a top-bar light/dark/system toggle), not a reopening of 06.2. **Now unblocked** — it consumes ho-06.4's `panelGround`/`ground*` tokens. Needs a Kamae-5 authoring pass (or a K4 overview pass first to place it alongside multi-root and 06.3).
- **ACTION ITEMS / BLOCKS** — none blocking. **Owed followup hos, for the K4 overview-collaborator pass to place:** (1) **right-side chrome/panel** (the NEXT); (2) **multi-root scan-MANAGEMENT UI** (add/remove/reconfigure) — 06.2 shipped read-only footer only; (3) **ho-06.3** — first-run wizard, age-key gen + backup nudge, GUI ingest (CLI-only `init` is the current front door). K4's ho-06 section body STILL needs the three-way split reconciled (same overview pass, now also placing chrome + multi-root + the 06.4/06.5 palette+panel numbering). Small new owed: **destructive-verb rust** — palana wants delete/remove affordances in `drift` rust; 06.4 left them unwired (out of migration scope). Unlinked-markers rows unit-tested but UI-UNVERIFIED (verify at next gate with a stray `.sharibako`). Owed, non-gating: the CLI ho (scriptable `init`, unconditional `git init`, non-atomic `ingest`); the "plain/not-secret" flag schema Think (parked, Kamae-2). **GUI build/dogfood path (recorded so it isn't re-litigated):** the Workshop builds from the committed `xcode/Sharibako.xcodeproj` → signed `Sharibako.app` in `/Applications` (NOT `swift run`, NOT `scripts/install.sh` which is CLI-only). Launch from `/Applications` explicitly — Spotlight resurfaces stale DerivedData builds.
- **PROJECT LIFECYCLE** — `dev`

_Updated 2026-07-11 after ho-06.4 MERGED (PR #14, `60f78f2`); NEXT is the owed right-side chrome/panel ho (now unblocked by the palette tokens). Previous entry: ho-06.2 close (PR #13). Before that: ho-06.1 (merged 2026-07-10)._
