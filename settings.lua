-- Behavior tunables (runtime-global).
data:extend({
    {
        type = "int-setting",
        name = "entities-per-pass",
        setting_type = "runtime-global",
        default_value = 50,
        minimum_value = 1,
        maximum_value = 10000,
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
    }
})
