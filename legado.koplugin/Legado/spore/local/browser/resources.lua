local Cache = require("Legado.spore.local.resources.cache")
local Localizer = require("Legado.spore.local.resources.localizer")
local Probe = require("Legado.Helper.Probe")
local M = {}

function M.new(root)
    root = root or require("Legado.Helper.Env").getTempDirectory()
    local resources = {}
    function resources:prepare(snapshot, stream, context)
        if not snapshot.html:lower():find("<img", 1, true) then return snapshot end
        local span = Probe.start("Browser", "页面图片准备", "public_images", nil, context)
        stream:throw_if_cancelled()
        local failures = 0
        local ok, prepared = pcall(function()
            local download = require("Legado.spore.local.resources.downloader").new{
                probe_url = "browser_public_image",
            }
            local cache = Cache.new{
                root = root,
                json = require("json"),
                limits = false,
                download = function(address, kind, remaining)
                    stream:throw_if_cancelled()
                    return download(address, kind, remaining)
                end,
            }
            local fetch = cache.fetch
            function cache:fetch(reference, base, kind)
                if kind ~= "image" then return nil end
                local resource, err = fetch(self, reference, base, kind)
                if not resource then
                    failures = failures + 1
                    return {reference = ""}, err
                end
                return resource
            end
            return Localizer.new(cache):prepare(snapshot)
        end)
        stream:throw_if_cancelled()
        if not ok or type(prepared) ~= "table" then
            Probe.fail("Browser", "页面图片准备", "public_images", span, "PREPARE_FAILED", context)
            return nil
        end
        prepared.image_failures = failures
        if failures > 0 then
            Probe.fail("Browser", "页面图片准备", "public_images", span, "IMAGE_UNAVAILABLE", context)
        else
            Probe.done("Browser", "页面图片准备", "public_images", span, "PREPARED", nil, nil, context)
        end
        return prepared
    end
    return resources
end

return M
