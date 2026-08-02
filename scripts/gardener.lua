--[[
gardener.lua

The matching engine: a budgeted, round-robin scan pass over logistic networks
and space platforms. Player-facing behavior is in README.md, design invariants
in CLAUDE.md, rationale and history in docs/decisions.md.
]]

local qualities = require("scripts.qualities")

local gardener = {}

gardener.PASS_INTERVAL_TICKS = 1

function gardener.initialize_storage()
  storage.pass = {cursor = 1}
  storage.order_ledger = {}
  storage.platform_wait_ledger = {}
  -- Storage keys from retired architectures; nil them so old saves migrate.
  storage.candidates = nil
  storage.ledger = nil
  storage.ledger_by_position = nil
  storage.cooldown = nil
  storage.refresh = nil
end

-- Network entry -------------------------------------------------------------

-- Fold a contents array (network get_contents or hub inventory) into
-- supply[item_name][tier] = count.
local function read_supply(contents)
  local supply = {}
  for _, row in ipairs(contents) do
    local tier = qualities.tier_of(row.quality)
    if tier then
      local by_tier = supply[row.name]
      if not by_tier then
        by_tier = {}
        supply[row.name] = by_tier
      end
      by_tier[tier] = (by_tier[tier] or 0) + row.count
    end
  end
  -- The player's reserve comes off every stocked tier up front; from here
  -- on, supply means spendable stock.
  local reserve = settings.global["reserve-per-item"].value
  if reserve > 0 then
    for _, by_tier in pairs(supply) do
      for tier in pairs(by_tier) do
        by_tier[tier] = by_tier[tier] - reserve
      end
    end
  end
  return supply
end

-- Enter one network: read everything needed from the live reference in this
-- single tick (the reference is never carried forward). Returns the plain-data
-- work state, or nil to skip the network.
local function enter_network(network, surface_index)
  if not network.valid then return nil end

  local manage_factory = settings.global["manage-factory"].value
  local manage_ghosts = settings.global["manage-ghosts"].value
  local manage_upgrade_requests = settings.global["manage-upgrade-requests"].value
  if not (manage_factory or manage_ghosts or manage_upgrade_requests) then
    return nil
  end

  local bot_headroom = network.available_construction_robots
  if bot_headroom == 0 then return nil end

  local supply = read_supply(network.get_contents())

  -- One box per stationary cell's construction area, scanned one cell at a
  -- time to bound each find_entities_filtered burst.
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
    order_budget = bot_headroom,
    cells = cells,
    cell_index = 0,
    entities = nil,
    entity_index = 1,
    manage_factory = manage_factory,
    manage_ghosts = manage_ghosts,
    manage_upgrade_requests = manage_upgrade_requests,
  }
end

-- What is physically en route to the hub (rockets and platform-to-platform
-- cargo pods both), as a set keyed "item/quality".
local function read_platform_inbound(point)
  local inbound = {}
  local deliveries = point and point.targeted_items_deliver
  if deliveries then
    for _, row in ipairs(deliveries) do
      inbound[row.name .. "/" .. row.quality] = true
    end
  end
  return inbound
end

-- Items the hub requests: point.filters merges the player's manual sections
-- and the hub's auto-generated construction section. Any filter on the item
-- counts, whatever its quality or count — a false match only starts a wait
-- clock.
local function read_platform_requests(point)
  local requested = {}
  local filters = point and point.filters
  if filters then
    for _, filter in ipairs(filters) do
      if filter.name then requested[filter.name] = true end
    end
  end
  return requested
end

