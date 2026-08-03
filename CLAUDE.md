# Quality Gardener

Factorio 2.1 mod: the mod upgrades buildings and ghosts in a factory to
higher-quality versions when those versions are available in storage.

The architecture, in short:

- The mod uses no entity events.
- The mod keeps no per-entity state. The two ledgers are the only exception.
- A scan pass visits networks round-robin, on a work budget.
- Each visit reads its logistic network or space platform fresh and orders
  upgrades on the spot.

`README.md` covers player-facing intent and behavior.

## Design invariants (read before you change core behavior)

### The world is the only source of truth

- Store nothing per-entity, except the two ledgers.
- Each ledger records only facts the world cannot answer. Such facts can
  never go stale.
  - The order ledger records that a mark is ours, and when we placed it.
  - The platform wait ledger records when a starved target was first seen
    waiting.
- Each visit reads reality fresh: contents, roboport cells or the hub, and
  the entities inside them. It issues orders directly.
- To recognize a marked entity, ask the entity itself: `to_be_upgraded()`.

### Every visible mark is demand

- A mark can be ours from a past round, a player's upgrade-planner mark, or
  another mod's mark.
- Every visible mark decrements the supply snapshot at its upgrade target.
- After the demand count, skip the marked entity.

### The order ledger is a cancellation license

- Membership in `storage.order_ledger` (keyed by unit number) records two
  facts: the mark is ours, and when we placed it.
- Everything else the mod does is ownership-blind and reads the world.
- Absence from the ledger means never cancelled. A player mark can be
  quality-retargeted, but it stays uncancellable forever.
- Cancel a ledgered mark only when both conditions are true:
  - The mark has outlived `order-expiry-seconds`.
  - Its target quality is out of stock.
- Do not cancel an order that is queued but stocked. That order is the
  bots' business.
- Loss of the ledger is safe. Orphaned marks simply never expire.
- The platform wait ledger (`storage.platform_wait_ledger`) is not a second
  ownership registry:
  - It is a clock table with no ownership meaning.
  - It answers only one question: since when has this target been waiting?
  - The same between-rounds sweep mechanism cleans it.

### A space platform is its own network

- A platform has no logistic network and no bots. The hub auto-builds
  ghosts, upgrades, and module requests from its own inventory.
- Under `manage-space-platforms`, the pass visits each platform like a
  network:
  - Supply is the hub inventory (`hub_main`). Cargo bays extend it.
    `hub_trash` is items leaving the platform; exclude it.
  - Coverage is one whole-surface scan. Platforms are small and bounded.
  - Orders are uncapped. There are no bots to meter, so
    only-order-against-stock is the only bound.

### Two views of platform supply, deliberately not merged

- Place orders only against spendable stock: hub contents, reserve
  subtracted.
- Never order against an inbound or requested item. That item is not yet
  available to build with.
- `order-expiry-seconds` is the queue-block escape hatch.

### Platform provisioning waits for deliveries

- Items can be on order from the planet below or another platform. A naive
  retarget would orphan the delivery the player is waiting on.
- The three retargeting arms (ghosts, non-ledgered marks, module requests)
  run the wait rules on platforms, in this order:
  1. The target is inbound (`targeted_items_deliver`): leave it alone.
  2. The platform is in transit (`space_location == nil`): act immediately.
     Deliveries are impossible, and a downgrade now beats a hole in the
     defenses.
  3. A request is possibly in play: retarget only after
     `space-platform-delivery-wait-seconds` on the wait-ledger clock.
     "Possibly in play" means any filter on the item (matching is
     deliberately coarse) or the hub's auto-request on.
  4. Nothing is requested and auto-request is off: act immediately.
- The clock starts the first time the target is seen starved. It starts even
  when nothing is aboard to retarget to, so stock that arrives after the
  wait is acted on at once.
- The clock resets when the observed target stops matching the recorded one.
- A request only starts the clock. It never vetoes retargeting forever. The
  timeout is the stale-request handling.
- Our own orders never wait. We place them only against spendable stock,
  ledger them, and they expire normally.
- These rules do not touch planet networks.

### Network identity is transient; only snapshots span ticks

- `LuaLogisticNetwork` references and ids become invalid on any merge or
  split. Never store one across a tick boundary.
- At network entry, read everything needed from the live reference in that
  single tick: bot count, supply, construction cell boxes.
- The rest of the visit runs from the plain-data snapshot. A snapshot can
  only go stale, never become invalid.
- Only the integer cursor persists between network visits.

