# Quality Gardener

Factorio 2.1 mod: when higher-quality versions of placed buildings sit in a logistic
network, lower-quality placed buildings in that network are marked for upgrade so
construction bots swap them out.

The architecture in one line: *no entity events and, except for the order
ledger, no per-entity state — a round-robin, budgeted scan pass reads each
logistic network fresh and orders upgrades on the spot.* `README.md` covers
player-facing intent and behavior.

## Design invariants (read before changing core behavior)

- **The world is the only source of truth.** Nothing per-entity is stored except
  the order ledger, which records only the two facts the world cannot answer:
  that a mark is ours, and when we placed it — facts that can never go stale.
  Each network visit reads reality fresh (contents, roboport cells, the entities
  inside them) and issues orders directly; marked entities are recognized by
  asking the entity itself (`to_be_upgraded()`).
- **Every visible mark is demand.** A marked entity — ours from a past round, a
  player's upgrade-planner mark, or another mod's — decrements the supply snapshot
  at its upgrade target and is otherwise skipped.
- **The order ledger is a cancellation license.** Membership in
  `storage.order_ledger` (keyed by unit number) records that a mark is ours
  and when we placed it; cancellation and expiry require membership.
  Everything else the mod does to marks — demand accounting, quality
  retargeting under `manage-upgrade-requests` (quality only — the chosen
  target prototype is sacred) — is ownership-blind and reads the world.
  Absence means *never cancelled*, not *never touched*: player marks can be
  quality-retargeted but stay uncancellable forever. A ledgered mark is
  cancelled only when it has outlived `order-expiry-seconds` *and* its target
  quality is out of stock — a queued-but-stocked order is the bots' business,
  and an entity re-marked to a different target is dropped from the ledger on
  sight. Losing the ledger is safe: orphaned marks simply never expire. Still
  accepted, deliberately: no cancel cooldown and no runtime-state restore; see
  the decision log.
- **Network identity is transient; only snapshots span ticks.** `LuaLogisticNetwork`
  refs and ids invalidate on any merge/split — never store one across a tick
  boundary. Entering a network reads everything needed (bot count, supply,
  construction cell boxes) from the live ref in that single tick; the rest of the
  visit runs from the plain-data snapshot, which can only go stale, never invalid.
  Only the integer cursor persists between network visits.
- **Pass state lives in `storage`, and abandoning it is always safe.** Cross-tick
  state in locals would desync a multiplayer join, so the resumable pass is plain
  data in `storage.pass`. Init and configuration changes reset it; a restarted pass
  just re-derives from the world. `LuaEntity` references may sit in the work state
  across ticks (they are storable); check `.valid` before each use.
