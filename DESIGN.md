# Quality Gardener — Design

Factorio 2.1 mod. When higher-quality versions of placed buildings sit in a logistic
network's storage, mark the lower-quality placed buildings in that network for upgrade
so construction bots swap them out. Like a gardener, it steadily replaces the worst
plants with the best cuttings on hand.

## Core insight: the world is the source of truth

An upgrade order lives on the entity itself (`to_be_upgraded()`, `get_upgrade_target()`
— which returns both the target prototype *and* target quality). That means our
"orders outstanding" ledger is always **derivable from world state** and can never
drift irrecoverably: at worst we rescan marks and rebuild. The mod keeps a ledger in
`storage` for performance and for timestamps, but when in doubt the entity marks win.

This resolves the central problem the mod faces: any event we miss (player looting a
chest, a chest exploding, a bot dying mid-flight) only makes our cached numbers stale
until the next scan, never wrong forever.

## The accounting model

Supply is read with **network-level calls only** — `network.get_contents(member?)` /
`network.get_item_count(item?, member?)` — never by iterating chests. One
`get_contents("storage")` call per network yields every `{name, quality, count}` in
storage chests; there is no per-chest work anywhere in the design.

For each `(network, item_name, quality)` group:

```
supply      = network.get_item_count({name=item, quality=q}, "storage")
outstanding = our pending orders for (item, q) in this network — straight from the ledger
available   = supply - outstanding - reserve_setting
```

Mark at most `available` new entities per scan.

**What we deliberately don't track:** player upgrade-planner marks, blueprint-ghost
demand, and other mods' construction orders all consume the same supply. They are
treated uniformly as *invisible demand*: they may starve our orders, and the timeout
cleans that up. (Tracking player marks via `on_marked_for_upgrade` was considered
and cut — it special-cases one of several equivalent demand sources at the cost of
an event handler, a reentrancy guard, and an ours-vs-theirs ledger distinction.
Without it, "ours" is simply "in the ledger.")

**Why `supply - outstanding` is deliberately conservative:** `get_item_count` counts
items physically in chests. An outstanding order whose bot hasn't picked up yet is
still counted in supply, so subtracting it is exactly right. Once a bot is carrying
the item, it's gone from supply *and* still subtracted as an order — double-counted
for the seconds the bot is in flight, then self-corrects on delivery. Undercounting
briefly is harmless; the marking path therefore needs **no in-flight tracking at all**.

## Order expiry: timeout, not reconciliation

Anything can yank supply after we've marked: a player grabs items from the chest, the
chest is destroyed, a requester chest siphons the items, a blueprint's ghosts consume
them, a bot carrying the item is shot down. Factorio's native behavior is that starved
upgrade orders sit pending forever and spam `no_material_for_construction` alerts.
There are **no events** for network content changes, so detection must be poll-based.

Rather than computing per-group supply deficits and deciding *which* orders are
starved, every order simply carries its `tick_ordered` and **expires after a
configurable timeout** (default ~3 min): during each scan, cancel any of our orders
older than the timeout via `entity.cancel_upgrade(force)`.

This is sufficient because of how it composes with re-marking:

- **Order was starved** (supply vanished): it times out and is cancelled. Next scan
  sees `supply = 0` → no re-mark. Alerts stop. Done.
- **Order was fine, bots just slow** (big base, busy fleet): it times out and is
  cancelled — but the next scan sees supply still present and immediately re-marks
  with a fresh timer. Net effect: orders persist exactly as long as the supply
  justifies them, which is the same outcome the deficit math would have produced,
  with none of its bookkeeping.
- **Bot mid-flight at expiry**: cancellation is safe — the bot returns the item to
  storage — just a wasted trip. The timeout length is a wastefulness knob, not a
  correctness one; default it comfortably above worst-case bot round-trips.

Rules: only expire **our own** orders (ledger membership), never player-issued marks;
a "never expire" setting preserves vanilla pending-order behavior for players who
prefer the alerts.

## Order lifecycle tracking

On every `order_upgrade` we ledger the entity and call
`script.register_on_object_destroyed(entity)`. Terminal transitions:

