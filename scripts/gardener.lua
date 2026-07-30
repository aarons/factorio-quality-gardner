--[[
gardener.lua

The matching engine: a stateless, scan-based pass over the player's logistic
networks. Networks are visited round-robin; entering one reads everything
needed from the live reference in that single tick (bot headroom, contents,
construction cell boxes), then the covered entities are scanned one cell at a
time and matched against the plain-data snapshot.

Marked entities are recognized by asking the entity itself (to_be_upgraded());
every visible mark — ours from a past round, a player's upgrade-planner mark,
or another mod's — consumes supply as demand. The one piece of per-entity
state is the order ledger, recording the two facts the world cannot answer:
that a mark is ours, and when we placed it. A ledgered mark that has outlived
the order-expiry setting with its target quality out of stock is starved —
biter damage forced rebuilds, or player upgrades drained the stock it counted
on — and is cancelled so the entity becomes an ordinary candidate again. A
ledger miss means hands off: player marks are never touched, and a lost
ledger just means existing orders never expire. Orphaned entries are pruned
by a budgeted sweep between rounds.

Ghosts are scanned too: one requesting a stocked quality just consumes supply
as demand; one requesting an unstocked quality is retargeted to the best
quality on hand — even a lower one — so it gets built at all.

Modules follow the same philosophy on built entities only (ghost module slots
are out of scope). An installed module with a higher stocked tier gets a swap
ordered through an item-request-proxy; a pending proxy request whose quality
is stocked is left to the bots (counted as demand); one whose quality is out
of stock is retargeted to the best stocked tier of the same module — even a
lower one, because a downgrade beats an empty slot. Module changes are
quality-only: which module prototype sits in a slot is never changed.
]]

local qualities = require("scripts.qualities")

local gardener = {}

-- The pass runs every tick; each invocation spends up to entities-per-tick
-- budget steps.
gardener.PASS_INTERVAL_TICKS = 1

function gardener.initialize_storage()
  -- Abandoning the pass state is always safe (the next pass re-derives
  -- everything from the world). Resetting the order ledger is safe too:
  -- orphaned marks simply never expire.
  storage.pass = {cursor = 1}
  storage.order_ledger = {}
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

  local bot_headroom = network.available_construction_robots
  if bot_headroom == 0 then return nil end

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
    bot_headroom = bot_headroom,
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
local function examine_ghost(network_snapshot, entity)
  local item_name = storage.config.placing_item_name[entity.ghost_name]
  if not item_name then return end
  local tier = qualities.tier_of(entity.quality.name)
  if not tier then return end
  local by_tier = network_snapshot.supply[item_name]
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
    network_snapshot.bot_headroom = network_snapshot.bot_headroom - 1
  end
end

-- Building upgrade: mark the entity when a higher tier of its placing item is
-- stocked. Returns true when an order was issued (module work then waits for
-- a later round — an upgrade swap would orphan any proxy work).
local function examine_building(network_snapshot, entity)
  local item_name = storage.config.placing_item_name[entity.name]
  if not item_name then return false end
  local tier = qualities.tier_of(entity.quality.name)
  if not tier then return false end

  local by_tier = network_snapshot.supply[item_name]
  if not by_tier then return false end
  local target_tier = best_stocked_tier(by_tier)
  if not target_tier or target_tier <= tier then return false end

  local ok = entity.order_upgrade{
    target = {name = entity.name, quality = qualities.at(target_tier).name},
    force = entity.force,
  }
  if ok then
    by_tier[target_tier] = by_tier[target_tier] - 1
    network_snapshot.bot_headroom = network_snapshot.bot_headroom - 1
    storage.order_ledger[entity.unit_number] = {
      entity = entity,
      order_tick = game.tick,
      target_quality = qualities.at(target_tier).name,
    }
  end
  return ok
end

-- Prototype name behind a plan row's id field. 2.1 documents these as plain
-- strings, 2.0 as ItemID/QualityID ("returns LuaItemPrototype when read"), and
-- the 2.1 changelog records no behavior change between them — so one doc is
-- describing the other's runtime and neither reading is verified in-game.
-- Reading through .name covers both; a name written back is accepted either
-- way. Under the prototype reading the plain field lookups silently missed,
-- which stopped module request retargeting without any error.
local function name_of(id_field)
  if id_field == nil then return nil end
  if type(id_field) == "string" then return id_field end
  return id_field.name
end

-- Modules a plan row asks for: the sum of its per-stack counts. Rows with no
-- inventory positions (e.g. equipment-grid requests) count as zero.
local function plan_module_count(plan)
  local positions = plan.items and plan.items.in_inventory
  if not positions then return 0 end
  local count = 0
  for _, position in ipairs(positions) do
    count = count + (position.count or 1)
  end
  return count
end

