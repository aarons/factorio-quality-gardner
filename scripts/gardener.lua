--[[
gardener.lua

The scan cycle and order ledger. Each cycle is a stateless function of
(current storage contents, current candidate index): per network, one
get_contents call gates everything (most networks stock no upgrade-grade
building items and exit immediately), coverage is tested in pure Lua against
per-cycle roboport AABBs, and marks go worst-quality-first up to what the
supply justifies.

The ledger (storage.ledger) is the only per-entity state: a transient entry
per order we've issued, used to count outstanding demand and to expire starved
orders. The world is the source of truth — entity upgrade marks always win;
at worst the ledger is rebuilt by adopting marks from a world rescan.

Accounting is deliberately conservative: supply counts items physically in
chests, outstanding orders are subtracted whole, and the brief double-count
while a bot is in flight only ever undercounts. No in-flight tracking exists.
]]

local qualities = require("scripts.qualities")
local index = require("scripts.index")

local gardener = {}

-- After a player cancels one of our marks, leave the entity alone this long
local REMARK_COOLDOWN_TICKS = 2 * 60 * 60
-- Candidate positions re-verified per cycle by the rotating refresh slice
local REFRESH_ENTITIES_PER_CYCLE = 200

function gardener.init_storage()
  storage.ledger = {}
  storage.ledger_by_position = {}
  storage.cooldown = {}
  storage.network_rotation = 0
  storage.pending_notify = 0
end

-- Ledger bookkeeping ------------------------------------------------------

local function position_key(surface_index, x, y)
  return string.format("%d:%.2f:%.2f", surface_index, x, y)
end

local function add_order(entity, item_name, tier, target_tier, restore, surface_index, position)
  local unit_number = entity.unit_number
  storage.ledger[unit_number] = {
    entity = entity,
    tick_ordered = game.tick,
    item_name = item_name,
    tier = tier,
    target_tier = target_tier,
    surface_index = surface_index,
    x = position.x,
    y = position.y,
    restore = restore,
  }
  storage.ledger_by_position[position_key(surface_index, position.x, position.y)] = unit_number
end

local function remove_order(unit_number)
  local entry = storage.ledger[unit_number]
  if not entry then return end
  storage.ledger[unit_number] = nil
  local key = position_key(entry.surface_index, entry.x, entry.y)
  if storage.ledger_by_position[key] == unit_number then
    storage.ledger_by_position[key] = nil
  end
end

local function on_cooldown(unit_number)
  local until_tick = storage.cooldown[unit_number]
  if until_tick then
    if until_tick > game.tick then return true end
    storage.cooldown[unit_number] = nil
  end
  return false
end

-- Runtime state that doesn't survive a bot swap; restored on completion
local function capture_restore(entity)
  local entity_type = entity.type
  if entity_type == "accumulator" then
    return {energy = entity.energy}
  elseif entity_type == "lamp" then
    return {always_on = entity.always_on}
  elseif entity_type == "rocket-silo" then
    return {send_to_orbit = entity.send_to_orbit_automatically}
  end
  return nil
end

-- Order expiry ------------------------------------------------------------