| How the order ends | Signal | Handling |
|---|---|---|
| Bot completes upgrade | `on_object_destroyed` for old entity (`useful_id` = old unit_number); `on_robot_built_entity` fires for the NEW entity (new unit_number, no link to old) | Drop ledger entry via `useful_id`; correlate new entity by position/name for notifications and to index it as a future candidate |
| Player cancels (planner or GUI) | `on_cancelled_upgrade` (`entity`, `target`, `quality`, `player_index?`) | Drop ledger entry; optionally blocklist the entity briefly so we don't instantly re-mark against the player's intent |
| We cancel (timeout expiry) | our own `cancel_upgrade` call also raises `on_cancelled_upgrade` | Handler must be idempotent — entry already removed, no-op |
| Entity dies / is mined while marked | `on_entity_died` / `*_mined_entity` / `on_object_destroyed`. **`on_cancelled_upgrade` does NOT fire** | Drop ledger entry; `on_object_destroyed` is the universal catch-all |

Key API facts (verified against 2.x docs + the quality-control reference mod):

- `order_upgrade{target={name=<same name>, quality=<higher>}, force=...}` — same-name
  quality-only upgrades are fully supported; `force` required. Returns bool. (We do
  not subscribe to `on_marked_for_upgrade` at all — see "What we deliberately don't
  track.")
- Bot upgrades auto-transfer inventory, modules, and fuel. The displaced lower-quality
  building item is returned to network storage. Runtime state that does NOT survive
  (restore on `on_robot_built_entity`): accumulator `energy`, lamp `always_on`,
  rocket silo `send_to_orbit_automatically`.
- `on_object_destroyed` registrations persist through save/load.

## Division of labor: events index, cycles match

Events and scans have strictly separated jobs, and it's the separation that gives
every building unlimited upgrade chances across its life:

- **Events maintain the candidate index** — who exists, at what quality, where.
  They never trigger upgrade attempts. An entity entering the index isn't queued
  for anything; it's registered.
- **Cycles do all matching** — each cycle is a *stateless* function of (current
  storage contents, current candidate population). Nothing is consumed or
  remembered by being considered: a building that found no supply this cycle is
  simply still in the index next cycle, and the moment better stock lands in
  storage, the next cycle matches it. No per-entity cooldowns, no "already
  processed" flags.
- **The loop closes through the index.** When an upgrade completes,
  `on_robot_built_entity` re-indexes the new entity at its new quality — where it
  immediately becomes a candidate for the *next* tier. A building can climb
  normal → rare → legendary across months of play purely by sitting in the index
  while storage contents evolve around it.

The only per-entity state anywhere is a transient ledger entry while an order is
pending (to count it as outstanding and to expire it).

## Scan loop

`on_nth_tick` (configurable), budgeted batches like the reference mod (small batches,
frequent ticks — never large spikes):

1. Iterate `force.logistic_networks` (dictionary keyed by surface name), skipping
   excluded surfaces (blueprint sandboxes `bpsb-*`, Factorissimo interiors via remote,
   space platforms by default).
2. Per network, `get_contents("storage")` → filter to items that place tracked entity
   types, quality above normal. Most networks have zero such items → early exit; this
   keeps the common case near-free.
3. For each hit, look up candidate entities from the **candidate index**
   (`storage.index[surface][item_name][quality_level] → set of unit_numbers`),
   maintained by build/destroy events, considering only qualities below the item's.
4. Filter candidates: `entity.valid`, not `to_be_upgraded()`, not
   `to_be_deconstructed()`, not on the fast_replace exclusion list, and within this
   network's **construction** coverage — construction radius, not logistic radius —
   tested in pure Lua against per-cycle AABBs (see "Performance model" §4).
5. Compute `available`; mark up to that many, **worst quality first** (gardener
   priority: biggest improvement per item).
6. Expire our orders older than the timeout (see "Order expiry").

### Network identity is transient

`LuaLogisticNetwork` objects and `network_id` invalidate on any merge/split (building
or removing a roboport), with no lookup-by-id API. Therefore: never store network
references or ids across ticks as truth. Each scan re-derives networks fresh; ledger
entries are keyed by entity unit_number, and their (network, item, quality) grouping is
recomputed per scan from the entity's position. Consequences handled for free:

- **Merge**: two ledgers' orders group into one bigger pool with combined supply. Fine.
- **Split**: an entity may land in the half without the items → order goes
  unfulfilled → times out. Fine.
- **Roboport destroyed, network gone**: entity in no network → order goes
  unfulfilled → times out. Fine.
- **Overlapping construction areas** (entity reachable by two networks): count it
  against the network whose stock justified the mark; if either network delivers,
  the order completes — any misattribution just times out.

## Performance model & data structures

Scale assumptions: thousands of upgrade candidates per network; quality mods can add
up to ~250 tiers, so entities sit anywhere on a long ladder. Governing principles:
**API calls must scale with matches made, never with total entity count**, and
**every quality-indexed structure is sparse** — 250 possible tiers but only a
handful ever occupied; never allocate dense per-tier arrays.

### 1. Matching is 1-D greedy per item name, not matrix math

Because assignment is totally ordered by quality (any higher-quality item can serve
any lower-quality building, and nothing else), supply-vs-demand never needs a 2-D
structure. Per `(surface, item_name)`:

- **Supply vector**: sparse map `quality_level → count`, from one
  `get_contents("storage")` call, minus the outstanding-order vector (a sparse
  subtraction) and the reserve setting.
- **Demand vector**: sparse map `quality_level → candidate set`, read straight from
  the candidate index below.
- **Match**: two-pointer greedy — walk supply from highest quality down, assign to
  candidates from lowest quality up (gardener priority), decrementing both. Cost is
  O(occupied tiers + marks issued), independent of ladder length.

### 2. The candidate index is event-maintained, never scanned

`storage.candidates[surface_index][item_name][quality_level] → unit_number → {position}`

Built once at init, then maintained purely by build/destroy events and
`on_object_destroyed` — no polling. **Position is cached at insert time** so scans
touch zero entity properties while filtering. Count totals per quality level are
kept alongside so the greedy match can size its work before touching any candidate.

**Cached positions are a filter hint, not truth.** Mods like Even Pickier Dollies
teleport entities by writing `position` directly, without base-game events. The
design tolerates stale positions in layers:

- *At mark time we touch the entity anyway* (validity, `to_be_upgraded()`), so
  re-read `entity.position` there and refresh the cache — the authoritative check
  costs one extra field read on the handful of entities actually being marked. A
  stale position that let a truly-out-of-coverage entity through just produces an
  order that times out.
- *The failure that needs active repair* is the inverse — a stale position wrongly
  filtering an in-coverage entity out, forever. Fix: refresh a small rotating slice
  of the index each cycle (amortized ~free), bounding staleness.

These two layers are sufficient, so no mover event is subscribed (a PickerDollies
`dolly_moved_entity_id` integration existed initially and was removed July 2026 —
it only tightened cache freshness the refresh slice already bounds).

### 3. Supply-centric iteration (why not entity-centric)

Start each cycle from `get_contents` and fan out into the index — not the reverse
(walking entities and asking "is there supply for me?"). The supply side is the
sparse side: most networks stock zero upgrade-grade building items and exit after a
single API call, and a walk over thousands of entities would pay its cost mostly on
misses. Entity-centric round-robin (the reference mod's shape) suits per-entity
accumulating state; this mod has none — all state lives on the supply side.

### 4. Coverage is Lua geometry, not API calls

The naive coverage test (`find_logistic_networks_by_construction_area` or
`cell.is_in_construction_range` per candidate) is an API call per entity — the
biggest hidden cost in the design. Instead: construction areas are squares, so once
per network per cycle read each cell's owner position and `construction_radius`
(API cost ∝ roboport count, not entity count), build a list of AABBs, and test
cached candidate positions against them in pure Lua. Skip mobile cells
(spidertron/personal roboports — their networks have no storage chests and exit at
the supply gate anyway). If a megabase network's roboport list makes linear AABB
scans hot, bucket the AABBs into a coarse spatial grid — but the supply gate usually
keeps match volumes far too small to need it.

### 5. Snapshot once per cycle, decrement locally

One `get_contents("storage")` per network per cycle. Every mark we issue decrements
the local snapshot (and appends to the ledger); the network is never re-queried
mid-cycle. The snapshot going slightly stale during a cycle is the same conservative
staleness the accounting model already tolerates everywhere else.

### 6. Budget the mutations

`order_upgrade` / `cancel_upgrade` are API calls too: cap marks+cancels per tick
(reference-mod cursor pattern) so a player dumping 500 legendary machines into
storage schedules upgrades over a few seconds instead of spiking one tick.

**Per-cycle API budget:** ≈ #networks `get_contents` calls + #roboports cell-field
reads + #marks `order_upgrade` calls. Nothing scales with total entity count; Lua
work scales with candidates *whose item names actually have supply* — the sparse
gate doing its job.

## Target selection

- **Direct-to-best** (default): if storage has uncommon and legendary, mark the normal
  building straight to legendary — one bot trip, no intermediate items. Optional
  single-step mode walks `quality.next` one tier at a time.
- **Upgrade upgrades**: if one of our orders is pending at uncommon and a rare item
  appears, a later scan re-issues `order_upgrade` at the higher target (re-marking an
  already-marked entity is allowed). Always on, no setting; applies only to orders in
  our ledger, never player marks.
- Quality chains are walked via `quality.next`, never hardcoded; hidden qualities
  respected per the skip/sticky pattern.
- Item↔entity mapping via `entity.prototype.items_to_place_this[1].name` (nil-checked);
  entities with no placing item are never candidates.
- The **cascade** is free: upgrading normal→rare returns a normal item to storage,
  which the next scan may use nowhere (it's the floor) — but upgrading uncommon→rare
  returns an uncommon item that can then lift a normal building. The gardener ripples
  quality downward through the base with no extra logic.

## Edge-case catalog

### Supply-side
| # | Case | Handling |
|---|---|---|
| S1 | Player withdraws items from storage chest | No event exists; starved order times out, and supply is re-checked before any re-mark |
| S2 | Storage chest destroyed/mined with quality items inside | Same as S1 (supply drop is indistinguishable and treated identically) |
| S3 | Bot carrying item is destroyed (`on_worker_robot_expired` / shot down) | Item lost; order times out |
| S4 | Requester/buffer chests or player logistic requests siphon quality items | Timeout; also why default source is storage chests only |
| S5 | Blueprint ghosts / player construction consume the same items | Invisible competing demand; timeout |
| S6 | Item picked up by bot → supply count drops while order still open | Deliberate double-count; conservative undercount, self-corrects on delivery |
| S7 | Player wants a float of spares for new construction | `reserve` setting: never drain a group below N |
| S8 | Cancelled order's bot returns item to storage | Supply rises; next scan re-marks. Harmless churn |
| S9 | Displaced lower-quality items accumulate in storage | Working as intended (recyclable / cascade fuel); not the mod's problem |

### Order lifecycle
| # | Case | Handling |
|---|---|---|
| O1 | Order fulfilled | `on_object_destroyed(useful_id)` drops entry; `on_robot_built_entity` correlates new entity by position |
| O2 | Player cancels our mark | `on_cancelled_upgrade` → drop entry + short re-mark cooldown (respect player intent) |
| O3 | Entity dies/mined while marked | `on_object_destroyed` catch-all (`on_cancelled_upgrade` does NOT fire — verified) |
| O4 | Player marks entities themselves (upgrade planner) | Untracked invisible demand, same as S5; never cancelled/retargeted by us (not in ledger). Their entities are skipped as candidates via `to_be_upgraded()` |
| O5 | Our own `cancel_upgrade` raises `on_cancelled_upgrade` | Idempotent handler — entry already removed, no-op |
| O6 | Another mod destroys/replaces entity inside our call stack | Re-check `entity.valid` after every mutating call (skill rule) |
| O7 | No construction bots in network / all busy | Orders pend, time out, and re-mark each cycle while supply persists — self-throttling with no special case |
| O8 | Entity already marked for deconstruction | Skipped as candidate |
| O9 | Mod disabled/removed then re-added; or on_configuration_changed | Rebuild ledger by scanning all tracked entities for `to_be_upgraded()` + same-name-higher-quality target; adopt matching marks (world is source of truth). This adopts indistinguishable player marks too — acceptable in a recovery path: adopted marks with supply behind them just complete or re-mark; starved ones get cleaned up |

### Network topology
| # | Case | Handling |
|---|---|---|
| N1 | Networks merge/split; roboport built/removed | Never cache network refs/ids; re-derive per scan (see "Network identity is transient") |
| N2 | Entity in construction range but outside logistic range | Correct and intended: coverage test is `is_in_construction_range` |
| N3 | Entity covered by two networks | Counted against one; either may fulfill; misattribution times out |
| N4 | Multiple surfaces / space platforms / Factorissimo / bpsb sandboxes | Per-surface iteration + exclusion cache; platforms default-excluded (no storage chests; hub semantics differ) |
| N5 | Multiplayer forces | All state and scans are per-force; default player force only |

### Selection & compat
| # | Case | Handling |
|---|---|---|
| C1 | Entity name ≠ item name / no placing item | `items_to_place_this` with nil check |
| C2 | fast_replace-broken entities (ammo-loader, miniloader-redux, …) | Reuse reference mod's exclusion list; never mark them |
| C3 | Modules keep their quality after upgrade | Native transfer keeps them; optional later feature could garden modules too (v2) |
| C4 | Lamp/accumulator/silo runtime state lost on swap | Restore on completion (known-state capture list) |
| C5 | Hidden/shiny qualities | Walk `quality.next` with skip/sticky settings |
| C6 | Infrastructure entities (poles, lamps, combinators) | Always tracked like everything else — no per-category settings (July 2026 decision) |
| C7 | Entity teleported without events (Even Pickier Dollies etc.) | Position cache is a hint: authoritative re-read at mark time, rotating refresh slice |

## Settings sketch

- Scan interval (runtime-global); batch size per tick
- Source chests: storage only (default) / + passive providers / + buffers
- Reserve count — keep at least N of any item-quality in storage (single global int,
  default 0)
- Direct-to-best vs single-step targeting (default direct)
- Order timeout before auto-cancel (default ~3 min); "never expire" option for
  players who prefer vanilla pending-order alerts
- Notifications (map pings / aggregate console, per reference mod patterns)

## Future feature: ghost quality retargeting

Planned v2: when a player stamps a blueprint whose ghosts request qualities the
network doesn't have, retarget each ghost to the **best available quality for that
building — higher or lower than requested** — so blueprints always get built with
what's on hand instead of stalling.

The architecture accommodates this now via three generalizations, none of which
change v1 behavior:

1. **The ledger is a *demand* ledger, not an upgrade ledger.** Each entry carries a
   `kind` field — `"upgrade"` (v1) or `"ghost-retarget"` (v2). Both kinds count as
   `outstanding` in the accounting model, since a ghost consumes an `(item, quality)`
   from the network on revival exactly like an upgrade order does. Building the
   ledger this way from day one means v2 adds a kind, not a parallel system.
2. **The candidate index has room for ghosts.** The index keyed by
   `surface → item_name → quality` gets a parallel ghost partition (entity-ghosts
   arrive through the same build events with type `"entity-ghost"` and expose
   `ghost_name`/`quality`). v1 simply doesn't populate it.
3. **Target selection is a policy function per kind**, not inline logic: placed
   entities only ever upgrade (never downgrade a player's real building); ghosts take
   best-available in either direction, and later scans re-raise a downgraded ghost's
   target if better supply arrives — same loop, different policy.

Asymmetries to respect in v2: a retargeted ghost isn't *our* order to expire (the
ghost's demand is native and persists regardless), so timeout logic applies only to
`kind = "upgrade"`; and player intent is preserved by remembering the originally
requested quality (likely via ghost `tags`) so we can restore targets upward as
supply improves rather than ratcheting blueprints down permanently.

## Open questions to validate in-game (before building on them)

1. **Bot source priority** — confirm construction bots pull upgrade items from storage
   chests (expected: storage, passive/active providers, and buffers all serve
   construction; requesters and roboport material slots do not).
2. **`get_item_count(..., "storage")` member semantics** — verify "storage" means
   storage chests specifically, and how buffer chests are counted, so the
   source-chest setting maps cleanly onto supply math.
   *Resolved (v0.1.0, checked against 2.x API docs):* the `member` parameter accepts
   only `"storage"` or `"providers"` — there is no buffer-chest member. The
   source-chest setting therefore offers exactly two values: storage only (default)
   and storage + providers; requester/buffer contents are never counted as supply.
3. **Ghost retargeting mechanics (v2)** — whether `order_upgrade` works on an
   entity-ghost for quality-only changes (including downgrades), or whether the ghost
   must be destroyed and re-created with `surface.create_entity{name="entity-ghost",
   inner_name=..., quality=...}` preserving tags/wiring; also whether ghost `tags`
   survive that round-trip for remembering the originally requested quality.
