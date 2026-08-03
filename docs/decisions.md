# Decision log

Historical record of deliberate design decisions, with the rationale that no
longer needs to live in `CLAUDE.md`. Consult a specific entry when a change
touches its subject; nothing here needs routine reading.

## 2026-07 — Per-entity state removed (candidate index, order ledger)

The original architecture kept an event-driven candidate index
(`storage.candidates`) with cached positions, plus an order ledger
(`storage.ledger`) with timestamps, expiry, and a rotating position-refresh
slice. Commit 08091a2 replaced it all with the stateless scan pass. The index
and ledger were caches of world state that could only go stale, and every
staleness mode needed its own repair machinery (adoption rescans, expiry
timeouts, position refresh); reading the world directly deletes that
machinery and its bug surface. The old shape survives in git history and the
reference mod — do not reintroduce it.

## 2026-07 — No mark cancellation, and its accepted consequences (superseded)

*Superseded 2026-07-29 by the order-ledger entry below: expiry-based
cancellation of our own marks was added for 1.1.0. The no-cancel-cooldown and
no-runtime-state-restore consequences still stand.*

Without a ledger we could not tell our marks from a player's, and cancelling
a player's mark is off-limits — so no mark was ever cancelled. Accepted
consequences, deliberate — do not "fix" them:

- **No order expiry.** A starved mark stays until a player clears it or
  supply reappears.
- **No cancel cooldown.** A player-cancelled mark gets re-marked on a later
  round while supply persists.
- **No runtime-state restore.** Our upgrades behave exactly like
  player-ordered native upgrades.

## 2026-07-29 — Order ledger reintroduced for expiry (supersedes no-cancellation)

A snapshot-based order can lose its supply moments after placement (biter
damage dispatching rebuild bots, a player upgrade pass draining stock), and
the starved mark then squats on the demand accounting and the player's alert
list until supply happens to return. The fix is a minimal ledger:
`storage.order_ledger`, `unit_number → {entity, order_tick, target_quality}`,
recording only that a mark is ours and when we placed it. Those facts never
go stale, so this is not the retired per-entity state, and losing it degrades
gracefully — orphaned marks simply never expire, the old accepted behavior.
A ledger miss means hands off, and an entity re-marked to a different target
than we ordered is dropped from the ledger on sight.

Cancellation requires expired **and** target-out-of-stock, never expiry
alone: cancelling a stocked-but-queued order would just churn. An order whose
item a bot already carries is invisible to the supply snapshot; the generous
default expiry (300 s) keeps such mid-flight cancels rare, and each one
self-corrects (the bot returns the item, the next round re-orders). After a
genuine starvation cancel there is no re-order loop — no supply means no
candidate.

Orphaned entries (entity destroyed or replaced by the completed upgrade — a
new unit number either way) are pruned by a budgeted `next()`-cursor sweep
between rounds. No destruction events: the sweep is housekeeping, not
correctness — a stale entry can at worst match a mark we would place
ourselves — so eventual pruning suffices and a mid-sweep save/load reordering
the hash walk is harmless. Marks in networks that lost bot coverage sit inert
and expire on the first visit after coverage returns.

## 2026-07-29 — Pass runs every tick, with uniform budget steps

`on_nth_tick(10)` with a 10× budget delivered the same average throughput in
bursts, so the pass runs every tick with `entities-per-tick` (default 1) —
the smallest chunks, the most consistent cost. Budget steps are uniform, not
weighted: there are no profiling numbers to ground a weight in, the budget
setting already scales all phases together, and the scan phase bounds the
ledger sweep anyway (every ledgered entity is also examined every round).

## 2026-07 — No supply-based early exit in the scan

Every network with bot headroom gets its cells scanned, whatever its
contents. Supply-less networks are rare and act as natural pacing; unfiltered
contents rows are harmless (nothing looks up items that place no entity), and
duplicate entities across overlapping cells are harmless (once marked, later
encounters take the demand-accounting path). Do not reintroduce the shortcut.

## 2026-07 — No exclusion machinery

No mod lists, surface filters, or Factorissimo integration. Bots perform the
upgrades natively, so entities other mods manage are handled fine. The
reference mod's exclusion machinery predates this decision — do not copy it
back.

## 2026-07 — Candidacy derived from prototypes

No per-entity-type enable settings and no hand-maintained type list.
`build_and_store_config` derives candidacy from prototypes (has a placing
item, not flagged `not-upgradable`) — belts and pipes included.

## 2026-07 — Hidden-quality machinery removed

The old skip/sticky startup settings are gone. Hidden qualities come from
other mods, and other-mod support waits until the core is proven. Every tier
on the normal chain is treated alike.

## 2026-07 — Ghost provisioning always on, no toggle

A ghost whose exact quality is stocked is left to the bots (counted as
demand); otherwise it is retargeted to the best stocked tier, even a lower
one.

*Superseded 2026-07 by the behavior toggles below: the retarget arm now sits
behind `manage-ghosts` (default on); the demand accounting is still always
on.*

## 2026-07 — Module provisioning quality-only, always on

Never change which module prototype sits in or is requested for a slot, only
its quality. Installed modules are only ever upgraded (a player chose them);
unfulfillable *requests* retarget in either direction — a downgrade beats an
empty slot. Built entities only; ghost module slots are out of scope.

*Amended 2026-07: "always on" became "under `manage-factory`" with the
behavior toggles below; quality-only is unchanged.*

## 2026-07 — Three behavior toggles, acting arms only

