-- Behavior tunables (runtime-global).
data:extend({
    {
        type = "int-setting",
        name = "entities-per-tick",
        setting_type = "runtime-global",
        default_value = 1,
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
        name = "round-delay-seconds",
        setting_type = "runtime-global",
        default_value = 20,
        minimum_value = 0,
        maximum_value = 3600,
        order = "a-2"
    },
    {
        type = "int-setting",
        name = "order-expiry-seconds",
        setting_type = "runtime-global",
        default_value = 300,
        minimum_value = 0,
        maximum_value = 86400,
        order = "a-3"
    }
})
