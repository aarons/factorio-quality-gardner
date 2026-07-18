-- Behavior tunables (runtime-global), then per-category entity toggles (startup).
data:extend({
    {
        type = "int-setting",
        name = "scan-interval-seconds",
        setting_type = "runtime-global",
        default_value = 5,
        minimum_value = 1,
        maximum_value = 300,
        order = "a-0"
    },
    {
        type = "int-setting",
        name = "max-orders-per-scan",
        setting_type = "runtime-global",
        default_value = 30,
        minimum_value = 1,
        maximum_value = 1000,
        order = "a-1"
    },
    {
        type = "string-setting",
        name = "source-chests",
        setting_type = "runtime-global",
        default_value = "storage",
        allowed_values = {"storage", "storage-and-providers"},
        order = "a-2"
    },
    {
        type = "int-setting",
        name = "reserve-per-item",
        setting_type = "runtime-global",
        default_value = 0,
        minimum_value = 0,
        maximum_value = 1000000,
        order = "a-3"
    },
    {
        type = "string-setting",
        name = "upgrade-targeting",
        setting_type = "runtime-global",
        default_value = "direct-to-best",
        allowed_values = {"direct-to-best", "single-step"},
        order = "a-4"
    },
    {
        type = "double-setting",
        name = "order-timeout-minutes",
        setting_type = "runtime-global",
        default_value = 3,
        minimum_value = 0,
        maximum_value = 600,
        order = "a-5"
    },
    {
        type = "bool-setting",
        name = "notifications",
        setting_type = "runtime-per-user",
        default_value = true,
        order = "b-0"
    },
    -- Hidden quality handling (for mods like Quality++ Shiny)
    {
        type = "bool-setting",
        name = "skip-hidden-qualities",
        setting_type = "startup",
        default_value = false,
        order = "c-0"
    },
    {
        type = "bool-setting",
        name = "hidden-qualities-sticky",
        setting_type = "startup",
        default_value = true,
        order = "c-1"
    },
    -- Entity categories (alphabetized; infrastructure defaults to off)
    {
        type = "bool-setting",
        name = "enable-accumulators",
        setting_type = "startup",
        default_value = true,
        order = "d-00"
    },
    {
        type = "bool-setting",
        name = "enable-agricultural-towers",
        setting_type = "startup",
        default_value = true,
        order = "d-01"
    },
    {
        type = "bool-setting",
        name = "enable-assembly-machines",
        setting_type = "startup",
        default_value = true,
        order = "d-02"
    },
    {
        type = "bool-setting",
        name = "enable-beacons",
        setting_type = "startup",
        default_value = true,
        order = "d-03"
    },
    {
        type = "bool-setting",
        name = "enable-boilers",
        setting_type = "startup",
        default_value = true,
        order = "d-04"
    },
    {
        type = "bool-setting",
        name = "enable-combinators-and-speakers",
        setting_type = "startup",
        default_value = false,
        order = "d-05"
    },
    {
        type = "bool-setting",
        name = "enable-defense-walls-and-gates",
        setting_type = "startup",
        default_value = true,
        order = "d-06"
    },
    {
        type = "bool-setting",
        name = "enable-furnaces",
        setting_type = "startup",
        default_value = true,
        order = "d-07"
    },
    {
        type = "bool-setting",
        name = "enable-generators",
        setting_type = "startup",
        default_value = true,
        order = "d-08"
    },
    {
        type = "bool-setting",
        name = "enable-heat-pipes",
        setting_type = "startup",
        default_value = false,
        order = "d-09"
    },
    {
        type = "bool-setting",
        name = "enable-inserters",
        setting_type = "startup",
        default_value = true,
        order = "d-10"
    },
    {
        type = "bool-setting",
        name = "enable-labs",
        setting_type = "startup",
        default_value = true,
        order = "d-11"
    },
    {
        type = "bool-setting",
        name = "enable-lamps",
        setting_type = "startup",
        default_value = false,
        order = "d-12"
    },
    {
        type = "bool-setting",
        name = "enable-lightning-rods",
        setting_type = "startup",
        default_value = true,
        order = "d-13"
    },
    {
        type = "bool-setting",
        name = "enable-mining-drills",
        setting_type = "startup",
        default_value = true,
        order = "d-14"
    },
    {
        type = "bool-setting",
        name = "enable-poles",
        setting_type = "startup",
        default_value = false,
        order = "d-15"
    },
    {
        type = "bool-setting",
        name = "enable-power-switches",
        setting_type = "startup",
        default_value = false,
        order = "d-16"
    },
    {
        type = "bool-setting",
        name = "enable-pumps",
        setting_type = "startup",
        default_value = true,
        order = "d-17"
    },
    {
        type = "bool-setting",
        name = "enable-radar",
        setting_type = "startup",
        default_value = true,
        order = "d-18"
    },
    {
        type = "bool-setting",
        name = "enable-reactors",
        setting_type = "startup",
        default_value = true,
        order = "d-19"
    },
    {
        type = "bool-setting",
        name = "enable-rocket-silos",
        setting_type = "startup",
        default_value = true,
        order = "d-20"
    },
    {
        type = "bool-setting",
        name = "enable-roboports",
        setting_type = "startup",
        default_value = true,
        order = "d-21"
    },
    {
        type = "bool-setting",
        name = "enable-solar-panels",
        setting_type = "startup",
        default_value = true,
        order = "d-22"
    },
    {
        type = "bool-setting",
        name = "enable-turrets",
        setting_type = "startup",
        default_value = true,
        order = "d-23"
    }
})
