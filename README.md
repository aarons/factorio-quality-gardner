# Quality Gardener

A Factorio 2.1 mod. When higher-quality versions of your buildings sit in a logistic
network, the lower-quality placed buildings in that network are marked for upgrade so
construction bots swap them out.

## How to use it

Drop spare higher-quality building items into the logistic network (from quality
recycling, asteroid reprocessing, or dedicated quality production) and let the bots
work. No manual upgrade-planner passes needed.

- **Direct to best.** Any building below the best quality on hand jumps straight
  to it — one bot trip, no intermediate items.
- **The cascade is free.** Upgrading a building returns its lower-quality item to
  storage, which can then lift an even worse building, and the upgraded building is
  itself a candidate for the next tier. Quality ripples through the base with no
  extra logic — over months of play a machine can walk normal → rare → legendary.

- **Ghosts get built with what's on hand.** Construction bots only fulfil a ghost
  from stock that exactly matches its quality — stamp a legendary blueprint with
  only common machines in storage and nothing is ever built. Quality Gardener steps
  in: if the exact quality is missing but any tier of the item is stocked, the ghost
  is re-ordered at the best available tier, even a lower one. Better a slow factory
  than no factory — and it self-heals: the downgraded building is an ordinary
  upgrade candidate, raised back up tier by tier as better stock appears.

- **Your upgrade orders get unstuck too.** An upgrade-planner order whose target
  quality is out of stock — including cross-type upgrades like burner inserter →
  fast inserter — would stall forever. Quality Gardener retargets it to the best
  stocked quality of the target item, even a lower one, so the swap happens.
  Only the quality is adjusted, never which building you asked for, and your
  orders are still never cancelled. Once swapped, the building is an ordinary
  candidate, raised back up as better stock appears.

- **Space platforms are gardened too.** A platform has no construction bots — the
  hub builds and upgrades directly from its own inventory — so Quality Gardener
  treats each platform as its own network, with the hub inventory (cargo bays
  included) as the supply. Buildings, ghosts, upgrade orders, and modules all get
  the same treatment as on a planet, and upgrades are only ever ordered against
  items actually aboard. The one platform-specific twist is deliveries: before
  adjusting a ghost or order whose quality isn't aboard, the gardener checks
  what's coming. An item already on its way up (rocket or cargo pod) is always
  left alone; one covered by an open request — including the hub's automatic
  "request missing construction materials" system — is given the delivery-wait
  setting (default 300 s) to arrive first. And a platform in transit never
  waits: a turret destroyed by asteroids is refilled immediately from whatever
  is on hand, because a downgrade now beats a hole in the defenses for the rest
  of the trip.

- **Modules are gardened too.** An installed module with a higher-quality version in
  storage gets swapped by the bots, the displaced module returning to storage — the
  same cascade as buildings. And a module request no bot can fill (the requested
  quality is out of stock) is retargeted to the best quality on hand, even a lower
  one — a filled slot now beats an empty one — then raised back up as better stock
  appears. Installed modules are only ever upgraded, never downgraded, and only the
  quality moves: the mod never changes which module you chose. The mod's own module
  orders get the order-expiry grace before any adjustment, so an order whose module
  is already riding a bot is left to complete rather than churned.

Everything placeable and upgradable is covered — assemblers down to belts, pipes, and
poles. Coverage is derived from prototypes (anything placed from an item that the game
allows upgrading), so modded buildings are included automatically. There are no
per-type toggles — but each of the three behaviors (factory upgrades, ghost
provisioning, upgrade-request provisioning) has its own map setting, all on by
default, so any combination can be switched off at runtime.

## Behavior details

- **Just like your own upgrade marks.** The mod's upgrades are ordinary native
  upgrade orders — bots transfer inventory, modules, and fuel exactly as they would
  for an upgrade-planner pass. Your marks are never cancelled: the mod only ever
  cancels orders it placed itself. (With Manage Upgrade Requests on, a starved
  mark of yours may have its quality retargeted — but the mark itself, and the
  building you chose, stay yours.)
- **Starved orders self-heal.** An order whose supply was taken out from under it —
  biters forced a rebuild, or your own upgrades used the stock — is cancelled once
  it has waited out the order-expiry setting with the item still out of stock, and
  the building becomes an ordinary candidate again. An order whose item is in stock
  but queued behind busy bots is left alone. Set the expiry to 0 to let starved
  orders pend (with the usual missing-material alert) until supply reappears.
- **Existing marks count as demand.** Anything already marked for upgrade — by you,
  the mod, or another mod — consumes the matching supply, so the same item is never
  promised twice.
- **Reserve.** Optionally keep N of each item-quality combination untouched in storage
  as a float for new construction.
- **Smooth, constant cost.** Networks are visited round-robin in small slices, with a
  rest between rounds while bots collect their items — never a burst scan or a lag
  spike.

## Settings

| Setting | Default | Notes |
|---|---|---|
| Manage factory | on | Upgrade placed buildings and their installed modules toward the best stocked quality |
| Manage ghosts | on | Retarget ghosts requesting an out-of-stock quality to the best quality on hand |
| Manage upgrade requests | on | Retarget your starved upgrade orders to the best stocked quality of their target item |
| Manage space platforms | on | Garden space platforms from the hub inventory; off = planets only |
| Entities per tick | 1 | Work budget per tick; raise for faster processing at the expense of UPS |
| Reserve per item | 0 | Spares kept untouched per item-quality |
| Round delay | 20 s | Rest between rounds so bots can pick up ordered items |
| Order expiry | 300 s | Grace for the mod's own starved orders: after this long out of stock, marks are cancelled and module orders become adjustable; 0 = never |
| Space platform delivery wait | 300 s | How long a platform ghost/order waits for a delivery before being adjusted; 0 = adjust immediately |

## Compatibility

Works with any quality mod — quality chains are walked via the prototype graph, never
hardcoded. Space Age is optional: without it there are no platforms and the platform
support is simply inert.

The mod keeps almost no state about your base — every round reads the world fresh,
so there is nothing to get out of sync. The exceptions are a small ledger of the
upgrade and module orders the mod itself placed, kept so that only its own marks
are ever expired and its fresh module orders are not churned (losing it is
harmless — those orders simply never expire), and on space platforms a table of
delivery-wait clocks (losing it just restarts the waits).
`/quality-gardener-init` resets the pass cursor and both ledgers if you ever want a
clean restart.

One consequence of statelessness: if you cancel a mark the mod made while the
higher-quality item is still in storage, the mod will re-mark it on a later round.
To keep a building at its quality permanently, remove the spare items from that
network (or use the reserve setting).
