# Decision log

Historical record of deliberate design decisions, with the context and
rationale that no longer needs to live in `CLAUDE.md`. Consult a specific
entry when a change touches its subject. Nothing here needs routine reading.

## 2026-07 — Per-entity state removed (candidate index, order ledger)

- The original architecture kept an event-driven candidate index
  (`storage.candidates`) with cached positions, plus an order ledger
  (`storage.ledger`) with timestamps, expiry, and a rotating
  position-refresh slice.
- Commit 08091a2 replaced all of it with a stateless scan-based pass. Each
  network visit reads reality fresh (contents, roboport cells, the entities
  inside them) and issues orders directly. It recognizes marked entities by
  asking the entity itself (`to_be_upgraded()`).
- Rationale: the index and ledger were caches of world state that could only
  go stale. Every staleness mode needed its own repair machinery (adoption
  rescans, expiry timeouts, position refresh). The scan pass reads truth
  directly, so that machinery — and its bug surface — disappears.
- The reference mod and this repo's git history both contain the old shape.
  Do not reintroduce it.

## 2026-07 — No mark cancellation, and its accepted consequences (superseded)

*Superseded 2026-07-29 by the order-ledger entry below: expiry-based
cancellation of our own marks was added for 1.1.0. The no-cancel-cooldown
and no-runtime-state-restore consequences still stand.*

- Without a ledger, we cannot distinguish our marks from a player's. To
  cancel a player's mark is off-limits. So no mark was ever cancelled.
- Consequences, accepted deliberately — do not "fix" them:
  - **No order expiry.** A starved mark stays until a player clears it or
    supply reappears.
  - **No cancel cooldown.** While supply persists, a later round re-marks an
    entity whose mark a player cancelled.
  - **No runtime-state restore.** Our upgrades behave exactly like
    player-ordered native upgrades.

## 2026-07-29 — Order ledger reintroduced for expiry (supersedes no-cancellation)

- Starved marks turned out to matter in practice. A snapshot-based order can
  lose its supply moments after it is placed: biter damage dispatches
  rebuild bots, or a player upgrade pass drains the stock. The starved mark
  then squats on the demand accounting and the player's alert list until
  supply happens to return.
- The fix is a minimal order ledger: `storage.order_ledger`, `unit_number →
  {entity, order_tick, target_quality}`. It records only the two facts the
  world cannot answer: the mark is ours, and when we placed it.
- This is not the retired per-entity state coming back:
  - That ledger cached world facts (positions, candidacy) that could go
    stale and needed repair machinery.
  - This ledger's facts never go stale. Loss degrades gracefully: orphaned
    marks simply never expire, which is exactly the old accepted behavior.
- Player marks remain untouchable: a ledger miss means hands off. When an
  entity is re-marked to a different target than we ordered, drop it from
  the ledger on sight.
- Cancellation requires expired **and** target-out-of-stock, never expiry
  alone. A stocked-but-queued order is the bots' business. To cancel it
  would just churn: the next round re-orders it.
- An order whose item a bot already carries is invisible to the supply
  snapshot. The generous default expiry (300 s) keeps such mid-flight
  cancels rare, and each one self-corrects: the bot returns the item, the
  next round re-orders, the clock resets.
- After a genuine starvation cancel there is no re-order loop: no supply
  means the entity is not a candidate.
- A budgeted sweep between rounds prunes orphaned entries (entity destroyed,
  or replaced by the completed upgrade — a new unit number either way). The
  sweep is a `next()`-cursor walk of the ledger in `storage`, one entry per
  budget step, in the round-delay rest window.
- No destruction events. The sweep is housekeeping, not correctness: a stale
  entry can at worst match a mark identical to one we would place ourselves.
  Eventual pruning suffices, and a mid-sweep save/load that reorders the
  hash walk is harmless.
- The sweep never encounters marks in networks that lost bot coverage. They
  sit inert and expire on the first visit after coverage returns.

## 2026-07-29 — Pass runs every tick, with uniform budget steps

- `on_nth_tick(10)` with a 10× budget delivered the same average throughput,
  in bursts. The pass now runs every tick with `entities-per-tick` (default
  1): the smallest chunks and the most consistent cost.
- Budget steps are uniform. One network entry, one entity examine, one cell
  scan, or one ledger check each cost one step.
- No weighted costs, for three reasons:
  - No profiling numbers exist to ground a weight in.
  - The budget setting already scales all phases together.
  - The scan phase bounds the ledger sweep from above anyway: every round
    examines every ledgered entity, alongside all the unmarked ones.

## 2026-07 — No supply-based early exit in the scan

- Every network with bot headroom gets its cells scanned, whatever its
  contents.
- Networks without buildable stock are rare in practice. They act as natural
  pacing between the networks that matter.
- The supply snapshot keeps every contents row unfiltered. Rows for items
  that place no entity are harmless: nothing ever looks them up.
- Duplicate entities across overlapping cells are harmless: once an entity
  is marked, later encounters take the demand-accounting path.