-- Enter one platform, re-fetched from the force by index (the reference is
-- never stored). The snapshot shape matches enter_network, plus the
-- delivery-wait data.
local function enter_platform(platform_index)
  local platform = game.forces.player.platforms[platform_index]
  if not (platform and platform.valid) then return nil end
  -- Platforms pending deletion still enumerate; the surface is nil before
  -- the starter pack lands; the hub can be valid-but-doomed the tick it dies.
  if platform.scheduled_for_deletion ~= 0 then return nil end
  local surface = platform.surface
  if not (surface and surface.valid) then return nil end
  local hub = platform.hub
  if not (hub and hub.valid) then return nil end

  local manage_factory = settings.global["manage-factory"].value
  local manage_ghosts = settings.global["manage-ghosts"].value
  local manage_upgrade_requests = settings.global["manage-upgrade-requests"].value
  if not (manage_factory or manage_ghosts or manage_upgrade_requests) then
    return nil
  end

  -- Spendable stock is hub_main only (cargo bays extend it; hub_trash is
  -- items leaving). Orders are placed only against existing stock
  -- never against inbound or requested items.
  local hub_inventory = hub.get_inventory(defines.inventory.hub_main)
  if not hub_inventory then return nil end
  local point = hub.get_logistic_point(
    defines.logistic_member_index.space_platform_hub_requester)

  return {
    surface_index = surface.index,
    platform = true,
    supply = read_supply(hub_inventory.get_contents()),
    -- No bots, no cap: stock alone bounds orders on a platform.
    order_budget = math.huge,
    -- Platforms have no coverage cells; one whole-surface scan stands in.
    cells = {"whole-surface"},
    cell_index = 0,
    entities = nil,
    entity_index = 1,
    manage_factory = manage_factory,
    manage_ghosts = manage_ghosts,
    manage_upgrade_requests = manage_upgrade_requests,
    inbound = read_platform_inbound(point),
    requested = read_platform_requests(point),
    auto_request = hub.request_missing_construction_materials,
    deliveries_possible = platform.space_location ~= nil,
  }
end

-- Matching -------------------------------------------------------------------

-- The supply idiom: stock_count answers availability, stock_consume books
-- demand. Booked stock may go negative — every mark, ghost, and request row
-- books its full need, so later orders never count on supply already
-- claimed. Only positive counts read as available.
local function stock_count(by_tier, tier)
  return by_tier and by_tier[tier] or 0
end

local function stock_consume(by_tier, tier, count)
  by_tier[tier] = (by_tier[tier] or 0) - count
end

-- Highest tier with stock remaining, or nil. Supply is decremented in place,
-- so the snapshot itself is the availability cache.
local function best_stocked_tier(by_tier)
  local best = nil
  for tier, count in pairs(by_tier) do
    if count > 0 and (not best or tier > best) then
      best = tier
    end
  end
  return best
end

-- May a starved target — ghost, player mark, or module request — be
-- retargeted right now, or should it wait for a delivery? The wait clock
-- lives in storage.platform_wait_ledger, keyed by unit number; it starts the
-- first time the target is seen starved and resets when the target changes.
-- A true return does not clear the entry — the caller clears after acting —
-- so an elapsed clock stays elapsed and acts the moment stock appears.
local function platform_retarget_allowed(network_snapshot, entity, target_name, target_quality_name)
  local wait_ledger = storage.platform_wait_ledger
  local unit_number = entity.unit_number

  -- The exact item and quality is physically en route: leave the target alone.
  if network_snapshot.inbound[target_name .. "/" .. target_quality_name] then
    wait_ledger[unit_number] = nil
    return false
  end

  -- In transit, deliveries impossible: act immediately — a downgrade now
  -- beats a hole in the defenses for the rest of the trip.
  if not network_snapshot.deliveries_possible then return true end

  -- A request may be in play: run the wait clock. A request only starts the
  -- clock, never vetoes retargeting — the timeout is the stale-request
  -- handling.
  if network_snapshot.requested[target_name] or network_snapshot.auto_request then
    local entry = wait_ledger[unit_number]
    if entry and (entry.target_name ~= target_name
      or entry.target_quality ~= target_quality_name) then
      -- Re-marked since the clock started: a new wait.
      entry = nil
    end
    if not entry then
      entry = {
        entity = entity,
        order_tick = game.tick,
        target_name = target_name,
        target_quality = target_quality_name,
      }
      wait_ledger[unit_number] = entry
    end
    local wait_ticks = math.floor(
      settings.global["space-platform-delivery-wait-seconds"].value * 60)
    return game.tick - entry.order_tick >= wait_ticks
  end

  -- Nothing requested and auto-request off: nothing is coming.
  return true
end

