# Quality Gardener

Factorio 2.1 mod: when higher-quality versions of placed buildings sit in a logistic
network, lower-quality placed buildings in that network are marked for upgrade so
construction bots swap them out.

The architecture in one line: *events maintain the candidate index, scan cycles do all
matching statelessly, and the entity's own upgrade mark is the source of truth (the
ledger is just a cache with timestamps).* `README.md` covers player-facing intent and
behavior.

## Design invariants (read before changing core behavior)

- **The world is the source of truth.** Upgrade orders live on entities
  (`to_be_upgraded()` / `get_upgrade_target()`); the ledger is always rebuildable by
  adopting marks from a world rescan. Missed events make cached numbers stale until
  the next scan, never wrong forever.
- **Accounting is conservative, with no in-flight tracking.** Supply is the
  network's full contents (one bare `get_contents()` call per network);
  outstanding ledger
  orders are subtracted whole. The brief double-count while a bot is in flight only
  ever undercounts, then self-corrects on delivery.
- **Timeout instead of reconciliation.** There are no events for network content
  changes, so starved orders simply expire after a configurable timeout. Orders that
  were healthy-but-slow get re-marked by the same scan while supply persists — same
  outcome as deficit math, none of the bookkeeping.
- **Player marks are invisible demand.** Upgrade-planner marks, blueprint ghosts, and
  other mods' orders all just consume supply; they are never tracked, cancelled, or
  retargeted. "Ours" means "in the ledger" — only ledger orders expire.
- **Network identity is transient.** `LuaLogisticNetwork` refs and ids invalidate on
  any merge/split; nothing network-shaped is ever stored. Each scan re-derives
  networks fresh; misattribution after a split just times out.
- **API cost scales with matches made, never with entity count.** Iteration is
  supply-centric (most networks stock no upgrade-grade items and exit after one
  call); coverage is pure-Lua AABB tests against per-cycle roboport boxes; cached
  candidate positions are hints, re-read from the entity at mark time, with a
  rotating refresh slice bounding staleness.
- **Deferred v2 idea:** ghost quality retargeting (retarget blueprint ghosts to the
  best available quality). The ledger and index shapes were chosen to accommodate it
  as a new order kind, not a parallel system.

## Engineering principles

- Keep code clear and the surface area small — clarity over brevity or cleverness.
- Avoid abbreviations in names (settings, locals, storage keys); spell words out.
- No prefixes on setting names.
- No exclusion machinery (mod lists, surface filters, Factorissimo integration): bots
  perform the upgrades natively, so entities other mods manage are handled fine. This
  is deliberate (July 2026) — don't reintroduce it from the reference mod, which
  predates the decision.
- No per-entity-type enable settings and no hand-maintained type list: candidacy is
  derived from prototypes in `build_and_store_config` (has a placing item, not
  flagged `not-upgradable`) — belts and pipes included. Deliberate (July 2026).
- No PickerDollies/teleport-mod event integration: cached positions are hints only —
  the mark-time position re-read plus the rotating refresh slice already tolerate
  untracked teleports. Deliberate (July 2026) — don't resubscribe to dolly events.
- No pytest/test suite — validation is luacheck via `./validate.sh` only.

## Repository structure

- `control.lua` — entry point: init lifecycle, event registration, nth-tick loop,
  `quality-gardener-init` console command
- `scripts/gardener.lua` — scan cycle, order ledger, marking, expiry, lifecycle handlers
- `scripts/index.lua` — event-maintained candidate index
  (`storage.candidates[surface][item][tier]`), rotating position-refresh slice
- `scripts/qualities.lua` — quality chain cached as ordered "tiers"; hidden-quality
  (skip/sticky) policy lives here only
- `settings.lua`, `locale/en/locale.cfg`, `info.json`, `changelog.txt`, `README.md`
- `reference/factorio-quality-control/` — gitignored vendored copy of the author's
  Quality Control mod, kept for pattern reference only

## Validation & packaging

`./validate.sh` runs luacheck. `./package.sh` validates, zips, and copies the mod into
the local Factorio mods folder.

## Verified API facts (don't re-derive)

- `LuaLogisticNetwork.get_contents(member?)` — `member` is optional (`"storage"` or
  `"providers"`); when omitted, returns item counts for the **entire network**. We
  always call it bare. Returns an array of `{name, quality, count}` where `quality`
  is a **string** prototype name.
- `order_upgrade{target={name=..., quality=...}, force=...}` supports same-name
  quality-only upgrades; `get_upgrade_target()` returns (prototype, quality).
- `on_object_destroyed.useful_id` is the entity's `unit_number`.
- `"not-upgradable"` is an `EntityPrototypeFlag` ("can't be selected by the upgrade
  planner"), testable via `LuaEntityPrototype.has_flag`; it is the only documented
  planner gate. `order_upgrade` returns a boolean — rejection is signalled by
  returning `false`, not by erroring.
- `items_to_place_this` is an optional array of `{name, count}` (`ItemToPlace`);
  entity name ≠ item name, always read `.name`.
- `remote.call` is forbidden in `on_load`.
- Requester-chest contents do not count toward logistic network contents; a bare
  `get_contents()` only reports what bots can actually draw from.
- Still unverified in-game: that construction bots pull upgrade items from network
  supply as expected. If orders stall despite stock, check this first.

## Localization

Only edit `locale/en/locale.cfg` by hand; other languages are managed separately.
