I read through all ~5,000 lines of AutoBestQuality 1.0.3 (event_handlers.lua, ghost_processor.lua, upgrade_handler.lua, network_finder.lua, pending_manager.lua, settings, changelog) and compared it against scripts/gardener.lua and our invariants. Here's the comparison.

The one-line difference

ABQ is intent-driven; Quality Gardener is supply-driven.

- ABQ: every action has a recorded target quality — the blueprint's ghost quality or the upgrade-planner's target. It substitutes down to the closest available quality so something gets built, then "steps up" that specific entity toward its recorded target as better stock arrives. It never touches a building nobody asked to upgrade, and (by default, max-higher-quality-levels = 0) never spends a better item than requested.

- QG: there is no target — the best stocked tier is the target. Every building, ghost, mark, and module in a network drifts toward whatever storage holds. A normal-quality blueprint gets upgraded to legendary if legendaries are on hand; ABQ would leave it alone forever.

Everything else follows from that choice.

Head to head

Trigger

AutoBestQuality 1.0.3: Event-driven: on_built_entity (ghost queue), on_marked_for_upgrade, on_entity_died, on_object_destroyed, cargo-pod events, blueprint

setup, ~15 handlers total; plus an on_tick retry state machine (fast 3 s / slow 30 s intervals) and a 1-chunk-per-tick proxy scan

Quality Gardener 1.3.0: One budgeted round-robin scan pass, every tick, no entity events

────────────────────────────────────────

Persistent state

AutoBestQuality 1.0.3: ~15 storage tables: substituted_ghosts (with captured recipe/filters/module requests), pending_ghosts per network, ghost_queue

(LuaEntity refs), expected_ghosts, network_cache (LuaLogisticNetwork refs, timeout + .valid check), roboport_registry, canonical_module_requests (10-min

TTL), owned-proxy unit numbers, registration-number reverse maps…

Quality Gardener 1.3.0: Two ledgers (order ownership + tick; platform wait clocks) plus the pass cursor

────────────────────────────────────────

Entity identity

AutoBestQuality 1.0.3: Position string "%.1f_%.1f" (surface-less for most tables) — entities are re-found via find_entities_filtered{position, radius=0.5} on

every touch

Quality Gardener 1.3.0: unit_number in the ledgers; otherwise none

────────────────────────────────────────

Ghost substitution mechanism

AutoBestQuality 1.0.3: ghost.destroy() + create_entity new ghost, then hand-capture and re-apply recipe (+quality), inserter filters, module requests via its

own item-request-proxy entities, abq_modules tags, and a blueprint-setup patch so copies keep original intent

Quality Gardener 1.3.0: order_upgrade on the ghost — native, in place

────────────────────────────────────────

Step-up of a built substitute

AutoBestQuality 1.0.3: create_entity a ghost at the intermediate tion on the current entity (two bot trips, contents dumped), then

re-issue order_upgrade to the original target after the build; dien the exact target is stocked

Quality Gardener 1.3.0: order_upgrade straight to best stocked, one trip; the cascade handles the rest

────────────────────────────────────────

Quality choice

AutoBestQuality 1.0.3: Closest to target by level distance (ties → higher), bounded by max-lower/max-higher settings

Quality Gardener 1.3.0: Best stocked tier, full stop

────────────────────────────────────────

Supply accounting

AutoBestQuality 1.0.3: can_satisfy_request(item, n, true) per candidate + a per-batch tick_allocations counter to avoid double-promising in one tick; no

