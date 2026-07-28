# Release polish: documentation, migration, packaging for 0.2.0

Sweep everything the rewrite (plans 001–003) touched but didn't finish:
documentation truth, old-save migration, locale completeness, version bump,
and a packaged release.

## Context

Plans 001–003 replace the mod's architecture (event-maintained index + order
ledger → stateless scan) and add ghost and module provisioning. Each plan
updates docs for its own change, but a final pass is needed to make the whole
story coherent for three audiences: players (README, mod portal description,
locale), future engineers (CLAUDE.md), and upgrading users (migration,
changelog). This plan assumes 001–003 are merged; trim any item already fully
handled there.

## Implementation Notes

- `info.json` — version, currently 0.1.0 → 0.2.0.
- `changelog.txt` — Factorio's changelog format is rigid (exact section
  headers, two-space indents); follow the existing file's structure.
- `locale/` — every setting must have a name and description entry; stale
  entries for removed settings (`entities-per-tick`, `order-timeout-minutes`)
  must go.
- Old-save migration: `on_configuration_changed` runs full `initialize()`,
  which must leave no stale storage keys (`storage.candidates`,
  `storage.ledger`, `storage.ledger_by_position`, `storage.cooldown`,
  `storage.refresh`) and must tolerate a save where bots are mid-flight on
  orders the old ledger tracked (they simply complete; nothing references
  them). No `migrations/` scripts should be needed — verify.
- `./package.sh` validates (luacheck via `./validate.sh`), zips, and copies
  the mod into the local Factorio mods folder.
- The `reference/` and `archive/` directories are historical; don't update
  them.

## Suggested Approach

1. **CLAUDE.md**: rewrite the one-line architecture summary and the design
   invariants to describe the scan-based design (world-only truth; no
   per-entity state; fresh bot count per visit; no expiry, cooldown, or
   restore — with the "deliberate, don't reintroduce" July 2026 markers the
   file already uses for such decisions). Refresh the verified-API-facts
   section with the ghost and proxy facts confirmed in plans 002/003, and
   delete facts that no longer matter. Keep it short; it's an instruction
   file, not a history.
2. **README.md**: player-facing behavior — upgrade gardening, ghost
   downgrade-to-build (headline feature), module provisioning, the settings
   that exist now, and honest notes on the accepted rough edges (stuck marks
   are never auto-cancelled; cancelled marks get re-marked while supply
   persists).
3. **Changelog + version bump.**
4. **Load test**: open a 0.1.0 save with the new version; confirm clean
   migration and normal operation.
5. **Package**: run `./package.sh`; smoke-test the zipped mod in-game.

## Testing

No test suite (project convention). `./validate.sh` and in-game checks.

## Validation

- `./validate.sh` and `./package.sh` succeed.
- A 0.1.0 save loads without errors; `/quality-gardener-init` runs clean; no
  stale storage keys remain (inspect via `/c game.print(serpent.block(...))`
  or the storage debug view).
- Every setting shown in-game has a proper localized name and description; no
  orphaned locale keys.
- README, CLAUDE.md, and actual behavior agree — read each claim against the
  code.
- Changelog renders correctly in the in-game mod browser.

## Documentation

This plan *is* the documentation pass: `CLAUDE.md`, `README.md`,
`changelog.txt`, `locale/`, `info.json`, and the mod-portal description if one
is maintained outside the repo.
