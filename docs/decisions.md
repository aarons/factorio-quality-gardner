# Decision log

Historical record of deliberate design decisions, with the context and rationale
that no longer needs to live in `CLAUDE.md`. Consult a specific entry when a
change touches its subject; nothing here needs to be read routinely.

## 2026-07 — Per-entity state removed (candidate index, order ledger)

The original architecture maintained an event-driven candidate index
(`storage.candidates`) with cached positions plus an order ledger
(`storage.ledger`) with timestamps, expiry, and a rotating position-refresh
slice. Commit 08091a2 replaced all of it with a stateless scan-based pass: each
network visit reads reality fresh (contents, roboport cells, the entities inside
them) and issues orders directly, recognizing marked entities by asking the
entity itself (`to_be_upgraded()`).

Rationale: the index and ledger were caches of world state that could only go
stale, and every staleness mode needed its own repair machinery (adoption
rescans, expiry timeouts, position refresh). The scan pass reads truth directly,
so that machinery — and its bug surface — disappears. The reference mod and this
repo's git history both contain the old shape; do not reintroduce it.

## 2026-07 — No mark cancellation, and its accepted consequences

Without a ledger we cannot distinguish our marks from a player's, and cancelling
a player's mark is off-limits — so no mark is ever cancelled. Consequences,
accepted deliberately; do not "fix" them:

- **No order expiry.** A starved mark stays until a player clears it or supply
  reappears.
- **No cancel cooldown.** A player-cancelled mark gets re-marked on a later
  round while supply persists.
- **No runtime-state restore.** Our upgrades behave exactly like player-ordered
  native upgrades.

## 2026-07 — No supply-based early exit in the scan

Every network with bot headroom gets its cells scanned, whatever its contents.
Networks without buildable stock are rare in practice and act as natural pacing
between the ones that matter. The supply snapshot keeps every on-chain contents
row unfiltered; rows for items that place no entity are harmless because nothing
ever looks them up. Duplicate entities across overlapping cells are harmless —
once marked, later encounters take the demand-accounting path. Don't reintroduce
a "skip networks without candidate supply" shortcut.

## 2026-07 — No exclusion machinery

No mod lists, surface filters, or Factorissimo integration. Bots perform the
upgrades natively, so entities other mods manage are handled fine. The reference
mod's exclusion machinery predates this decision — don't copy it back.

## 2026-07 — Candidacy derived from prototypes

No per-entity-type enable settings and no hand-maintained type list. Candidacy
is derived from prototypes in `build_and_store_config` (has a placing item, not
flagged `not-upgradable`) — belts and pipes included.

## 2026-07 — Hidden-quality machinery removed

The old skip/sticky startup settings are gone. Hidden qualities come from other
mods, and other-mod support waits until the core is proven. Every tier on the
normal chain is treated alike.

## 2026-07 — Ghost provisioning always on, no toggle

A ghost whose exact quality is stocked is left to the bots (counted as demand);
otherwise it is retargeted to the best stocked tier, even a lower one.

## 2026-07 — Module provisioning quality-only, always on

Never change which module prototype sits in or is requested for a slot, only its
quality. Installed modules are only ever upgraded (a player chose them);
unfulfillable *requests* are retargeted in either direction, a downgrade beating
an empty slot. Built entities only — ghost module slots are out of scope.

## 2026-07 — No PickerDollies/teleport-mod event integration

Originally: cached candidate positions were hints only, tolerated by a mark-time
re-read plus a rotating refresh slice. Since the per-entity state removal the
question is moot — no positions are cached anywhere, every round scans entities
fresh, so untracked teleports cannot go stale. Don't resubscribe to dolly
events, and don't add a position cache that would make them relevant again.

## 2026-07 — No test suite

Validation is luacheck via `./validate.sh`, nothing more. Factorio runtime
behavior can't be meaningfully unit-tested outside the game; in-game
verification plus the "still unverified" list in `CLAUDE.md` is the process.