- Do not reintroduce a "skip networks without candidate supply" shortcut.

## 2026-07 — No exclusion machinery

- No mod lists, no surface filters, no Factorissimo integration.
- Bots perform the upgrades natively, so entities other mods manage are
  handled fine.
- The reference mod's exclusion machinery predates this decision. Do not
  copy it back.

## 2026-07 — Candidacy derived from prototypes

- No per-entity-type enable settings, and no hand-maintained type list.
- `build_and_store_config` derives candidacy from prototypes: the entity has
  a placing item and is not flagged `not-upgradable`. Belts and pipes are
  included.

## 2026-07 — Hidden-quality machinery removed

- The old skip/sticky startup settings are gone.
- Hidden qualities come from other mods, and other-mod support waits until
  the core is proven.
- Every tier on the normal chain is treated alike.

## 2026-07 — Ghost provisioning always on, no toggle

- When a ghost's exact quality is stocked, leave it to the bots and count it
  as demand.
- Otherwise, retarget it to the best stocked tier, even a lower one.

*Superseded 2026-07 by the behavior toggles below: the retarget arm now sits
behind `manage-ghosts` (default on). The demand accounting is still always
on.*

## 2026-07 — Module provisioning quality-only, always on

- Never change which module prototype sits in or is requested for a slot;
  change only its quality.
- Installed modules are only ever upgraded: a player chose them.
- Unfulfillable *requests* are retargeted in either direction: a downgrade
  beats an empty slot.
- Built entities only. Ghost module slots are out of scope.

*Amended 2026-07: "always on" became "under `manage-factory`" with the
behavior toggles below. Quality-only is unchanged.*

## 2026-07 — Three behavior toggles, acting arms only

- The three behaviors each sit behind a runtime-global bool setting, default
  on:
  - `manage-factory`: upgrades of placed buildings and their installed
    modules, module-request retargets included.
  - `manage-ghosts`: ghost retargets.
  - `manage-upgrade-requests`: retargets of starved non-ledgered marks.
- `manage-` is a shared verb that names the behavior, not a mod prefix.
- The flags are snapshotted at network entry, like everything else. A
  mid-visit change applies from the next network.
- Crucially, a toggle gates only the *acting* arm of its behavior. Demand
  accounting always runs: a stocked ghost or pending proxy consumes bots and
  supply whether or not we may retarget it. To skip the count would make the
  enabled behaviors over-order.
- When all three are off, `enter_network` skips the network outright.
- No per-entity-type toggles. That remains a retired alternative.

## 2026-07 — Upgrade-request provisioning is quality-only and ledger-free

- When a non-ledgered mark's (a player's, or another mod's) target quality
  is out of stock, retarget it to the best stocked tier of its *target*
  item.
- "Target item" means the target prototype's placing item. So a
  cross-prototype mark (burner inserter → fast inserter) resolves through
  what the mark asks for, not what the entity is.
- Quality only: the chosen prototype is sacred. This mirrors module
  provisioning.
- Do not adopt the retargeted mark into the ledger. It stays the player's,
  so expiry can never cancel it. The original quality is not remembered —
  the ghost-provisioning philosophy: once swapped, the entity chases best
  supply.
- If stock drains again, a later round just retargets again. If nothing is
  stocked, the mark sits untouched with the native missing-material alert.
- This refines, not breaks, "only ledgered marks are ever cancelled": a
  retarget is not a cancel.

## 2026-07 — No PickerDollies/teleport-mod event integration

- Originally, cached candidate positions were hints only, tolerated by a
  mark-time re-read plus a rotating refresh slice.
- Since the per-entity state removal, the question is moot: no positions are
  cached anywhere, and every round scans entities fresh, so untracked
  teleports cannot go stale.
- Do not resubscribe to dolly events. Do not add a position cache that would
  make them relevant again.

## 2026-07 — No test suite

- Validation is luacheck via `./validate.sh`, nothing more.
- Factorio runtime behavior cannot be meaningfully unit-tested outside the
  game.
- The process is in-game verification plus the "still unverified" list in
  `docs/api-notes.md`.

## 2026-08-01 — The order ledger reframed as a cancellation license

- Upgrade-request provisioning made "a ledger miss means hands off"
  imprecise: the mod now retargets non-ledgered marks (quality only), so
  absence stopped meaning untouchable.
- Rather than patch the rule with exceptions ("a retarget is not a cancel"),
  the invariant is restated from what it protects: **membership in the order
  ledger is a cancellation license**.
  - The ledger records that a mark is ours and when we placed it.
  - Cancellation and expiry require membership.
  - Everything else — demand accounting, quality retargeting — is
    ownership-blind and reads the world.
  - Absence means *never cancelled*, not *never touched*.
- This is a rewording, not a behavior change. The code was already exactly
  this.
