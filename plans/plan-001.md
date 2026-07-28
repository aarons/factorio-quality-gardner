# Core rewrite: scan-based matching, no tracking state

Replace the event-maintained candidate index and order ledger with a stateless,
scan-based loop: each logistic network is visited round-robin, its contents are
snapshotted once, its construction coverage is scanned for entities, and upgrades
are ordered directly against the snapshot. All per-entity bookkeeping
(candidate index, ledger, cooldowns, position cache) is deleted.

## Context

Quality Gardener is a Factorio 2.1 mod: when higher-quality versions of placed
buildings sit in a logistic network's storage, lower-quality placed buildings in
that network get marked for upgrade so construction bots swap them out.

The current implementation (see git history on the `downgrades` branch) maintains
a candidate index of every upgradeable entity via build/destroy events, plus a
ledger of orders the mod has issued, with timeout-based expiry, player-cancel
cooldowns, and captured runtime state restored after the bot swap. This was
decided (July 2026) to be more machinery than the problem needs, and it blocks
the next features (ghost and module provisioning, plans 002/003) because ghosts
and module contents can't be tracked cleanly by events.

The new design: **the world is the only source of truth**. Nothing per-entity is
stored. Each network visit reads reality fresh — network contents, roboport
coverage, and the entities inside it — and issues orders on the spot. Marked
entities are recognized by asking the entity itself (`to_be_upgraded()`), not by
looking anything up.

Deliberate behavior changes, agreed with the mod author (July 2026) — do not
"fix" these:

- **No order expiry.** An upgrade mark whose supply vanished stays until a
  player clears it or supply reappears. We never cancel any mark: without a
  ledger we cannot distinguish our marks from a player's, and cancelling a
  player's mark is off-limits.
- **No cancel cooldown.** If a player cancels a mark we made, we will re-mark it
  on a later round while supply persists. Accepted; the delay between rounds
  makes this slow.
- **No runtime-state restore.** The old code captured accumulator charge, lamp
  state, and silo auto-launch and restored them after the swap. Deleted. Our
  upgrades should behave exactly like a player-ordered native upgrade.
- **No persistent per-network bot budget.** `available_construction_robots`
  already excludes busy bots (including bots flying our orders), so reading it
  fresh at each visit is the whole cap. Never store a `LuaLogisticNetwork`
  reference or network id across a tick boundary — they invalidate on any
  network merge or split.

## Implementation Notes

Files:

- `control.lua` — entry point, config build, event registration.
- `scripts/gardener.lua` — the matching engine. Bulk of the rewrite.
- `scripts/index.lua` — the candidate index. **Delete this file.**
- `scripts/qualities.lua` — quality-chain/tier helpers. Keep as is. Everything
  refers to qualities by "tier", the 1-based position in the chain walked from
  "normal" via `quality.next`. `tier_of(name)`, `at(tier)`,
  `is_candidate_tier(tier)`, `is_target_tier(tier)`.
- `settings.lua` — runtime settings.
- `locale/en/…` — setting names/descriptions live here; new settings need entries.

Verified API facts (do not re-derive):

- `LuaLogisticNetwork.get_contents()` called bare returns item counts for the
  entire network as an array of `{name, quality, count}`, where `quality` is a
  string prototype name. Requester-chest stock does not count; bare contents is
  exactly what bots can draw from.
- `LuaLogisticNetwork.available_construction_robots` — idle bots; busy bots
  self-exclude.
- `entity.order_upgrade{target={name=..., quality=...}, force=...}` supports
  same-name quality-only changes and returns a boolean (`false` = rejected, no
  error). `to_be_upgraded()`, `to_be_deconstructed()` are cheap entity reads.
- `"not-upgradable"` is the prototype flag gating the upgrade planner; candidacy
  is derived in `build_and_store_config` (has a placing item, not flagged) —
  keep that derivation, including `all_tracked_types`.
- Network refs/ids invalidate on merge/split. Never persist them. Enumerate
  networks fresh via `game.forces.player.logistic_networks` (a map of surface
  name → array of networks) each time the cursor needs a network.

Storage after this plan (all plain data, safe to reset at any time):

- `storage.config` — per-prototype `placing_item_name` map and
  `all_tracked_types` (unchanged).
- `storage.pass` — the resumable cursor: round-robin position, the in-progress
  network's work state, and `resume_tick` for the between-rounds delay.

Multiplayer constraint: all cross-tick state must live in `storage` (locals
would desync a joining player). Abandoning `storage.pass` must always be safe —
init and configuration changes reset it and the next pass re-derives everything
from the world. `LuaEntity` references are storable and may sit in the work
list across ticks; check `.valid` before each use.

## Suggested Approach

**The loop.** Replace `on_tick` with `script.on_nth_tick(interval, ...)` using a
small fixed interval (suggest 10 ticks). Each invocation performs up to
`entities-per-pass` iterations, where one iteration examines one entity (or pays
for one network-entry step). When every network has been visited, set
`storage.pass.resume_tick = game.tick + round-delay-seconds * 60` and idle until
then. The delay is the pickup window: it gives bots time to collect ordered
items so the next round's contents reads are close to accurate.

