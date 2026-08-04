__Summary__

This is an automated helper for factories with mixed quality buildings. Ghosts are matched to the best-available item in logistic storage, and bots automatically upgrade buildings to higher qualities when they become available.

__Description__

# **Quality Relaxation Time**

This mod makes dealing with mixed quality buildings easier. 

Bots automatically upgrade buildings (and other entities) when higher qualities are available in logistic storage. 

They will also replace ghosts with the next best quality when the requested item is *not* in inventory. So they will lower the quality of ghosts in some cases, but then once higher quality buildings show up they get upgraded.

This makes copy-pasting parts of the factory with mixed quality levels a non-issue, you never need to worry about whether something is in stock in that exact quality. 

## **Details**

**Only quality is managed**

A speed-module-1 can get upgraded to a higher quality speed-module-1, but won't get changed to a speed-module-2. Same principle applies to assembly machines, belts, and all other entities. 

If you would like a mod that will upgrade yellow belts to red belts, or assembler-1 to assembler-2, check out [Belt Upgrader](https://mods.factorio.com/mod/BeltUpgrader), which handles those scenarios. 

**UPS Efficient**

By default it evaluates 1 entity per tick (can be adjusted in settings), and only checks logistic network storage once at the beginning of a pass. 

A single check of network storage could lead to over-provisioning upgrade requests if the inventory lowers while the Gardner is evaluating buildings. They won't leave things in a messy state; old upgrade requests that have been sitting for a while will get cleaned up (default 5 minutes, configurable). 

Any upgrade ordered by the player will be left alone, to preserve intentional base changes.

## **Beta Version**

Normally I play test a lot more before releasing, but I don't have as much playtime in the near future, and the mod feels super helpful. There are likely some unforeseen issues that will still need to be fixed. I do have the time to make patches, so let me know if you find any issues! 

## **Planned Features**

- Support for space platforms 
- Prefer upgrading the busiest machines first (currently it's just whatever comes up first in the search)
- Ability to turn off ghost matching to inventory 
- Support for shiny quality mod and mods that add hidden qualities 
- Support for ignoring/skipping certain logistic networks 
- Any UPS performance tuning ideas or suggestions that come up

