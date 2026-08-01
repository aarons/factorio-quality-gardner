__Summary__

Let bots manage your garden **ahem** factory. This is a helper for factories with mixed quality buildings. Ghosts are matched to the best-available item in inventory, and bots automatically upgrade buildings to higher qualities when they become available in logistic storage.

__Description__

# Mixed Quality Relaxation

This mod makes dealing with mixed qualities easier.

Bots automatically upgrade buildings (and other entities) when higher qualities are available in logistic storage.

They will also replace ghosts with the next best quality when the requested item is *not* in inventory - so they will lower the quality of ghosts in some cases, but then once higher quality buildings show up they get upgraded.

All entity types are supported, including modules in machines and beacons.

## Space Platforms

Platforms are gardened too (with Space Age installed). A platform has no construction bots - the hub builds and upgrades directly from its own inventory - so each platform is treated as its own network, with the hub inventory (cargo bays included) as the supply. Upgrades are only ever ordered against items actually aboard.

Deliveries are respected: an item already on its way up (rocket or cargo pod) is always left alone, and a ghost or order covered by an open request - including the hub's automatic "request missing construction materials" system - is given a configurable delivery wait (default 300 s) to arrive before it is adjusted to the best quality aboard. A platform in transit never waits: a turret destroyed by asteroids is refilled immediately from whatever is on hand, because a downgrade now beats a hole in the defenses for the rest of the trip.

Platform management can be turned off with the Manage Space Platforms map setting.

## Helps with mixed quality factories

This is built as a companion mod for [Quality Control](https://mods.factorio.com/mod/quality-control), to help with copy-pasting parts of the factory that have lots of mixed quality levels. You can copy/paste without worrying as bots will figure out the best alternative options if they aren't available.

## Only Changes Quality

A speed-module-1 can get upgraded to a higher quality speed-module-1, but won't get changed to a speed-module-2. Same principle applies to assembly machines, belts, and all other entities.

If you would like a mod that will upgrade yellow belts to red belts, or assembler-1 to assembler-2, check out [Belt Upgrader](https://mods.factorio.com/mod/BeltUpgrader), which handles those scenarios.

## UPS Efficient

There are a lot of ways to program a mod like this. The general principle was to spread the work out as much as possible to avoid lag spikes and minimize UPS impact.

By default it evaluates 1 entity per tick (can be adjusted in settings), and only checks logistic network storage once at the beginning of a pass.

A single check of network storage could lead to over-provisioning upgrade requests if the inventory lowers while the Gardner is evaluating buildings. They won't leave things in a messy state; old upgrade requests that have been sitting for a while will get cleaned up (default 5 minutes, configurable).

Any upgrade ordered by the player will be left alone, to preserve intentional base changes.

## Beta Version

Normally I play test a lot more before releasing, but I don't have as much playtime in the near future, and the mod feels super helpful. There are likely some unforeseen issues that will still need to be fixed. I do have the time to make patches, so let me know if you find any issues!

## Planned Features

- Ability to turn off the ghost downgrading
- Support for shiny quality mod and mods that add hidden qualities
- Support for ignoring/skipping certain logistic networks
- Any UPS performance tuning ideas or suggestions that come up
- Prefer upgrading the busiest machines first (currently it's just whatever comes up first in the search)

