local TaskGroup = {}
TaskGroup.__index = TaskGroup

function TaskGroup:new(parent)
    return setmetatable({
        parent = parent,
        tasks = {},
        handles = {},
        total = 0,
        finished = 0,
        cancelled = false,
        done = false,
    }, self)
end

function TaskGroup:add(task)
    if not task then return nil, "invalid_task" end
    if self.done or self.cancelled then return nil, "group_done" end

    self.tasks[task.id] = task
    self.total = self.total + 1
    task.parent_task = self.parent

    task:on("done", function()
        if self.tasks[task.id] then
            self.tasks[task.id] = nil
            self.finished = self.finished + 1
            self:check_done()
        end
    end)

    return task
end

function TaskGroup:check_done()
    if not self.done and self.finished >= self.total then
        self.done = true
        if self.parent then
            self.parent:emit("children_done", self)
        end
    end
end

function TaskGroup:is_done()
    return self.done
end

function TaskGroup:cancel(reason)
    if self.cancelled then return end
    self.cancelled = true

    local tasks = {}
    for id, task in pairs(self.tasks) do
        tasks[id] = task
    end

    for id, task in pairs(tasks) do
        if task:is_done() then
            self.tasks[id] = nil
            self.finished = self.finished + 1
        else
            task:cancel(reason or "parent_cancelled")
        end
    end

    self:cancel_handles()
    self:check_done()
end

function TaskGroup:add_handle(handle)
    if not handle then return handle end
    if self.done or self.cancelled then
        if self.cancelled and handle.cancel then
            pcall(handle.cancel, handle)
        end
        return handle
    end

    self.handles[#self.handles + 1] = handle
    return handle
end

function TaskGroup:cancel_handles()
    for _, handle in ipairs(self.handles) do
        if handle and handle.cancel then
            pcall(handle.cancel, handle)
        end
    end
    self.handles = {}
end

return TaskGroup
