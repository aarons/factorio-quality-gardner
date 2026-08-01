# Quality Gardener

Factorio 2.1 mod: when higher-quality versions of placed buildings sit in a logistic
network (or a space platform's hub), lower-quality placed buildings there are marked
for upgrade so construction bots — or the hub — swap them out.

The architecture in one line: *no entity events and, except for the two
ledgers, no per-entity state — a round-robin, budgeted scan pass reads each
logistic network and space platform fresh and orders upgrades on the spot.*
`README.md` covers player-facing intent and behavior.

## Design invariants (read before changing core behavior)

- **The world is the only source of truth.** Nothing per-entity is stored except
  two ledgers, each recording only facts the world cannot answer — the order
  ledger: that a mark is ours and when we placed it; the platform wait ledger:
  when a starved target was first seen waiting. Facts that can never go stale.
  Each visit reads reality fresh (contents, roboport cells or the hub, the
  entities inside them) and issues orders directly; marked entities are
  recognized by asking the entity itself (`to_be_upgraded()`).
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
  The platform wait ledger (`storage.platform_wait_ledger`, swept by the same
  between-rounds mechanism) is *not* a second ownership registry — it is a
  clock table with no ownership meaning, answering only "since when has this
  target been waiting." Losing it restarts clocks, which only ever means
  waiting longer — the conservative direction. One mechanism, two tables: the
  table answers "what does membership mean."
- **A space platform is its own network.** Platforms have no logistic network
  and no bots — the hub auto-builds ghosts, upgrades, and module requests from
  its own inventory. Under `manage-space-platforms`, each platform is visited
  like a network: supply is the hub inventory (`hub_main`; cargo bays extend
  it, `hub_trash` is items leaving and excluded), coverage is one
  whole-surface scan (platforms are small and bounded), and orders are
  uncapped — there are no bots to meter, so only-order-against-stock is the
  only bound. Platform slots carry only the force's platform index — the
  platform is re-fetched at entry, never stored.
- **Two views of platform supply, deliberately not merged.** Spendable stock
  (hub contents, reserve subtracted) is the only thing orders are placed
  against. Never order against an inbound or requested item: an upgrade order
  whose item is absent from the hub blocks the platform's *entire* serial
  construction queue (community-reported, 2.0.72 dev-confirmed), so
  only-order-against-stock is safety-critical on platforms, with
  `order-expiry-seconds` as the queue-block escape hatch. Pending fulfillment
  (`targeted_items_deliver`, outstanding request filters) is only ever a
  reason to *wait* before retargeting, never to order.
- **Platform provisioning waits for deliveries.** Items can be on order from
  the planet below or another platform, and a naive retarget would orphan the
  delivery the player is waiting on. The three retargeting arms (ghosts,
  non-ledgered marks, module requests) run the wait rules on platforms, in
  order: target inbound (`targeted_items_deliver`) → leave alone; in transit
  (`space_location == nil`, deliveries impossible) → act immediately, a
  downgrade now beats a hole in the defenses; a request possibly in play (any
  filter on the item — matching is deliberately coarse — or the hub's
  auto-request on) → retarget only after
  `space-platform-delivery-wait-seconds` on the wait-ledger clock; nothing
  requested and auto-request off → act immediately. The clock starts the
  first time the target is seen starved — even with nothing aboard to
  retarget to, so stock arriving after the wait acts at once — and resets
  when the observed target stops matching the recorded one. A request only
  starts the clock, never vetoes retargeting forever — the timeout is the
  stale-request handling. Our own orders never wait (placed only against
  spendable stock, ledgered, expiring normally). Planet networks are
  untouched by all of this.
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
- **Orders are capped by bot headroom.** Each network's per-visit order budget
  is `available_construction_robots`, read fresh at entry — busy bots
  (including ones flying our orders) self-exclude, so the fresh read is the whole
  cap. A stale count only delays marks until the next visit. Platforms are
  exempt: no bots, no cap — the budget is infinite and spendable stock alone
  bounds orders there.

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
  default on, snapshotted at visit entry. A toggle gates only the acting arm of
  its behavior; demand accounting always runs, so enabled behaviors never
  over-order against stock a disabled one's marks or ghosts will consume.
  A fourth toggle, `manage-space-platforms` (default on), gates platform visits
  entirely — platforms are disjoint from planet networks, so skipping them has
  no cross-contamination effect on demand accounting.
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

## API notes

Verified API facts and the in-game verification backlog live in
`docs/api-notes.md`. Consult it before touching an API call; don't re-derive a
fact recorded there, and move newly verified items from its backlog into its
verified list.

## Localization

Only edit `locale/en/locale.cfg` by hand; other languages are managed separately.
