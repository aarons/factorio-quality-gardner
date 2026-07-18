# Quality Gardener

Factorio 2.1 mod: when higher-quality versions of placed buildings sit in a logistic
network's storage, lower-quality placed buildings in that network are marked for upgrade
so construction bots swap them out.

**Read `DESIGN.md` before changing core behavior** — it documents the accounting model,
the timeout-instead-of-reconciliation approach, the performance model, and a full
edge-case catalog. The architecture in one line: *events maintain the candidate index,
scan cycles do all matching statelessly, and the entity's own upgrade mark is the source
of truth (the ledger is just a cache with timestamps).*

## Engineering principles

- Keep code clear and the surface area small — clarity over brevity or cleverness.
- Avoid abbreviations in names (settings, locals, storage keys); spell words out.
- No prefixes on setting names.
- No exclusion machinery (mod lists, surface filters, Factorissimo integration): bots
  perform the upgrades natively, so entities other mods manage are handled fine. This
  is deliberate (July 2026) — don't reintroduce it from the reference mod or DESIGN.md,
  which predate the decision.
- No pytest/test suite — validation is luacheck via `./validate.sh` only.

## Repository structure

- `control.lua` — entry point: init lifecycle, event registration, nth-tick loop,
  `quality-gardener-init` console command
- `scripts/gardener.lua` — scan cycle, order ledger, marking, expiry, lifecycle handlers
- `scripts/index.lua` — event-maintained candidate index
  (`storage.candidates[surface][item][tier]`), rotating position-refresh slice
- `scripts/qualities.lua` — quality chain cached as ordered "tiers"; hidden-quality
  (skip/sticky) policy lives here only
- `settings.lua`, `locale/en/locale.cfg`, `info.json`, `changelog.txt`
- `reference/factorio-quality-control/` — gitignored vendored copy of the author's
  Quality Control mod, kept for pattern reference only

## Validation & packaging

`./validate.sh` runs luacheck. `./package.sh` validates, zips, and copies the mod into
the local Factorio mods folder.

## Verified API facts (don't re-derive)

- `LuaLogisticNetwork.get_contents(member?)` — `member` accepts only `"storage"` or
  `"providers"`; returns an array of `{name, quality, count}` where `quality` is a
  **string** prototype name. There is no buffer-chest member (this resolved DESIGN.md
  open question 2; requester/buffer contents are never counted).
- `order_upgrade{target={name=..., quality=...}, force=...}` supports same-name
  quality-only upgrades; `get_upgrade_target()` returns (prototype, quality).
- `on_object_destroyed.useful_id` is the entity's `unit_number`.
- `remote.call` is forbidden in `on_load` — the PickerDollies event id is resolved at
  init and stored in `storage.dolly_event_id`.

## Localization

Only edit `locale/en/locale.cfg` by hand; other languages are managed separately.
