-- Behavior tunables (runtime-global), then hidden-quality policy (startup).
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
        type = "double-setting",
        name = "order-timeout-minutes",
        setting_type = "runtime-global",
        default_value = 3,
        minimum_value = 0,
        maximum_value = 600,
        order = "a-4"
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
    }
})