-- A pending proxy on a built entity. Every fulfillable request row consumes
-- supply as demand (the proxy is a visible mark, whoever made it). A module
-- row whose quality is out of stock is retargeted in place — insert_plan is
-- read-write — to the best stocked tier of the same module, a downgrade
-- included: filled now beats empty until the requested tier shows up. Only
-- the quality moves; the module prototype and slot positions are untouched.
-- Non-module rows (fuel, ammo) are never retargeted.
--
-- Overlapping cells can revisit the same proxy within one visit; while stock
-- at the requested tier stays positive the second pass just re-counts demand,
-- and only exhausted stock can step a row down again. Accepted thrash — items
-- in flight are invisible to the snapshot either way.
local function examine_proxy(network_snapshot, proxy)
  local plans = proxy.insert_plan
  local changed = false
  for _, plan in ipairs(plans) do
    local item_name = name_of(plan.id.name)
    local tier = qualities.tier_of(name_of(plan.id.quality) or "normal")
    local by_tier = tier and item_name and network_snapshot.supply[item_name]
    if by_tier then
      local count = plan_module_count(plan)
      local stock = by_tier[tier]
      if stock and stock > 0 then
        -- Stocked: bots will fill this; its demand consumes the supply.
        by_tier[tier] = stock - count
      elseif count > 0 and count <= network_snapshot.bot_headroom
        and storage.config.module_item[item_name] then
        local best = best_stocked_tier(by_tier)
        if best then
          plan.id.quality = qualities.at(best).name
          by_tier[best] = by_tier[best] - count
          network_snapshot.bot_headroom = network_snapshot.bot_headroom - count
          changed = true
        end
      end
    end
  end
  if changed then
    proxy.insert_plan = plans
  end
end

-- Installed modules: for each slot holding a module with a higher stocked
-- tier, order a swap — removal of the installed module plus insert of the
-- better one at the same slot — batched into one proxy per entity. Installed
-- modules are never downgraded: a player chose them, and unlike a request an
-- installed module is not an empty slot waiting to be filled. Removals are
-- ignored in the supply snapshot (stock returns only after the bot trip);
-- each insert costs one unit of bot headroom.
local function examine_modules(network_snapshot, entity)
  local module_inventory = entity.get_module_inventory()
  if not module_inventory or #module_inventory == 0 then return end

  local proxy = entity.item_request_proxy
  if proxy and proxy.valid then
    -- An in-flight proxy owns this entity's module logistics; only its
    -- requests are examined. Installed-module swaps wait for a later round.
    return examine_proxy(network_snapshot, proxy)
  end

  local inventory_index = module_inventory.index
  if not inventory_index then return end

  local removal_plans, insert_plans
  for slot = 1, #module_inventory do
    if network_snapshot.bot_headroom <= 0 then break end
    local stack = module_inventory[slot]
    if stack.valid_for_read then
      local tier = qualities.tier_of(stack.quality.name)
      local by_tier = tier and network_snapshot.supply[stack.name]
      if by_tier then
        local best = best_stocked_tier(by_tier)
        if best and best > tier then
          -- Plan stack indices are 0-based, unlike LuaInventory's 1-based.
          local position = {inventory = inventory_index, stack = slot - 1, count = 1}
          removal_plans = removal_plans or {}
          removal_plans[#removal_plans + 1] = {
            id = {name = stack.name, quality = stack.quality.name},
            items = {in_inventory = {position}},
          }
          insert_plans = insert_plans or {}
          insert_plans[#insert_plans + 1] = {
            id = {name = stack.name, quality = qualities.at(best).name},
            items = {in_inventory = {position}},
          }
          by_tier[best] = by_tier[best] - 1
          network_snapshot.bot_headroom = network_snapshot.bot_headroom - 1
        end
      end
    end
  end

  if insert_plans then
    entity.surface.create_entity{
      name = "item-request-proxy",
      position = entity.position,
      force = entity.force,
      target = entity,
      modules = insert_plans,
      removal_plan = removal_plans,
    }
  end
end

