-- Behavior toggles and tunables (all runtime-global).
data:extend({
    {
        type = "bool-setting",
        name = "manage-factory",
        setting_type = "runtime-global",
        default_value = true,
        order = "a-0"
    },
    {
        type = "bool-setting",
        name = "manage-ghosts",
        setting_type = "runtime-global",
        default_value = true,
        order = "a-1"
    },
    {
        type = "bool-setting",
        name = "manage-upgrade-requests",
        setting_type = "runtime-global",
        default_value = true,
        order = "a-2"
    },
    {
        type = "bool-setting",
        name = "manage-space-platforms",
        setting_type = "runtime-global",
        default_value = true,
        order = "a-3"
    },
    {
        type = "int-setting",
        name = "entities-per-tick",
        setting_type = "runtime-global",
        default_value = 1,
        minimum_value = 1,
        maximum_value = 1000,
        order = "b-0"
    },
    {
        type = "int-setting",
        name = "reserve-per-item",
        setting_type = "runtime-global",
        default_value = 0,
        minimum_value = 0,
        maximum_value = 1000000,
        order = "b-1"
    },
    {
        type = "double-setting",
        name = "round-delay-seconds",
        setting_type = "runtime-global",
        default_value = 20,
        minimum_value = 0,
        maximum_value = 3600,
        order = "b-2"
    },
    {
        type = "int-setting",
        name = "order-expiry-seconds",
        setting_type = "runtime-global",
        default_value = 300,
        minimum_value = 0,
        maximum_value = 86400,
        order = "b-3"
    },
    {
        type = "double-setting",
        name = "space-platform-delivery-wait-seconds",
        setting_type = "runtime-global",
        default_value = 300,
        minimum_value = 0,
        maximum_value = 86400,
        order = "b-4"
    }
})
