# Space platform support: garden platforms from the hub inventory

Extend the gardener to space platforms. Platforms have no logistic network and
no construction robots — the space platform hub auto-builds ghosts, upgrades,
and module requests directly from its own inventory. The matching engine ports
unchanged; what changes is how a "network" is found and where its supply comes
from. Platforms also introduce one genuinely new concern: items can be *on
order* from the planet below (or, in 2.1, from other platforms), and a naive
retarget would orphan that delivery — so platform provisioning waits for
deliveries before touching anything.

## Context

Players asked for platform management. On a planet, the mod scans each logistic
network's construction coverage and orders quality upgrades against network
stock. Platforms are invisible to that: `game.forces.player.logistic_networks`
never yields a platform surface, because platforms have no logistic network at
all (roboports cannot be placed in space; the hub is not a roboport-equivalent
— verified against the prototype definition, which has no logistic or roboport
properties). The mapping is clean, though: for a platform, *the platform is the
network* — supply is the hub inventory, coverage is the whole (small, bounded)
surface, and the hub itself is the builder.

The complication is deliveries. A common player pattern: paste ghosts or
upgrade marks for items the platform doesn't stock, then wait for the hub's
"request missing construction materials" system to fetch them from the planet
(rocket + cargo pod) or, in 2.1, from nearby platforms. Rocket deliveries take
minutes. If the gardener saw "target quality out of stock" and immediately
retargeted the ghost to a stocked tier, it would silently strand the pending
delivery the player was waiting on. Worse, a known 2.1.7 bug (forum report,
still pending) shows that retargeting ghosts on a platform can leave the
auto-request list stale — neither cancelling the old request nor inducing one
for the new tier — leaving a permanently unbuildable ghost.

Hence the two new player-facing controls (names open to bikeshedding, but
follow the no-abbreviation, no-mod-prefix conventions):

- **`manage-space-platforms`** (bool, runtime-global, default true) — master
  toggle for visiting platforms at all. Platforms are disjoint from planet
  networks, so skipping them entirely has no cross-contamination effect on
  demand accounting.
- **`space-platform-delivery-wait-seconds`** (double, runtime-global, default
  300, minimum 0) — how long a ghost's / mark's / module request's unfulfilled
  target is given for a delivery to arrive before platform provisioning may
  retarget it. The wait applies only when a delivery could actually happen —
  see "The wait rules" below; in transit, or with nothing requested and
  auto-request off, provisioning acts immediately. This is the player's "how
  long do I wait for an order to fill" knob. 0 means retarget immediately
  (planet-like behavior).

A second live bug matters to us defensively: in 2.0.72 (dev-confirmed), an
upgrade order whose item is absent from the hub **blocks the platform's entire
construction queue**. Bots ignore unfulfillable marks; the platform's serial
queue does not. Our existing discipline — only order against confirmed stock,
expire-and-cancel starved orders — is therefore *safety-critical* on
platforms, not merely tidy.

Space Age is technically an optional dependency: without it,
`game.forces.player.platforms` is empty and all of this is inert. No
`info.json` dependency change is needed.

## Implementation Notes

### Verified API facts (runtime-api.json 2.1.12; keep with CLAUDE.md's verified list)

Enumeration and supply:

- `LuaForce.platforms` — dict[uint32 → LuaSpacePlatform], includes platforms
  pending deletion. Guards at entry: `platform.valid`, `platform.hub` exists
  and is `.valid` (nil before the starter pack lands; valid-but-doomed the tick
  the hub dies), `platform.scheduled_for_deletion == 0`.
- `LuaSpacePlatform.surface` — typed non-optional but documented "(if it has
  been created yet)"; treat as nilable.
- Hub supply: `hub.get_inventory(defines.inventory.hub_main)` →
  `LuaInventory.get_contents()` returns `array[{name, quality, count}]` with
  quality as a **string** — the identical shape to
  `LuaLogisticNetwork.get_contents()`, so `read_supply` generalizes to take a
  contents array. Cargo bays extend this single inventory. `hub_trash` is
  items leaving the platform — exclude it.
