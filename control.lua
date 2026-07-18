--[[
control.lua

Entry point for Quality Gardener. Events maintain the candidate index (who
exists, at what quality, where); a continuous per-tick budgeted pass does all
matching. Events never trigger upgrade attempts, and the pass never scans the
world.
]]

local qualities = require("scripts.qualities")
local index = require("scripts.index")
local gardener = require("scripts.gardener")

-- Candidacy is derived from prototypes, not a hand-maintained type list: any
-- entity placed from an item that the engine allows upgrading. The per-name
-- placing-item map is the eligibility gate everywhere; the type list only
-- narrows world rescans.
local function build_and_store_config()
  local placing_item_name = {}
  local is_tracked_type = {}
  local all_tracked_types = {}
  for name, prototype in pairs(prototypes.entity) do
    if not prototype.has_flag("not-upgradable") then
      local items = prototype.items_to_place_this
      if items and #items > 0 then
        placing_item_name[name] = items[1].name
        if not is_tracked_type[prototype.type] then
          is_tracked_type[prototype.type] = true
          all_tracked_types[#all_tracked_types + 1] = prototype.type
        end
      end
    end
  end
  storage.config = {
    placing_item_name = placing_item_name,
    all_tracked_types = all_tracked_types,
  }
end

-- Full world rescan: rebuild the candidate index and adopt existing upgrade
-- marks into the ledger (world state is the source of truth)
local function rescan_world()
  for _, surface in pairs(game.surfaces) do
    local entities = surface.find_entities_filtered{
      type = storage.config.all_tracked_types,
      force = game.forces.player,
    }
    for _, entity in ipairs(entities) do
      index.add(entity)
      gardener.adopt(entity)
    end
  end
end

-- Event handlers ----------------------------------------------------------

local function on_entity_created(event)
  local entity = event.entity or event.destination
  if entity and entity.valid then
    index.add(entity)
  end
end

local function on_entity_removed(event)
  local entity = event.entity
  if entity and entity.valid and index.placing_item_name(entity) then
    index.remove(entity)
  end
end

local function register_event_handlers()
  -- The main loop: a small, constant slice of work every tick
  script.on_event(defines.events.on_tick, gardener.on_tick)

  -- Entity creation (candidate index maintenance)
  script.on_event(defines.events.on_built_entity, on_entity_created, {{filter = "force", force = "player"}})
  script.on_event(defines.events.on_robot_built_entity, gardener.on_robot_built_entity, {{filter = "force", force = "player"}})
  script.on_event(defines.events.on_space_platform_built_entity, on_entity_created, {{filter = "force", force = "player"}})
  script.on_event(defines.events.script_raised_built, on_entity_created)
  script.on_event(defines.events.script_raised_revive, on_entity_created)
  script.on_event(defines.events.on_entity_cloned, on_entity_created)

  -- Entity destruction (candidate index maintenance)
  script.on_event(defines.events.on_player_mined_entity, on_entity_removed)
  script.on_event(defines.events.on_robot_mined_entity, on_entity_removed)
  script.on_event(defines.events.on_space_platform_mined_entity, on_entity_removed)
  script.on_event(defines.events.on_entity_died, on_entity_removed, {{filter = "force", force = "player"}})
  script.on_event(defines.events.script_raised_destroy, on_entity_removed)

  -- Order lifecycle
  script.on_event(defines.events.on_cancelled_upgrade, gardener.on_cancelled_upgrade)
  script.on_event(defines.events.on_object_destroyed, gardener.on_object_destroyed)
end

-- Initialization ----------------------------------------------------------

local function initialize(command)
  if command and command.player_index then
    local player = game.get_player(command.player_index)
    if player then
      player.print("Quality Gardener: rebuilding index, scanning entities...")
    end
  end

  build_and_store_config()
  index.init_storage()
  gardener.init_storage()
  qualities.initialize()
  rescan_world()
  register_event_handlers()

  if command and command.player_index then
    local player = game.get_player(command.player_index)
    if player then
      player.print("Quality Gardener: rebuild complete.")
    end
  end
end

commands.add_command("quality-gardener-init", "Reinitialize Quality Gardener: rescan all entities and adopt existing upgrade marks", initialize)

script.on_init(initialize)

script.on_configuration_changed(function(_)
  initialize()
end)

script.on_load(function()
  qualities.initialize()
  register_event_handlers()
end)
