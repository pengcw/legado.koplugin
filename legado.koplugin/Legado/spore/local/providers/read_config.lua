local M = {}
function M.snapshot()
    local Device = package.loaded['device']
    if Device and Device.screen and type(Device.screen.night_mode) == 'boolean' then
        return {isNightTheme = Device.screen.night_mode}
    end
    local settings = G_reader_settings
    return {isNightTheme = settings and settings:isTrue('night_mode') or false}
end
return M
