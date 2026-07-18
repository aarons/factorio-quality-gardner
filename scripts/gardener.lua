--[[
gardener.lua

The matching engine: a continuous, budgeted pass over the player's logistic
networks. Each tick spends a configurable number of entity touches
(candidates examined, contents rows read, orders issued or cancelled,
positions refreshed), so the cost per tick is small and constant — no burst
scans, no idle gaps. Networks are visited round-robin; entering one reads
everything needed from the live reference in that single tick (supply,
coverage boxes, available construction robots), and all matching then runs
from the plain-data snapshot. Network references never span ticks; the pass
state lives in storage so saves and multiplayer joins resume it identically.

Orders per network are capped by available_construction_robots, read once at
entry with no in-flight accounting: never mark more work than bots can
start. Staleness in the count only delays marks until the next visit.

The ledger (storage.ledger) is the only per-entity state: a transient entry
per order we've issued, used to count outstanding demand and to expire starved
orders. The world is the source of truth — entity upgrade marks always win;
at worst the ledger is rebuilt by adopting marks from a world rescan.

Accounting is deliberately conservative: supply counts items physically in
the network, outstanding orders are subtracted whole, and the brief
double-count while a bot is in flight only ever undercounts. No in-flight
tracking exists.
]]

local qualities = require("scripts.qualities")
local index = require("scripts.index")

local gardener = {}

-- After a player cancels one of our marks, leave the entity alone this long
local REMARK_COOLDOWN_TICKS = 2 * 60 * 60
-- Fraction of the per-tick budget reserved for the position-refresh slice,
-- so sustained marking can't starve it (leftover budget also refreshes)
local REFRESH_SHARE = 10

function gardener.init_storage()
  storage.ledger = {}
  storage.ledger_by_position = {}
  storage.cooldown = {}
  -- Resumable pass state: an integer round-robin cursor plus plain-data
  -- snapshots of the network being worked — never network references (they
  -- invalidate on merge/split, and locals would desync a multiplayer join)
  storage.pass = {cursor = 1}
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

