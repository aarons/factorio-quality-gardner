--[[
index.lua

The candidate index: who exists, at what quality, where. Maintained purely by
build/destroy events (plus a rotating position-refresh slice) — never polled.
Entering the index queues nothing; scan cycles read it as the demand side of
matching.

storage.candidates[surface_index][item_name][tier] = {
  [unit_number] = { entity = LuaEntity, x = double, y = double }
}

Cached positions are a filter hint, not truth: movers like Even Pickier Dollies
teleport entities without base-game events. The authoritative position re-read
happens at mark time (gardener.lua); the refresh slice bounds how long a stale
position can wrongly filter an entity out.
]]

local qualities = require("scripts.qualities")

local index = {}

function index.init_storage()
  storage.candidates = {}
  -- Rotating refresh: flat list of bucket keys, rebuilt each full pass
  storage.refresh = {list = nil, position = 1}
end

-- The item that places an entity, or nil if it can never be upgraded from
-- network supply (no placing item, or the engine forbids upgrading it).
-- Precomputed per prototype name in build_and_store_config.
function index.placing_item_name(entity)
  return storage.config.placing_item_name[entity.name]
end

-- Add an entity as an upgrade candidate. Caller guarantees entity.valid.
-- Silently ignores anything that can't ever be upgraded (not placeable or
-- upgradable, wrong force, terminal or sticky-hidden quality).
function index.add(entity)
  local item_name = index.placing_item_name(entity)
  if not item_name then return end
  if entity.force.name ~= "player" then return end
  local unit_number = entity.unit_number
  if not unit_number then return end

  local tier = qualities.tier_of(entity.quality.name)
  if not tier or not qualities.is_candidate_tier(tier) then return end

  local surface_index = entity.surface.index
  local position = entity.position

  local by_item = storage.candidates[surface_index]
  if not by_item then
    by_item = {}
    storage.candidates[surface_index] = by_item
  end
  local by_tier = by_item[item_name]
  if not by_tier then
    by_tier = {}
    by_item[item_name] = by_tier
  end
  local bucket = by_tier[tier]
  if not bucket then
    bucket = {}
    by_tier[tier] = bucket
  end
  bucket[unit_number] = {entity = entity, x = position.x, y = position.y}
end

-- Remove by explicit keys (used when the entity is already gone). Prunes empty
-- tables so scans never walk dead buckets.
function index.remove_key(surface_index, item_name, tier, unit_number)
  local by_item = storage.candidates[surface_index]
  local by_tier = by_item and by_item[item_name]
  local bucket = by_tier and by_tier[tier]
  if not bucket then return end

  bucket[unit_number] = nil
  if next(bucket) == nil then
    by_tier[tier] = nil
    if next(by_tier) == nil then
      by_item[item_name] = nil
    end
  end
end

-- Remove a still-valid entity (mined/died events)
function index.remove(entity)
  local unit_number = entity.unit_number
  if not unit_number then return end
  local item_name = index.placing_item_name(entity)
  local tier = qualities.tier_of(entity.quality.name)
  if not item_name or not tier then return end
  index.remove_key(entity.surface.index, item_name, tier, unit_number)
end

-- Candidates for (surface, item): tier -> bucket, or nil
function index.get_buckets(surface_index, item_name)
  local by_item = storage.candidates[surface_index]
  return by_item and by_item[item_name]
end

function index.has_candidates_for_item(surface_index, item_name)
  local by_item = storage.candidates[surface_index]
  return (by_item and by_item[item_name]) ~= nil
end

local function build_bucket_list()
  local list = {}
  for surface_index, by_item in pairs(storage.candidates) do
    for item_name, by_tier in pairs(by_item) do
      for tier in pairs(by_tier) do
        list[#list + 1] = {surface_index = surface_index, item_name = item_name, tier = tier}
      end
    end
  end
  return list
end

-- Refresh cached positions for roughly max_entities candidates per call,
-- rotating through all buckets over successive calls. Also evicts records
-- whose entities have become invalid without our events firing.
function index.refresh_slice(max_entities)
  local refresh = storage.refresh
  if not refresh.list or refresh.position > #refresh.list then
    refresh.list = build_bucket_list()
    refresh.position = 1
    if #refresh.list == 0 then return end
  end

  local refreshed = 0
  while refreshed < max_entities and refresh.position <= #refresh.list do
    local key = refresh.list[refresh.position]
    refresh.position = refresh.position + 1

    local by_item = storage.candidates[key.surface_index]
    local by_tier = by_item and by_item[key.item_name]
    local bucket = by_tier and by_tier[key.tier]
    if bucket then
      local dead = nil
      local moved = nil
      for unit_number, record in pairs(bucket) do
        local entity = record.entity
        if not entity.valid then
          dead = dead or {}
          dead[#dead + 1] = unit_number
        elseif entity.surface.index ~= key.surface_index then
          moved = moved or {}
          moved[#moved + 1] = unit_number
        else
          local position = entity.position
          record.x = position.x
          record.y = position.y
        end
        refreshed = refreshed + 1
      end
      if dead then
        for _, unit_number in ipairs(dead) do
          index.remove_key(key.surface_index, key.item_name, key.tier, unit_number)
        end
      end
      if moved then
        for _, unit_number in ipairs(moved) do
          local entity = bucket[unit_number] and bucket[unit_number].entity
          index.remove_key(key.surface_index, key.item_name, key.tier, unit_number)
          if entity and entity.valid then
            index.add(entity)
          end
        end
      end
    end
  end
end

return index
