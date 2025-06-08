local DataStorage = require("datastorage")
local plugin_path = ("%s/plugins/legado.koplugin/patches/core.lua"):format(DataStorage:getDataDir())

local ok, pathes_code =  pcall(dofile, plugin_path)
if ok and pathes_code and type(pathes_code.install) == "function" then
    pathes_code.install()
end