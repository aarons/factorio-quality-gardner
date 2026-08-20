# API notes

Verified Factorio API facts and the in-game verification backlog. Consult
before touching an API call; don't re-derive a fact recorded here.

The default assumption is that the engine behaves sanely — script calls that
mirror the upgrade planner do what the planner does. Record only facts that
are surprising, version-dependent, or oddly shaped; routine engine behavior
does not need a backlog entry.

## Verified

- `LuaLogisticNetwork.get_contents(member?)` — `member` is optional (`"storage"` or
  `"providers"`); when omitted, returns item counts for the **entire network**. We
  always call it bare. Returns an array of `{name, quality, count}` where `quality`
  is a **string** prototype name.
- `order_upgrade{target={name=..., quality=...}, force=...}` supports same-name
  quality-only upgrades; `get_upgrade_target()` returns (prototype, quality).
- `LuaEntity.cancel_upgrade(force, player?)` returns a boolean — true when a
  pending upgrade was cancelled.
- Planner-equivalent behavior confirmed in-game, recorded once so it stays out
  of the backlog: construction bots pull upgrade items from network supply;
  `order_upgrade` on an entity-ghost applies instantly, supports quality
  downgrades, and preserves the ghost's settings — recipe *quality* included
  (a separate field from the recipe, and the one a destroy-and-recreate
  substitution loses; verified 2026-08-18); `order_upgrade` on an
  already-marked entity replaces the existing mark's target in place;
  `cancel_upgrade` on an order whose item a bot is already carrying recalls
  the bot and returns the item to storage.
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
- `storage` serializes numbers as bit-exact IEEE-754 doubles, so `math.huge`
  round-trips through save/load (verified empirically on 2.0.76: raw
  `0x7FF0…` bytes in the save's script.dat) — the platform snapshot's
  infinite order budget depends on this. Two traps to keep it safe: never
  feed a possibly-infinite value to an engine setter, and never route one
  through `helpers.table_to_json` (emits bare `inf`, invalid JSON).
- Space platforms (verified against runtime-api.json 2.1.12):
  - `LuaForce.platforms` — dict[uint32 → LuaSpacePlatform], **includes platforms
    pending deletion**. Guards at entry: `platform.valid`, `platform.hub` exists
    and is `.valid` (nil before the starter pack lands; valid-but-doomed the
    tick the hub dies), `platform.scheduled_for_deletion == 0`. Without Space
    Age the dict is empty and platform support is inert (no `info.json`
    dependency change needed).
  - `LuaSpacePlatform.surface` — typed non-optional but documented "(if it has
    been created yet)"; treat as nilable.
  - `hub.get_inventory(defines.inventory.hub_main)` →
    `LuaInventory.get_contents()` returns `array[{name, quality, count}]` with
    quality as a **string** — the identical shape to
    `LuaLogisticNetwork.get_contents()`, so `read_supply` takes a contents
    array. Cargo bays extend this single inventory. `hub_trash` is items
    leaving the platform — excluded.
  - There is **no** platform analogue of `available_construction_robots`, no
    build-queue accessor, and no coverage cells — whole-surface
    `find_entities_filtered` is the coverage model.
  - The hub owns logistic points despite having no network:
    `hub.get_logistic_point(defines.logistic_member_index.space_platform_hub_requester)`
    → `LuaLogisticPoint`. Its `filters`
    (`array[CompiledLogisticFilter]?`) is the *merged* view of the player's
    manual sections plus the auto-generated construction section
    (`defines.logistic_section_type.request_missing_materials_controlled`);
    filter shape `{name?, quality? (string, nil = any), comparator? (nil =
    any), count, ...}`; auto sections are read-only to scripts. The auto
    section exists **only while `hub.request_missing_construction_materials`
    is true** (read-write on the hub; we read it, never write it).
  - `point.targeted_items_deliver` — `array[{name, quality, count}]`: items
    to be dropped off by robots **or cargo pods** — rockets from the planet
    and 2.1 platform-to-platform pods both. (`LuaSpacePlatform.ejected_items`
    is items thrown overboard — unrelated.)
  - 2.1 inter-platform logistics adds no other API surface: just
    `request_from` (`"planet" | "platforms" | "all"`) and `import_from` on
    logistic filters.
  - `order_upgrade`, `to_be_upgraded()`, `cancel_upgrade`,
    item-request-proxies, and `find_entities_filtered` are all
    surface-agnostic — the matching engine ports unchanged.
  - The platform services scripted upgrade marks and item-request-proxies
    from hub inventory, and construction is effectively immediate once
    materials are aboard.
  - The hub builds its queue serially, so an order whose item is not aboard
    holds the queue behind it. Long-standing engine behavior, accepted as-is
    — only-order-against-stock (with order expiry as the escape hatch) is
    the whole accommodation; the mod is not in the business of working
    around it further.

## Still unverified in-game

Verify each, then move it up into the verified list.

- Nothing outstanding.
