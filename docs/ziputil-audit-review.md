# ZipUtil.lua 审核报告评估（对照当前实际代码）

> 评估日期：2026-08-23
> 审核来源：`/home/py/文档/压缩库审核.md`（第三方 AI 审核）
> 核实基准：当前工作区 `legado.koplugin/Legado/Helper/ZipUtil.lua`（885 行）——已含 truncate 增量 patch、流式重写、crc32 精简（bit 备份 + zlib 优先）等；外部 AI 另有部分改动（`has_archiver` 条件加载等）。
> 判定符号：✅ 已解决（无需动作）｜🔧 建议采纳（真实缺口）｜⚠️ 可选增强｜❌ 不采纳（理由）

---

## 一、P0 级

### P0-1 commit 写失败导致 ZIP 损坏 —— ⚠️ 可选增强（现状有兜底）

**核实**：`Patcher:commit`（L755-767）确实是"truncate → write"顺序，truncate 成功后 write 失败（磁盘满/IO）会损坏文件。但现状已有三层兜底：
1. 失败返回 `nil, err, intact=false`，调用方（SkeletonEpub）**不回退重写**，避免读损坏源；
2. 损坏后骨架 epub 由 `ensureVirtualBookEpub` 按 schema 重建恢复；
3. truncate 失败（原子）返回 `intact=true`，可安全回退全量重写。

**审核建议**（临时文件+rename / truncate 前保存旧尾）：
- 临时文件+rename = 全量复制，与增量写目标冲突，**不采纳**；
- "truncate 前保存旧 cd/eocd"：`self.entries` 已保留全部旧记录 raw + `cd_size/cd_offset/entry_count`，write 失败后可尝试写回旧尾恢复（~10 行）。收益低（write 失败场景罕见且恢复写也可能失败，磁盘满时无效）。
- **建议**：维持现状（intact=false + schema 重建已覆盖）；如要加固可加"失败写回旧尾"，优先级低。

### P0-2 不支持 ZIP64 —— ⚠️ 可选增强（已安全降级）

**核实**：Patcher 用 `u32` + 4GB/65535 上限检查（L720/732/750），明确拒绝超限（返回 `intact=true`）。`Patcher:open` 对 ZIP64 文件（EOCD 哨兵值 0xFFFFFFFF）会解析失败 → open 失败 → SkeletonEpub **回退全量重写**（`rewriteWithUpdates` 走 libarchive，支持 ZIP64）。

**评估**：骨架 epub 为文本，章节 < 65535、文件 < 4GB 是常态；超限场景自动安全降级。**无需实现 ZIP64**。可选：open 时对哨兵值显式报错（错误信息更清晰，~5 行）。

### P0-3 libarchive 内部字段依赖 —— ❌ 不采纳

**核实**：`copy_entry_stream`（L787-808）直接访问 `writer.backend.archive` / `reader._archive.archive`，依赖 ffi.archiver 内部字段名。

**评估**：与用户既定策略一致——"基于当前测试 koreader 版本，版本差异用补丁兼容"。`ffi.archiver` 是 koreader 长期稳定模块，字段名升级概率低，升级发现问题打补丁即可。加 `getArchiveHandle()` wrapper 属过度设计，调用点仅一处。**不采纳**。

---

## 二、资源泄漏

### R0-1 Reader/Writer 生命周期（Reader 缺 __gc）—— 🔧 采纳

**核实**：Writer 有 `ffi_gc`（L170-177）；**Reader 无 `__gc`**（L424 只有 close 定义）。Reader 持有 archiver handle + 临时目录，调用方异常未 close 会泄漏。

**修复**：给 Reader 注册 `ffi_gc(Reader, { __gc = function(t) pcall(function() t:close() end) end })`（仿 Writer，~8 行）。

### R0-2 Reader.close 不完整清理状态 —— ⚠️ 可选

**核实**：`Reader:close`（L424-432）close archive + 删 tmp_dir，但 `_path`/`_extracted` 未清理。`open` 时都会重置（L257-264），重复 open/close 无实际危害。

**建议**：可选加 `self._path = nil; self._extracted = false` 使状态干净（3 行），非必须。

### R0-3 临时目录泄漏 —— 🔧 采纳（随 R0-1 解决）

**核实**：unzip_cli 模式 `ensure_extracted` 创建 `_tmp_dir`，正常 close 删除；异常路径（未 close）残留。Reader 加 `__gc`（R0-1）后 GC 会调 close → 自动清理。**随 R0-1 一并解决**。崩溃场景无法代码防（需全局 cleanup，不现实）。

### R0-4 ffi.gc 使用范围 —— 🔧 部分采纳

**核实**：Writer ✓；**Reader 缺**（见 R0-1）；libarchive entry **已有** `ffi.gc`（L789 `ffi.gc(libarchive.archive_entry_new(), libarchive.archive_entry_free)`）；Patcher 为纯 Lua 对象（无外部资源），**无需** __gc。审核称"缺 libarchive entry"不准确（已有）。

### R0-5 file handle 异常路径 —— ✅ 已解决

**核实**：`Patcher:open` 所有 return 前均 `f:close()`（L599/616/622/636/641）；`Patcher:commit` 的 f 在 truncate 失败（L760）、write 后（L766）均关闭，reopen 在 close 之后。无泄漏路径。

---

## 三、P1 级

### P1-1 unzip/解压路径穿越 —— 🔧 采纳（真实漏洞）

