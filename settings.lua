-- Behavior tunables (runtime-global), then hidden-quality policy (startup).
data:extend({
    {
        type = "int-setting",
        name = "entities-per-tick",
        setting_type = "runtime-global",
        default_value = 20,
        minimum_value = 1,
        maximum_value = 1000,
        order = "a-0"
    },
    {
        type = "int-setting",
        name = "reserve-per-item",
        setting_type = "runtime-global",
        default_value = 0,
        minimum_value = 0,
        maximum_value = 1000000,
        order = "a-1"
    },
    {
        type = "double-setting",
        name = "order-timeout-minutes",
        setting_type = "runtime-global",
        default_value = 3,
        minimum_value = 0,
        maximum_value = 600,
        order = "a-2"
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
    }
})
