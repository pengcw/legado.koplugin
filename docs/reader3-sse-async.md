# reader3 SSE 异步化改造（复用 SSEClientCopas）

> 2026-08-23 实施。背景：reader3 的历史形态反复在"异步回调"与"同步手写"之间切换（见 §3），当前最终形态为 **TaskQueue 子进程 copas + 复用 SSEClientCopas.open**。

## 1. 改造内容

### 1.1 SSEClientCopas.open 补齐三个契约缺口

`legado.koplugin/Legado/Helper/SSEClientCopas.lua`：

| 缺口 | 改动 | 用途 |
|------|------|------|
| **SNI** | TLS wrap 后、`dohandshake` 前 `pcall(sec_sock.sni, sec_sock, host)` | 部分 HTTPS 服务器无 SNI 握手失败；旧 reader3 手写版有（`s.sni`），不能丢 |
| **on_status 回调** | 解析出 `status_code` 后 `pcall(on_status, status_code, status_line)`（无论 2xx） | reader3 的 401 → `RETRY_LOGIN` 重登录分支 |
| **事件可中止 + 结果透传** | `on_event` 返回非 nil 时：记录 `event_result` → `finish(nil)` → 停止读取；新增 `handle:get_result()` | reader3 的 `on_event_sync` 返回值（`true`/`"RETRY_LOGIN"`/错误串）驱动流结局 |

### 1.2 reader3.fetch_sse_stream_sync 重写

`legado.koplugin/Legado/spore/reader3.lua`：~175 行裸 socket 手写（TCP+TLS+HTTP+chunked+SSE 轮询）→ ~110 行。

- **函数签名不变**：`fetch_sse_stream_sync(req_url, timeout_sec, ctx, on_event_sync)` → `return true / false, msg`；
- `SSEClientCopas.open{ url, timeout, headers={Connection=close, User-Agent=KOReader-Legado}, on_status, on_event(推队列), on_close }`；
- 业务协程 `while not handle:is_done()` 循环：`ctx.is_cancelled()` → `handle:cancel()`；消费事件队列执行 `on_event_sync`（返回值驱动结局）；否则 `copas.sleep(0.01)` 让出给 copas 调度；
- 删除 `resolve_host_sync`（open 内部 `connect(host, port)` 走 DNS）。

**为什么可行**：`TaskQueue.spawn`（init.lua L172）强制 `opts.engine="process"`，子进程内（Engine.lua L174-256）`copas.running=true` + 业务 job 与看门狗都 `copas.addthread`，主协程 `while not job_finished do copas.step(0.02) end` 驱动——copas 事件循环存活期覆盖 job 执行全程，`open` 内部线程与业务协程同实例可调度，业务协程 `copas.sleep` 合法。

**收益**：事件分发从 0.5s socket 轮询（裸 receive 会 C 阻塞整个 Lua 状态机，step/看门狗/取消全部停摆）变为 copas 即时调度（~10ms）；取消响应从最差 0.6s 变 ~10ms；消除裸 socket 手写与旧 `start_time` 未定义隐患。

## 2. 语义对照（回归断言）

| 场景 | 旧实现 | 新实现 | 测试 |
|------|--------|--------|------|
| 正常流自然结束 | `true` | `true` | t20 normal |
| 事件回调返回 `true`（提前结束） | `true` + probe_done | `true` + probe_done | t20 stop_true |
| 事件回调返回 `"RETRY_LOGIN"` | `false, "RETRY_LOGIN"` | 同 | t20 retry_login |
| HTTP 401 | `false, "RETRY_LOGIN"` | 同（on_status 记录 401） | t20 status401 |
| HTTP 非 200 | `false, "HTTP状态码异常: xx"` | 同 | t20 status500 |
| 连接失败 | `false, "连接服务器失败..."` | `false, "连接失败：..."`（open 措辞） | t20 norefused |
| 用户取消 | `false, "已取消"` + probe_fail | 同 | t20 cancel |
| 读响应头超时 | `false, "读取响应头超时"` | `false, "连接超时"`（open deadline 措辞） | —（措辞差异可接受） |

## 3. 历史形态演进（git 核实）

