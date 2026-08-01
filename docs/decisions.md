# Decision log

Historical record of deliberate design decisions, with the context and rationale
that no longer needs to live in `CLAUDE.md`. Consult a specific entry when a
change touches its subject; nothing here needs to be read routinely.

## 2026-07 — Per-entity state removed (candidate index, order ledger)

The original architecture maintained an event-driven candidate index
(`storage.candidates`) with cached positions plus an order ledger
(`storage.ledger`) with timestamps, expiry, and a rotating position-refresh
slice. Commit 08091a2 replaced all of it with a stateless scan-based pass: each
network visit reads reality fresh (contents, roboport cells, the entities inside
them) and issues orders directly, recognizing marked entities by asking the
entity itself (`to_be_upgraded()`).

Rationale: the index and ledger were caches of world state that could only go
stale, and every staleness mode needed its own repair machinery (adoption
rescans, expiry timeouts, position refresh). The scan pass reads truth directly,
so that machinery — and its bug surface — disappears. The reference mod and this
repo's git history both contain the old shape; do not reintroduce it.

## 2026-07 — No mark cancellation, and its accepted consequences (superseded)

*Superseded 2026-07-29 by the order-ledger entry below: expiry-based
cancellation of our own marks was added for 1.1.0. The no-cancel-cooldown and
no-runtime-state-restore consequences still stand.*

Without a ledger we cannot distinguish our marks from a player's, and cancelling
a player's mark is off-limits — so no mark is ever cancelled. Consequences,
accepted deliberately; do not "fix" them:

- **No order expiry.** A starved mark stays until a player clears it or supply
  reappears.
- **No cancel cooldown.** A player-cancelled mark gets re-marked on a later
  round while supply persists.
- **No runtime-state restore.** Our upgrades behave exactly like player-ordered
  native upgrades.

## 2026-07-29 — Order ledger reintroduced for expiry (supersedes no-cancellation)

Starved marks turned out to matter in practice: a snapshot-based order can lose
its supply moments after it is placed (biter damage dispatching rebuild bots,
player upgrade passes draining stock), and a starved mark then squats on the
demand accounting and the player's alert list until supply happens to return.
The fix is a minimal order ledger — `storage.order_ledger`, `unit_number →
{entity, order_tick, target_quality}` — recording only the two facts the world
cannot answer: that a mark is ours, and when we placed it.

This is not the retired per-entity state coming back. That ledger cached world
facts (positions, candidacy) that could go stale and needed repair machinery;
this one's facts never go stale, and losing it degrades gracefully — orphaned
marks simply never expire, which is exactly the old accepted behavior. Player
marks remain untouchable (a ledger miss means hands off), and an entity
re-marked to a different target than we ordered is dropped from the ledger on
sight.

Cancellation requires expired **and** target-out-of-stock, never expiry alone:
a stocked-but-queued order is the bots' business, and cancelling it would just
churn (re-ordered next round). Orders whose item a bot is already carrying are
invisible to the supply snapshot; the generous default expiry (300 s) keeps
mid-flight cancels rare, and each one self-corrects — the bot returns the item,
the next round re-orders, the clock resets. After a genuine starvation cancel
there is no re-order loop: no supply means the entity is not a candidate.

Orphaned entries (entity destroyed, or replaced by the completed upgrade — a
new unit number either way) are pruned by a budgeted sweep between rounds: a
`next()`-cursor walk of the ledger in `storage`, one entry per budget step,
overlapping the round-delay rest window. No destruction events — the sweep is
housekeeping, not correctness (a stale entry can at worst match a mark
identical to one we would place ourselves), so eventual pruning suffices and a
mid-sweep save/load reordering the hash walk is harmless. Marks in networks
that lost bot coverage are never encountered; they sit inert and expire on the
first visit after coverage returns.

## 2026-07-29 — Pass runs every tick, with uniform budget steps

`on_nth_tick(10)` with a 10× budget delivered the same average throughput in
bursts; the pass now runs every tick with `entities-per-tick` (default 1) —
the smallest chunks and the most consistent cost. Budget steps are uniform:
one network entry, one entity examine, one cell scan, or one ledger check each
cost one step. No weighted costs — there are no profiling numbers to ground a
weight in, the budget setting already scales all phases together, and the
ledger sweep is bounded above by the scan phase anyway (every ledgered entity
is also examined every round, alongside all the unmarked ones).

## 2026-07 — No supply-based early exit in the scan

Every network with bot headroom gets its cells scanned, whatever its contents.
Networks without buildable stock are rare in practice and act as natural pacing
between the ones that matter. The supply snapshot keeps every on-chain contents
row unfiltered; rows for items that place no entity are harmless because nothing
ever looks them up. Duplicate entities across overlapping cells are harmless —
once marked, later encounters take the demand-accounting path. Don't reintroduce
a "skip networks without candidate supply" shortcut.

