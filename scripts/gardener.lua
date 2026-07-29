--[[
gardener.lua

The matching engine: a stateless, scan-based pass over the player's logistic
networks. Networks are visited round-robin; entering one reads everything
needed from the live reference in that single tick (bot headroom, contents,
construction cell boxes), then the covered entities are scanned one cell at a
time and matched against the plain-data snapshot.

Nothing per-entity is stored. Marked entities are recognized by asking the
entity itself (to_be_upgraded()); every visible mark — ours from a past round,
a player's upgrade-planner mark, or another mod's — consumes supply as demand.
No mark is ever cancelled: without a ledger we cannot tell ours from a
player's, and cancelling a player's mark is off-limits.

Ghosts are scanned too: one requesting a stocked quality just consumes supply
as demand; one requesting an unstocked quality is retargeted to the best
quality on hand — even a lower one — so it gets built at all.
]]

local qualities = require("scripts.qualities")

local gardener = {}

-- How often the pass runs; each invocation spends up to entities-per-pass
-- iterations.
gardener.PASS_INTERVAL_TICKS = 10

function gardener.init_storage()
  -- The resumable cursor is the only cross-tick state; abandoning it is
  -- always safe (the next pass re-derives everything from the world).
  storage.pass = {cursor = 1}
  -- Storage keys from the event-tracking architecture; nil them out so old
  -- saves migrate cleanly.
  storage.candidates = nil
  storage.ledger = nil
  storage.ledger_by_position = nil
  storage.cooldown = nil
  storage.refresh = nil
end

-- Network entry -------------------------------------------------------------

-- One bare get_contents call for the entire network, folded into
-- supply[item_name][tier] = count, with the per-item reserve subtracted as
-- each (item, tier) entry is created. No filtering beyond the quality being
-- on the chain: rows for items that place no entity are harmless — nothing
-- ever looks them up.
local function read_supply(network)
  local reserve = settings.global["reserve-per-item"].value
  local supply = {}
  for _, row in ipairs(network.get_contents()) do
    local tier = qualities.tier_of(row.quality)
    if tier then
      local by_tier = supply[row.name]
      if not by_tier then
        by_tier = {}
        supply[row.name] = by_tier
      end
      by_tier[tier] = (by_tier[tier] or -reserve) + row.count
    end
  end
  return supply
end

-- Enter one network: read everything needed from the live reference in this
-- single tick — the reference is never carried forward. Returns the
-- plain-data work state, or nil to skip the network.
local function enter_network(network, surface_index)
  if not network.valid then return nil end

  local bots = network.available_construction_robots
  if bots == 0 then return nil end

  local supply = read_supply(network)

  -- Construction areas are squares: one box per stationary cell, scanned one
  -- cell at a time to bound each find_entities_filtered burst.
  local cells = {}
  for _, cell in pairs(network.cells) do
    if not cell.mobile then
      local radius = cell.construction_radius
      if radius > 0 then
        local owner = cell.owner
        if owner and owner.valid then
          local position = owner.position
          cells[#cells + 1] = {
            {position.x - radius, position.y - radius},
            {position.x + radius, position.y + radius},
          }
        end
      end
    end
  end
  if #cells == 0 then return nil end

  return {
    surface_index = surface_index,
    supply = supply,
    bots = bots,
    cells = cells,
    cell_index = 0,
    entities = nil,
    entity_index = 1,
  }
end

-- Matching -------------------------------------------------------------------

-- Highest tier with stock remaining, or nil. Supply is decremented in place,
-- so the snapshot itself is the availability cache. Callers compare the
-- result against the entity's own tier: built entities act only on a better
-- tier; ghosts take whatever is best.
local function best_stocked_tier(by_tier)
  local best = nil
  for tier, count in pairs(by_tier) do
    if count > 0 and (not best or tier > best) then
      best = tier
    end
  end
  return best
end

-- Ghost provisioning: a ghost whose exact quality is stocked is left for the
-- bots (its demand consumes supply); otherwise the ghost is retargeted via
-- order_upgrade to the best stocked tier of its item — even a lower one, so
-- the building gets built at all. The originally requested quality is not
-- remembered: once built, the entity is an ordinary upgrade candidate that
-- chases the best available supply.
local function examine_ghost(net, entity)
  local item_name = storage.config.placing_item_name[entity.ghost_name]
  if not item_name then return end
  local tier = qualities.tier_of(entity.quality.name)
  if not tier then return end
  local by_tier = net.supply[item_name]
  if not by_tier then return end

  local stock = by_tier[tier]
  if stock and stock > 0 then
    -- Exact quality stocked: a bot will fulfil this ghost natively; its
    -- demand consumes the supply.
    by_tier[tier] = stock - 1
    return
  end

  -- The exact tier is out of stock, so the best stocked tier — above or
  -- below the requested one — is never the requested tier itself.
  local best = best_stocked_tier(by_tier)
  if not best then return end

  local ok = entity.order_upgrade{
    target = {name = entity.ghost_name, quality = qualities.at(best).name},
    force = entity.force,
  }
  if ok then
    -- Without the retarget the ghost consumed no bot; now one will build it.
    by_tier[best] = by_tier[best] - 1
    net.bots = net.bots - 1
  end
