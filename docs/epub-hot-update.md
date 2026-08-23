# EPUB 骨架热更新方案备忘

> 状态：**核心缺陷已修复**（§6.1 中部 EOCD、§6.2 xpointer 失效）；遗留观察见 §9
> 记录日期：2026-08-23
> 用途：升级维护 / 故障排查参考。本文档记录骨架 EPUB 的生成、增量更新、垃圾回收机制，以及排查过程中发现的问题与修复过程（完整时间线见 §8）。

---

## 1. 概述

Legado 插件以"骨架 EPUB"（Skeleton EPUB）作为整本阅读载体：书籍打开时先构建一个含全部章节占位页的 EPUB，章节正文在后台陆续下载，下载完成后**原地热更新**该 EPUB，读者无需重开书籍即可看到正文。

设计目标：
- 磁盘/内存开销与书籍规模解耦：更新一章不应重写整本书（50MB 书更新一章不应重写 50MB）。
- 兼容 KOReader 阅读链路（crengine 渲染 EPUB）。

## 2. 核心模块

| 模块 | 文件 | 职责 |
|---|---|---|
| `SkeletonEpub` | `legado.koplugin/Legado/Helper/SkeletonEpub.lua` | 骨架构建、章节更新/追加的对外接口 |
| `ZipUtil.Patcher` | `legado.koplugin/Legado/Helper/ZipUtil.lua` | 增量原地 patch（truncate 后追加，兼容 crengine） |
| `ZipUtil.rewriteWithUpdates` | 同上 | 全量流式重写（垃圾回收 / fallback） |
| `Backend.refreshDocumentInPlace` | `legado.koplugin/Legado/Backend.lua` | 热重载 ReaderUI 当前文档 |

**ZipUtil 能力矩阵**（后端可用性决定的功能降级，详见模块顶部注释）：

| 能力 | 新版 koreader（ffi.archiver） | 旧版 koreader（ffi.zipwriter） |
|---|---|---|
| 基础写入 / 读取 | archiver / archiver | zipwriter / unzip CLI（无 unzip 时 Reader 不可用） |
| crc32 | zlib（`ffi/zlib_h`） | bit 手写备份 |
| 增量 patch（Patcher） | truncate + 追加，兼容 crengine | **禁用**（无 truncate → commit 返回 intact=true → 回退全量重写） |
| 流式重写 | libarchive 流式复制 | **禁用**（can_stream=false → 全内存 extractToMemory） |

## 3. 数据流

```
书源下载章节 → cache 文件
  → Backend.syncChaptersToVirtualBook / syncVirtualBookNewChapters
      → SkeletonEpub.updateChapters / appendChapters
          → (优先) ZipUtil.Patcher:commit 增量追加
          → (垃圾超阈值或 patch 失败) ZipUtil.rewriteWithUpdates 全量重写
  → Backend.refreshDocumentInPlace 原地热重载
```

### 3.1 构建（buildSkeleton）

- 全部条目 **store（不压缩）**，含 `mimetype`（必须首条目且 store）。
- 章节无缓存 → 占位页（`legado-placeholder`），有缓存 → 直接注入正文。
- `SKELETON_SCHEMA_VERSION` 记录在 DocSettings；版本不符时 `ensureVirtualBookEpub` 自动重建。

### 3.2 增量 patch（ZipUtil.Patcher）

truncate 后追加布局（方案 A，2026-08-23，兼容 crengine）：

```
[旧条目 local 数据][新条目 local+data][新中央目录][新 EOCD]
```

- 先 `truncate` 文件到旧中央目录偏移（删除旧中央目录 + 旧 EOCD），再从该位置追加新条目（被替换章节 / 新增章节 / 更新后的 opf/ncx）local header+data、新中央目录、新 EOCD。
- 文件中部不残留 EOCD（crengine 顺序解析会把中部 EOCD 当文件尾，见 §6.1）。
- 重写中央目录：被替换条目的旧记录删除（任何读取器只见唯一版本），其余旧记录原样保留。
- 全部 store 写入；crc32 优先用 koreader 自带 zlib，手写表驱动作备份。
- 垃圾：被替换条目的旧 local 数据不回收，文件只增不减，由全量重写回收。
- `truncate` 依赖 `ffi.C.truncate`（koreader 环境）；纯 Lua 环境无 truncate 时 `commit` 返回 `intact=true`，上层回退全量重写。
- `commit` 返回 `true / nil, err, intact`：`intact` 标识文件是否未被修改（写入失败为 false，前置失败为 true）。