## 2026-07 — No exclusion machinery

No mod lists, surface filters, or Factorissimo integration. Bots perform the
upgrades natively, so entities other mods manage are handled fine. The reference
mod's exclusion machinery predates this decision — don't copy it back.

## 2026-07 — Candidacy derived from prototypes

No per-entity-type enable settings and no hand-maintained type list. Candidacy
is derived from prototypes in `build_and_store_config` (has a placing item, not
flagged `not-upgradable`) — belts and pipes included.

## 2026-07 — Hidden-quality machinery removed

The old skip/sticky startup settings are gone. Hidden qualities come from other
mods, and other-mod support waits until the core is proven. Every tier on the
normal chain is treated alike.

## 2026-07 — Ghost provisioning always on, no toggle

A ghost whose exact quality is stocked is left to the bots (counted as demand);
otherwise it is retargeted to the best stocked tier, even a lower one.

*Superseded 2026-07 by the behavior toggles below: the retarget arm now sits
behind `manage-ghosts` (default on); the demand accounting is still always on.*

## 2026-07 — Module provisioning quality-only, always on

Never change which module prototype sits in or is requested for a slot, only its
quality. Installed modules are only ever upgraded (a player chose them);
unfulfillable *requests* are retargeted in either direction, a downgrade beating
an empty slot. Built entities only — ghost module slots are out of scope.

*Amended 2026-07: "always on" became "under `manage-factory`" with the behavior
toggles below; quality-only is unchanged.*

## 2026-07 — Three behavior toggles, acting arms only

The three behaviors each sit behind a runtime-global bool setting, default on:
`manage-factory` (upgrades of placed buildings and their installed modules,
including module-request retargets), `manage-ghosts` (ghost retargets), and
`manage-upgrade-requests` (starved non-ledgered marks retargeted). `manage-` is
a shared verb naming the behavior, not a mod prefix. The flags are snapshotted
at network entry like everything else; a mid-visit change applies from the next
network. Crucially a toggle gates only the *acting* arm of its behavior —
demand accounting always runs, because a stocked ghost or pending proxy
consumes bots and supply whether or not we may retarget it, and skipping the
count would make the enabled behaviors over-order. When all three are off,
`enter_network` skips the network outright. No per-entity-type toggles — that
remains a retired alternative.

## 2026-07 — Upgrade-request provisioning is quality-only and ledger-free

A non-ledgered mark (a player's, or another mod's) whose target quality is out
of stock is retargeted to the best stocked tier of its *target* item — the
target prototype's placing item, so cross-prototype marks (burner inserter →
fast inserter) resolve through what the mark asks for, not what the entity is.
Quality only: the chosen prototype is sacred, mirroring module provisioning.
The retargeted mark is deliberately not adopted into the ledger: it stays the
player's, so expiry can never cancel it, and the original quality is not
remembered (ghost-provisioning philosophy — once swapped, the entity chases
best supply). If stock drains again a later round just retargets again; if
nothing is stocked the mark sits untouched with the native missing-material
alert. This refines, not breaks, "only ledgered marks are ever cancelled":
retargeting is not cancelling.

## 2026-07 — No PickerDollies/teleport-mod event integration

Originally: cached candidate positions were hints only, tolerated by a mark-time
re-read plus a rotating refresh slice. Since the per-entity state removal the
question is moot — no positions are cached anywhere, every round scans entities
fresh, so untracked teleports cannot go stale. Don't resubscribe to dolly
events, and don't add a position cache that would make them relevant again.

## 2026-07 — No test suite

Validation is luacheck via `./validate.sh`, nothing more. Factorio runtime
behavior can't be meaningfully unit-tested outside the game; in-game
verification plus the "still unverified" list in `docs/api-notes.md` is the
process.

## 2026-08-01 — The order ledger reframed as a cancellation license

