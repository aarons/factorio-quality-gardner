# Quality Gardener

Factorio 2.1 mod: buildings and ghosts in a factory are upgraded
to higher-quality versions when they are available in storage.

The architecture in one line: no entity events and almost no per-entity
state — a scan pass visits each logistic network and space platform in
turn, reads it fresh, and orders upgrades on the spot. `README.md` covers
player-facing behavior; `docs/decisions.md` holds the rationale behind the
rules below.

## Design invariants (read before changing core behavior)

- **The world is the only source of truth.** No per-entity state is stored
  except facts the world cannot answer: which orders are ours and when we
  placed them (the order ledger), and how long a platform target has been
  waiting (the platform wait ledger). Each visit reads reality fresh and
  issues orders on the spot.
- **Every visible mark is demand.** A marked entity counts against supply
  whoever marked it, so orders are never placed against stock an existing
  mark will consume.
- **Only our own orders are ever cancelled.** Orders the mod placed may be
  cancelled when they grow stale; orders placed by players or other mods
  never are. The order ledger records which orders are ours, and membership
  in it is the only license to cancel.
- **A space platform is its own network,** with the hub inventory as its
  supply. Orders are placed only against stock actually aboard — never
  against inbound or requested items.
- **Platform retargets wait for deliveries.** On a platform the wanted item
  can be minutes away by rocket, and retargeting would strand the delivery,
  so the retargeting arms wait out a possible delivery before acting.
  Planet networks never wait.
- **Never keep a live network reference across ticks.** They invalidate on
  any merge or split. A visit reads everything it needs from the live
  reference in a single tick and runs from plain-data snapshots afterwards.
- **Cross-tick pass state lives in `storage`** — locals would desync a
  multiplayer join — and resetting it is always safe: a restarted pass
  re-derives everything from the world.
- **Work is spread, never burst.** The pass spends a small per-tick budget,
  rests between rounds, and caps each network's orders by available
  construction bots (platforms have no bots and no cap).

## Retired alternatives (don't reintroduce — rationale in `docs/decisions.md`)

- Per-entity state as a cache of the world (candidate index, position-caching ledger).
- Exclusion machinery: mod lists, surface filters, Factorissimo integration.
- Per-entity-type enable settings or a hand-maintained type list.
- Hidden-quality skip/sticky settings.
- PickerDollies/teleport-mod event integration.
- A "skip networks without candidate supply" early exit in the scan.
- A test suite — luacheck via `./validate.sh` is the whole validation story.

## Engineering principles

- Avoid abbreviations in names (settings, locals, storage keys); spell words out.
- No mod prefixes on setting names (`manage-` is a shared verb, not a prefix).
- Behaviors sit behind runtime `manage-*` toggles, all default on. A toggle
  disables only the acting arm of its behavior; demand accounting always
  runs, so enabled behaviors never over-order.
- Ghosts: one whose exact quality is stocked is left to the bots; otherwise
  it is retargeted to the best stocked tier, even a lower one.
- Player upgrade marks: a starved mark is retargeted to the best stocked
  tier of its target item. It stays the player's mark.
- Modules: only quality ever changes, never which module prototype.
  Installed modules are only upgraded; requests retarget in either
  direction. Built entities only.

## Validation & packaging

`./validate.sh` runs luacheck. `./package.sh` validates, zips, and copies
the mod into the local Factorio mods folder.

This branch is the Factorio **2.1** release line; branch `2.0` is the
parallel 2.0 line. Every behavior change ships as two portal releases with
distinct version numbers — weigh changes here against the 2.0 branch. Its
`package.sh` builds to `builds/` without installing.

## API notes

Verified API facts and the in-game verification backlog live in
`docs/api-notes.md`. Consult it before touching an API call, and move newly
verified items from its backlog into its verified list.

## Localization

Only edit `locale/en/locale.cfg` by hand; other languages are managed
separately.