**核实**：`Reader:extractAll` archiver 分支（L354-399）**手动拼接** `dest_dir .. "/" .. entry.path`，**无路径校验**——恶意 zip 条目 `../../evil` / `/abs/path` 可写出解压目录（真实穿越）。该函数用于 `Update.lua:259` 解压**外部下载的 zip**。unzip_cli 分支（L410-421）依赖 Info-ZIP unzip 默认拒 `../`（但绝对路径行为因版本而异，且 archiver 分支才是 koreader 实际路径）。

**修复**：extractAll 两个分支前校验 entry.path：拒绝含 `..` 路径段或绝对路径的条目（~10 行，返回错误或跳过）。

### P1-2 iterate callback 异常保护 —— ❌ 不采纳

**评估**：callback 是内部代码（`rewriteWithUpdates`/Backend 调用），非用户输入。`pcall(callback)` 会吞掉内部 bug 的异常、掩盖错误定位。异常应向上抛。**不采纳**。

### P1-3 shell_escape 不能完全保护 unzip 参数 —— ❌ 不采纳

**评估**：路径参数已 shell_escape（单引号包裹）。exclude pattern 是内部代码控制（非用户输入），以 `-` 开头被 unzip 当选项的场景实际不可达。**不采纳**。

---

## 四、P2 级

### P2-1 chmod 权限过度 —— ❌ 不采纳

**核实**：`ensure_file_readable`（L191-198）**仅在文件打开失败时**才 `chmod 0644`（有注释说明 libarchive perm 位问题），非无条件覆盖。0644 去掉执行位对解压的文本/图片文件无影响。**设计合理，不采纳**。

### P2-2 Patcher.open EOCD 校验不足 —— ⚠️ 可选增强

**核实**：已有 entry_count 与 CD 记录数一致性校验（L677）、CD 读取长度校验（L634）。缺：disk number / cd_offset+cd_size 是否越界校验。

**建议**：可选加 `cd_offset + cd_size <= fsize` 与 disk number=0 校验（~5 行），提高对损坏文件的报错清晰度。

### P2-3 CRC32 标准测试 —— ✅ 已解决

**核实**：`tests/t5_crc.lua` 已有标准向量 `crc32("123456789") == 0xcbf43926` + zlib/手写多组一致性对照，纳入 `run_all` 回归。审核基于旧版（当时无测试）。**无需动作**。

### P2-4 os.tmpname 目录生成 —— ❌ 不采纳

**评估**：koreader 单进程场景，`os.tmpname()` + remove + mkdir 唯一性足够；mkdtemp 需 ffi 扩展，收益低。**不采纳**。

---

## 五、设计一致性

### D1 Writer backend 行为不一致 —— ❌ 不采纳

**核实**：koreader 环境只有 archiver 后端（`ffi.zipwriter` 在 koreader 不存在，L54 分支为历史兼容死代码）。实际运行无分歧。**不采纳**。

### D2 exclude 行为不一致 —— ⚠️ 可选

**核实**：archiver 分支用 plain 子串匹配（L362），unzip 分支用 `-x` wildcard（L408）。不一致真实存在，但 unzip 分支仅在无 archiver 时触发（koreader 总有 archiver）→ 实际不生效。可选统一（unzip 分支改手动过滤），优先级低。

### D3 Patcher 与 rewriteWithUpdates 能力不一致 —— ✅ 已覆盖

**核实**：Patcher 限 classic ZIP，rewrite 用 libarchive（支持 ZIP64）。超限场景自动安全降级（见 P0-2）。已知限制 + 降级已保证。**无需动作**（可补文档说明）。

---

## 六、性能

### S1 commit 大量内存复制 —— ❌ 不采纳

**评估**：`table.concat(new_cd_recs)` 为全部 CD 记录（O(条目数)，5000 条目约数百 KB），非 O(文件大小)；新条目数据为增量章节（小）。内存可接受，stream write 复杂度高收益低。**不采纳**。

### S2 rewrite 缺少 fsync —— ❌ 不采纳

**评估**：临时文件 + rename 已是较好原子性；fsync 增加 IO 开销且与 koreader 惯例不符（koreader 一般不 fsync）；骨架 epub 可再生。**不采纳**。

---

## 七、推荐采纳清单（供选择）

| 优先级 | 项 | 内容 | 工作量 |
|---|---|---|---|
| 🔧 建议采纳 | **R0-1** | Reader 加 `__gc`（close 兜底，同时解决 R0-3 临时目录泄漏） | ~8 行 |
| 🔧 建议采纳 | **P1-1** | `extractAll` 路径穿越校验（拒绝 `..`/绝对路径条目，两个分支） | ~10 行 |
| ⚠️ 可选 | **P0-2** | Patcher.open 对 ZIP64 哨兵值显式报错（错误信息更清晰） | ~5 行 |
| ⚠️ 可选 | **P2-2** | Patcher.open 增加 disk number / cd 范围校验 | ~5 行 |
| ⚠️ 可选 | **R0-2** | Reader.close 清理 `_path`/`_extracted` | ~3 行 |
| ⚠️ 可选 | **P0-1** | commit 写失败尝试写回旧尾恢复 | ~10 行 |
| ⚠️ 可选 | **D2** | extractAll exclude 语义统一（unzip 分支手动过滤） | ~10 行 |

**明确不采纳**：P0-3（wrapper 过度）、P1-2（pcall 掩盖 bug）、P1-3（非用户输入）、P2-1（chmod 设计合理）、P2-4（tmpname 够用）、S1（内存可接受）、S2（fsync 与惯例冲突）、D1（zipwriter 死代码）。

**已解决**：P2-3（CRC32 测试已在回归）、R0-5（file handle 均有关闭路径）、D3（安全降级已保证）。
