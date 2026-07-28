# Quality Gardener

Factorio 2.1 mod: when higher-quality versions of placed buildings sit in a logistic
network, lower-quality placed buildings in that network are marked for upgrade so
construction bots swap them out.

The architecture in one line: *events maintain the candidate index, a continuous
per-tick budgeted pass does all matching from single-tick network snapshots.*
`README.md` covers player-facing intent and behavior.

## Design invariants (read before changing core behavior)

- **The world is the source of truth.** Upgrade orders live on entities
  (`to_be_upgraded()` / `get_upgrade_target()`); the ledger is always rebuildable by
  adopting marks from a world rescan.
- **Accounting is conservative, with no in-flight tracking.** Supply is the
  network's full contents (one bare `get_contents()` call per network); outstanding
  ledger orders are subtracted whole. The brief double-count while a bot is in flight
  only ever undercounts.
- **Timeout instead of reconciliation.** There are no events for network content
  changes, so starved orders simply expire after a configurable timeout (expiry runs
  once per full round of the networks). Orders that were healthy-but-slow get
  re-marked when their network is next visited while supply persists.
- **Player marks are invisible demand.** Upgrade-planner marks, blueprint ghosts, and
  other mods' orders all just consume supply; they are never tracked, cancelled, or
  retargeted. "Ours" means "in the ledger" — only ledger orders expire.
- **Network identity is transient; only snapshots span ticks.** `LuaLogisticNetwork`
  refs and ids invalidate on any merge/split; no network reference or id is ever
  stored or held across a tick boundary. Entering a network reads everything needed
  (supply, coverage boxes, bot count) from the live ref in that single tick; matching
  then runs from the plain-data snapshot, which can only go stale, never invalid.
- **Pass state lives in `storage`, and abandoning it is always safe.** Cross-tick
  state in locals would desync a multiplayer join, so the resumable pass (cursor,
  network snapshot, expiry queue) is plain data in `storage.pass`. Init and
  configuration changes reset it; a restarted pass just re-derives from the world.
- **Work is spread, never burst.** Every tick spends the `entities-per-tick` budget
  (candidates examined, contents rows read, orders issued or cancelled — one touch
  each, with a share reserved for the position-refresh slice) and stops. There is no
  scan interval and no idle backoff: cost per tick is small and constant by design.
- **Orders are capped by bot headroom.** Each network gets at most
  `available_construction_robots` orders (marks plus raises) per visit, read once at
  entry with no in-flight accounting — never mark more work than bots can start.
  A stale count only delays marks until the next visit.
- **API cost scales with matches made, never with entity count.** Iteration is
  supply-centric (most networks stock no upgrade-grade items and exit after one
  call); coverage is pure-Lua AABB tests against per-visit roboport boxes; cached
  candidate positions are hints, re-read from the entity at mark time, with a
  rotating refresh slice bounding staleness.

## Engineering principles

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

## Validation & packaging

`./validate.sh` runs luacheck — that is the whole validation story; don't add a test
suite. `./package.sh` validates, zips, and copies the mod into the local Factorio mods
folder.

## Verified API facts (don't re-derive)

- `LuaLogisticNetwork.get_contents(member?)` — `member` is optional (`"storage"` or
  `"providers"`); when omitted, returns item counts for the **entire network**. We
  always call it bare. Returns an array of `{name, quality, count}` where `quality`
  is a **string** prototype name.
- `order_upgrade{target={name=..., quality=...}, force=...}` supports same-name
  quality-only upgrades; `get_upgrade_target()` returns (prototype, quality).
- `LuaLogisticNetwork.available_construction_robots` — read-only uint32, "number of
  construction robots available for a job" (idle bots; busy ones self-exclude).
- `"not-upgradable"` is an `EntityPrototypeFlag` ("can't be selected by the upgrade
  planner"), testable via `LuaEntityPrototype.has_flag`; it is the only documented
  planner gate. `order_upgrade` returns a boolean — rejection is signalled by
  returning `false`, not by erroring.
- Requester-chest contents do not count toward logistic network contents; a bare
  `get_contents()` only reports what bots can actually draw from.
- Still unverified in-game: that construction bots pull upgrade items from network
  supply as expected. If orders stall despite stock, check this first.