**Round-robin.** Only an integer cursor persists between visits. Re-enumerate
network slots fresh whenever a new network is needed; a mid-round merge/split at
worst skips or repeats a network for one round.

**Network entry** (single tick, live ref — never carry the ref forward):

1. `available_construction_robots` → this visit's order cap. Zero → skip network.
2. One bare `get_contents()` → supply snapshot:
   `supply[item_name][tier] = count`, keeping only rows whose quality is on the
   normal chain, minus `reserve-per-item`. (The old per-row candidate-index
   filter is gone; keep the snapshot small by dropping items that place no
   entity — invert `placing_item_name` once in config to get
   `item_places_entity`.)
3. Per stationary cell (`cell.mobile == false`, `construction_radius > 0`):
   `surface.find_entities_filtered` over the cell's construction-radius square
   with `force = "player"` and `type = storage.config.all_tracked_types`.
   Scanning per cell rather than per network keeps the burst bounded by one
   roboport's area. Cells should be processed up to one per iteration batch to
   spread the bursts.

   Duplicate entities across overlapping cells are fine: an entity
   encountered twice in one visit is harmless — once marked, later encounters
   take the demand-accounting path, so it can never be ordered twice or spend
   the bot cap twice. We are ok with slow traversal of the full network, and
   over accounting for provisioned items is actually good, so we avoid actual
   over provisioning.

Per entity (one iteration each, first-come-first-served in scan order):

- Invalid, wrong force, no `placing_item_name`, or quality not
  `is_candidate_tier` → skip.
- `to_be_deconstructed()` → skip.
- `to_be_upgraded()` → **demand accounting**: decrement
  `supply[item][target tier]` by 1 for its upgrade target
  (`get_upgrade_target()` returns prototype, quality) and skip. This covers our
  own past orders, player upgrade-planner marks, and other mods' orders — all
  demand is visible because we enumerate everything. No ledger needed.
- Otherwise, find the best tier above the entity's with `supply > 0`
  (highest first). If found: `order_upgrade` to it; on success decrement that
  supply count and the visit's bot cap. Bot cap at 0 → abandon the rest of this
  network, move on.

Supply is decremented in place, so "best available tier for item X" is just a
walk down the tiers — the snapshot is the cache; no separate caching layer.

**Ghost demand (forward-compat for plan-002):** if the scan is cheap to widen
now, also count unbuilt ghosts whose quality has stock as demand (decrement).
Optional here; plan-002 handles ghosts fully.

**Deletions:**

- `scripts/index.lua` and every call into it.
- In `gardener.lua`: ledger, `ledger_by_position`, cooldowns, expiry,
  `capture_restore`/restore, raises (`try_raise` — re-issuing at a higher
  target now happens naturally: a marked entity is skipped, but once rebuilt it
  becomes a fresh candidate), `adopt`, `subtract_outstanding`,
  `refresh_slice` plumbing.
- In `control.lua`: all build/destroy/robot-built/cancelled-upgrade/
  object-destroyed registrations; `rescan_world` and the init-command scan
  messaging (the `quality-gardener-init` command can stay as a plain
  storage/pass reset). Init must also nil out the removed storage keys
  (`candidates`, `ledger`, `ledger_by_position`, `cooldown`, `refresh`) so old
  saves migrate cleanly.

**Settings** (`settings.lua` + locale; project style: no prefixes, no
abbreviations, spell words out):

- Remove `entities-per-tick` and `order-timeout-minutes`.
- Add `entities-per-pass` (int, suggest default 50) — iterations per nth-tick
  invocation.
- Add `round-delay-seconds` (double, default 20, minimum 0) — wait after a full
  round before starting the next.
- Keep `reserve-per-item` and the two hidden-quality startup settings.

## Testing

There is no test suite and none should be added — `./validate.sh` (luacheck) is
the whole automated story per project convention. Validation is in-game.

## Validation

- `./validate.sh` passes.
- In-game (fresh save + a save from the previous version): with
  higher-quality machines in a storage chest, lower-quality placed machines in
  the same network get upgrade-marked, at most `available_construction_robots`
  orders per network per visit, and bots complete the swaps.
- A just-upgraded machine becomes a candidate for the next tier on a later
  round with no event plumbing involved.
- Marks (ours or player-made) visibly reduce what gets ordered next round
  (place 1 uncommon machine in storage, mark something for upgrade with the
  upgrade planner — the mod must not order a second upgrade against it).
- No mark is ever cancelled by the mod, including on setting changes and
  `quality-gardener-init`.
- Loading an old save (`on_configuration_changed`) leaves no stale storage keys
  and does not crash; pre-existing mod marks simply complete via bots.
- Entities marked for deconstruction are never upgrade-marked.

## Documentation

- `CLAUDE.md` — the design-invariants section describes the old architecture;
  rewrite it to match (world-only truth, no tracking, scan-based pass,
  no expiry/cooldown/restore, fresh bot count per visit).
- `README.md` — behavior notes that mention order timeout or cancel cooldown.
- `changelog.txt` — entry under a new version.
- `locale/` — entries for the new settings, removal of the old ones.
