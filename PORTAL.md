**Summary**

Bot's automatically upgrade the factory when higher quality buildings become available. Ghosts are matched to the best-available item, and destroyed buildings are replaced with best available quality. 



 

**Description**

# **# Quality Relaxation Time**

**This mod makes dealing with mixed quality buildings easier.** 

**Bots automatically upgrade buildings (and other entities) when higher qualities are available in logistic storage.** 

**They will also replace ghosts with the next best quality when the requested item is *not* in inventory. So they will lower the quality of ghosts in some cases, but then once higher quality buildings show up they get upgraded.**

**This makes copy-pasting parts of the factory with mixed quality levels a non-issue, you never need to worry about whether something is in stock in that exact quality.** 

**## Details**

**Only quality is managed**

**A speed-module-1 can get upgraded to a higher quality speed-module-1, but won't get changed to a speed-module-2. Same principle applies to assembly machines, belts, and all other entities.** 

**If you would like a mod that will upgrade yellow belts to red belts, or assembler-1 to assembler-2, check out [Belt Upgrader]([https://mods.factorio.com/mod/BeltUpgrader](https://mods.factorio.com/mod/BeltUpgrader)), which handles those scenarios.** 

**UPS Efficient**

**This mod is written in a way to minimize UPS impact.** 

**It will eventually visit every building in a logistic network, but it's not made for instant response to events. It handles a few entities per tick (configurable) to spread out the processing load and avoid lag-spikes.** 

**Designed for Stability**

**The mod is designed to work in a stable and consistent way. It intentionally avoids tracking the state of entities beyond whether an upgrade was ordered by the mod or not.** 

**This avoids a number of issues that can come up if other mods change the world in unexpected ways.** 

**General Algorithm**

**Probably too low level for the mod description page, but I find it interesting :D And hopefully it helps future mod authors with their designs.** 

**The gardener checks for available inventory and bots in a network once, then evaluates each entity within that network (assemblers, inserters, belts, etc) one at a time to see if an upgrade can be ordered.** 

**On future visits, if an order that it placed has been sitting for a while (the time is configurable) it will cancel the upgrade request. This helps in situations where the inventory changed unexpectedly (such as the player picking up a stack of items or a chest getting destroyed).** 

**The alternative is to read logistic inventory more frequently, but that would introduce a much larger impact on UPS. This slow and steady approach means that the gardener is always active and making adjustments, and waits an appropriate amount of time to cancel adjustments without having to explicitly track the state of the world and it's entities.**

**## Feedback**

**It's always great to hear feedback, ideas, and issues. Please feel free to reach out in the comments/forum section!**

**## Future Features**

**There are some things that would be nice to add in the future.** 

**- Prefer upgrading the busiest machines first (currently it's just whatever comes up first in the search)**

**- Support for the Shiny Quality Mod (and other mods that add hidden qualities)**

**- Support for ignoring/skipping specified logistic networks**

