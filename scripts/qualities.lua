-- The quality chain, walked from "normal" via quality.next and cached as an
-- ordered array; a "tier" is the 1-based position in this chain. Qualities
-- not reachable from "normal" are ignored. Rebuilt on init/load; nothing
-- here persists.

local qualities = {}

local chain = {}          -- tier -> LuaQualityPrototype
local tier_by_name = {}   -- quality prototype name -> tier

function qualities.initialize()
  chain, tier_by_name = {}, {}
  local quality = prototypes.quality["normal"]
  while quality do
    chain[#chain + 1] = quality
    tier_by_name[quality.name] = #chain
    quality = quality.next
  end
end

-- Tier for a quality prototype name; nil if not on the normal chain
function qualities.tier_of(name)
  return tier_by_name[name]
end

-- LuaQualityPrototype at a tier
function qualities.at(tier)
  return chain[tier]
end

return qualities