- **Work is spread, never burst.** The pass runs every tick and spends up to
  `entities-per-tick` budget steps per invocation — entering a network, examining
  one entity, scanning one cell, or checking one ledger entry each cost one step
  (uniform, deliberately unweighted) — with at most one per-cell entity scan
  burst per invocation. After a full round of the networks it rests for
  `round-delay-seconds` (the pickup window: bots collect ordered items so the
  next round's contents reads are close to accurate); the ledger sweep runs
  during the rest under the same budget, delaying the next round only when the
  ledger outlasts the delay.
- **Orders are capped by bot headroom.** Each network gets at most
  `available_construction_robots` orders per visit, read fresh at entry — busy bots
  (including ones flying our orders) self-exclude, so the fresh read is the whole
  cap. A stale count only delays marks until the next visit.

## Retired alternatives (don't reintroduce — rationale in `docs/decisions.md`)

- Per-entity state as a cache of the world: the candidate index and the old order
  ledger with cached positions, expiry machinery, and refresh slices (still in git
  history and the reference mod). The current `storage.order_ledger` is not this —
  it stores only mark ownership and the order tick, facts the world cannot answer.
- Exclusion machinery: mod lists, surface filters, Factorissimo integration.
- Per-entity-type enable settings or a hand-maintained type list (candidacy is
  derived from prototypes in `build_and_store_config`).
- Hidden-quality skip/sticky settings.
- PickerDollies/teleport-mod event integration.
- A "skip networks without candidate supply" early exit in the scan.
- A test suite — luacheck via `./validate.sh` is the whole validation story.

## Engineering principles

- Avoid abbreviations in names (settings, locals, storage keys); spell words out.
- No mod prefixes on setting names (`manage-` is a shared verb, not a prefix).
- The three behaviors sit behind runtime `manage-*` toggles (`manage-factory` —
  building and module upgrades, `manage-ghosts`, `manage-upgrade-requests`), all
  default on, snapshotted at network entry. A toggle gates only the acting arm of
  its behavior; demand accounting always runs, so enabled behaviors never
  over-order against stock a disabled one's marks or ghosts will consume.
- Ghost provisioning: a ghost whose exact quality is stocked is left to
  the bots (counted as demand); otherwise it is retargeted to the best stocked tier,
  even a lower one.
- Upgrade-request provisioning: a non-ledgered mark (a player's or another mod's)
  whose target quality is out of stock is retargeted to the best stocked tier of
  its *target* item — cross-prototype marks resolve through the mark's target, not
  the entity. The mark stays unledgered (still the player's, never expired) and the
  original quality is not remembered.
- Module provisioning is quality-only: never change which module
  prototype sits in or is requested for a slot, only its quality. Installed modules
  are only ever upgraded; unfulfillable *requests* retarget in either direction.
  Built entities only — ghost module slots are out of scope.

## Validation & packaging

`./validate.sh` runs luacheck. `./package.sh` validates, zips, and copies the mod
into the local Factorio mods folder.

This branch is the Factorio **2.1** release line; branch `2.0` is the parallel 2.0
line. A mod declares exactly one major version, so every behavior change ships as
two portal releases with distinct version numbers — weigh changes here against the
2.0 branch, and note its `package.sh` builds to `builds/` without installing.

## Verified API facts (don't re-derive)

- `LuaLogisticNetwork.get_contents(member?)` — `member` is optional (`"storage"` or
  `"providers"`); when omitted, returns item counts for the **entire network**. We
  always call it bare. Returns an array of `{name, quality, count}` where `quality`
  is a **string** prototype name.
- `order_upgrade{target={name=..., quality=...}, force=...}` supports same-name
  quality-only upgrades; `get_upgrade_target()` returns (prototype, quality).
- `LuaEntity.cancel_upgrade(force, player?)` returns a boolean — true when a
  pending upgrade was cancelled.
- `LuaLogisticNetwork.available_construction_robots` — read-only uint32, "number of
  construction robots available for a job" (idle bots; busy ones self-exclude).
- `"not-upgradable"` is an `EntityPrototypeFlag` ("can't be selected by the upgrade
  planner"), testable via `LuaEntityPrototype.has_flag`; it is the only documented
  planner gate. `order_upgrade` returns a boolean — rejection is signalled by
  returning `false`, not by erroring.
- Requester-chest contents do not count toward logistic network contents; a bare
  `get_contents()` only reports what bots can actually draw from.
- Item-request-proxy (verified against runtime-api v2.1.12):
  `LuaEntity.insert_plan` and `.removal_plan` are **read-write**
  `array[BlueprintInsertPlan]` — retargeting an existing proxy is a plain
  assignment. A plan is `{id = {name, quality}, items = {in_inventory =
  {{inventory, stack, count?}}}}` where `inventory` is a `defines.inventory` value
  and `stack` is **0-based** (LuaInventory slots are 1-based).
  What `id.name`/`id.quality` give back on **read** is the one thing the two API
  generations disagree about: 2.1 types them as plain **strings**
  (`BlueprintItemIDAndQualityIDPair`), 2.0 as `ItemID`/`QualityID` ("returns
  `LuaItemPrototype` when read"), and the 2.1 changelog records no behavior change
  — so one doc describes the other's runtime and neither is verified in-game.
  `name_of` in `gardener.lua` reads through `.name` so both work; writing a name
  string back is accepted either way. Don't "simplify" it away.
- `entity.item_request_proxy` (read-only) returns the first proxy targeting the
  entity; multiple proxies per entity are possible but there is no plural accessor.
  `proxy.proxy_target` is the reverse link.
- `surface.create_entity{name = "item-request-proxy", target = <required entity>,
  position, force, modules = <insert plans>, removal_plan = <removal plans>}` —
  `modules` takes full `BlueprintInsertPlan`s despite the legacy name, and
  `removal_plan` is accepted at creation time.
- `entity.get_module_inventory()` returns `LuaInventory?`; `LuaInventory.index`
  gives the matching `defines.inventory` value (no hand-built per-type table
  needed). Per-slot stacks expose `.name` (string) and `.quality`
  (`LuaQualityPrototype`); check `valid_for_read` first.
- Bots performing a module swap use the removal plan to return the old module to
  storage — no special handling needed (confirmed by the mod author).
- Still unverified in-game: that construction bots pull upgrade items from network
  supply as expected. If orders stall despite stock, check this first.
- Still unverified in-game (ghost provisioning): that `order_upgrade` on an
  entity-ghost applies instantly (upgrade-planner-on-ghost behavior), preserves ghost
  settings and `item_requests`, and supports quality downgrades. Verify, then move
  these up into the verified list.
- Still unverified in-game (module provisioning): that writing `insert_plan` on a
  dispatched proxy re-issues bot orders cleanly, and that a removal and insert
  targeting the same slot resolve pickup-before-delivery (vanilla's
  upgrade-planner-on-modules does exactly this, but it's undocumented). Verify,
  then move these up.
- Still unverified in-game (upgrade-request provisioning): that `order_upgrade`
  on an already-marked entity replaces the existing mark's target in place
  (upgrade-planner re-run behavior) rather than being rejected. Verify, then
  move this up.
- Still unverified in-game (order expiry): that `cancel_upgrade` on an order
  whose item a bot is already carrying recalls the bot and returns the item to
  storage cleanly (rare with the 300 s default expiry, and self-correcting
  either way — the next round re-orders). Verify, then move this up.

## Localization

Only edit `locale/en/locale.cfg` by hand; other languages are managed separately.