### 3.3 垃圾回收与回退（rewriteWithUpdates）

- 触发条件：`patcher.waste_bytes`（文件大小 − 逻辑数据量）超过 **20MB 或文件大小 50%**；或 `options.force_rewrite`。
- 全量重写：未变化条目用 `archive_read_data_block` **流式复制**（内存 O(单章)），更新条目直接写新内容，输出统一 store。
- `patcher:open` 失败（文件损坏）→ 回退全量重写；`patcher:commit` 失败（文件可能已部分写入）→ **不回退**，直接报错（避免读取已损坏源）。

### 3.4 热重载（refreshDocumentInPlace）

`doc._document:loadDocument(doc.file, false)` + `renderDocument()` + `ui.rolling:onUpdatePos(true)`。
⚠️ 该流程依赖 crengine 能读到更新后的文件内容，且位置恢复依赖 `ReaderRolling.xpointer`（见 §6.1、§6.2 两个独立失效机制）。

## 4. 验证与回归

```bash
/home/py/koreader_extracted/luajit tests/run_all.lua
# 4/4：t5_crc（crc32 标准向量+zlib/手写一致性）、t7_patch（Patcher）、
#      t8_rewrite（流式重写）、t9_skeleton（端到端 build/update/append）
```

- 双读取器验证：libarchive（koreader `ffi.archiver`）+ Python `zipfile.testzip()` 无损坏。
- 增量写入量实测：50MB 级书更新一章仅追加写入数 KB~数十 KB（相对全量重写的全书大小）。

## 5. 升级注意

- **schema 版本**：`SKELETON_SCHEMA_VERSION` bump 会使所有已生成骨架重建（一次成本），用于格式/行为变更。
- store 与 deflate 可混用（旧 deflate 骨架 + 新 store 条目），zip 允许；读取无碍。
- 文件原地追加写非原子：崩溃可能留下损坏尾部，但骨架可再生（schema 重建），可接受。

## 6. 已知问题与故障排查

### 6.1 ✅ 增量 patch 与 crengine 不兼容（已修复，方案 A）

**现象**：骨架 EPUB 插入新章节（`appendChapters`）后原地热重载，返回书籍首页；新章节不出现。

**根因（已用 crengine 实测确认）**：
1. 旧版追加式 patch 在文件**中部残留旧 EOCD**（`PK\x05\x06`）。
2. crengine 的 zip 读取器**从文件开头顺序扫描 local entries，遇到 EOCD 签名即视为文件结束**。
3. 因此 crengine 只读到旧 EOCD 之前的条目（旧版本），追加在末尾的新章节/新 opf/ncx **全部读不到**。
4. 同时 crengine 重新 `loadDocument` 后内部位置重置到文档开头（实测 `pos=156 page=1`），配合内容未更新/`xpointer` 恢复机制，表现即"回首页"。

**修复（方案 A，2026-08-23）**：`ZipUtil.Patcher:commit` 改为"先 `truncate` 到旧中央目录偏移、再追加"：

```
旧布局（缺陷）：[旧 local 数据][旧 EOCD][新条目][新中央目录][新 EOCD]
新布局（修复）：[旧 local 数据][新条目 local+data][新中央目录][新 EOCD]
```

- 文件中部不再残留 EOCD；truncate 同时回收旧中央目录/旧 EOCD 的垃圾（实测同场景垃圾 1705→694 字节）。
- `truncate` 经 `ffi.cdef` + `ffi.C.truncate` 提供（koreader 环境稳定）；纯 Lua 环境无 truncate 时 `commit` 返回 `nil, err, intact=true`，调用方回退全量重写。
- `commit` 返回值扩展为 `true / nil, err, intact`：`intact=false` 表示写入阶段失败（文件可能损坏，不应回退重写）；`intact=true` 表示文件未动（可安全回退）。