- There is **no** platform analogue of `available_construction_robots`, no
  build-queue accessor, no coverage cells. Whole-surface
  `find_entities_filtered` on `platform.surface` is the coverage model;
  platforms are small, so it is one cheap scan burst.

Requests and in-flight deliveries (the delivery-wait machinery):

- The hub owns logistic points despite having no network:
  `hub.get_logistic_point(defines.logistic_member_index.space_platform_hub_requester)`
  → `LuaLogisticPoint`.
- `point.filters` — `array[CompiledLogisticFilter]?`, the *merged* view of
  everything the hub requests: the player's manual sections plus the
  auto-generated construction section
  (`defines.logistic_section_type.request_missing_materials_controlled`,
  "Used by space platform hubs"). Filter shape: `{name?, quality?  (string,
  nil = any), comparator? (nil = any), count, ...}`. Auto sections are
  read-only to scripts — we cannot clobber them by accident.
- `point.targeted_items_deliver` — `array[{name, quality, count}]`: "Items
  targeted to be dropped off into this logistic point by robots **or cargo
  pods**." This one member covers rockets from the planet *and* 2.1
  platform-to-platform pods (both arrive as cargo pods). No pod enumeration
  needed. (`LuaSpacePlatform.ejected_items` is items thrown overboard —
  unrelated; ignore.)
- The auto-request section exists **only while
  `hub.request_missing_construction_materials` is true** (read-write on the
  hub entity; read it, never write it). With the player's toggle off, a ghost
  generates no readable request at all.
- 2.1 inter-platform logistics has no other API surface: just
  `request_from` (`"planet" | "platforms" | "all"`) and `import_from` on
  logistic filters. Nothing new on `LuaSpacePlatform`.
- `order_upgrade`, `to_be_upgraded()`, `cancel_upgrade`, item-request-proxies,
  and `find_entities_filtered` (including its `to_be_upgraded` filter) are all
  surface-agnostic. The whole matching engine ports unchanged.

Community-reported behavior (treat as true until verified in-game):

- The platform services upgrade marks and item-request-proxies from hub
  inventory (2.0.72 forum thread with dev reply).
- Unfulfillable upgrade marks block the construction queue (same thread).
- Retargeting ghosts on a platform can leave the auto-request list stale
  (2.1.7 report, unresolved).
- Entity construction is effectively immediate once materials are aboard.

### The wait clock needs a small ledger — parallel to, not merged with, the order ledger

The delivery wait needs "how long has this target been waiting" — a fact the
world cannot answer, which is exactly the order-ledger test. Add
`storage.platform_wait_ledger`, keyed by unit number (ghosts have unit
numbers), holding `{entity, order_tick, target_name, target_quality}` — the
same entry shape as the order ledger. An entry is created the first time a
platform visit finds a target unfulfilled and waiting (rule 3 below); it is
cleared whenever the target is seen stocked or inbound, or the entity is
gone. The clock **resets when the observed target no longer matches the
recorded one** — either field: upgrade marks can be cross-prototype (gun
turret → laser turret, yellow belt → red belt), so a player re-marking to a
different prototype at the same quality is a new wait, not a continuation of
the old one. Losing the ledger is safe: the clock restarts, which only ever
means waiting *longer* — the conservative direction.

Our own platform orders reuse the existing `order_ledger` unchanged (same
entry, same expiry, same sweep). The wait ledger shares the entry shape and
the budgeted between-rounds sweep — generalize `sweep_ledger_step` to take a
table and a validity predicate (order ledger: entity valid and still marked;
wait ledger: entity valid — wait entries attach to ghosts and module-request
targets, for which `to_be_upgraded()` is meaningless) and run both during the
rest window under the same budget. But the wait ledger **must be a separate
table**: the order ledger is a *cancellation license* — membership is itself
the ownership fact — while the wait ledger is a clock table with no ownership
meaning at all. Mixing them would turn a structurally-enforced membership
fact into a field check at every call site. One mechanism, one entry shape,
two tables — the table answers "what does membership mean," the entry answers
"since when, for what target."