Upgrade-request provisioning made "a ledger miss means hands off" imprecise:
the mod now retargets non-ledgered marks (quality only), so absence stopped
meaning untouchable. Rather than patch the rule with exceptions ("retargeting
is not cancelling"), the invariant is restated from what it protects:
**membership in the order ledger is a cancellation license**. The ledger
records that a mark is ours and when we placed it; cancellation and expiry
require membership. Everything else — demand accounting, quality retargeting —
is ownership-blind and reads the world. Absence means *never cancelled*, not
*never touched*. This is a rewording, not a behavior change; the code was
already exactly this.

The framing also settles the data-model question raised by plan-005's
platform wait ledger. That table is not a second ownership registry — it is a
clock table recording a different world-unanswerable fact (when a target was
first seen starved), with no ownership meaning. The two tables share one
entry shape (`{entity, order_tick, target_name, target_quality}` — the
target fields matter because upgrade marks can be cross-prototype, and a
player re-marking to a different prototype at the same quality must reset the
wait clock) and one budgeted sweep mechanism, but stay separate: merging
them would turn the structurally-enforced membership fact into a per-entry
field check at every call site, and a row-per-managed-entity table with
status columns is the retired per-entity state's shape. One mechanism, one
entry shape, two tables — the table answers "what does membership mean."

## 2026-08-01 — Space platform support: deliveries gate retargeting (plan-005)

Platforms map cleanly onto the existing engine — the platform is the network,
the hub inventory is the supply, one whole-surface scan is the coverage, the
hub is the builder — but they introduce one genuinely new concern: items can
be *on order* from the planet below (or, in 2.1, another platform). A common
player pattern is pasting ghosts or marks for items the platform doesn't
stock and waiting minutes for the rocket; a naive "target out of stock →
retarget now" would silently strand that delivery. Hence the delivery-wait
rules, applied on platforms only, by the three retargeting arms only:

- **Inbound wins outright.** A target present in `targeted_items_deliver` is
  physically en route (rocket or cargo pod — both arrive as pods, one member
  covers both); retargeting it would orphan real cargo. Left alone, no clock.
- **In transit skips the wait.** With no planet below and no neighbors
  (`space_location == nil`) nothing can arrive, and the motivating case is
  turrets destroyed mid-flight: a downgrade now beats a hole in the defenses
  for the rest of the trip. Act immediately.
- **A request only starts a clock, never vetoes.** Any request filter on the
  item, or the hub's auto-request system being on at all (it can lag a fresh
  ghost, and per the unresolved 2.1.7 report may never populate for
  retargeted ghosts), starts the `space-platform-delivery-wait-seconds` clock
  in the wait ledger. Filter matching is deliberately coarse — quality and
  count are ignored — because a false match only delays acting by the
  timeout, the conservative direction, and the exactness machinery isn't
  worth its weight. Anything stronger than a clock — treating "requested" as
  "not starved" — would let a stale request veto retargeting forever, the
  opposite of the setting's purpose; the timeout *is* the stale-request
  handling. The clock starts the first time the target is seen starved, even
  when nothing is aboard to retarget to — starting it only once an
  alternative tier shows up would make the player wait the full delay *after*
  stock arrives, exactly backwards. It resets when the observed target stops
  matching the recorded one (cross-prototype re-marks included), clears when
  the target is seen stocked or inbound, and an elapsed clock that couldn't
  act (nothing stocked to retarget to) stays elapsed so stock arriving later
  is acted on at once.
- **Nothing requested, auto-request off:** nothing is coming and nothing will
  be. Act immediately.

Why our own orders skip the wait: `examine_building` orders only against
confirmed hub stock, is ledgered, and expires through `order-expiry-seconds`
— which on platforms doubles as the escape hatch for the dev-confirmed 2.0.72
behavior where an unfulfillable upgrade order blocks the hub's entire serial
construction queue. That bug is also why only-order-against-stock (never
against inbound or requested items) is safety-critical on platforms rather
than merely tidy, and why the two views of supply — spendable stock vs
pending fulfillment — are deliberately never merged. Note the window: a
starved order can wedge the queue for up to the full expiry; platform-heavy
saves may want a lower `order-expiry-seconds` until in-game verification
suggests a platform-specific expiry.

Why platform orders are uncapped: the network cap exists because bots are a
scarce shared executor — headroom meters how much work the network can absorb.
A platform has no bots; the hub builds serially from its own inventory, and
every order is already placed against confirmed stock, so spendable stock is
the natural and sufficient bound. An artificial per-visit constant would only
slow convergence for nothing. In the code the platform snapshot carries an
infinite order budget (the field bot headroom feeds on networks), keeping the
shared arithmetic untouched.

Why player marks get the wait too (extra caution relative to planets): on a
planet a starved player mark is retargeted on sight, because bots simply
ignore unfulfillable marks and stock is usually a bot-trip away. On a
platform the same mark is more likely to be a deliberate "waiting for the
rocket" order, deliveries take minutes, and the mark may itself have induced
an auto-request — so the wait rules run first. The mark stays unledgered and
uncancellable either way; the wait ledger's entry for it is a clock, not a
claim (see the cancellation-license entry above).

Module-request proxies run the wait at proxy granularity: one clock keyed by
the proxy, its target recorded from the first starved row, all starved rows
retargeted together when it elapses. A per-row clock would need a composite
key and buys nothing — multiple simultaneously-starved rows on one proxy are
rare, and the cost of imprecision is only waiting longer.