end

-- One iteration: examine one scanned entity, first-come-first-served in scan
-- order. Duplicates from overlapping cells are harmless — once marked, later
-- encounters take the demand-accounting path.
local function examine(net, entity)
  if not entity.valid then return end
  if entity.force.name ~= "player" then return end
  if entity.name == "entity-ghost" then
    return examine_ghost(net, entity)
  end
  local item_name = storage.config.placing_item_name[entity.name]
  if not item_name then return end
  local tier = qualities.tier_of(entity.quality.name)
  if not tier then return end
  if entity.to_be_deconstructed() then return end

  if entity.to_be_upgraded() then
    -- Demand accounting: an existing mark consumes supply at its target.
    local target_prototype, target_quality = entity.get_upgrade_target()
    local target_item = target_prototype
      and storage.config.placing_item_name[target_prototype.name]
    local by_tier = target_item and net.supply[target_item]
    local target_tier = target_quality and qualities.tier_of(target_quality.name)
    if by_tier and target_tier then
      by_tier[target_tier] = (by_tier[target_tier] or 0) - 1
    end
    return
  end

  local by_tier = net.supply[item_name]
  if not by_tier then return end
  local target_tier = best_stocked_tier(by_tier)
  if not target_tier or target_tier <= tier then return end

  local ok = entity.order_upgrade{
    target = {name = entity.name, quality = qualities.at(target_tier).name},
    force = entity.force,
  }
  if ok then
    by_tier[target_tier] = by_tier[target_tier] - 1
    net.bots = net.bots - 1
  end
end

-- The pass ------------------------------------------------------------------

-- Network slots are re-enumerated fresh whenever a new network is needed;
-- only the integer cursor persists, so a mid-round merge or split at worst
-- skips or repeats a network for one round.
local function collect_network_slots()
  local slots = {}
  for surface_name, networks in pairs(game.forces.player.logistic_networks) do
    local surface = game.surfaces[surface_name]
    if surface then
      for _, network in pairs(networks) do
        slots[#slots + 1] = {network = network, surface_index = surface.index}
      end
    end
  end
  return slots
end

-- Scan one construction cell's area for entities the pass can act on.
-- Returns nil if the surface vanished mid-visit.
local function scan_cell(net)
  local surface = game.get_surface(net.surface_index)
  if not surface then return nil end
  return surface.find_entities_filtered{
    area = net.cells[net.cell_index],
    force = "player",
    type = storage.config.all_tracked_types,
  }
end

function gardener.on_pass()
  local pass = storage.pass
  if pass.resume_tick then
    if game.tick < pass.resume_tick then return end
    pass.resume_tick = nil
  end

  local budget = settings.global["entities-per-pass"].value
  local scanned_cell_this_invocation = false

  while budget > 0 do
    local net = pass.network
    if not net then
      -- One iteration: advance the cursor and enter the next network
      budget = budget - 1
      local slots = collect_network_slots()
      if pass.cursor > #slots then
        -- Round complete: rest, giving bots time to collect ordered items so
        -- the next round's contents reads are close to accurate.
        pass.cursor = 1
        pass.resume_tick = game.tick
          + math.floor(settings.global["round-delay-seconds"].value * 60)
        return
      end
      local slot = slots[pass.cursor]
      pass.cursor = pass.cursor + 1
      pass.network = enter_network(slot.network, slot.surface_index)
    elseif net.entities and net.entity_index <= #net.entities then
      budget = budget - 1
      local entity = net.entities[net.entity_index]
      net.entity_index = net.entity_index + 1
      examine(net, entity)
      if net.bots <= 0 then
        -- Bot headroom spent: abandon the rest of this network
        pass.network = nil
      end
    else
      net.cell_index = net.cell_index + 1
      if net.cell_index > #net.cells then
        pass.network = nil
      elseif scanned_cell_this_invocation then
        -- At most one scan burst per invocation; resume here next time
        net.cell_index = net.cell_index - 1
        return
      else
        scanned_cell_this_invocation = true
        budget = budget - 1
        net.entities = scan_cell(net)
        net.entity_index = 1
        if not net.entities then
          pass.network = nil
        end
      end
    end
  end
end

return gardener