-- A ghost whose exact quality is stocked is left for the bots (counted as
-- demand); otherwise it is retargeted to the best stocked tier of its item.
local function examine_ghost(network_snapshot, entity)
  local item_name = storage.config.placing_item_name[entity.ghost_name]
  if not item_name then return end
  local tier = qualities.tier_of(entity.quality.name)
  if not tier then return end

  local by_tier = network_snapshot.supply[item_name]
  if stock_count(by_tier, tier) > 0 then
    stock_consume(by_tier, tier, 1)
    if network_snapshot.platform then
      -- Target seen stocked: any wait clock is stale.
      storage.platform_wait_ledger[entity.unit_number] = nil
    end
    return
  end

  -- Demand was counted above; the toggle gates only the retarget.
  if not network_snapshot.manage_ghosts then return end

  -- The wait rules run before the stock check so the clock starts at first
  -- starvation, even with nothing aboard to retarget to.
  if network_snapshot.platform
    and not platform_retarget_allowed(network_snapshot, entity,
      entity.ghost_name, entity.quality.name) then
    return
  end

  local best = by_tier and best_stocked_tier(by_tier)
  if not best then return end

  local ok = entity.order_upgrade{
    target = {name = entity.ghost_name, quality = qualities.at(best).name},
    force = entity.force,
  }
  if ok then
    stock_consume(by_tier, best, 1)
    network_snapshot.order_budget = network_snapshot.order_budget - 1
    if network_snapshot.platform then
      storage.platform_wait_ledger[entity.unit_number] = nil
    end
  end
end

-- Mark the entity for upgrade when a higher tier of its placing item is
-- stocked. Returns true when an order was issued — module work then waits
-- for a later round, since the upgrade swap would orphan any proxy work.
local function examine_building(network_snapshot, entity)
  if not network_snapshot.manage_factory then return false end
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
    stock_consume(by_tier, target_tier, 1)
    network_snapshot.order_budget = network_snapshot.order_budget - 1
    storage.order_ledger[entity.unit_number] = {
      entity = entity,
      order_tick = game.tick,
      target_quality = qualities.at(target_tier).name,
    }
  end
  return ok
end

-- Prototype name behind a plan row's id field, which the API docs type as a
-- string (2.1) or a prototype (2.0) with neither verified in-game — reading
-- through .name covers both. Don't simplify to a plain field lookup: under
-- the prototype reading it silently misses (see docs/api-notes.md).
local function name_of(id_field)
  if id_field == nil then return nil end
  if type(id_field) == "string" then return id_field end
  return id_field.name
end

-- Modules a plan row asks for: the sum of its per-stack counts. Rows with no
-- inventory positions (equipment-grid requests) count as zero.
local function plan_module_count(plan)
  local positions = plan.items and plan.items.in_inventory
  if not positions then return 0 end
  local count = 0
  for _, position in ipairs(positions) do
    count = count + (position.count or 1)
  end
  return count
end

-- A pending proxy on a built entity. Stocked request rows consume supply as
-- demand; a starved module row is retargeted in place (insert_plan is
-- read-write) to the best stocked tier of the same module. Non-module rows
-- (fuel, ammo) are never retargeted. On a platform the wait clock runs at
-- proxy granularity: one entry keyed by the proxy, its target recorded from
-- the first starved module row.
local function examine_proxy(network_snapshot, proxy)
  local plans = proxy.insert_plan
  local changed = false
  -- nil until the first starved module row runs the wait rules; nil at the
  -- end means no row was starved.
  local retarget_allowed
  for _, plan in ipairs(plans) do
    local item_name = name_of(plan.id.name)
    local quality_name = name_of(plan.id.quality) or "normal"
    local tier = item_name and qualities.tier_of(quality_name)
    if tier then
      local by_tier = network_snapshot.supply[item_name]
      local count = plan_module_count(plan)
      if stock_count(by_tier, tier) > 0 then
        stock_consume(by_tier, tier, count)
      elseif network_snapshot.manage_factory
        and count > 0 and count <= network_snapshot.order_budget
        and storage.config.module_item[item_name] then
        if retarget_allowed == nil then
          retarget_allowed = not network_snapshot.platform
            or platform_retarget_allowed(network_snapshot, proxy, item_name, quality_name)
        end
        local best = retarget_allowed and by_tier and best_stocked_tier(by_tier)
        if best then
          plan.id.quality = qualities.at(best).name
          stock_consume(by_tier, best, count)
          network_snapshot.order_budget = network_snapshot.order_budget - count
          changed = true
        end
      end
    end
  end
  if changed then
    proxy.insert_plan = plans
  end
  if network_snapshot.platform and (changed or retarget_allowed == nil) then
    -- Acted, or no starved module row this visit: any wait clock is stale.
    storage.platform_wait_ledger[proxy.unit_number] = nil
  end