### Pass state lives in `storage`; abandoning it is always safe

- Cross-tick state in locals would desync a multiplayer join. Keep the
  resumable pass as plain data in `storage.pass`.
- Init and configuration changes reset the pass. A restarted pass just
  re-derives from the world.
- `LuaEntity` references may sit in the work state across ticks (they are
  storable). Check `.valid` before each use.

### Work is spread, never burst

- The pass runs every tick and spends up to `entities-per-tick` budget steps
  per invocation.
- These operations cost one step each: enter a network, examine one entity,
  scan one cell, check one ledger entry. Steps are uniform, deliberately
  unweighted.
- Each invocation runs at most one per-cell entity scan burst.
- After a full round of the networks, the pass rests for
  `round-delay-seconds`. This is the pickup window: bots collect ordered
  items, so the next round's contents reads stay close to accurate.
- The ledger sweep runs during the rest, under the same budget. It delays
  the next round only when the ledger outlasts the delay.

### Orders are capped by bot headroom

- Each network's per-visit order budget is `available_construction_robots`,
  read fresh at entry.
- Busy bots self-exclude, including ones flying our orders. So the fresh
  read is the whole cap.
- A stale count only delays marks until the next visit.
- Platforms are exempt: no bots, no cap. The budget is infinite, and
  spendable stock alone bounds orders there.

## Retired alternatives (do not reintroduce — rationale in `docs/decisions.md`)

- Per-entity state as a cache of the world: the candidate index and the old
  order ledger with cached positions, expiry machinery, and refresh slices
  (still in git history and the reference mod). The current
  `storage.order_ledger` is not this — it stores only mark ownership and the
  order tick, facts the world cannot answer.
- Exclusion machinery: mod lists, surface filters, Factorissimo integration.
- Per-entity-type enable settings, or a hand-maintained type list
  (`build_and_store_config` derives candidacy from prototypes).
- Hidden-quality skip/sticky settings.
- PickerDollies/teleport-mod event integration.
- A "skip networks without candidate supply" early exit in the scan.
- A test suite. Luacheck via `./validate.sh` is the whole validation story.

## Engineering principles

- Do not abbreviate names (settings, locals, storage keys). Spell words out.
- Do not put mod prefixes on setting names. `manage-` is a shared verb, not
  a prefix.
- Three behaviors sit behind runtime `manage-*` toggles, all default on,
  snapshotted at visit entry:
  - `manage-factory`: building and module upgrades.
  - `manage-ghosts`: ghost retargets.
  - `manage-upgrade-requests`: retargets of starved non-ledgered marks.
- A toggle gates only the acting arm of its behavior. Demand accounting
  always runs, so enabled behaviors never over-order against stock that a
  disabled behavior's marks or ghosts will consume.
- A fourth toggle, `manage-space-platforms` (default on), gates platform
  visits entirely. Platforms are disjoint from planet networks, so skipping
  them has no cross-contamination effect on demand accounting.
- Ghost provisioning: when a ghost's exact quality is stocked, leave it to
  the bots and count it as demand. Otherwise, retarget it to the best
  stocked tier, even a lower one.
- Upgrade-request provisioning: when a non-ledgered mark's (a player's or
  another mod's) target quality is out of stock, retarget it to the best
  stocked tier of its *target* item. Cross-prototype marks resolve through
  the mark's target, not the entity. The mark stays unledgered — still the
  player's, never expired — and the original quality is not remembered.
- Module provisioning is quality-only. Never change which module prototype
  sits in or is requested for a slot; change only its quality. Installed
  modules are only ever upgraded. Unfulfillable *requests* retarget in
  either direction. Built entities only: ghost module slots are out of
  scope.

## Validation & packaging

- `./validate.sh` runs luacheck.
- `./package.sh` validates, zips, and copies the mod into the local Factorio
  mods folder.
- This branch is the Factorio **2.1** release line. Branch `2.0` is the
  parallel 2.0 line.
- A mod declares exactly one major version, so every behavior change ships
  as two portal releases with distinct version numbers. Weigh changes here
  against the 2.0 branch. Its `package.sh` builds to `builds/` without
  installing.

## API notes

- Verified API facts and the in-game verification backlog live in
  `docs/api-notes.md`.
- Consult it before you touch an API call. Do not re-derive a fact recorded
  there.
- Move newly verified items from its backlog into its verified list.

## Localization

- Edit only `locale/en/locale.cfg` by hand. Other languages are managed
  separately.
