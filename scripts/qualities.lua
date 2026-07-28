--[[
qualities.lua

The quality chain, walked once from "normal" via quality.next and cached as an
ordered array. Everything else in the mod refers to qualities by "tier" — the
1-based position in this chain. Qualities not reachable from "normal" are
ignored entirely.

Rebuilt from prototypes + startup settings on init/load; nothing here persists.
]]

local qualities = {}

local chain = {}          -- tier -> LuaQualityPrototype
local tier_by_name = {}   -- quality prototype name -> tier
local target_ok = {}      -- tier -> may be upgraded INTO (above normal, not skip-hidden)
local candidate_ok = {}   -- tier -> entities at this tier may be upgraded out of
local next_allowed = {}   -- tier -> lowest higher tier that is target_ok (drives candidate_ok)

function qualities.initialize()
  local skip_hidden = settings.startup["skip-hidden-qualities"].value
  local sticky_hidden = settings.startup["hidden-qualities-sticky"].value

  chain, tier_by_name, target_ok, candidate_ok, next_allowed = {}, {}, {}, {}, {}

  local q = prototypes.quality["normal"]
  while q do
    chain[#chain + 1] = q
    tier_by_name[q.name] = #chain
    q = q.next
  end

  for tier, proto in ipairs(chain) do
    target_ok[tier] = tier > 1 and not (skip_hidden and proto.hidden)
  end

  -- Backward pass: next_allowed[t] = nearest higher target_ok tier
  local nearest = nil
  for tier = #chain, 1, -1 do
    next_allowed[tier] = nearest
    if target_ok[tier] then
      nearest = tier
    end
  end

  for tier, proto in ipairs(chain) do
    local sticky_blocked = sticky_hidden and proto.hidden
    candidate_ok[tier] = (not sticky_blocked) and next_allowed[tier] ~= nil
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

function qualities.is_candidate_tier(tier)
  return candidate_ok[tier] or false
end

function qualities.is_target_tier(tier)
  return target_ok[tier] or false
end

return qualities