-- Expiry runs once per full round of the networks: our orders older than
-- the timeout are queued, then cancelled under the same per-tick budget.
-- Starved orders stay cancelled (their networks show no supply); healthy-
-- but-slow orders are re-marked when their network is next visited.
local function queue_expired_orders(pass)
  local timeout_minutes = settings.global["order-timeout-minutes"].value
  if timeout_minutes == 0 then return end

  local cutoff = game.tick - math.floor(timeout_minutes * 3600)
  local expired = nil
  for unit_number, entry in pairs(storage.ledger) do
    if entry.tick_ordered <= cutoff then
      expired = expired or {}
      expired[#expired + 1] = unit_number
    end
  end
  if expired then
    pass.expiry = expired
    pass.expiry_index = 1
  end
end

local function run_expiry(pass, budget)
  local queue = pass.expiry
  while budget > 0 and pass.expiry_index <= #queue do
    local unit_number = queue[pass.expiry_index]
    pass.expiry_index = pass.expiry_index + 1
    budget = budget - 1
    local entry = storage.ledger[unit_number]
    if entry then
      local entity = entry.entity
      -- Remove before cancelling so our own on_cancelled_upgrade is a no-op
      remove_order(unit_number)
      if entity.valid and entity.to_be_upgraded() then
        entity.cancel_upgrade(entity.force)
      end
    end
  end
  if pass.expiry_index > #queue then
    pass.expiry = nil
    pass.expiry_index = nil
  end
  return budget
end

-- Supply ------------------------------------------------------------------

-- One get_contents call for the entire network; rows are kept only when the
-- item has candidates on this surface and the quality is a permitted upgrade
-- target. Returns supply[item_name][tier] = count (or nil, the common exit)
-- and the number of rows examined.
local function read_supply(network, surface_index)
  local rows = network.get_contents()
  local supply = nil
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
  return supply, #rows
end

-- Coverage ----------------------------------------------------------------

-- Construction areas are squares: one AABB per stationary cell, built once
-- at network entry (API cost scales with roboport count, never entities)
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
-- target quality; subtract them. Grouping is recomputed at every network
-- entry — network identity is transient, so nothing network-shaped is stored.
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
-- target, re-issue the order at the higher target (ours only).
local function try_raise(net, unit_number)
  local entry = storage.ledger[unit_number]
  if not entry or entry.surface_index ~= net.surface_index then return end
  local by_tier = net.supply[entry.item_name]
  if not by_tier then return end

  local best = nil
  for tier, count in pairs(by_tier) do
    if count > 0 and tier > entry.target_tier and (not best or tier > best) then
      best = tier
    end
  end
  if not best then return end

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
      net.bots = net.bots - 1
    end
  end
end

-- The supply tier a candidate at this tier would be upgraded to, or nil
local function pick_target(item, by_tier)
  for _, tier in ipairs(item.supply_tiers) do
    if tier <= item.candidate_tier then return nil end
    if by_tier[tier] > 0 then return tier end
  end
  return nil
end

-- The marking cursor for one item: candidate tiers ascending (worst first),
-- supply tiers descending (best target first). Unit lists are snapshotted
-- per tier as the cursor reaches them (marking mutates buckets via removals).
local function build_item_state(net, item_name)
  local by_tier = net.supply[item_name]
  local supply_tiers = {}
  for tier, count in pairs(by_tier) do
    if count > 0 then supply_tiers[#supply_tiers + 1] = tier end
  end
  if #supply_tiers == 0 then return nil end
  table.sort(supply_tiers, function(a, b) return a > b end)

  local buckets = index.get_buckets(net.surface_index, item_name)
  if not buckets then return nil end
  local candidate_tiers = {}
  for tier in pairs(buckets) do candidate_tiers[#candidate_tiers + 1] = tier end
  table.sort(candidate_tiers)

  return {
    item_name = item_name,
    supply_tiers = supply_tiers,
    candidate_tiers = candidate_tiers,
    tier_index = 0,
    candidate_tier = nil,
    units = {},
    unit_index = 1,
  }
end

-- Advance the item cursor to the next unit number, or nil (item exhausted)
local function next_unit(net, item)
  while true do
    if item.unit_index <= #item.units then
      local unit_number = item.units[item.unit_index]
      item.unit_index = item.unit_index + 1
      return unit_number
    end
    item.tier_index = item.tier_index + 1
    local tier = item.candidate_tiers[item.tier_index]
    if not tier then return nil end
    item.candidate_tier = tier
    item.units = {}
    item.unit_index = 1
    if pick_target(item, net.supply[item.item_name]) then
      local buckets = index.get_buckets(net.surface_index, item.item_name)
      local bucket = buckets and buckets[tier]
      if bucket then
        for unit_number in pairs(bucket) do
          item.units[#item.units + 1] = unit_number
        end
      end
    end
  end
end

local function try_mark(net, item, unit_number)
  local by_tier = net.supply[item.item_name]
  local target_tier = pick_target(item, by_tier)
  if not target_tier then
    -- Availability exhausted for this candidate tier; skip its remaining units
    item.unit_index = #item.units + 1
    return
  end

  local buckets = index.get_buckets(net.surface_index, item.item_name)
  local bucket = buckets and buckets[item.candidate_tier]
  local record = bucket and bucket[unit_number]
  if not record or storage.ledger[unit_number] or on_cooldown(unit_number)
    or not in_coverage(net.boxes, record.x, record.y) then
    return
  end

  local entity = record.entity
  if not entity.valid then
    index.remove_key(net.surface_index, item.item_name, item.candidate_tier, unit_number)
    return
  end
  if entity.to_be_upgraded() or entity.to_be_deconstructed() then return end

  -- Cached position is a hint; the entity is authoritative (teleport mods)
  local position = entity.position
  record.x = position.x
  record.y = position.y
  if not in_coverage(net.boxes, position.x, position.y) then return end

  local restore = capture_restore(entity)
  script.register_on_object_destroyed(entity)
  local ok = entity.order_upgrade{
    target = {name = entity.name, quality = qualities.at(target_tier).name},
    force = entity.force,
  }
  if ok then
    add_order(entity, item.item_name, item.candidate_tier, target_tier, restore,
      net.surface_index, position)
    by_tier[target_tier] = by_tier[target_tier] - 1
    net.bots = net.bots - 1
  end
end

-- Advance the current network snapshot by up to `budget` touches; returns
-- the remaining budget. Clears the snapshot when its work or the bot
-- headroom is exhausted.
local function step_network(pass, budget)
  local net = pass.network

  while budget > 0 and net.raise_index <= #net.raises do
    local unit_number = net.raises[net.raise_index]
    net.raise_index = net.raise_index + 1
    budget = budget - 1
    try_raise(net, unit_number)
    if net.bots <= 0 then
      pass.network = nil
      return budget
    end
  end

  while budget > 0 do
    local item = net.item
    if item then
      local unit_number = next_unit(net, item)
      if unit_number then
        budget = budget - 1
        try_mark(net, item, unit_number)
        if net.bots <= 0 then
          pass.network = nil
          return budget
        end
      else
        net.item = nil
      end
    else
      net.item_index = net.item_index + 1
      local item_name = net.items[net.item_index]
      if not item_name then
        pass.network = nil
        return budget
      end
      net.item = build_item_state(net, item_name)
    end
  end
  return budget
end

-- Network entry -----------------------------------------------------------

-- Enter a network: read everything needed from the live reference in this
-- single tick — supply, coverage boxes, bot headroom — so only plain-data
-- snapshots ever span ticks. Costs one touch plus one per contents row.
local function enter_network(network, surface_index, pass, budget)
  budget = budget - 1
  if not network.valid then return budget end

  local bots = network.available_construction_robots
  if bots == 0 then return budget end

  local supply, rows = read_supply(network, surface_index)
  budget = budget - rows
  if not supply then return budget end

  local boxes = build_coverage(network)
  if #boxes == 0 then return budget end

  subtract_outstanding(supply, surface_index, boxes)

  -- Snapshot our pending orders eligible for a raise in this network
  local raises = {}
  for unit_number, entry in pairs(storage.ledger) do
    if entry.surface_index == surface_index and supply[entry.item_name]
      and in_coverage(boxes, entry.x, entry.y) then
      raises[#raises + 1] = unit_number
    end
  end

  local items = {}
  for item_name in pairs(supply) do
    items[#items + 1] = item_name
  end

  pass.network = {
    surface_index = surface_index,
    supply = supply,
    boxes = boxes,
    bots = bots,
    raises = raises,
    raise_index = 1,
    items = items,
    item_index = 0,
    item = nil,
  }
  return budget
end

-- Networks are re-enumerated fresh at every use (merges and splits handled
-- for free); only the integer cursor persists, so a mid-round merge or split
-- at worst skips or repeats a network for one round.
local function collect_network_slots()
  local slots = {}
  for surface_name, networks in pairs(game.forces.player.logistic_networks) do
    local surface = game.surfaces[surface_name]
    if surface and storage.candidates[surface.index] then
      for _, network in pairs(networks) do
        slots[#slots + 1] = {network = network, surface_index = surface.index}
      end
    end
  end
  return slots
end

-- The per-tick loop -------------------------------------------------------

function gardener.on_tick()
  local budget = settings.global["entities-per-tick"].value
  local refresh_budget = math.floor(budget / REFRESH_SHARE)
  budget = budget - refresh_budget

  local pass = storage.pass
  local slots = nil
  local entered = 0

  while budget > 0 do
    if pass.expiry then
      budget = run_expiry(pass, budget)
    elseif pass.network then
      budget = step_network(pass, budget)
    else
      slots = slots or collect_network_slots()
      if #slots == 0 or entered >= #slots then break end
      if pass.cursor > #slots then
        pass.cursor = 1
        queue_expired_orders(pass)
      else
        entered = entered + 1
        local slot = slots[pass.cursor]
        pass.cursor = pass.cursor + 1
        budget = enter_network(slot.network, slot.surface_index, pass, budget)
      end
    end
  end

  -- The reserved share plus any leftover refreshes cached positions
  local refresh = refresh_budget + math.max(0, budget)
  if refresh > 0 then
    index.refresh_slice(refresh)
  end
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
  if not index.placing_item_name(entity) then return end

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