(Optional, for shape parity only: the order ledger may also adopt
`target_name` alongside `target_quality`. Not needed for correctness — our
own orders are always same-name and the `entity.name` match check in
`examine_marked` is sound — but it makes the two entry shapes identical and
the match check uniform.)

Document this in CLAUDE.md under the cancellation-license framing: both
ledgers record only facts the world cannot answer; only the order ledger's
membership carries ownership.

### Two views of supply, deliberately not merged

- **Spendable stock** (what upgrades may be ordered against): `hub_main`
  contents only, reserve subtracted — the existing `read_supply` shape. Never
  order against an inbound or requested item: the hub doesn't hold it yet, and
  an unfulfillable order risks blocking the whole queue.
- **Pending fulfillment** (what may be worth waiting for): the item+quality
  appears in `targeted_items_deliver` (physically en route), or an
  *outstanding* request filter matches — outstanding meaning the filter's
  `count` exceeds current hub stock, so a long-satisfied standing request
  doesn't start clocks. Quality matching is conservative: a filter with nil
  quality, nil comparator, or any non-`"="` comparator matches every tier of
  that item.

### The wait rules

For an **unfulfilled** target (exact quality not in spendable stock), in
order:

1. **Inbound** — the item+quality is in `targeted_items_deliver`: leave the
   target alone and clear its wait entry. A delivery is physically en route.
2. **Deliveries impossible** — the platform is in transit (no planet below,
   no neighboring platforms; predicate: `platform.space_location == nil`,
   exact semantics vs `state`/`paused` to be verified in-game): **act
   immediately, no wait.** The motivating case: turrets destroyed mid-flight
   must be refilled from whatever the hub holds — a downgrade now beats a
   hole in the defenses for the rest of the trip.
3. **Deliveries possible and a request may be in play** — a matching
   outstanding request filter exists, *or* the hub's
   `request_missing_construction_materials` is true (the auto-request section
   can lag a freshly pasted ghost, and per the 2.1.7 bug may never populate):
   run the wait clock; retarget only once
   `space-platform-delivery-wait-seconds` has elapsed since the wait entry's
   `order_tick` — first checking that the entry's recorded `target_name` and
   `target_quality` still match what the world reports, and resetting the
   clock if not. The timeout is the stale-request handling: an item
   requested forever that no planet or platform supplies eventually gets
   acted on anyway.
4. **Deliveries possible but nothing requested and auto-request off** —
   nothing is coming and nothing will be: act immediately.

Note rule 3 deliberately does *not* treat "requested" as "not starved": an
outstanding request only starts the clock. Anything stronger would let a
stale request veto retargeting forever — the opposite of the setting's
purpose. Planet networks are untouched by all of this (no wait, no ledger).

## Suggested Approach

1. **Generalize supply reading.** `read_supply(contents_array)` takes the
   `{name, quality, count}` array; network entry passes
   `network.get_contents()`, platform entry passes the hub inventory's
   contents.
2. **Slot collection.** Rename `collect_network_slots` to something like
   `collect_visit_slots`; append one slot per eligible platform
   (`manage-space-platforms` on, guards above pass) after the network slots.
   A slot carries either a live network ref or a platform index — platforms
   are re-fetched from `force.platforms[index]` at entry, never stored.