-- Cancel our orders older than the timeout. Starved orders stay cancelled
-- (next scan sees no supply); healthy-but-slow orders are re-marked by the
-- same scan since the supply is still present. Returns mutations used.
local function expire_orders(budget)
  local timeout_minutes = settings.global["order-timeout-minutes"].value
  if timeout_minutes == 0 then return 0 end

  local cutoff = game.tick - math.floor(timeout_minutes * 3600)
  local expired = {}
  for unit_number, entry in pairs(storage.ledger) do
    if entry.tick_ordered <= cutoff then
      expired[#expired + 1] = unit_number
    end
  end

  local used = 0
  for _, unit_number in ipairs(expired) do
    if used >= budget then break end
    local entity = storage.ledger[unit_number].entity
    -- Remove before cancelling so our own on_cancelled_upgrade is a no-op
    remove_order(unit_number)
    if entity.valid and entity.to_be_upgraded() then
      entity.cancel_upgrade(entity.force)
      used = used + 1
    end
  end
  return used
end

-- Supply ------------------------------------------------------------------

-- One get_contents call per network; rows are kept only when the item has
-- candidates on this surface and the quality is a permitted upgrade target.
-- Returns supply[item_name][tier] = count, or nil (the common early exit).
local function read_supply(network, surface_index)
  local supply = nil
  local function absorb(rows)
    for _, row in ipairs(rows) do
      local tier = qualities.tier_of(row.quality)
      if tier and qualities.is_target_tier(tier)
        and index.has_candidates_for_item(surface_index, row.name) then
        supply = supply or {}
        local by_tier = supply[row.name]
        if not by_tier then
          by_tier = {}
          supply[row.name] = by_tier
        end
        by_tier[tier] = (by_tier[tier] or 0) + row.count
      end
    end
  end

  absorb(network.get_contents("storage"))
  if settings.global["source-chests"].value == "storage-and-providers" then
    absorb(network.get_contents("providers"))
  end

  if supply then
    local reserve = settings.global["reserve-per-item"].value
    if reserve > 0 then
      for _, by_tier in pairs(supply) do
        for tier, count in pairs(by_tier) do
          by_tier[tier] = count - reserve
        end
      end
    end
  end
  return supply
end

-- Coverage ----------------------------------------------------------------

-- Construction areas are squares: one AABB per stationary cell, built once
-- per network per cycle (API cost scales with roboport count, never entities)
local function build_coverage(network)
  local boxes = {}
  for _, cell in pairs(network.cells) do
    if not cell.mobile then
      local radius = cell.construction_radius
      if radius > 0 then
        local owner = cell.owner
        if owner and owner.valid then
          local position = owner.position
          boxes[#boxes + 1] = {
            x1 = position.x - radius, y1 = position.y - radius,
            x2 = position.x + radius, y2 = position.y + radius,
          }
        end
      end
    end
  end
  return boxes
end

local function in_coverage(boxes, x, y)
  for i = 1, #boxes do
    local box = boxes[i]
    if x >= box.x1 and x <= box.x2 and y >= box.y1 and y <= box.y2 then
      return true
    end
  end
  return false
end

-- Matching ----------------------------------------------------------------

-- Our pending orders in this network's coverage consume supply at their
-- target quality; subtract them. Grouping is recomputed here every scan —
-- network identity is transient, so nothing network-shaped is ever stored.
local function subtract_outstanding(supply, surface_index, boxes)
  for _, entry in pairs(storage.ledger) do
    if entry.surface_index == surface_index then
      local by_tier = supply[entry.item_name]
      if by_tier and in_coverage(boxes, entry.x, entry.y) then
        by_tier[entry.target_tier] = (by_tier[entry.target_tier] or 0) - 1
      end
    end
  end
end

-- Upgrade upgrades: when better supply appears above a pending order's
-- target, re-issue the order at the higher target (ours only, direct mode
-- only — single-step targets are already the next tier by definition).
local function raise_pending_orders(supply, surface_index, boxes, state)
  if settings.global["upgrade-targeting"].value == "single-step" then return end
  for _, entry in pairs(storage.ledger) do
    if state.used >= state.budget then return end
    if entry.surface_index == surface_index then
      local by_tier = supply[entry.item_name]
      if by_tier and in_coverage(boxes, entry.x, entry.y) then
        local best = nil
        for tier, count in pairs(by_tier) do
          if count > 0 and tier > entry.target_tier and (not best or tier > best) then
            best = tier
          end
        end
        if best then
          local entity = entry.entity
          if entity.valid and entity.to_be_upgraded() then
            local ok = entity.order_upgrade{
              target = {name = entity.name, quality = qualities.at(best).name},
              force = entity.force,
            }
            if ok then
              by_tier[best] = by_tier[best] - 1
              by_tier[entry.target_tier] = (by_tier[entry.target_tier] or 0) + 1
              entry.target_tier = best
              entry.tick_ordered = game.tick
              state.used = state.used + 1
            end
          end
        end
      end
    end
  end
end

-- Mark new candidates for one item, worst quality first, until availability
-- or the mutation budget runs out.
local function process_item(item_name, available_by_tier, buckets, boxes, surface_index, state)
  local supply_tiers = {}
  for tier, count in pairs(available_by_tier) do
    if count > 0 then supply_tiers[#supply_tiers + 1] = tier end
  end
  if #supply_tiers == 0 then return end
  table.sort(supply_tiers, function(a, b) return a > b end)

  local single_step = settings.global["upgrade-targeting"].value == "single-step"
  local function pick_target(candidate_tier)
    if single_step then
      local tier = qualities.next_allowed_tier(candidate_tier)
      if tier and (available_by_tier[tier] or 0) > 0 then return tier end
      return nil
    end
    for _, tier in ipairs(supply_tiers) do
      if tier <= candidate_tier then return nil end
      if available_by_tier[tier] > 0 then return tier end
    end
    return nil
  end

  local candidate_tiers = {}
  for tier in pairs(buckets) do candidate_tiers[#candidate_tiers + 1] = tier end
  table.sort(candidate_tiers)

  for _, candidate_tier in ipairs(candidate_tiers) do
    local bucket = buckets[candidate_tier]
    if not pick_target(candidate_tier) then
      bucket = nil  -- availability exhausted for this tier; skip the bucket
    end
    -- Snapshot unit numbers: marking mutates the bucket via removals
    local units = {}
    if bucket then
      for unit_number in pairs(bucket) do units[#units + 1] = unit_number end
    end

    for _, unit_number in ipairs(units) do
      if state.used >= state.budget then return end
      local target_tier = pick_target(candidate_tier)
      if not target_tier then break end

      local record = bucket[unit_number]
      if record and not storage.ledger[unit_number] and not on_cooldown(unit_number)
        and in_coverage(boxes, record.x, record.y) then
        local entity = record.entity
        if not entity.valid then
          index.remove_key(surface_index, item_name, candidate_tier, unit_number)
        elseif not entity.to_be_upgraded() and not entity.to_be_deconstructed() then
          -- Cached position is a hint; the entity is authoritative (teleport mods)
          local position = entity.position
          record.x = position.x
          record.y = position.y
          if in_coverage(boxes, position.x, position.y) then
            local restore = capture_restore(entity)
            script.register_on_object_destroyed(entity)
            local ok = entity.order_upgrade{
              target = {name = entity.name, quality = qualities.at(target_tier).name},
              force = entity.force,
            }
            if ok then
              add_order(entity, item_name, candidate_tier, target_tier, restore, surface_index, position)
              available_by_tier[target_tier] = available_by_tier[target_tier] - 1
              state.used = state.used + 1
            end
          end
        end
      end
    end
  end
end

local function process_network(network, surface_index, state)
  if not network.valid then return end
  local supply = read_supply(network, surface_index)
  if not supply then return end

  local boxes = build_coverage(network)
  if #boxes == 0 then return end

  subtract_outstanding(supply, surface_index, boxes)
  raise_pending_orders(supply, surface_index, boxes, state)

  for item_name, available_by_tier in pairs(supply) do
    if state.used >= state.budget then return end
    local buckets = index.get_buckets(surface_index, item_name)
    if buckets then
      process_item(item_name, available_by_tier, buckets, boxes, surface_index, state)
    end
  end
end

-- Notifications -----------------------------------------------------------

local function flush_notifications()
  local count = storage.pending_notify
  if count == 0 then return end
  storage.pending_notify = 0
  for _, player in pairs(game.connected_players) do
    if settings.get_player_settings(player)["notifications"].value then
      player.print({"quality-gardener.upgraded-summary", count})
    end
  end
end

-- Scan cycle --------------------------------------------------------------

function gardener.run_cycle()
  local state = {
    budget = settings.global["max-orders-per-scan"].value,
    used = 0,
  }
  state.used = state.used + expire_orders(state.budget)

  -- Networks are re-derived fresh every cycle (merges/splits handled for free)
  local slots = {}
  for surface_name, networks in pairs(game.forces.player.logistic_networks) do
    local surface = game.surfaces[surface_name]
    if surface then
      local surface_index = surface.index
      if storage.candidates[surface_index] then
        for _, network in pairs(networks) do
          slots[#slots + 1] = {network = network, surface_index = surface_index}
        end
      end
    end
  end

  -- Rotate the starting network so a saturated budget can't starve the tail
  local count = #slots
  if count > 0 and state.used < state.budget then
    local offset = storage.network_rotation % count
    for i = 0, count - 1 do
      local slot = slots[((offset + i) % count) + 1]
      process_network(slot.network, slot.surface_index, state)
      if state.used >= state.budget then break end
    end
    storage.network_rotation = offset + 1
  end

  index.refresh_slice(REFRESH_ENTITIES_PER_CYCLE)
  flush_notifications()
end

-- Lifecycle event handlers ------------------------------------------------

-- Player (or another mod) cancelled one of our marks: drop the order and
-- back off briefly so we don't instantly re-mark against their intent.
-- Our own cancel_upgrade calls also raise this event, but the entry is
-- already removed by then, so this is a no-op for them.
function gardener.on_cancelled_upgrade(event)
  local entity = event.entity
  if not (entity and entity.valid) then return end
  local unit_number = entity.unit_number
  if unit_number and storage.ledger[unit_number] then
    remove_order(unit_number)
    storage.cooldown[unit_number] = game.tick + REMARK_COOLDOWN_TICKS
  end
end

-- Universal catch-all for marked entities: upgrade completed, died, mined,
-- or destroyed by script — in every case the order and the old index record
-- are dropped. Registration persists through save/load.
function gardener.on_object_destroyed(event)
  if event.type ~= defines.target_type.entity then return end
  local unit_number = event.useful_id
  if unit_number == 0 then return end
  local entry = storage.ledger[unit_number]
  if entry then
    index.remove_key(entry.surface_index, entry.item_name, entry.tier, unit_number)
    remove_order(unit_number)
  end
  storage.cooldown[unit_number] = nil
end

-- A bot built something: index it (closing the loop — a just-upgraded
-- building immediately becomes a candidate for the next tier), and if it
-- completes one of our orders, restore captured runtime state. The new
-- entity has no link to the old one, so correlate by position.
function gardener.on_robot_built_entity(event)
  local entity = event.entity
  if not entity.valid then return end
  if not storage.config.is_tracked_type[entity.type] then return end

  index.add(entity)

  local position = entity.position
  local surface_index = entity.surface.index
  local unit_number = storage.ledger_by_position[position_key(surface_index, position.x, position.y)]
  local entry = unit_number and storage.ledger[unit_number]
  if entry and entry.item_name == index.placing_item_name(entity)
    and entry.target_tier == qualities.tier_of(entity.quality.name) then
    local restore = entry.restore
    if restore then
      if restore.energy ~= nil then entity.energy = restore.energy end
      if restore.always_on ~= nil then entity.always_on = restore.always_on end
      if restore.send_to_orbit ~= nil then entity.send_to_orbit_automatically = restore.send_to_orbit end
    end
    -- The old entity's on_object_destroyed may not have fired yet; clean up
    -- its ledger entry and index record now (the later event then no-ops)
    index.remove_key(entry.surface_index, entry.item_name, entry.tier, unit_number)
    remove_order(unit_number)
    storage.pending_notify = storage.pending_notify + 1
  end
end

-- Recovery path (on_configuration_changed / quality-gardener-init): adopt an
-- existing upgrade mark into the ledger when it looks like ours — same name,
-- higher quality target. Indistinguishable player marks get adopted too; ones
-- with supply behind them just complete or re-mark, starved ones get expired.
function gardener.adopt(entity)
  if not entity.to_be_upgraded() then return end
  local target_prototype, target_quality = entity.get_upgrade_target()
  if not (target_prototype and target_quality) then return end
  if target_prototype.name ~= entity.name then return end

  local tier = qualities.tier_of(entity.quality.name)
  local target_tier = qualities.tier_of(target_quality.name)
  if not (tier and target_tier) or target_tier <= tier then return end

  local item_name = index.placing_item_name(entity)
  if not item_name then return end

  script.register_on_object_destroyed(entity)
  add_order(entity, item_name, tier, target_tier, capture_restore(entity),
    entity.surface.index, entity.position)
end

return gardener