-- One iteration: examine one scanned entity, first-come-first-served in scan
-- order. Duplicates from overlapping cells are harmless — once marked, later
-- encounters take the demand-accounting path.
local function examine(network_snapshot, entity)
  if not entity.valid then return end
  if entity.force.name ~= "player" then return end
  if entity.name == "entity-ghost" then
    return examine_ghost(network_snapshot, entity)
  end
  if entity.to_be_deconstructed() then return end

  if entity.to_be_upgraded() then
    -- Marked entities get no module orders — the swap would orphan them.
    local target_prototype, target_quality = entity.get_upgrade_target()
    local target_item = target_prototype
      and storage.config.placing_item_name[target_prototype.name]
    local by_tier = target_item and network_snapshot.supply[target_item]
    local target_tier = target_quality and qualities.tier_of(target_quality.name)

    local entry = storage.order_ledger[entity.unit_number]
    if entry then
      if target_prototype and target_prototype.name == entity.name
        and target_quality and target_quality.name == entry.target_quality then
        -- Still the mark we placed. Expired with the target out of stock
        -- means starved; a queued-but-stocked order is the bots' business.
        local expiry_ticks = settings.global["order-expiry-seconds"].value * 60
        local stock = by_tier and target_tier and by_tier[target_tier]
        if expiry_ticks > 0
          and game.tick - entry.order_tick >= expiry_ticks
          and not (stock and stock > 0)
          and entity.cancel_upgrade(entity.force) then
          storage.order_ledger[entity.unit_number] = nil
          -- No mark left, no demand; an ordinary candidate again next round.
          return
        end
      else
        -- Re-marked to a different target since we ordered: whoever did
        -- that owns the mark now.
        storage.order_ledger[entity.unit_number] = nil
      end
    end

    -- Demand accounting: an existing mark consumes supply at its target.
    if by_tier and target_tier then
      by_tier[target_tier] = (by_tier[target_tier] or 0) - 1
    end
    return
  end

  if examine_building(network_snapshot, entity) then return end
  if network_snapshot.bot_headroom > 0 then
    examine_modules(network_snapshot, entity)
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
local function scan_cell(network_snapshot)
  local surface = game.get_surface(network_snapshot.surface_index)
  if not surface then return nil end
  return surface.find_entities_filtered{
    area = network_snapshot.cells[network_snapshot.cell_index],
    force = "player",
    type = storage.config.all_tracked_types,
  }
end

-- One budgeted step of the ledger sweep that runs between rounds: check one
-- entry, pruning it when its entity is gone (destroyed, or replaced by the
-- completed upgrade) or no longer marked (the player cancelled). Housekeeping
-- only, not correctness — a stale entry can at worst match a mark identical
-- to one we would place — so a save/load reordering the hash walk mid-sweep
-- is harmless. Entries are deleted only here and at examine time, never while
-- the sweep cursor points at them, so resuming next() from the stored key is
-- safe.
local function sweep_ledger_step(pass)
  local ledger = storage.order_ledger
  local key = pass.sweep_cursor
  local entry
  if key == nil then
    key, entry = next(ledger)
  else
    entry = ledger[key]
  end
  if not entry then
    -- Ledger exhausted (or the cursor's entry vanished across a reload —
    -- the next round's sweep starts fresh either way).
    pass.sweeping = nil
    pass.sweep_cursor = nil
    return
  end
  pass.sweep_cursor = (next(ledger, key))
  if not (entry.entity.valid and entry.entity.to_be_upgraded()) then
    ledger[key] = nil
  end
  if pass.sweep_cursor == nil then
    pass.sweeping = nil
  end
end

function gardener.on_pass()
  local pass = storage.pass
  local budget = settings.global["entities-per-tick"].value
  local scanned_cell_this_invocation = false

  while budget > 0 do
    local network_snapshot = pass.network_snapshot
    if pass.sweeping then
      -- Between rounds: sweep the ledger during the rest window.
      budget = budget - 1
      sweep_ledger_step(pass)
    elseif pass.resume_tick then
      if game.tick < pass.resume_tick then return end
      pass.resume_tick = nil
    elseif not network_snapshot then
      -- One iteration: advance the cursor and enter the next network
      budget = budget - 1
      local slots = collect_network_slots()
      if pass.cursor > #slots then
        -- Round complete: rest, giving bots time to collect ordered items so
        -- the next round's contents reads are close to accurate. The ledger
        -- sweep overlaps the rest, delaying the next round only when the
        -- ledger outlasts the delay.
        pass.cursor = 1
        pass.resume_tick = game.tick
          + math.floor(settings.global["round-delay-seconds"].value * 60)
        pass.sweeping = true
        pass.sweep_cursor = nil
      else
        local slot = slots[pass.cursor]
        pass.cursor = pass.cursor + 1
        pass.network_snapshot = enter_network(slot.network, slot.surface_index)
      end
    elseif network_snapshot.entities and network_snapshot.entity_index <= #network_snapshot.entities then
      budget = budget - 1
      local entity = network_snapshot.entities[network_snapshot.entity_index]
      network_snapshot.entity_index = network_snapshot.entity_index + 1
      examine(network_snapshot, entity)
      if network_snapshot.bot_headroom <= 0 then
        -- Bot headroom spent: abandon the rest of this network
        pass.network_snapshot = nil
      end
    else
      network_snapshot.cell_index = network_snapshot.cell_index + 1
      if network_snapshot.cell_index > #network_snapshot.cells then
        pass.network_snapshot = nil
      elseif scanned_cell_this_invocation then
        -- At most one scan burst per invocation; resume here next time
        network_snapshot.cell_index = network_snapshot.cell_index - 1
        return
      else
        scanned_cell_this_invocation = true
        budget = budget - 1
        network_snapshot.entities = scan_cell(network_snapshot)
        network_snapshot.entity_index = 1
        if not network_snapshot.entities then
          pass.network_snapshot = nil
        end
      end
    end
  end
end

return gardener