**验证（crengine 实测，`tests/t11i.lua`）**：5 章构建 + append 3 章 + 模拟热重载后——
`toc=8`（读到全部章节）、渲染高度 8313→13104（新章节排版）、旧 xpointer 恢复位置 `page 6`（不再回首页）。

**兼容性对照（修复后同一 append 文件）**：Python / libarchive / unzip / crengine 均读到 8 章。

### 6.2 ✅ 章节占位→正文 DOM 变化导致 xpointer 失效，热重载回第一页（已修复）

**现象**（用户实测，2026-08-23）：阅读到某章（占位状态），该章正文下载完成后原地热重载，返回书籍第一页。连续翻页多章（如读到 15 章跳到 18 章，触发新章节注水）时更易出现。

**根因（crengine 实测复现，`tests/t16_update.lua`）**：与 §6.1（文件布局）是**两个独立机制**。

1. `updateChapters` 把章节从占位 HTML 替换为正文 HTML，**DOM 结构变化**：
   - 占位：`<div class="legado-ch"><h2>…</h2><div class="legado-placeholder-box">…</div></div>`
   - 正文：`<div class="legado-ch"><h2>…</h2><p>…</p>…</div>`
2. 用户正在读该章时，`ReaderRolling.xpointer` 指向**占位 DOM 节点**（如 `/body/DocFragment[16]/body/div/div/div[1]/text().0`，`div[1]` 即占位框）。
3. 热重载（`loadDocument` + `renderDocument`）后，占位节点**已不存在**；crengine 对无法解析的 xpointer **静默 fallback 到第 1 页**：
   - 实测 `getPageFromXPointer(old_xp)` 在更新前返回 `page 12`，更新 15-17 章为正文并重载后返回 **`page 1`**；
   - `gotoXPointer(old_xp)` → 定位到 **page 1**（无异常、无报错，静默回首页）。
4. `ReaderRolling:updatePos(true)` 的 `_gotoXPointer(self.xpointer)` 无有效性校验，直接 `_gotoPage(1)`。

**对照**：appendChapters（新增章节不改已有章节 DOM）时旧 xpointer 有效，热重载恢复成功（§6.1 验证、`tests/t14_deep.lua` 20 章读到 page 27 恢复成功）；partial rerendering 在本环境不可用，排除。

**修复（方案 A 升级版，2026-08-23，`Backend.refreshDocumentInPlace`）**：两阶段兜底——
1. 重载前记录进度：`old_pos`/`old_height`/`old_page` 折算百分比；并从当前 `getXPointer()` 提取 `DocFragment` 前缀，构造**章节头锚点** `/body/DocFragment[N]/body/div/h2`（占位页与正文页的章节根节点 `<div class="legado-ch"><h2>…</h2>` 结构一致，章节更新后该锚点仍有效）。
2. 重载后按原流程用 xpointer 恢复；若恢复后 `getCurrentPage() <= 1` 且原本不在第 1 页（`old_page > 1`）：
   - **优先** `ui.rolling:onGotoXPointer(章节头锚点)`——精确回到章节头（onGotoXPointer 内部同步 `self.xpointer`）；
   - 无锚点（xpointer 不含章节结构）时回退 `ui.rolling:onGotoPercent(old_percent * 100)`（scroll 走 `_gotoPos`、page 走 `_gotoPage`），非 rolling 文档防御性 `doc._document:gotoPos`；
   - 随后触发重绘（hash 未变，幂等）。

**验证（crengine 实测，`tests/t16_update.lua`、`tests/t17d.lua`）**：
- 章节锚点：占位骨架读到 page 12（第 17 章附近），updateChapters 更新 15-17 章后热重载 → xpointer 失效回 page 1 → 锚点恢复到 **page 11**（±1 页内，精确到章节头）；
- 章节头场景：跳到 18 章头（page 14），更新 18 章后热重载 → 锚点恢复到 **page 14**（精确一致）；
- 百分比兜底备用路径仍有效（page 14），无锚点场景不会回首页。

### 6.3 排查清单

