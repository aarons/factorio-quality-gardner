-- Entry point. No entity events: the scan pass in gardener.lua reads the
-- world fresh each round.

local qualities = require("scripts.qualities")
local gardener = require("scripts.gardener")

-- Candidacy is derived from prototypes: an entity is covered when an item
-- places it and the engine allows upgrading it. The type list narrows the
-- per-cell entity scans.
local function build_and_store_config()
  local placing_item_name = {}
  local is_tracked_type = {}
  local all_tracked_types = {}
  local module_item = {}
  for name, prototype in pairs(prototypes.item) do
    if prototype.type == "module" then
      module_item[name] = true
    end
  end
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
  all_tracked_types[#all_tracked_types + 1] = "entity-ghost"
  storage.config = {
    placing_item_name = placing_item_name,
    all_tracked_types = all_tracked_types,
    module_item = module_item,
  }
end

local function register_event_handlers()
  script.on_nth_tick(gardener.PASS_INTERVAL_TICKS, gardener.on_pass)
end

local function initialize(command)
  build_and_store_config()
  gardener.initialize_storage()
  qualities.initialize()
  register_event_handlers()

  if command and command.player_index then
    local player = game.get_player(command.player_index)
    if player then
      player.print("Quality Gardener: pass state reset; the next round re-reads the world.")
    end
  end
end

commands.add_command("quality-gardener-init",
  "Reset Quality Gardener's pass state (everything else is read fresh from the world)",
  initialize)

script.on_init(initialize)

script.on_configuration_changed(function(_)
  initialize()
end)

script.on_load(function()
  qualities.initialize()
  register_event_handlers()
end)
