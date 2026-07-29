# Module provisioning: upgrade installed modules, fulfil module ghosts

Extend matching to modules: when network storage holds a better-quality version
of a module installed in an entity, swap it in; when a module request on an entity
can't be met at its exact quality, retarget it to the best
available quality (downgrades included, same philosophy as plan-002).

Depends on plans 001 and 002. This is the most API-uncertain chunk — it begins
with a verification step, and its findings may reshape the approach.

## Context

Machines carry modules and module requests.

- An entity has a common speed module installed while a rare one sits in
  storage → nobody upgrades it.
- An entity has a request for a rare speed module, there is none in storage, but
  there are lower quality ones available -> it sits empty until rare shows up, instead
  of being filled by something lower for now.

Scope: same-module quality changes only — never change which module prototype
is requested, only its quality. Both directions follow plan-002's philosophy:
prefer the best available tier; a downgrade beats an empty slot. Module
provisioning should respect the same feature toggle as ghost provisioning for
the downgrade direction (or its own setting — engineer's call, default on
either way; project style: no prefixes, no abbreviations).

## Implementation Notes

**Verification first.** Unlike entities, modules have no `order_upgrade`.
Module logistics in Factorio 2.x run through **item-request-proxy** entities
carrying insert/removal plans. Before writing code, verify against the current
API docs (https://lua-api.factorio.com/latest/, and the answer-agent is
available for this) and in-game:

- The shape of `LuaEntity.insert_plan` / `removal_plan` on an
  item-request-proxy (`BlueprintInsertPlan`: id `ItemIDAndQualityIDPair` plus
  `ItemInventoryPositions`), and whether they are read-write.
- Creating a proxy: `surface.create_entity{name = "item-request-proxy",
  target = <entity>, position = ..., force = ..., modules = ...}` — exact
  parameter shape for requesting "remove module X quality a from slot n, insert
  quality b."
- How an unfulfilled module request appears on a built entity: on
  built entities, a pending request is an existing proxy attached to the
  entity. Confirm how to find a proxy for an entity
  (`find_entities_filtered{type = "item-request-proxy"}` in the scan area, or
  a property on the target).
- Whether editing an existing proxy's plans is permitted and takes effect, or
  whether the proxy must be destroyed and recreated (destroying a *proxy* is
  acceptable — unlike ghosts, a proxy carries no configuration beyond its
  plans; recreate it in the same call).
- Reading installed modules: `entity.get_module_inventory()` →
  `LuaInventory`; per-slot `LuaItemStack.name` / `.quality`.
- Whether bots performing a module swap use the removal plan to return the old
  module to storage. (Note from mod author: yes they do, we don't need to do any special handling here).

Record what's confirmed in CLAUDE.md's verified-facts section.

Supply side needs no new reads: module items appear in the same bare
`get_contents()` snapshot.

## Suggested Approach

(Subject to the verification step.)

Extend the per-entity scan step; every check stays one-entity-local so the
iteration budget still holds. Three cases:

1. **Built entity, installed modules**: walk `get_module_inventory()`; for
   each slot whose module has a higher tier in supply, add a swap (removal of
   the installed module + insert of the better one) to a proxy for this
   entity. Batch all slots of one entity into one proxy operation. Decrement
   supply for inserts, increment (or ignore, conservatively) for removals —
   removals return stock only after the bot trip, so ignoring them is the
   conservative choice. Costs bot cap (one per proxy, or per module —
   engineer's call, document it).
2. **Built entity with a pending proxy** whose requested quality isn't
   stocked: retarget the proxy's insert plans to the best stocked tier of the
   same module. Count fulfillable proxy requests as demand (decrement supply),
   mirroring plan-002's ghost accounting.

Skip entities marked for deconstruction or upgrade (an upgrade swap would
orphan the proxy work). Respect `reserve-per-item` for module items too.

## Testing

No test suite (project convention); `./validate.sh` plus in-game checks.

## Validation

- `./validate.sh` passes.
- Entity with common modules + rare modules in storage → bots swap them; the
  displaced common modules return to storage.
- Module swaps respect bot cap, `reserve-per-item`, and the feature toggle.
- Requests at a stocked quality are never touched.
- Entities marked for upgrade or deconstruction get no module orders.

## Documentation

- `CLAUDE.md` — add the verified proxy/module API facts; note module scope
  (quality-only, never prototype changes) as an invariant.
- `README.md` — module provisioning behavior.
- `changelog.txt`, `locale/` (if a new setting is added).