3. **`enter_platform`.** Produces the *same snapshot shape* as
   `enter_network` so everything downstream is untouched: supply from
   `hub_main`; `cells` = one box covering the surface (or a nil-area
   whole-surface scan variant); `bot_headroom` = a fixed per-visit order cap
   (a module-local constant, e.g. 10 — there is no headroom signal to read,
   and the cap's real job of "don't flood the builder" still applies);
   toggles snapshotted as usual. Additionally snapshot everything the wait
   rules need: fold `targeted_items_deliver` into plain
   `inbound[item][tier] = count` data, the outstanding request filters into
   `requested[item][tier]` plus an any-quality set for range/any filters, and
   read `request_missing_construction_materials` and the
   deliveries-possible predicate (`space_location`) once at entry.
4. **Wait rules in the examine paths.** For platform snapshots only (a flag
   on the snapshot), the three retargeting arms — ghost provisioning,
   upgrade-request provisioning, proxy-request retargeting — run the wait
   rules from the section above before their existing retarget step,
   consulting and advancing the wait ledger as described. Planet networks are
   untouched (no wait, no ledger).
5. **Our own orders** (`examine_building`) need no wait: they are placed only
   against spendable stock, ledgered, and expire through the existing
   `order-expiry-seconds` path — which on platforms doubles as the queue-block
   escape hatch. Note the window: a starved order can wedge the platform's
   construction queue for up to the full expiry (300 s default). Document a
   recommendation to lower `order-expiry-seconds` in platform-heavy saves, or
   revisit with a platform-side cap once the in-game behavior is verified.
6. **Settings, locale, changelog.** Two new settings as named in Context;
   locale entries in `locale/en/locale.cfg` only; changelog entry.
7. **Both release lines.** Port to the `2.0` branch as a separate version.
   2.0 has platforms but no platform-to-platform transfers (`request_from`
   may not exist there — verify against the 2.0 runtime JSON and degrade the
   filter reading gracefully).

## Testing

There is no test suite by design (see CLAUDE.md retired alternatives);
`./validate.sh` (luacheck) is the mechanical check. Real validation is the
in-game checklist below.

## Validation

`./validate.sh` passes, and the in-game checklist (a Space Age save with at
least one platform):

- [ ] A platform with a lower-quality building and a higher-quality spare in
      the hub gets the upgrade ordered and the hub swaps it. (Verifies:
      scripted `order_upgrade` is serviced by the platform at all.)
- [ ] With the target absent from the hub, no order is ever placed (watch for
      the construction-queue block — this must never happen).
- [ ] A ghost for an unstocked quality with a delivery on the way (rocket in
      transit) is left alone; `targeted_items_deliver` visibly covers the
      window from launch (verify: does it include pods still on the pad?).
- [ ] The same ghost with a matching outstanding request (or auto-request on)
      is retargeted, but only after `space-platform-delivery-wait-seconds`
      (stale-request timeout).
- [ ] With auto-request off and nothing requested or inbound, the ghost is
      retargeted immediately (rule 4 — nothing is coming).
- [ ] Mid-flight: destroy a turret whose exact replacement quality isn't
      aboard; the ghost is refilled immediately from the best stocked tier,
      no wait (rule 2). Verify the deliveries-impossible predicate: what
      `space_location`, `state`, and `paused` report while in transit, at a
      station, and paused mid-route.
- [ ] An upgrade mark's missing item: check whether it populates the
      auto-request section at all (the 2.1.7 report suggests it may not) —
      this decides whether the request half of the starved test ever fires
      for marks.
- [ ] Module proxy on a platform entity resolves cleanly (hub module
      inserter is known quirk-prone).
- [ ] Hub requester point exists with no logistic network; its
      `logistic_network` member is never dereferenced.
- [ ] Toggling `manage-space-platforms` off stops platform visits within one
      round; planet behavior unchanged.
- [ ] A save without Space Age loads and runs (platforms list empty).
- [ ] Kill the hub / delete the platform mid-round: no invalid-entity errors
      (the snapshot's surface_index path and entity `.valid` checks hold).

Move each verified item from "community-reported" / "unverified" into
CLAUDE.md's verified list as it is confirmed.

## Documentation

- `CLAUDE.md` — architecture line ("logistic networks *and space platforms*"),
  design invariants (platform-as-network, the two-views-of-supply rule, the
  wait ledger as a clock table under the cancellation-license framing, the
  queue-block hazard), verified API facts (move the platform facts in once
  confirmed in-game).
- `docs/decisions.md` — why deliveries gate retargeting, why in-transit
  platforms skip the wait, why the wait ledger is a separate table from the
  order ledger, why our own orders skip the wait, why the per-visit order cap
  is a constant, why player marks get extra caution on platforms.
- `README.md` and `PORTAL.md` — player-facing description of platform
  management and the two new settings.
- `locale/en/locale.cfg` — setting names and descriptions (delivery wait
  description should mention "time to wait for deliveries from the planet or
  other platforms before adjusting an order").
- `changelog.txt` — Factorio's strict format, both branches.
