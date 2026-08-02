local TaskQueue = require("Legado.task.Queue")
local MessageBox = require("Legado/MessageBox")

local QueueStatus = {}

function QueueStatus:show()
    local function show_queue_status_dialog()
        local engine_status = TaskQueue:getEngineStatus()
        local is_busy, total_queued, total_active = TaskQueue:hasAnyTasks()
        
        local lines = {}
        table.insert(lines, string.format("【队列状态】: %s", is_busy and "运行中" or "空闲"))
        table.insert(lines, string.format("活动任务: %d | 排队任务: %d\n", total_active, total_queued))

        local has_channels = false
        for ch_name, status in pairs(engine_status) do
            has_channels = true
            
            local display_name = ch_name
            local is_bulk = ch_name:match("^PreloadBulk_")
            local is_preload = ch_name:match("^Preload_")
            
            if ch_name == "Menu_Covers" then
                display_name = "[系统] 封面下载"
            elseif is_bulk or is_preload then
                local book_id = is_bulk and ch_name:match("^PreloadBulk_(.*)") or ch_name:match("^Preload_(.*)")
                local prefix = is_bulk and "[批量下载]" or "[预读缓存]"
                local book_name = book_id
                
                if book_id then
                    local Backend = require("Legado/Backend")
                    local ok, book_info = pcall(function() return Backend:getBookInfoCache(book_id) end)
                    if ok and type(book_info) == "table" and book_info.name then
                        book_name = "《" .. book_info.name .. "》"
                    end
                end
                display_name = prefix .. " " .. book_name
            end
            
            local pause_str = status.is_paused and " [已暂停]" or ""
            local time_str = ""
            if is_bulk and status.total_elapsed and status.total_elapsed > 0 then
                if status.total_elapsed > 60 then
                    time_str = string.format(" [用时 %dm%ds]", math.floor(status.total_elapsed / 60), status.total_elapsed % 60)
                else
                    time_str = string.format(" [用时 %.1fs]", status.total_elapsed)
                end
            end
            table.insert(lines, string.format("- 任务: %s%s%s (线程 %d/%d)", display_name, time_str, pause_str, status.active_workers, status.max_workers))
            
            if #status.running > 0 then
                for _, r in ipairs(status.running) do
                    table.insert(lines, string.format("  └─ [运行中] Task#%d (PID:%s, 已用时%.1fs, 重试:%d)", r.id, tostring(r.pid or "main"), r.elapsed or 0, r.retry or 0))
                end
            end
            if #status.pending > 0 then
                table.insert(lines, string.format("  └─ [等待中] %d 个任务排队中", #status.pending))
            end
            if #status.running == 0 and #status.pending == 0 then
                table.insert(lines, "  └─ (无任务)")
            end
            table.insert(lines, "")
        end

        if not has_channels then
            table.insert(lines, "暂无活跃通道。")
        end

        local content_text = table.concat(lines, "\n")
        
        MessageBox:confirm(
            content_text,
            function(result)
                if result then
                    show_queue_status_dialog() -- 刷新
                end
            end,
            {
                title = "后台任务队列状态",
                ok_text = "刷新",
                cancel_text = "关闭",
                hold_callback = function()
                    MessageBox:confirm("确定清空所有排队中的后台任务吗？", function(is_ok)
                        if is_ok then
                            TaskQueue:destroyAll()
                            local Backend = require("Legado/Backend")
                            local TaskLock = require("Legado/task/Lock")
                            pcall(function() TaskLock.cleanAll(Backend.dbManager) end)
                            MessageBox:notice("所有任务队列已清空！")
                        end
                    end)
                end
            }
        )
    end
    show_queue_status_dialog()
end

return QueueStatus
