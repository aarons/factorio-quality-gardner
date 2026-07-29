# Ghost provisioning: retarget ghosts to the best available quality

> **Amended after implementation (2026-07-28):** the `provision-ghosts` setting
> described below was a mistake — the feature shipped always-on with no toggle.
> In the same pass, hidden-quality support (skip/sticky) and the supply-centric
> early exit were removed mod-wide, so the tier-policy subtleties below no
> longer apply: supply keeps every on-chain contents row, and both built
> entities and ghosts share one best-stocked-tier lookup.

When a ghost requests a quality the network does not stock, retarget the ghost
to the best quality the network does have — even a lower one — so the building
gets built. "Better a slow factory than no factory."

Depends on plan-001 (the scan-based loop); this plan extends the per-entity
scan step to ghosts.

## Context

Construction bots fulfil a ghost only from stock that exactly matches the
ghost's quality. Stamp a legendary blueprint with only common machines in
storage and nothing is ever built. This plan makes the mod step in: if the
exact quality is missing but any tier of the item is in network storage,
re-order the ghost at the best available tier.

This is a headline feature, not a side effect — **downgrading ghosts is
intended behavior, on by default**. It is self-healing: a legendary ghost
downgraded to common gets built as common, and the built entity is then an
ordinary upgrade candidate that the mod raises tier by tier as better stock
appears (plan-001 handles that with no extra code). The ghost's originally
requested quality is not remembered; future upgrades simply chase the best
available supply. Gate the feature behind one runtime-global bool setting,
default on.

Design decisions already made (July 2026) — do not revisit:

- **Never destroy-and-recreate a ghost.** Retargeting must go through
  `order_upgrade` on the ghost. Per the Factorio docs, "Most functions on
  LuaEntity also work when the entity is contained in a ghost," and the
  "upgrade" naming is ubiquitous with "change" — the API supports lowering
  quality (the in-game upgrade planner itself can downgrade).
- Retargeting counts against the network visit's bot cap: without the retarget
  the ghost consumed no bot; after it, a bot will go build it.

## Implementation Notes

All work is in `scripts/gardener.lua` (scan step), `settings.lua`, and locale.

Ghost API surface (verify exact behavior in-game during this plan; these are
from the docs plus author guidance):

- Ghosts are entities of type `"entity-ghost"`. `entity.name` is
  `"entity-ghost"`; `entity.ghost_name` is the contained prototype's name.
  `entity.quality` is the ghost's requested quality. Ghosts have unit numbers
  and a force.
- `entity.is_registered_for_construction()` — true for a ghost awaiting revive.
- `entity.order_upgrade{target={name=<ghost_name>, quality=...}, force=...}`
  on a ghost changes the ghost. Expected to apply instantly (upgrade-planner-
  on-ghost behavior) and preserve ghost settings; confirm in-game, including
  that `entity.item_requests` (module/item requests attached to the ghost)
  survive.
- `to_be_deconstructed()` is meaningless for ghosts; no deconstruction check
  needed on the ghost path.

Scan changes: the plan-001 scan filters `find_entities_filtered` by
`type = storage.config.all_tracked_types`; add `"entity-ghost"` to the types
requested (as a scan-time addition or in config). For ghosts, candidacy is
`placing_item_name[ghost_name]` instead of `placing_item_name[name]`.

Quality-tier subtlety: a ghost may request a tier that
`qualities.is_candidate_tier` would reject for built entities (e.g. the top
tier, or hidden tiers under the sticky setting). Ghost handling should not use
`is_candidate_tier` — any chain tier is retargetable when its stock is absent.
Respect `is_target_tier` for the tier being retargeted *to* only as far as
hidden-quality policy demands (`skip-hidden-qualities`); note `is_target_tier`
also excludes tier 1 (normal), which is a valid downgrade target for ghosts —
so it cannot be reused blindly. Decide the check explicitly.

## Suggested Approach

In the per-entity scan step, branch on `type == "entity-ghost"`:

1. Resolve `item = placing_item_name[ghost_name]`; skip if nil.
2. Skip if the feature setting is off — but still do step 3's demand
   accounting, which is correct regardless.
3. If `supply[item][ghost's tier] > 0` → decrement it (a bot will fulfil this
   ghost natively) and move on. This is the ghost demand accounting plan-001
   optionally sketched; it becomes mandatory here.
4. Otherwise find the best tier of `supply[item]` with count > 0 (highest
   first, any tier — higher or lower than requested). None → skip.
5. `order_upgrade` the ghost to that tier. On success: decrement that supply
   count and the visit's bot cap.

Setting: `provision-ghosts` (runtime-global bool, default true; project style —
no prefixes, no abbreviations). Locale entry describing the downgrade behavior
plainly, since it surprises players who expect "legendary or wait."

## Testing

No test suite (project convention); validation is in-game via `./validate.sh`
plus the checklist below.

## Validation

- `./validate.sh` passes.
- Legendary-quality blueprint stamped with only common machines in storage:
  ghosts get retargeted to common and built. With mixed stock (common +
  uncommon), ghosts take the uncommon.
- A ghost whose exact quality is stocked is left alone (bots fulfil it
  natively) and its demand reduces what the mod orders elsewhere.
- Retargeted ghosts keep their configuration (recipe, direction, circuit
  wires) and their module/item requests — verify `item_requests` survives.
- Once built at the lower tier, the entity is upgraded normally as better
  stock arrives (self-healing loop closes).
- With `provision-ghosts` off, ghosts are never retargeted but ghost demand is
  still counted.
- Retargets respect the bot cap and `reserve-per-item`.

## Documentation

- `README.md` — this is a headline feature; describe the downgrade-to-build
  behavior and the toggle.
- `CLAUDE.md` — record verified ghost API facts (instant apply, settings
  survival, downgrade support) in the verified-facts section once confirmed
  in-game.
- `changelog.txt`, `locale/`.
