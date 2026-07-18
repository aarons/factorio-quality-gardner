--[[
control.lua

Entry point for Quality Gardener. Events maintain the candidate index (who
exists, at what quality, where); the nth-tick scan cycle does all matching.
Events never trigger upgrade attempts, and cycles never scan the world.
]]

local qualities = require("scripts.qualities")
local index = require("scripts.index")
local gardener = require("scripts.gardener")

-- Entity types tracked as upgrade candidates
local tracked_entity_types = {
  -- Production
  "assembling-machine",
  "furnace",
  "rocket-silo",
  "agricultural-tower",
  "mining-drill",

  -- Electrical infrastructure
  "electric-pole",
  "solar-panel",
  "accumulator",
  "generator",
  "reactor",
  "fusion-reactor",
  "fusion-generator",
  "boiler",
  "heat-pipe",
  "power-switch",
  "lightning-attractor",

  -- Defense
  "turret",
  "ammo-turret",
  "electric-turret",
  "fluid-turret",
  "artillery-turret",
  "wall",
  "gate",

  -- Other
  "lamp",
  "arithmetic-combinator",
  "decider-combinator",
  "constant-combinator",
  "programmable-speaker",
  "lab",
  "roboport",
  "beacon",
  "pump",
  "offshore-pump",
  "radar",
  "inserter",
}

local function build_and_store_config()
  local is_tracked_type = {}
  for _, entity_type in ipairs(tracked_entity_types) do
    is_tracked_type[entity_type] = true
  end
  storage.config = {
    is_tracked_type = is_tracked_type,
    all_tracked_types = tracked_entity_types,
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
  if entity and entity.valid and storage.config.is_tracked_type[entity.type] then
    index.remove(entity)
  end
end

local function register_main_loop()
  -- Registrations are keyed by interval: clear any old one first
  script.on_nth_tick(nil)
  script.on_nth_tick(storage.scan_interval_ticks, gardener.run_cycle)
end

local function register_event_handlers()
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

  script.on_event(defines.events.on_runtime_mod_setting_changed, function(event)
    if event.setting == "scan-interval-seconds" then
      storage.scan_interval_ticks = settings.global["scan-interval-seconds"].value * 60
      register_main_loop()
    end
  end)
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
  storage.scan_interval_ticks = settings.global["scan-interval-seconds"].value * 60
  register_event_handlers()
  register_main_loop()

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
  register_main_loop()
end)