| commit | 分支 | reader3 SSE IO 形态 |
|--------|------|---------------------|
| `b26e180` | dev 主线 | **异步回调**：`SSEClient.open`（非 Copas，UI 线程 ZMQ 驱动） |
| `01e3ea4` / `7190171` | dev 主线 | 异步（同上） |
| `8dd552f` | backup/copas-research（未进 dev 主线，`e36cfb7` 注明"撤销后"） | **纯 copas 异步**：`SSEClientCopas.open` + `client:cancel()` |
| `dc6c8d7` / `e36cfb7` / `dadf1d6` | backup | SSEClientCopas 异步实验（if debug 修复、watchdog） |
| `5e3a971`（当前 HEAD 贡献点） | dev 主线 | **改回同步**：`TaskQueue.spawn` 子进程 + `fetch_sse_stream_sync` 手写裸 socket；SSEClientCopas 引入但 open 无人调用 |
| **本次改造** | dev | TaskQueue 子进程 + **复用 SSEClientCopas.open**（copas 同步协程语义） |

## 4. 测试

- `tests/t20_reader3_async.lua`：从 reader3.lua 提取 fetch 真实源码（`return function` 包装 + 嵌套 `local function` 深度解析），`copas.addserver` mock SSE 服务器，`copas.running + step` 模拟子进程环境；8 场景断言（正常流/顺序/提前中止/RETRY_LOGIN 事件/401/500/连接拒绝/取消）。
- `tests/t21_spawn_copas.lua` + `t21_child.lua`：**真实子进程实证**——`t21_child` 逐行复刻 Engine.lua L174-239 子进程回调结构（`copas.running` + job 入 `copas.addthread` + 主协程 `copas.step` 循环），主进程 `io.popen` 起独立 luajit 进程并断言结果（3 事件全收、`ok=true`）。用于否决"子进程无 copas 驱动"的疑虑。
- 已加入 `tests/run_all.lua`（t20/t21 位于 t19 与 t9 之间）。**注意**：被 run_all dofile 的测试脚本不得用 `os.exit`（会杀死 run_all 进程），失败用 `error()`；`t21_child.lua` 是独立进程可任意退出。
- run_all 8/8 全绿（t5/t7/t8/t18/t19/t20/t21/t9）。

## 5. 审查结论与处理（2026-08-23 review）

| 意见 | 级别 | 处理 |
|------|------|------|
| `copas.sleep` 在子进程主协程执行会炸（引 ProcessStream.lua:327 裸 xpcall） | Blocking | **否决（实证）**：ProcessStream L327 的 xpcall 执行的是 Engine.lua L174 传入的**回调**，回调内部自建 copas（L183/L205 `addthread` + L237 `step` 循环）；业务 job 在 copas 线程内运行，`copas.sleep` 合法。t21 真实子进程复刻该结构 3 事件全收。 |
| `purgeDir` 只清内容、保留目录本体 | Should-fix | **否决（实测）**：t22 验证 `ffi_util.purgeDir` 递归删除文件+目录本体（LuaJIT `os.remove` 对空目录走 POSIX remove()），`dir remains=false`。 |
| `handle:get_result` 无调用方（死接口） | Should-fix | 保留 + 注释：为回调式调用方预留（reader3 走队列模式，`on_event` 只入队恒返回 nil，该分支不可达但属库能力）。 |
| `drain_queue` 用 `table.remove(ev_queue,1)` O(n²) | Nit | 已修为头指针（`q_head` 索引 + 队列空后复位）。 |
| `isArchiverAvailable` 契约漂移（Reader 可用 vs Writer 可用） | Should-fix | 不动：Reader:new 内部自探测可回退 unzip CLI，功能正确；属既有代码非本次引入。 |

## 6. 连带修复

- **ZipUtil Reader 临时目录泄漏（原 R0-3）**：`util.removePath`（frontend/util.lua L884）**只删空目录链**——`lfs.rmdir` 遇非空目录（ENOTEMPTY）即失败返回，extractAll 后的临时目录永远删不掉。改为 `ffi_util.purgeDir`（ffi/util.lua，递归删除文件+目录）。`ZipUtil.lua` L267/L452 两处。
- **t19_safety 的 "got 1" 幽灵失败**：根因同上——上次运行残留的 `sub/nested.txt` 让 `removePath` 清理失败，dest 目录始终残留 1 个文件。改为 `ffi_util.purgeDir` 后连续多次 run_all 稳定通过。

## 7. 遗留

- 错误措辞两处与旧版不同（`连接失败：` / `连接超时`），由 open 的 finish 消息产生，业务上无影响（调用方只按 false + 非空 err 处理，401/RETRY_LOGIN 语义不变）。
- open 目前唯一使用者仍是 reader3（`_parsers` 转挂 `M._parsers` 保留），未来若其他模块需要 SSE 可直接复用 open 新契约。