| 现象 | 检查点 |
|---|---|
| 热重载后内容不更新/回首页 | ① `unzip -l <epub>` 与文件实际章节数对比；若文件有多个 `PK\x05\x06`（`python3 -c` 扫描）→ §6.1（已修，旧文件需重建）；② 若文件章节数正确、内容已更新但位置回首页，且更新目标是当前阅读章节（占位→正文）→ §6.2（xpointer 失效） |
| 增量写入量异常大 | 是否触发全量重写（垃圾超阈值 / patch open 失败） |
| patch 报错 | `logger.warn` 中的 "incremental patch failed" / "patcher open failed" 区分：commit 失败不重试重写（文件可能已损坏，靠 schema 重建恢复） |
| 章节标题含 `%` | 已修复（gsub 函数替换），appendChapters 的 opf/ncx 替换不再因 `%` 崩溃 |

## 7. 相关实验记录

- `tests/t11i.lua`：方案 A 修复验证（5 章 + append 3 章，热重载后 crengine toc=8、渲染增长、位置恢复 page 6）。
- `tests/t14_deep.lua`：20 章书读到 page 27（翻页后）append + 热重载，位置恢复成功（对照组，§6.2 反证）。
- `tests/t15_partial.lua`：partial rerendering 影响排查（本环境不可用，排除）。
- `tests/t16_update.lua`：**§6.2 复现与修复验证**——占位骨架读到 page 12，updateChapters 更新 15-17 章后热重载，`getPageFromXPointer` 从 12 变为 1（复现回首页）；章节锚点恢复 page 11、百分比兜底 page 14（修复验证）。
- `tests/t17d.lua`：章节头锚点验证——跳到 18 章头（page 14），更新 18 章后重载，构造锚点 `/body/DocFragment[19]/body/div/h2` 精确恢复到 page 14。
- 环境：`KO_HOME` 指向可写目录（koreader_extracted 只读），`CanvasContext:init(Device)` 后 `DocumentRegistry:openDocument` 初始化 crengine。

## 8. 更新记录（2026-08-23，按时间线）

### 8.1 初始实现（骨架 + 增量更新 + 热重载）

- 增量 `Patcher` 为**纯追加式**布局（新条目追加到文件末尾），全 store 写入，`rewriteWithUpdates` 全量流式重写回收垃圾；`refreshDocumentInPlace` 复用同一 cre docview 原地重载。详见 §3。

### 8.2 问题一：append 新章节后热重载回首页、新章节不出现

- **调查**：对比 libarchive / Python zipfile / Info-ZIP unzip / crengine 四种读取器对同一 append 文件的解析，仅 crengine 读到旧章节数（5 章，其余读到 8 章）；扫描文件确认中部残留旧 EOCD。
- **根因**：crengine 顺序扫描 local entries，把中部 EOCD 当文件尾（§6.1）。
- **修复**（方案 A）：`Patcher:commit` 改为"先 `truncate` 到旧 cd_offset 再追加"；`commit` 返回值扩展 `true / nil, err, intact`（intact 区分"文件未动可回退"与"已写坏不可回退"）；纯 Lua 无 truncate 环境回退全量重写。
- **验证**：crengine 实测 toc=8、渲染增长、位置恢复 page 6；`run_all` 全绿。

### 8.3 问题二：占位章节更新为正文后热重载回第一页（xpointer 失效）

- **调查**：`tests/t16_update.lua` 复现——占位骨架读到 page 12，updateChapters 更新 15-17 章后重载，旧 xpointer（指向占位框 DOM）解析回 **page 1**（crengine 对失效 xpointer 静默 fallback 到第 1 页），`_gotoXPointer` 无校验直接 `_gotoPage(1)`。
- **根因**：占位→正文 DOM 结构变化（占位框 `div` → 正文段落），`ReaderRolling.xpointer` 指向的节点重载后不存在（§6.2）。
- **修复 v1（百分比兜底）**：重载前记录进度百分比，失效时 `onGotoPercent` 恢复。
- **用户实测反馈**：修复可用但**位置不准确**——期望"跳到 18 章头，重载后保持 18 章头"，百分比只能近似。
- **修复 v2（章节锚点，最终版）**：利用占位/正文共享的章节根节点结构（`<div class="legado-ch"><h2>…</h2>`），从当前 xpointer 提取 `DocFragment[N]` 前缀构造章节头锚点 `/body/DocFragment[N]/body/div/h2`；失效时优先 `onGotoXPointer(锚点)`（精确到章节头），锚点无效降级百分比；重绘统一在恢复后执行。
- **验证**：章节锚点恢复 page 11（原 12，±1 页）、章节头场景精确 page 14 = 14；`run_all` 4/4 全绿。

