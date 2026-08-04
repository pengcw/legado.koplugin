unused_args = false
std = "luajit"
self = false

globals = {
    "G_reader_settings",
    "G_defaults",
    "G_reader_service",
    "table.pack",
    "table.unpack",
}

read_globals = {
    "_ENV",
}

files["*_spec.lua"] = {
    std = "+busted",
    globals = {
        "package",
        "describe",
        "it",
        "before_each",
        "after_each",
        "assert",
        "spy",
        "stub",
    }
}

ignore = {
    "211/__*", -- Unused local variable starting with __
    "231/__",  -- Local variable is set but never accessed
    "631",     -- Line is too long
}
