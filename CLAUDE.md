# Quality Gardener

Factorio 2.1 mod: upgrades buildings and ghosts to higher-quality versions
when those versions are available in storage.

Architecture in short: no entity events; no per-entity state except two
ledgers; a budgeted round-robin scan pass reads each logistic network or
space platform fresh and orders upgrades on the spot.

`README.md` covers player-facing intent and behavior.

## Design invariants (read before you change core behavior)

The rules are here; rationale lives in `docs/decisions.md`.

### The world is the only source of truth

- Store nothing per-entity, except the two ledgers.
- A ledger records only facts the world cannot answer, so they never go
  stale:
  - Order ledger: a mark is ours, and when we placed it.
  - Platform wait ledger: when a starved target was first seen waiting.
- Each visit reads reality fresh (contents, roboport cells or the hub, the
  entities inside them) and issues orders directly.
- To recognize a marked entity, ask it: `to_be_upgraded()`.

### Every visible mark is demand

- Every mark — ours, a player's, another mod's — decrements the supply
  snapshot at its upgrade target. Then the entity is skipped.

### The order ledger is a cancellation license

- Membership in `storage.order_ledger` (keyed by unit number) records that
  a mark is ours and when we placed it. Everything else the mod does is
  ownership-blind and reads the world.
- Cancel a ledgered mark only when it has outlived `order-expiry-seconds`
  **and** its target quality is out of stock. A queued-but-stocked order is
  the bots' business.
- Absence means never cancelled: a player mark can be quality-retargeted
  but never cancelled.
- Losing the ledger is safe; orphaned marks simply never expire.
- The platform wait ledger (`storage.platform_wait_ledger`) is a clock
  table with no ownership meaning — since when has this target been
  waiting? The same between-rounds sweep cleans both ledgers.

### A space platform is its own network

- No logistic network, no bots: the hub auto-builds ghosts, upgrades, and
  module requests from its own inventory.
- Under `manage-space-platforms`, the pass visits each platform like a
  network. Supply is the hub inventory (`hub_main`, cargo bays included;
  `hub_trash` is items leaving — exclude it). Coverage is one whole-surface
  scan. Orders are uncapped: no bots to meter, so only-order-against-stock
  is the only bound.

### Two views of platform supply, never merged

- Order only against spendable stock: hub contents minus reserve. Never
  against an inbound or requested item — it is not yet available to build
  with.
- `order-expiry-seconds` is the queue-block escape hatch.

### Platform provisioning waits for deliveries

The three retargeting arms (ghosts, non-ledgered marks, module requests)
run these rules on platforms only, in order:

1. Target inbound (`targeted_items_deliver`): leave it alone.
2. Platform in transit (`space_location == nil`): act immediately.
3. A request possibly in play — any filter on the item (matching is
   deliberately coarse) or hub auto-request on: retarget only after
   `space-platform-delivery-wait-seconds` on the wait-ledger clock.
4. Nothing requested and auto-request off: act immediately.

- The clock starts the first time the target is seen starved, even when
  nothing is aboard to retarget to. It resets when the observed target
  stops matching the recorded one.
- A request only starts the clock, never vetoes; the timeout is the
  stale-request handling.
- Our own orders never wait: placed only against spendable stock, ledgered,
  expired normally.

### Network identity is transient; only snapshots span ticks

- `LuaLogisticNetwork` references and ids invalidate on any merge or split.
  Never store one across a tick boundary.
- At entry, read everything needed (bot count, supply, construction cell
  boxes) in that single tick. The rest of the visit runs from the
  plain-data snapshot, which can go stale but never invalid.
- Only the integer cursor persists between network visits.

### Pass state lives in `storage`; abandoning it is always safe

- Cross-tick state in locals would desync a multiplayer join. Keep the
  resumable pass as plain data in `storage.pass`.
- Init and configuration changes reset the pass; it re-derives from the
  world.
- `LuaEntity` references may sit in the work state (they are storable);
  check `.valid` before each use.

### Work is spread, never burst

- The pass runs every tick, spending up to `entities-per-tick` budget
  steps. Steps are uniform: network entry, entity examine, cell scan, or
  ledger check cost one each.
- At most one per-cell entity scan burst per invocation.
- After a full round, the pass rests `round-delay-seconds` while bots
  collect ordered items. The ledger sweep runs during the rest under the
  same budget, delaying the next round only if it outlasts the rest.

### Orders are capped by bot headroom

- Each network's per-visit order budget is `available_construction_robots`,
  read fresh at entry. Busy bots self-exclude, so that read is the whole
  cap; a stale count only delays marks to the next visit.
- Platforms are exempt: no bots, infinite budget; spendable stock alone
  bounds orders.

## Retired alternatives (do not reintroduce — rationale in `docs/decisions.md`)

- Per-entity state as a cache of the world: the candidate index and the old
  order ledger with cached positions, expiry machinery, and refresh slices
  (in git history and the reference mod). The current `storage.order_ledger`
  stores only mark ownership and the order tick — not this.
- Exclusion machinery: mod lists, surface filters, Factorissimo integration.
- Per-entity-type enable settings, or a hand-maintained type list
  (`build_and_store_config` derives candidacy from prototypes).
- Hidden-quality skip/sticky settings.
- PickerDollies/teleport-mod event integration.
- A "skip networks without candidate supply" early exit in the scan.
- A test suite. Luacheck via `./validate.sh` is the whole validation story.

## Engineering principles

- Do not abbreviate names (settings, locals, storage keys).
- No mod prefixes on setting names; `manage-` is a shared verb, not a
  prefix.
- Runtime toggles, all default on, snapshotted at visit entry:
  `manage-factory` (building and module upgrades), `manage-ghosts` (ghost
  retargets), `manage-upgrade-requests` (starved non-ledgered mark
  retargets), `manage-space-platforms` (platform visits entirely).
- A toggle gates only the acting arm of its behavior. Demand accounting
  always runs, so enabled behaviors never over-order against stock that a
  disabled behavior's marks or ghosts will consume.
- Ghost provisioning: exact quality stocked → leave it to the bots and
  count it as demand; otherwise retarget to the best stocked tier, even a
  lower one.
- Upgrade-request provisioning: a starved non-ledgered mark retargets to
  the best stocked tier of its *target* item (cross-prototype marks resolve
  through the mark's target, not the entity). The mark stays unledgered,
  and the original quality is not remembered.
- Module provisioning is quality-only: never change which module prototype,
  only its quality. Installed modules only ever upgrade; unfulfillable
  *requests* retarget in either direction. Built entities only — ghost
  module slots are out of scope.

## Validation & packaging

- `./validate.sh` runs luacheck. `./package.sh` validates, zips, and copies
  the mod into the local Factorio mods folder.
- This branch is the Factorio **2.1** release line; branch `2.0` is the
  parallel 2.0 line. Every behavior change ships as two portal releases
  with distinct version numbers, so weigh changes here against the 2.0
  branch. Its `package.sh` builds to `builds/` without installing.

## API notes

- Verified API facts and the in-game verification backlog live in
  `docs/api-notes.md`. Consult it before touching an API call; do not
  re-derive a fact recorded there. Move newly verified items from its
  backlog into its verified list.

## Localization

- Edit only `locale/en/locale.cfg` by hand. Other languages are managed
  separately.
