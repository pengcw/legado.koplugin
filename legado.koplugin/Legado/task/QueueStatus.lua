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
            local pause_str = status.is_paused and " [已暂停]" or ""
            table.insert(lines, string.format("- 通道: %s%s (线程 %d/%d)", ch_name, pause_str, status.active_workers, status.max_workers))
            
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
