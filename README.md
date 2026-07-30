# Quality Gardener

A Factorio 2.0 mod. When higher-quality versions of your buildings sit in a logistic
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

- **Modules are gardened too.** An installed module with a higher-quality version in
  storage gets swapped by the bots, the displaced module returning to storage — the
  same cascade as buildings. And a module request no bot can fill (the requested
  quality is out of stock) is retargeted to the best quality on hand, even a lower
  one — a filled slot now beats an empty one — then raised back up as better stock
  appears. Installed modules are only ever upgraded, never downgraded, and only the
  quality moves: the mod never changes which module you chose.

Everything placeable and upgradable is covered — assemblers down to belts, pipes, and
poles. Coverage is derived from prototypes (anything placed from an item that the game
allows upgrading), so modded buildings are included automatically. There are no
per-type toggles.

## Behavior details

- **Just like your own upgrade marks.** The mod's upgrades are ordinary native
  upgrade orders — bots transfer inventory, modules, and fuel exactly as they would
  for an upgrade-planner pass. Your marks are never touched: the mod only ever
  cancels orders it placed itself.
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
| Entities per tick | 1 | Work budget per tick; raise for faster processing at the expense of UPS |
| Reserve per item | 0 | Spares kept untouched per item-quality |
| Round delay | 20 s | Rest between rounds so bots can pick up ordered items |
| Order expiry | 300 s | Cancel the mod's own starved orders after this long out of stock; 0 = never |

## Compatibility

Works with any quality mod — quality chains are walked via the prototype graph, never
hardcoded.

The mod keeps almost no state about your base — every round reads the world fresh,
so there is nothing to get out of sync. The one exception is a small ledger of the
upgrade orders the mod itself placed, kept so that only its own marks are ever
expired; losing it is harmless (those orders simply never expire).
`/quality-gardener-init` resets the pass cursor and the ledger if you ever want a
clean restart.

One consequence of statelessness: if you cancel a mark the mod made while the
higher-quality item is still in storage, the mod will re-mark it on a later round.
To keep a building at its quality permanently, remove the spare items from that
network (or use the reserve setting).
