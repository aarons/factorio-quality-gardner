# Quality Gardener

Factorio 2.1 mod: when higher-quality versions of placed buildings sit in a logistic
network, lower-quality placed buildings in that network are marked for upgrade so
construction bots swap them out.

The architecture in one line: *no entity events and no per-entity state — a
round-robin, budgeted scan pass reads each logistic network fresh and orders
upgrades on the spot.* `README.md` covers player-facing intent and behavior.

## Design invariants (read before changing core behavior)

- **The world is the only source of truth.** Nothing per-entity is stored — no
  candidate index, no order ledger. Each network visit reads reality fresh (contents,
  roboport cells, the entities inside them) and issues orders directly. Marked
  entities are recognized by asking the entity itself (`to_be_upgraded()`).
- **Every visible mark is demand.** A marked entity — ours from a past round, a
  player's upgrade-planner mark, or another mod's — decrements the supply snapshot at
  its upgrade target and is otherwise skipped. No ledger is needed because the scan
  enumerates everything.
- **No mark is ever cancelled.** Without a ledger we cannot distinguish our marks
  from a player's, and cancelling a player's mark is off-limits. Consequences,
  accepted deliberately (July 2026) — do not "fix" them: no order expiry (a starved
  mark stays until a player clears it or supply reappears), no cancel cooldown (a
  player-cancelled mark gets re-marked on a later round while supply persists), and
  no runtime-state restore (our upgrades behave exactly like player-ordered native
  upgrades).
- **Network identity is transient; only snapshots span ticks.** `LuaLogisticNetwork`
  refs and ids invalidate on any merge/split; no network reference or id is ever
  stored or held across a tick boundary. Entering a network reads everything needed
  (bot count, supply, construction cell boxes) from the live ref in that single tick;
  the rest of the visit runs from the plain-data snapshot, which can only go stale,
  never invalid. Network slots are re-enumerated fresh whenever the cursor needs a
  network; only the integer cursor persists.
- **Pass state lives in `storage`, and abandoning it is always safe.** Cross-tick
  state in locals would desync a multiplayer join, so the resumable pass (cursor,
  in-progress network work state, `resume_tick`) is plain data in `storage.pass`.
  Init and configuration changes reset it; a restarted pass just re-derives from the
  world. `LuaEntity` references may sit in the work state across ticks (they are
  storable); `.valid` is checked before each use.
- **Work is spread, never burst.** The pass runs on `on_nth_tick(10)` and spends up
  to `entities-per-pass` iterations per invocation — one entity examined or one
  network entered per iteration — with at most one per-cell entity scan burst per
  invocation. After a full round of the networks it rests for
  `round-delay-seconds` (the pickup window: bots collect ordered items so the next
  round's contents reads are close to accurate).
- **Orders are capped by bot headroom.** Each network gets at most
  `available_construction_robots` orders per visit, read fresh at entry — busy bots
  (including ones flying our orders) self-exclude, so the fresh read is the whole
  cap. Never mark more work than bots can start; a stale count only delays marks
  until the next visit.
- **No supply-based early exit.** Every network with bot headroom gets its cells
  scanned, whatever its contents — networks without buildable stock are rare in
  practice and act as natural pacing between the ones that matter. The supply
  snapshot keeps every on-chain contents row unfiltered; rows for items that place
  no entity are harmless because nothing ever looks them up. Deliberate (July
  2026) — don't reintroduce a "skip networks without candidate supply" shortcut.
  Duplicate entities across overlapping cells are harmless — once marked, later
  encounters take the demand-accounting path.

## Engineering principles

- Avoid abbreviations in names (settings, locals, storage keys); spell words out.
- No prefixes on setting names.
- No exclusion machinery (mod lists, surface filters, Factorissimo integration): bots
  perform the upgrades natively, so entities other mods manage are handled fine. This
  is deliberate (July 2026) — don't reintroduce it from the reference mod, which
  predates the decision.
- No per-entity-type enable settings and no hand-maintained type list: candidacy is
  derived from prototypes in `build_and_store_config` (has a placing item, not
  flagged `not-upgradable`) — belts and pipes included. Deliberate (July 2026).
- No hidden-quality machinery (the old skip/sticky startup settings are gone):
  hidden qualities come from other mods, and other-mod support waits until the core
  is proven. Every tier on the normal chain is treated alike. Deliberate (July
  2026).
- Ghost provisioning is always on — no toggle. A ghost whose exact quality is
  stocked is left to the bots (counted as demand); otherwise it is retargeted to
  the best stocked tier, even a lower one. Deliberate (July 2026).
- Module provisioning is quality-only and always on — never change which module
  prototype sits in or is requested for a slot, only its quality. Installed modules
  are only ever upgraded (a player chose them); unfulfillable *requests* are
  retargeted in either direction, a downgrade beating an empty slot. Built entities
  only — ghost module slots are out of scope. Deliberate (July 2026).
- No PickerDollies/teleport-mod event integration: no positions are cached anywhere —
  every round scans entities fresh, so untracked teleports cannot go stale.
  Deliberate (July 2026) — don't resubscribe to dolly events.

## Validation & packaging

`./validate.sh` runs luacheck — that is the whole validation story; don't add a test
suite. `./package.sh` validates, zips, and copies the mod into the local Factorio mods
folder.

## Verified API facts (don't re-derive)

- `LuaLogisticNetwork.get_contents(member?)` — `member` is optional (`"storage"` or
  `"providers"`); when omitted, returns item counts for the **entire network**. We
  always call it bare. Returns an array of `{name, quality, count}` where `quality`
  is a **string** prototype name.
- `order_upgrade{target={name=..., quality=...}, force=...}` supports same-name
  quality-only upgrades; `get_upgrade_target()` returns (prototype, quality).
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
  {{inventory, stack, count?}}}}` where `name`/`quality` are plain **strings**
  (not prototypes), `inventory` is a `defines.inventory` value, and `stack` is
  **0-based** (LuaInventory slots are 1-based).
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
