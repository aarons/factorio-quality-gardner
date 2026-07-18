# Quality Gardener

A Factorio 2.1 mod. When higher-quality versions of your buildings sit in a logistic
network's storage chests, the lower-quality placed buildings in that network are marked
for upgrade so construction bots swap them out — like a gardener steadily replacing the
worst plants with the best cuttings on hand.

## How to use it

Drop spare higher-quality building items into storage chests (from quality recycling,
asteroid reprocessing, or dedicated quality production) and let the bots work. No
manual upgrade-planner passes needed.

- **Worst first.** The lowest-quality buildings are upgraded before better ones, so
  each item delivers the biggest improvement.
- **Direct to best.** A normal building jumps straight to the best quality on
  hand — one bot trip, no intermediate items.
- **The cascade is free.** Upgrading a building returns its lower-quality item to
  storage, which can then lift an even worse building. Quality ripples down through
  the base with no extra logic.
- **Every building keeps climbing.** A just-upgraded building immediately becomes a
  candidate for the next tier; over months of play a machine can walk
  normal → rare → legendary as stock evolves around it.

Everything placeable and upgradable is covered — assemblers down to belts, pipes, and
poles. Coverage is derived from prototypes (anything placed from an item that the game
allows upgrading), so modded buildings are included automatically. There are no
per-type toggles.

## Behavior details

- **Starved orders clean themselves up.** If supply vanishes after marking (players,
  blueprints, or other demand took the items), the order is cancelled after a
  configurable timeout instead of pending forever with missing-material alerts.
  Orders that are merely slow re-mark automatically while supply persists.
- **Player intent is respected.** Marks made with the upgrade planner are never touched,
  and cancelling one of the mod's marks puts that building on a brief cooldown.
- **Runtime state survives.** Accumulator charge, lamp always-on, and rocket silo
  auto-launch settings are restored after the swap (bots natively transfer inventory,
  modules, and fuel).
- **Reserve.** Optionally keep N of each item-quality combination untouched in storage
  as a float for new construction.

## Settings

| Setting | Default | Notes |
|---|---|---|
| Scan interval | 5 s | How often networks are checked |
| Max orders per scan | 30 | Spreads large jobs over several scans |
| Supply source | storage | Optionally also passive/active providers; requesters and buffers never count |
| Reserve per item | 0 | Spares kept untouched per item-quality |
| Order timeout | 3 min | 0 = never cancel (vanilla pending-order behavior) |
| Console notifications | on | Per-player aggregate message |
| Hidden-quality handling | — | Skip and/or sticky startup options for mods like Quality++ Shiny |

## Compatibility

- Works with any quality mod — quality chains are walked via the prototype graph, never
  hardcoded, including hidden qualities (skip/sticky startup settings).
- Entities managed by other mods are fine: bots perform the upgrades natively, so no
  exclusion lists or integrations are needed.
- Teleport mods (Even Pickier Dollies, etc.) are tolerated without integration: cached
  entity positions are treated as hints and re-verified before any order is issued.

If the mod's state ever looks wrong, `/quality-gardener-init` rebuilds everything from
the world (the entity's own upgrade marks are the source of truth).
