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

## 2026-07 — No mark cancellation, and its accepted consequences (superseded)

*Superseded 2026-07-29 by the order-ledger entry below: expiry-based
cancellation of our own marks was added for 1.1.0. The no-cancel-cooldown and
no-runtime-state-restore consequences still stand.*

Without a ledger we cannot distinguish our marks from a player's, and cancelling
a player's mark is off-limits — so no mark is ever cancelled. Consequences,
accepted deliberately; do not "fix" them:

- **No order expiry.** A starved mark stays until a player clears it or supply
  reappears.
- **No cancel cooldown.** A player-cancelled mark gets re-marked on a later
  round while supply persists.
- **No runtime-state restore.** Our upgrades behave exactly like player-ordered
  native upgrades.

## 2026-07-29 — Order ledger reintroduced for expiry (supersedes no-cancellation)

Starved marks turned out to matter in practice: a snapshot-based order can lose
its supply moments after it is placed (biter damage dispatching rebuild bots,
player upgrade passes draining stock), and a starved mark then squats on the
demand accounting and the player's alert list until supply happens to return.
The fix is a minimal order ledger — `storage.order_ledger`, `unit_number →
{entity, order_tick, target_quality}` — recording only the two facts the world
cannot answer: that a mark is ours, and when we placed it.

This is not the retired per-entity state coming back. That ledger cached world
facts (positions, candidacy) that could go stale and needed repair machinery;
this one's facts never go stale, and losing it degrades gracefully — orphaned
marks simply never expire, which is exactly the old accepted behavior. Player
marks remain untouchable (a ledger miss means hands off), and an entity
re-marked to a different target than we ordered is dropped from the ledger on
sight.

Cancellation requires expired **and** target-out-of-stock, never expiry alone:
a stocked-but-queued order is the bots' business, and cancelling it would just
churn (re-ordered next round). Orders whose item a bot is already carrying are
invisible to the supply snapshot; the generous default expiry (300 s) keeps
mid-flight cancels rare, and each one self-corrects — the bot returns the item,
the next round re-orders, the clock resets. After a genuine starvation cancel
there is no re-order loop: no supply means the entity is not a candidate.

Orphaned entries (entity destroyed, or replaced by the completed upgrade — a
new unit number either way) are pruned by a budgeted sweep between rounds: a
`next()`-cursor walk of the ledger in `storage`, one entry per budget step,
overlapping the round-delay rest window. No destruction events — the sweep is
housekeeping, not correctness (a stale entry can at worst match a mark
identical to one we would place ourselves), so eventual pruning suffices and a
mid-sweep save/load reordering the hash walk is harmless. Marks in networks
that lost bot coverage are never encountered; they sit inert and expire on the
first visit after coverage returns.

## 2026-07-29 — Pass runs every tick, with uniform budget steps

`on_nth_tick(10)` with a 10× budget delivered the same average throughput in
bursts; the pass now runs every tick with `entities-per-tick` (default 1) —
the smallest chunks and the most consistent cost. Budget steps are uniform:
one network entry, one entity examine, one cell scan, or one ledger check each
cost one step. No weighted costs — there are no profiling numbers to ground a
weight in, the budget setting already scales all phases together, and the
ledger sweep is bounded above by the scan phase anyway (every ledgered entity
is also examined every round, alongside all the unmarked ones).

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

*Superseded 2026-07 by the behavior toggles below: the retarget arm now sits
behind `manage-ghosts` (default on); the demand accounting is still always on.*

## 2026-07 — Module provisioning quality-only, always on

Never change which module prototype sits in or is requested for a slot, only its
quality. Installed modules are only ever upgraded (a player chose them);
unfulfillable *requests* are retargeted in either direction, a downgrade beating
an empty slot. Built entities only — ghost module slots are out of scope.

*Amended 2026-07: "always on" became "under `manage-factory`" with the behavior
toggles below; quality-only is unchanged.*

## 2026-07 — Three behavior toggles, acting arms only

The three behaviors each sit behind a runtime-global bool setting, default on:
`manage-factory` (upgrades of placed buildings and their installed modules,
including module-request retargets), `manage-ghosts` (ghost retargets), and
`manage-upgrade-requests` (starved non-ledgered marks retargeted). `manage-` is
a shared verb naming the behavior, not a mod prefix. The flags are snapshotted
at network entry like everything else; a mid-visit change applies from the next
network. Crucially a toggle gates only the *acting* arm of its behavior —
demand accounting always runs, because a stocked ghost or pending proxy
consumes bots and supply whether or not we may retarget it, and skipping the
count would make the enabled behaviors over-order. When all three are off,
`enter_network` skips the network outright. No per-entity-type toggles — that
remains a retired alternative.

## 2026-07 — Upgrade-request provisioning is quality-only and ledger-free

A non-ledgered mark (a player's, or another mod's) whose target quality is out
of stock is retargeted to the best stocked tier of its *target* item — the
target prototype's placing item, so cross-prototype marks (burner inserter →
fast inserter) resolve through what the mark asks for, not what the entity is.
Quality only: the chosen prototype is sacred, mirroring module provisioning.
The retargeted mark is deliberately not adopted into the ledger: it stays the
player's, so expiry can never cancel it, and the original quality is not
remembered (ghost-provisioning philosophy — once swapped, the entity chases
best supply). If stock drains again a later round just retargets again; if
nothing is stocked the mark sits untouched with the native missing-material
alert. This refines, not breaks, "only ledgered marks are ever cancelled":
retargeting is not cancelling.

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