- The framing also settles the data-model question raised by plan-005's
  platform wait ledger:
  - That table is not a second ownership registry. It is a clock table with
    no ownership meaning. It records a different world-unanswerable fact:
    when a target was first seen starved.
  - The two tables share one entry shape (`{entity, order_tick, target_name,
    target_quality}`) and one budgeted sweep mechanism. The target fields
    matter because upgrade marks can be cross-prototype: a player re-mark to
    a different prototype at the same quality must reset the wait clock.
  - The tables stay separate. A merge would turn the structurally-enforced
    membership fact into a per-entry field check at every call site. And a
    row-per-managed-entity table with status columns is the retired
    per-entity state's shape.
  - One mechanism, one entry shape, two tables. The table answers "what does
    membership mean."

## 2026-08-01 — Space platform support: deliveries gate retargeting (plan-005)

- Platforms map cleanly onto the existing engine: the platform is the
  network, the hub inventory is the supply, one whole-surface scan is the
  coverage, the hub is the builder.
- Platforms introduce one genuinely new concern: items can be *on order*
  from the planet below or, in 2.1, another platform. A common player
  pattern is to paste ghosts or marks for items the platform doesn't stock
  and wait minutes for the rocket. A naive "target out of stock → retarget
  now" would silently strand that delivery.
- Hence the delivery-wait rules, applied on platforms only, by the three
  retargeting arms only:
  - **Inbound wins outright.** A target present in `targeted_items_deliver`
    is physically en route (rocket or cargo pod — both arrive as pods, one
    member covers both). To retarget it would orphan real cargo. Leave it
    alone, no clock.
  - **In transit skips the wait.** With no planet below and no neighbors
    (`space_location == nil`), nothing can arrive. The motivating case is
    turrets destroyed mid-flight: a downgrade now beats a hole in the
    defenses for the rest of the trip. Act immediately.
  - **A request only starts a clock, never vetoes.** Two conditions start
    the `space-platform-delivery-wait-seconds` clock in the wait ledger: any
    request filter on the item, or the hub's auto-request system on at all.
    (Auto-request can lag a fresh ghost, and per the unresolved 2.1.7 report
    it may never populate for retargeted ghosts.)
    - Filter matching is deliberately coarse: quality and count are ignored.
      A false match only delays acting by the timeout — the conservative
      direction — and the exactness machinery isn't worth its weight.
    - Anything stronger than a clock — treating "requested" as "not
      starved" — would let a stale request veto retargeting forever, the
      opposite of the setting's purpose. The timeout *is* the stale-request
      handling.
    - The clock starts the first time the target is seen starved, even when
      nothing is aboard to retarget to. To start it only once an alternative
      tier shows up would make the player wait the full delay *after* stock
      arrives — exactly backwards.
    - The clock resets when the observed target stops matching the recorded
      one (cross-prototype re-marks included). It clears when the target is
      seen stocked or inbound. An elapsed clock that couldn't act (nothing
      stocked to retarget to) stays elapsed, so stock that arrives later is
      acted on at once.
  - **Nothing requested, auto-request off:** nothing is coming and nothing
    will be. Act immediately.
- Why our own orders skip the wait: `examine_building` orders only against
  confirmed hub stock, is ledgered, and expires through
  `order-expiry-seconds`.
  - On platforms that expiry doubles as the escape hatch for the
    dev-confirmed 2.0.72 behavior: an unfulfillable upgrade order blocks the
    hub's entire serial construction queue.
  - That bug is also why only-order-against-stock (never against inbound or
    requested items) is safety-critical on platforms rather than merely
    tidy, and why the two views of supply — spendable stock vs pending
    fulfillment — are deliberately never merged.
  - Note the window: a starved order can wedge the queue for up to the full
    expiry. Platform-heavy saves may want a lower `order-expiry-seconds`
    until in-game verification suggests a platform-specific expiry.
- Why platform orders are uncapped:
  - The network cap exists because bots are a scarce shared executor:
    headroom meters how much work the network can absorb.
  - A platform has no bots. The hub builds serially from its own inventory,
    and every order is already placed against confirmed stock, so spendable
    stock is the natural and sufficient bound. An artificial per-visit
    constant would only slow convergence for nothing.
  - In the code, the platform snapshot carries an infinite order budget in
    the field bot headroom feeds on networks. The shared arithmetic stays
    untouched.
- Why player marks get the wait too (extra caution relative to planets):
  - On a planet, a starved player mark is retargeted on sight: bots simply
    ignore unfulfillable marks, and stock is usually a bot-trip away.
  - On a platform, the same mark is more likely a deliberate "waiting for
    the rocket" order, deliveries take minutes, and the mark may itself have
    induced an auto-request. So the wait rules run first.
  - The mark stays unledgered and uncancellable either way. The wait
    ledger's entry for it is a clock, not a claim (see the
    cancellation-license entry above).
- Module-request proxies run the wait at proxy granularity: one clock keyed
  by the proxy, its target recorded from the first starved row, all starved
  rows retargeted together when the clock elapses. A per-row clock would
  need a composite key and buys nothing: multiple simultaneously-starved
  rows on one proxy are rare, and the cost of imprecision is only waiting
  longer.
