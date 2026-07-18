-- Luacheck configuration for Factorio mod development
-- Based on Nexela's Factorio-luacheckrc configuration

std = "lua53c"

globals = {
    "storage",
}

read_globals = {
    -- Standard Lua libraries that Factorio provides
    "table",
    "math",
    "string",
    "debug",
    "coroutine",
    "utf8",
    "package",
    "io",
    "os",

    -- Factorio specific read-only
    "defines",
    "data",
    "settings",
    "log",
    "localised_print",
    "table_size",
    "serpent",
    "util",
    "mods",
    "script",
    "remote",
    "commands",
    "game",
    "rendering",
    "rcon",
    "prototypes",
    "helpers",
}

exclude_files = {
    "reference/",
    "*.zip",
}

max_line_length = 360
max_cyclomatic_complexity = 30
