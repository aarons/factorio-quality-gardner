--[[
control.lua

Entry point for Quality Gardener. Events maintain the candidate index (who
exists, at what quality, where); the nth-tick scan cycle does all matching.
Events never trigger upgrade attempts, and cycles never scan the world.
]]

local qualities = require("scripts.qualities")
local index = require("scripts.index")
local gardener = require("scripts.gardener")

-- Entity type -> the startup setting that enables tracking it
local entity_to_setting_map = {
  -- Production
  ["assembling-machine"] = "enable-assembly-machines",
  ["furnace"] = "enable-furnaces",
  ["rocket-silo"] = "enable-rocket-silos",
  ["agricultural-tower"] = "enable-agricultural-towers",
  ["mining-drill"] = "enable-mining-drills",

  -- Electrical infrastructure
  ["electric-pole"] = "enable-poles",
  ["solar-panel"] = "enable-solar-panels",
  ["accumulator"] = "enable-accumulators",
  ["generator"] = "enable-generators",
  ["reactor"] = "enable-reactors",
  ["fusion-reactor"] = "enable-reactors",
  ["fusion-generator"] = "enable-generators",
  ["boiler"] = "enable-boilers",
  ["heat-pipe"] = "enable-heat-pipes",
  ["power-switch"] = "enable-power-switches",
  ["lightning-attractor"] = "enable-lightning-rods",

  -- Defense
  ["turret"] = "enable-turrets",
  ["ammo-turret"] = "enable-turrets",
  ["electric-turret"] = "enable-turrets",
  ["fluid-turret"] = "enable-turrets",
  ["artillery-turret"] = "enable-turrets",
  ["wall"] = "enable-defense-walls-and-gates",
  ["gate"] = "enable-defense-walls-and-gates",

  -- Other
  ["lamp"] = "enable-lamps",
  ["arithmetic-combinator"] = "enable-combinators-and-speakers",
  ["decider-combinator"] = "enable-combinators-and-speakers",
  ["constant-combinator"] = "enable-combinators-and-speakers",
  ["programmable-speaker"] = "enable-combinators-and-speakers",
  ["lab"] = "enable-labs",
  ["roboport"] = "enable-roboports",
  ["beacon"] = "enable-beacons",
  ["pump"] = "enable-pumps",
  ["offshore-pump"] = "enable-pumps",
  ["radar"] = "enable-radar",
  ["inserter"] = "enable-inserters",
}

local function build_and_store_config()
  local is_tracked_type = {}
  local all_tracked_types = {}
  for entity_type, setting_name in pairs(entity_to_setting_map) do
    if settings.startup[setting_name].value then
      is_tracked_type[entity_type] = true
      all_tracked_types[#all_tracked_types + 1] = entity_type
    end
  end
  storage.config = {
    is_tracked_type = is_tracked_type,
    all_tracked_types = all_tracked_types,
  }
end

-- Full world rescan: rebuild the candidate index and adopt existing upgrade
-- marks into the ledger (world state is the source of truth)
local function rescan_world()
  if #storage.config.all_tracked_types == 0 then return end
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

  -- PickerDollies-lineage teleports (id resolved at init, since remote.call
  -- is not allowed in on_load; registration itself is)
  if storage.dolly_event_id then
    script.on_event(storage.dolly_event_id, function(event)
      gardener.on_entity_moved(event.moved_entity)
    end)
  end
end

-- Resolve the moved-entity event id from any PickerDollies-lineage mod.
-- Must not be called from on_load (uses remote.call).
local function resolve_dolly_event_id()
  storage.dolly_event_id = nil
  for _, interface_name in ipairs({"PickerDollies", "EvenPickierDollies"}) do
    local interface = remote.interfaces[interface_name]
    if interface and interface["dolly_moved_entity_id"] then
      storage.dolly_event_id = remote.call(interface_name, "dolly_moved_entity_id")
      return
    end
  end
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
  resolve_dolly_event_id()
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