cross-round demand accounting for existing ghosts/marks (relies o

Quality Gardener 1.3.0: Snapshot at network entry; every visible mark and stocked ghost decrements it; orders capped by available_construction_robots; reserve

setting

────────────────────────────────────────

Network lookup

AutoBestQuality 1.0.3: Ghost → network: iterate roboport [registryll.is](http://registryll.is)_in_construction_range(pos), cache per chunk

Quality Gardener 1.3.0: Network → entities: force.logistic_networks, per-cell entity scans; no lookup problem exists

────────────────────────────────────────

Existing buildings (no ghost, no mark)

AutoBestQuality 1.0.3: Never touched

Quality Gardener 1.3.0: Core behavior (manage-factory)

────────────────────────────────────────

Installed modules (no request)

AutoBestQuality 1.0.3: Never touched

Quality Gardener 1.3.0: Upgraded when better stocked

────────────────────────────────────────

Player upgrade marks

AutoBestQuality 1.0.3: Registered for step-up; if target unavailat intermediate (the player's mark effectively replaced, re-issued

later)

Quality Gardener 1.3.0: Quality retargeted in place; never cancelled

────────────────────────────────────────

Death of a substituted entity

AutoBestQuality 1.0.3: Intercepts on_entity_died, re-creates the ghost at the original target quality

Quality Gardener 1.3.0: Vanilla ghost at current quality; the cascade lifts it later

────────────────────────────────────────

Space platforms

AutoBestQuality 1.0.3: Hub inventory + cargo-pod events trigger iurface chunk scan

Quality Gardener 1.3.0: Hub inventory as supply, delivery-wait rules (targeted_items_deliver, request filters, in-transit exception)

────────────────────────────────────────

Escape hatches

AutoBestQuality 1.0.3: /abq-reset, /abq-cleanup, /abq-stats, /abq-perf, /abq-network-stats, /abq-inspect-ghosts

Quality Gardener 1.3.0: /quality-gardener-init

────────────────────────────────────────

Forces

AutoBestQuality 1.0.3: Any

Quality Gardener 1.3.0: player only

What their approach costs them (and why we retired it)

ABQ is a very good example of the design docs/[decisions.md](http://decisions.md) walks away from. Because it remembers intent per entity, it must keep that memory consistent with

a world that changes under it — and every 1.0.x changelog entry i sticky dedup flags after ghost expiry (1.0.2), bots building theghost before the queue drained (1.0.2), module intent lost on copy/paste (1.0.1, 1.0.2), recipe quality lost on destroy/recreate (1.0.1). The

destroy-and-recreate substitution is the root of most of it: once own the job of preserving recipe, filters, module requests,

blueprint tags — hence capture_ghost_settings/reapply_settings (~nt patcher. Our order_upgrade-on-ghost path (verified in-game toapply instantly and support downgrades) sidesteps that whole surface — with the one open backlog item that settings/item_requests survive it, which is

exactly the thing they got bitten by.

Position-string identity is the other recurring cost: nearly every touch is a find_entities_filtered at a position, and any entity at that spot collides with the record.

What their approach buys them

Fair to say plainly:

1. Latency. Stamp a legendary blueprint and ABQ substitutes withi0/tick). We wait until that network's turn in the round — secondsto minutes on a big base. This is the real UX gap between the two.

2. Intent preservation. A legendary blueprint stays "legendary-wanting" even after being built as normal, and ABQ won't burn legendaries on a normal-quality

blueprint (max-higher = 0). Our only brake is the reserve settingerence, not a bug, but it's the argument someone would makeagainst a gardener.

3. Ghost recreation at original quality on death.

Things worth noting for us

- Nothing here argues for reintroducing per-entity state — ABQ is the reference case for why not.

- The one behavior gap that isn't philosophical is round latency nts. If we ever cared, the smallest move would be prioritizing the

Fair to say plainly:

1. Latency. Stamp a legendary blueprint and ABQ substitutes within the tick (queue drains 20/tick). We wait until that network's turn in the round — seconds

to minutes on a big base. This is the real UX gap between the two

2. Intent preservation. A legendary blueprint stays "legendary-wanting" even after being built as normal, and ABQ won't burn legendaries on a normal-quality blueprint (max-higher = 0). Our only brake is the reserve setting; that's a philosophy difference, not a bug, but it's the argument someone would make against a gardener.

3. Ghost recreation at original quality on death.

Things worth noting for us

- Nothing here argues for reintroducing per-entity state — ABQ isy not.

- The one behavior gap that isn't philosophical is round latency on freshly stamped blueprints. If we ever cared, the smallest move would be prioritizing the surface/network the player is on, not events — but that's a design change, and I wouldn't do it unprompted.

- Their comment that find_entities_filtered{to_be_upgraded=true} can return entity-ghost in 2.0 is harmless to us (we branch on entity-ghost first in

examine), but it's a nice sanity note.

- Our api-notes backlog item "order_upgrade on a ghost preserves settings and item_requests" is worth verifying sooner rather than later — ABQ's 1.0.1 recipe-quality bug is precisely the failure that would surface if it doesn't.

Happy to write this up into docs/ (e.g. a "prior art" section in it kept — I've left the repo untouched.

✻ Worked for 2m 56s

❯ I'm trying to find a good way to summarize or provide an analogy of the differences. How many lines of code are these two mods?

  Searched for 1 pattern, ran 2 shell commands

Raw and code-only counts (Lua files only, locale/info excluded):

┌───────────────────────────────────────────────────────┬─────────────────────────┐

│                                                       │ Quality Gardener 1.3.0 │  AutoBestQuality 1.0.3   │

├───────────────────────────────────────────────────────┼────────────────────────┼──────────────────────────┤

│ Total lines                                           │ 926                     │

├───────────────────────────────────────────────────────┼────────────────────────┼──────────────────────────┤

│ Non-blank, non-comment                                │ 686                    │ 3,766                    │

├───────────────────────────────────────────────────────┼─────────────────────────┤

│ Without ABQ's debug/command tooling (debug_utils.lua) │ —                      │ ~4,600 raw / ~3,460 code │

└───────────────────────────────────────────────────────┴────────────────────────┴──────────────────────────┘

So ABQ is roughly 5.5× the size on both measures, and that ratio its debug commands. Note QG does more behaviors (upgrades existing buildings and installed modules, which ABQ never touches), so the size difference is entirely the cost of remembering intent and reconciling that memory with the world.

A few analogies you could use, in order of how much I like them:

1. Gardener vs. contractor. A gardener walks the beds on a schedule and improves whatever it finds with what's in the shed — no work orders, no memory of

what was planted, just "is there something better on hand?" A conrint: every job has a spec, and if the spec'd material isn't instock they substitute, keep the work order open, and come back to swap it out when the right material arrives. The contractor's filing cabinet is most of the code. (Fits the mod's name, which is a nice bonus.)

2. Thermostat vs. to-do list. QG is a thermostat: it reads the ropossible, and nudges — no record of past decisions needed, because the room is the record. ABQ is a to-do list: every substitution is a task written down with its goal, and the mod's job is keeping the list in sync with a world that keeps editing itself behind its back (bots build early, ghosts expire, players copy-paste). Every bug in its changelog is a stale to-do item.

3. Stateless vs. stateful, in one sentence. "QG asks the world one question — is there something better in stock? — and never writes anything down. ABQ writes down what you asked for and spends 4,000 lines making sure the note stays true."

If you want a single line for a README or portal page: "Quality Gardener has no memory and no work orders — the world is the to-do list, so it stays under 700 lines of code."

> Can we learn anything from their approach that would be worth considering? 

  
Your instinct matches what I saw — almost everything in ABQ that isn't the core "substitute then step up" idea is scaffolding to keep its memory in sync with a world it can't reliably observe (bots building early, ghosts expiring silently, copy/paste, biter deaths), and we simply don't have that problem.

Worth adopting

1. Verify recipe quality specifically, not just recipe, when we retarget a ghost. ABQ 1.0.1's bug was that recipe survived their substitution but recipe quality silently reset to normal — it's a separate field (get_recipe() returns (recipe, quality), and set_recipe(recipe, quality)). Our backlog item says "settings and item_requests"; I'd make the in-game check explicit: a ghost with a quality recipe (their example: rare personal batteries on an uncommon assembler), retargeted via order_upgrade, then inspect recipe and recipe quality. If it drops, the fix is one set_recipe call after the retarget — still stateless. Also worth checking inserter filters and use_filters in the same session, since those are the other things they had to hand-carry.
2. Disclose the copy/paste consequence in the README rather than fight it. In-place retargeting means the ghost or module request is now the lower quality — so a blueprint or copy of a retargeted ghost/machine captures the substitute quality, not what the player originally asked for. ABQ spent two releases (1.0.1, 1.0.2) on tags and a blueprint-setup patcher to preserve the original intent. For us it's just "the world is the record" — the pasted copy gets gardened up like everything else — but a player who copies a legendary blueprint after we've retargeted it to common and gets a common blueprint back will file that as a bug unless it's stated. One bullet next to the existing "if you cancel a mark the mod made…" caveat under Compatibility covers it. I'd add the same note to docs/[decisions.md](http://decisions.md) so the "why not tags/patching" is on record.
3. (Optional, small) A read-only status command. ABQ's /abq-stats / /abq-inspect-ghosts exist because the #1 player question is "why didn't X get upgraded?" A /quality-gardener-status that prints the pass position (surface/network cursor, resting-or-scanning), ledger sizes, and last round's order count is stateless apart from one or two counters already implicit in storage.pass. Only if you want it — it's surface area, and the README's "no marks = the item isn't stocked in that network" already answers most of it.

Considered and not worth it

- can_satisfy_request(item, n, true) instead of the contents snapshot. ABQ's comment claims it accounts for bot reservations; per the API docs the third argument is include_buffers (buffer chests), not reservations. Our snapshot + every-mark-is-demand + bot-headroom cap is more principled and doesn't do a per-quality API call per candidate.
- Fast/slow idle back-off (3 s when a round made progress, 30 s when not). Stateless enough, but it only trades reaction time for a UPS gain that entities-per-tick already bounds. Not worth a setting.
- Roboport-less / "no network" ghost pending list. A ghost outside every network can't be built by bots anyway; retargeting it is pointless. Correctly nothing for us.
- max-higher-quality-levels ("don't spend legendaries on my common blueprint"). Legitimate preference, but it's the opposite of the gardener premise; reserve is the brake we offer.
- Ghost recreation at original quality on death, cargo-pod-event triggers, on_marked_for_upgrade immediate handling. All either intent memory or event integration — retired for good reason.
- Their module-inventory-id-by-entity-type table. We already do this properly via module_inventory.index. Likewise cargo bays in platform supply and slot-level insert_plan handling — we're ahead there.

One footnote unrelated to ABQ but visible while comparing: we hardcode game.forces.player throughout (scripts/gardener.lua:163,563,590,599,616,655). ABQ passes entity.force everywhere and works for any force. It's fine for essentially all players, but if a multi-force scenario report ever comes in, that's the reason.

If you want, I can (a) turn the two doc items into concrete edits to [README.md](http://README.md), docs/[decisions.md](http://decisions.md), and the api-notes backlog line, and (b) sketch the /quality-gardener-status command so you can decide on it by looking at it — just say which.