`manage-factory`, `manage-ghosts`, and `manage-upgrade-requests` are
runtime-global bools, default on, snapshotted at network entry (a mid-visit
change applies from the next network). `manage-` is a shared verb, not a mod
prefix. Crucially, a toggle gates only the *acting* arm of its behavior:
demand accounting always runs, because a stocked ghost or pending proxy
consumes bots and supply whether or not we may retarget it, and skipping the
count would make the enabled behaviors over-order. When all three are off,
`enter_network` skips the network outright. No per-entity-type toggles — that
remains a retired alternative.

## 2026-07 — Upgrade-request provisioning is quality-only and ledger-free

A starved non-ledgered mark (a player's, or another mod's) retargets to the
best stocked tier of its *target* item — the target prototype's placing item,
so a cross-prototype mark (burner inserter → fast inserter) resolves through
what the mark asks for, not what the entity is. Quality only: the chosen
prototype is sacred, mirroring module provisioning. The mark is deliberately
not adopted into the ledger — it stays the player's, so expiry can never
cancel it — and the original quality is not remembered: once swapped, the
entity chases best supply, ghost-provisioning style. If nothing is stocked
the mark sits untouched with the native missing-material alert. This refines,
not breaks, "only ledgered marks are ever cancelled": retargeting is not
cancelling.

## 2026-07 — No PickerDollies/teleport-mod event integration

Since the per-entity state removal, no positions are cached anywhere and
every round scans fresh, so untracked teleports cannot go stale. Do not
resubscribe to dolly events, and do not add a position cache that would make
them relevant again.

## 2026-07 — No test suite

Validation is luacheck via `./validate.sh`, nothing more. Factorio runtime
behavior cannot be meaningfully unit-tested outside the game; in-game
verification plus the "still unverified" list in `docs/api-notes.md` is the
process.

## 2026-08-01 — The order ledger reframed as a cancellation license

Upgrade-request provisioning made "a ledger miss means hands off" imprecise:
the mod now retargets non-ledgered marks, so absence stopped meaning
untouchable. Rather than patch the rule with exceptions, the invariant is
restated from what it protects: **membership in the order ledger is a
cancellation license**. Cancellation and expiry require membership;
everything else (demand accounting, quality retargeting) is ownership-blind
and reads the world. Absence means *never cancelled*, not *never touched*. A
rewording, not a behavior change — the code was already exactly this.

The framing also settles plan-005's data-model question: the platform wait
ledger is a clock table, not a second ownership registry. The two tables
share one entry shape (`{entity, order_tick, target_name, target_quality}` —
the target fields let a cross-prototype re-mark reset the wait clock) and one
budgeted sweep mechanism, but stay separate: merging would turn the
structurally-enforced membership fact into a per-entry field check at every
call site, and a row-per-managed-entity table with status columns is the
retired per-entity state's shape.

## 2026-08-01 — Space platform support: deliveries gate retargeting (plan-005)

Platforms map cleanly onto the existing engine (platform = network, hub
inventory = supply, one whole-surface scan = coverage, hub = builder). The
one genuinely new concern: items can be *on order* from the planet below or,
in 2.1, another platform, and a naive "out of stock → retarget now" would
strand the delivery a player is waiting minutes for. Hence the delivery-wait
rules (listed in `CLAUDE.md`) — platforms only, retargeting arms only. The
reasoning behind each:

- **Inbound wins outright:** a target in `targeted_items_deliver` is
  physically en route (rockets and 2.1 platform-to-platform pods both arrive
  as pods, so one member covers both); retargeting would orphan real cargo.
- **In transit skips the wait:** with `space_location == nil` nothing can
  arrive, and the motivating case is turrets destroyed mid-flight — a
  downgrade now beats a hole in the defenses for the rest of the trip.
- **A request only starts a clock, never vetoes:** anything stronger would
  let a stale request veto retargeting forever; the timeout *is* the
  stale-request handling. The hub's auto-request being on counts as a
  request because it can lag a fresh ghost and (per an unresolved 2.1.7
  report) may never populate for retargeted ghosts. Filter matching ignores
  quality and count deliberately: a false match only delays acting by the
  timeout — the conservative direction — and exactness isn't worth its
  weight.
- **The clock starts on first starvation,** even with nothing aboard to
  retarget to; starting it only once an alternative tier shows up would make
  the player wait the full delay *after* stock arrives, exactly backwards.
  An elapsed clock that couldn't act stays elapsed, so stock arriving later
  is acted on at once.

Our own orders skip the wait: placed only against confirmed hub stock,
ledgered, and expired via `order-expiry-seconds` — which on platforms doubles
as the escape hatch for the dev-confirmed 2.0.72 behavior where an
unfulfillable order blocks the hub's entire serial construction queue. That
bug is why only-order-against-stock is safety-critical on platforms rather
than merely tidy, and why spendable stock and pending fulfillment are never
merged. A starved order can still wedge the queue for up to the full expiry;
platform-heavy saves may want a lower `order-expiry-seconds` until in-game
verification suggests a platform-specific one.

Platform orders are uncapped because the network cap meters a scarce shared
executor (bots) that platforms lack; every order is already placed against
confirmed stock, so stock is the natural and sufficient bound. In the code,
the platform snapshot carries an infinite order budget in the field bot
headroom feeds on networks, keeping the shared arithmetic untouched.

Player marks get the wait too — extra caution relative to planets, where a
starved mark is retargeted on sight (bots ignore unfulfillable marks, and
stock is a bot-trip away). On a platform the same mark is more likely a
deliberate "waiting for the rocket" order and may itself have induced an
auto-request. It stays unledgered and uncancellable either way; its
wait-ledger entry is a clock, not a claim.

Module-request proxies run one clock per proxy: target recorded from the
first starved row, all starved rows retargeted together when it elapses. A
per-row clock would need a composite key and buys nothing — simultaneous
starved rows on one proxy are rare, and the cost of imprecision is only
waiting longer.