end

-- Installed modules: for each slot holding a module with a higher stocked
-- tier, order a swap — removal plus insert at the same slot — batched into
-- one proxy per entity. Installed modules are never downgraded. Removals are
-- ignored in the supply snapshot: stock returns only after the bot trip.
local function examine_modules(network_snapshot, entity)
  local module_inventory = entity.get_module_inventory()
  if not module_inventory or #module_inventory == 0 then return end

  local proxy = entity.item_request_proxy
  if proxy and proxy.valid then
    -- An in-flight proxy owns this entity's module logistics; installed-
    -- module swaps wait for a later round.
    return examine_proxy(network_snapshot, proxy)
  end

  if not network_snapshot.manage_factory then return end

  local inventory_index = module_inventory.index
  if not inventory_index then return end

  local removal_plans, insert_plans
  for slot = 1, #module_inventory do
    if network_snapshot.order_budget <= 0 then break end
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
          stock_consume(by_tier, best, 1)
          network_snapshot.order_budget = network_snapshot.order_budget - 1
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

-- Returns the ledger entry while the mark is still the one we placed, plus a
-- "cancelled just now" flag. Cancellation requires membership, expiry, and
-- starvation. An entity re-marked to a different target is dropped from the
-- ledger: whoever re-marked it owns the mark now.
local function reconcile_order_ledger(entity, target_prototype, target_quality, starved)
  local entry = storage.order_ledger[entity.unit_number]
  if not entry then return nil, false end

  if not (target_prototype and target_prototype.name == entity.name
    and target_quality and target_quality.name == entry.target_quality) then
    storage.order_ledger[entity.unit_number] = nil
    return nil, false
  end

  local expiry_ticks = settings.global["order-expiry-seconds"].value * 60
  if expiry_ticks > 0
    and game.tick - entry.order_tick >= expiry_ticks
    and starved
    and entity.cancel_upgrade(entity.force) then
    storage.order_ledger[entity.unit_number] = nil
    return nil, true
  end
  return entry, false
end

-- A marked entity. An expired, starved ledgered mark is cancelled. A starved
-- non-ledgered mark (a player's or another mod's) is retargeted to the best
-- stocked tier of its target item — quality only, and it stays unledgered.
-- Whatever survives counts as demand.
local function examine_marked(network_snapshot, entity)
  local target_prototype, target_quality = entity.get_upgrade_target()
  local target_item = target_prototype
    and storage.config.placing_item_name[target_prototype.name]
  local by_tier = target_item and network_snapshot.supply[target_item]
  local target_tier = target_quality and qualities.tier_of(target_quality.name)
  local starved = not (target_tier and stock_count(by_tier, target_tier) > 0)

  local entry, cancelled =
    reconcile_order_ledger(entity, target_prototype, target_quality, starved)
  if cancelled then return end

  if network_snapshot.platform and not starved then
    -- Target seen stocked: any wait clock is stale.
    storage.platform_wait_ledger[entity.unit_number] = nil
  end

  if network_snapshot.manage_upgrade_requests
    and not entry and starved
    and target_prototype and target_item and target_tier
    and (not network_snapshot.platform
      or platform_retarget_allowed(network_snapshot, entity,
        target_prototype.name, target_quality.name)) then
    local best = by_tier and best_stocked_tier(by_tier)
    if best then
      local ok = entity.order_upgrade{
        target = {name = target_prototype.name, quality = qualities.at(best).name},
        force = entity.force,
      }
      if ok then
        stock_consume(by_tier, best, 1)
        network_snapshot.order_budget = network_snapshot.order_budget - 1
        if network_snapshot.platform then
          storage.platform_wait_ledger[entity.unit_number] = nil
        end
        return
      end
    end
  end

  -- Demand accounting: an existing mark consumes supply at its target.
  if by_tier and target_tier then
    stock_consume(by_tier, target_tier, 1)
  end