### 8.4 第三方调查核实（deepwiki《跳转章节》）

**来源**：`/home/py/下载/跳转章节.md`（deepwiki 对 KOReader"跳转到章节位置"机制的调查）。

**调查内容概要**：
- 用户主动翻章统一入口是 `ReaderRolling:onGotoNextChapter` / `onGotoPrevChapter`（响应 `GotoNextChapter`/`GotoPrevChapter` 事件），内部按有无隐藏流（`hasHiddenFlows`）分两条分支；
- 核心计算依赖 `ReaderToc:getTocTicksFlattened(true)` 得到的**章节起始页码 tick 列表**做线性查找（`getNextChapter`/`getPreviousChapter`），`isChapterStart` 同样基于该列表；
- 找到目标页后经 `self.ui.link:addCurrentLocationToStack()` 记录历史、`self:onGotoPage()` 跳转。

**本地核实**（`koreader_extracted/frontend/apps/reader/modules/readertoc.lua:519/568/592`）：`getTocTicksFlattened`、`getNextChapter`、`isChapterStart` 均存在，描述属实。✓

**与我们问题的对比**：

| 维度 | deepwiki 机制（ticks 页码） | 我们的方案（DocFragment 锚点） |
|---|---|---|
| 场景 | 用户主动翻章（正常渲染文档） | 热重载后位置恢复（占位→正文） |
| 章节标识 | 章节**起始页码**（依赖渲染后页码） | `DocFragment[N]` 索引（章节文件唯一标识，与 spine 绑定） |
| 重载后稳定性 | ✗ 页码随内容变化（占位→正文页数大增） | ✓ 重载前后一致 |
| 占位页场景 | ✗ **占位页很短，多章挤在同一页**（实测 page 14 同时是 18/19/20 章起点，无法区分） | ✓ 每章独立 fragment，无歧义 |
| 定位精度 | 页码级 | 章节头（h2），实测精确到 page 14 = 14 |

**结论**：
1. **场景不同，无直接可借鉴方案**——deepwiki 覆盖"主动翻章"，我们处理"重载后恢复"，两者不共用代码。
2. **ticks 页码机制反而不如现有方案**：其 page 依赖在占位页场景不可靠（`t17b` 实验已实测"用 page 判定当前章节"选错章节），DocFragment 锚点绕开了该问题。
3. **间接确认了我们实现的正确性**：deepwiki 提到 `onGotoPage` 后更新 `self.xpointer`，与我们采用的 `onGotoXPointer`（内部 `_gotoXPointer` → `_gotoPage`，同步 `self.xpointer`）机制一致。
4. **未采用的机制**：`addCurrentLocationToStack`（翻章历史栈）——那是用户主动跳转所需；热重载是后台静默恢复，不应污染跳转历史。

无改动。

## 9. 遗留观察（未处理，另行决策）

1. **`getPageCount()` 旧值**：同一 cre docview 二次 `loadDocument` 后 `cre` 的 `getPages()`/`doc:getPageCount()` 仍返回旧页数（渲染高度与 `gotoXPointer` 均正确，实测可导航到第 16 页 > 旧 11 页）。影响：
   - 状态栏总页数显示为旧值、按页翻页边界可能受限；
   - page 模式下 `_gotoPercent` 用旧页数折算，兜底偏差约 1-3 页（不影响定位到原章节附近）。
   - 候选方案：对齐 KOReader 官方 `reloadDocument`（重建 docview）或重开 docview，放弃复用同一 docview。
2. **文件原地写非原子**：崩溃可能留下损坏尾部，骨架可再生（schema 重建），当前可接受。
3. **垃圾回收仅靠阈值触发**：增量 patch 累积垃圾，`rewriteWithUpdates` 回收；频繁强制刷新同一章会加速垃圾累积。