end

-- Examine one scanned entity.
local function examine(network_snapshot, entity)
  if not entity.valid then return end
  if entity.force.name ~= "player" then return end
  if entity.name == "entity-ghost" then
    return examine_ghost(network_snapshot, entity)
  end
  if entity.to_be_deconstructed() then return end

  if entity.to_be_upgraded() then
    -- Marked entities get no module orders — the swap would orphan them.
    return examine_marked(network_snapshot, entity)
  end

  if examine_building(network_snapshot, entity) then return end
  if network_snapshot.order_budget > 0 then
    examine_modules(network_snapshot, entity)
  end
end

-- The pass ------------------------------------------------------------------

-- Slots are re-enumerated fresh whenever a new network is needed; only the
-- integer cursor persists, so a mid-round merge or split at worst skips or
-- repeats a network for one round. Without Space Age the platforms dict is
-- empty.
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
  if settings.global["manage-space-platforms"].value then
    for platform_index in pairs(game.forces.player.platforms) do
      slots[#slots + 1] = {platform_index = platform_index}
    end
  end
  return slots
end

-- Scan one construction cell's area — or a platform's whole surface — for
-- entities the pass can act on. Returns nil if the surface vanished.
local function scan_cell(network_snapshot)
  local surface = game.get_surface(network_snapshot.surface_index)
  if not surface then return nil end
  local area = network_snapshot.cells[network_snapshot.cell_index]
  if area == "whole-surface" then area = nil end
  return surface.find_entities_filtered{
    area = area,
    force = "player",
    type = storage.config.all_tracked_types,
  }
end

-- One budgeted step of the between-rounds sweep over both ledgers in
-- sequence (pass.sweeping names the current one): prune an entry when its
-- entity is gone — and, for order entries, when no longer marked. Wait
-- entries skip the mark check: they attach to ghosts and proxies, where
-- to_be_upgraded() is meaningless. Entries are deleted only here and at
-- examine time, never while the sweep cursor points at them, so resuming
-- next() from the stored key is safe.
local function sweep_ledger_step(pass)
  local ledger_name = pass.sweeping
  local ledger_name_following =
    ledger_name == "order_ledger" and "platform_wait_ledger" or nil
  local ledger = storage[ledger_name]
  local key = pass.sweep_cursor
  local entry
  if key == nil then
    key, entry = next(ledger)
  else
    entry = ledger[key]
  end
  if not entry then
    pass.sweeping = ledger_name_following
    pass.sweep_cursor = nil
    return
  end
  pass.sweep_cursor = (next(ledger, key))
  if not (entry.entity.valid
    and (ledger_name ~= "order_ledger" or entry.entity.to_be_upgraded())) then
    ledger[key] = nil
  end
  if pass.sweep_cursor == nil then
    pass.sweeping = ledger_name_following
  end
end

function gardener.on_pass()
  local pass = storage.pass
  local budget = settings.global["entities-per-tick"].value
  local scanned_cell_this_invocation = false

  while budget > 0 do
    local network_snapshot = pass.network_snapshot
    if pass.sweeping then
      -- Between rounds: sweep the ledgers during the rest window.
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
        -- Round complete: rest so bots can collect ordered items.
        pass.cursor = 1
        pass.resume_tick = game.tick
          + math.floor(settings.global["round-delay-seconds"].value * 60)
        pass.sweeping = "order_ledger"
        pass.sweep_cursor = nil
      else
        local slot = slots[pass.cursor]
        pass.cursor = pass.cursor + 1
        if slot.platform_index then
          pass.network_snapshot = enter_platform(slot.platform_index)
        else
          pass.network_snapshot = enter_network(slot.network, slot.surface_index)
        end
      end
    elseif network_snapshot.entities and network_snapshot.entity_index <= #network_snapshot.entities then
      budget = budget - 1
      local entity = network_snapshot.entities[network_snapshot.entity_index]
      network_snapshot.entity_index = network_snapshot.entity_index + 1
      examine(network_snapshot, entity)
      if network_snapshot.order_budget <= 0 then
        -- Order budget spent: abandon the rest of this network
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
