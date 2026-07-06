# Mole for Mac — 完整技术方案与路线图

> 状态：设计稿 v2（2026-07）
> 定位：本文档是 Mole Mac App 的**开发交付级规格**。目标读者是后续接手开发的工程师 / AI Agent，读完本文应能直接开工，不需要再向设计者提问核心问题。
> 说明：参考图仅用于功能范围说明；UI 视觉、交互、文案均为原创设计。
> 配套：CLI 仓库为 <https://github.com/tw93/mole>（本仓库）；App 建议独立仓库 `mole-mac`。

---

## 目录

1. [产品定义](#1-产品定义)
2. [现状盘点：CLI 能力矩阵](#2-现状盘点cli-能力矩阵)
3. [总体架构](#3-总体架构)
4. [通信协议规范（Robot Protocol v1）](#4-通信协议规范robot-protocol-v1)
5. [功能模块详细设计](#5-功能模块详细设计)
6. [超出现有 CLI 的新增功能设计](#6-超出现有-cli-的新增功能设计)
7. [权限与安全设计](#7-权限与安全设计)
8. [UI / 设计系统](#8-ui--设计系统)
9. [工程结构与编码规范](#9-工程结构与编码规范)
10. [性能预算](#10-性能预算)
11. [测试与质量保障体系](#11-测试与质量保障体系)
12. [构建、签名与发布](#12-构建签名与发布)
13. [ROADMAP](#13-roadmap)
14. [附录：错误码 / 事件 Schema / 术语表](#14-附录)

---

## 1. 产品定义

### 1.1 一句话定位

把 Mole CLI 的"深度清理 + 安全卸载 + 系统优化 + 磁盘分析 + 健康状态"能力，装进一个**默认安全、处处可预览、删除可撤销、操作可审计**的原生 macOS 应用。

### 1.2 目标用户

- 主力：不用终端的普通 Mac 用户（CLI 触达不到的群体）。
- 次要：已在用 `mo` 的高级用户，希望在图形界面里做磁盘分析、看系统状态。

### 1.3 产品原则（从 CLI 平移，GUI 场景下的表述）

1. **先看后删**：任何破坏性动作前，用户必须能看到完整的将删列表（路径、大小、原因）。
2. **可撤销优先**：用户可见的删除一律进废纸篓；只有明确标注"不可恢复"且用户单独确认的项才直接删除。
3. **可审计**：每次操作写入操作日志，App 内可回看"什么时候删了什么"。
4. **保守默认**：拿不准的项默认不勾选；开发工具/AI 工具的活跃状态永不进入默认清理集。
5. **单一规则来源**：什么能删、什么受保护，只在 CLI 核心（shell 库）里定义一次。GUI 永远不自己判断"这个能不能删"。
6. **克制**：不做常驻后台、不做告警轰炸、不做与清理无关的系统管控。

### 1.4 非目标

- 不上 Mac App Store（沙盒与清理工具本质冲突），走 Developer ID 直发 + 公证。
- 不做菜单栏常驻监控（P3 有一个可选的轻量方案，默认关闭，见 §6.7）。
- 不做隐私清理（浏览记录、Cookie 等）、不做杀毒、不做内存"加速球"这类伪优化。
- 首个大版本不做多语言以外的本地化（先中英双语）。

---

## 2. 现状盘点：CLI 能力矩阵

开发前必读。下表标注了每个能力当前的接口形态，决定 GUI 侧接入成本。**路径与函数名均为真实代码引用，接手者应先通读这些文件。**

### 2.1 已有机器可读接口（GUI 直接消费）

| 能力 | 入口 | 形态 | 备注 |
|---|---|---|---|
| 系统状态（一次性） | `status-go --json`（`cmd/status/main.go:25`） | 全量指标 JSON | `MetricsSnapshot` 结构见 `cmd/status/metrics.go:60`，含 CPU/GPU/内存/磁盘/网络/电池/热/进程/蓝牙 |
| 系统状态（流式） | `status-go --watch --interval 2s`（`main.go:31`） | **NDJSON 持续输出** | 状态页数据源，已可用，无需改造 |
| 磁盘扫描 | `analyze-go --json <path>`（`cmd/analyze/main.go:20`、`json.go`） | 一次性 JSON：`{path, entries[{name,path,size,is_dir,cleanable,last_access}], large_files, total_size}` | 一次性输出；GUI 需要增量/常驻模式（§5.4） |
| 应用清单 | `mo uninstall --list`（`bin/uninstall.sh:1389`，`uninstall_list_apps`） | JSON：name / bundle_id / path / size | 只读短路路径，无破坏性代码 |
| 健康 JSON | `lib/check/health_json.sh` | 内存/磁盘健康 JSON | optimize 诊断用 |
| 操作历史 | `mo history`（`bin/history.sh`、`lib/core/history.sh`） | 文本 + 结构化日志文件 | 日志文件本身可解析；GUI 需要 `--json` 出口（M0 加） |

### 2.2 已有安全设施（GUI 必须经由、禁止绕过）

| 设施 | 位置 | 职责 |
|---|---|---|
| `mole_delete` | `lib/core/file_ops.sh` | 唯一删除入口：Trash 路由 + dry-run + 路径保护 + oplog |
| `should_protect_path` | `lib/core/file_ops.sh` | 保护路径判定（/System、com.apple.* 等） |
| App 保护策略 | `lib/core/app_protection.sh` + `app_protection_data.sh` | 受保护应用、bundle 匹配、残留判定 |
| 白名单 | `lib/manage/whitelist.sh`，配置在 `~/.config/mole/whitelist` | 用户自定义保护 |
| 卸载 sibling guard | `lib/uninstall/batch.sh` | 同 bundle id 副本（/Volumes 拷贝等）保护，5 次事故收敛出的不变量 |
| dry-run / 测试开关 | `MOLE_DRY_RUN=1` / `MOLE_TEST_NO_AUTH=1` / `MOLE_TEST_MODE=1` | 预览与免真实授权测试 |

### 2.3 纯 TUI、需要新增结构化出口（M0 的工作量主体）

| 能力 | 现状 | GUI 需要 |
|---|---|---|
| `mo clean` | 终端 section 文本（`bin/clean.sh:1195-1305` 共 16 个 section） | `robot clean plan/apply`（§4） |
| `mo optimize` | 任务函数集（`lib/optimize/tasks.sh`，`opt_*` 约 25 个任务，经 `execute_optimization` 调度） | `robot optimize list/run`（§4） |
| `mo purge` | 交互式菜单（`lib/clean/project.sh`） | `robot purge plan/apply` |
| `mo installer` | 交互式（`bin/installer.sh`） | `robot installer plan/apply` |
| `mo uninstall`（执行） | 交互式选择器 | `robot uninstall plan/apply` |

### 2.4 clean 的 16 个 section（GUI 分组的事实来源）

来自 `bin/clean.sh` 主流程，GUI 清理页的分组直接映射：

External volume / System(需 sudo) / User essentials / App caches / Browsers / Cloud & Office / Developer tools / Applications / Virtualization / Application Support / App leftovers / Device backups & firmware / Time Machine / Large files(提示性) / System Data clues(提示性) / Project artifacts。

注意：其中 "Large files"、"System Data clues" 是**提示类**（只报告不删除），GUI 中应呈现为"洞察卡片"而非可勾选清理项。

---

## 3. 总体架构

### 3.1 选型决策记录（ADR）

**ADR-1：GUI 壳采用 SwiftUI 原生 App，而非 Electron/Tauri。**
理由：状态页需要低开销高频刷新；分析页需要大数据量 Treemap 渲染；清理工具的用户对"这软件本身干不干净"敏感，原生包体与内存占用是产品力。SwiftUI 在 macOS 13+ 足够成熟。

**ADR-2：清理/卸载/优化逻辑不重写，内嵌 CLI 核心，通过结构化协议驱动。**
候选对比：
- (a) 解析现有终端文本 —— 文本非契约，颜色/文案一改即断，否决。
- (b) Swift 重写清理规则 —— 规则出现两份实现，安全规则漂移是本项目最大风险（CLI 历史上多次因匹配放宽出事故并回滚），否决。
- (c) **内嵌 shell 库 + Go 二进制，新增 robot（机器）模式出口** —— 规则单源，bats 测试继续覆盖真实执行路径，GUI 只做展示与编排。采纳。

**ADR-3：不启用 App Sandbox；Developer ID 直发 + 公证 + Hardened Runtime。**
理由：需要全盘遍历、Trash 操作、可选 root 任务。同类产品（CleanMyMac、DaisyDisk 直发版）同策略。

**ADR-4：root 能力通过 SMAppService privileged helper，接口为封闭任务枚举，不暴露通用命令执行。**
把 CLI 的"sudo 必须有 guard"原则平移到 XPC 边界（详见 §7.3）。

**ADR-5：App 与内嵌核心同版本发布，核心不做运行时独立更新。**
协议与实现同步演进；App 更新走 Sparkle 整包更新。避免"新 GUI + 旧核心"的组合爆炸。

**ADR-6：分析页扫描引擎复用 `cmd/analyze` 的 Go 扫描器，新增 `--serve` 常驻模式，而非 Swift 重写 FileManager 遍历。**
Go 扫描器已有并发遍历、缓存（`cache.go`）、cleanable 识别（`cleanable.go`）、大文件收集，且与 CLI 行为一致。

### 3.2 组件图

```
┌───────────────────────────────────────────────────────────────┐
│ Mole.app（SwiftUI，macOS 13+，universal binary）                │
│                                                               │
│ ┌───────────────┐  ┌──────────────┐  ┌──────────────────────┐ │
│ │ Feature Views │→ │ Feature      │→ │ MoleKit (SwiftPM)     │ │
│ │ 清理/软件/优化  │  │ Stores       │  │ · RobotSession        │ │
│ │ 分析/状态/历史  │  │ (@Observable)│  │ · 事件解码 (Codable)   │ │
│ │ 设置/引导      │  │              │  │ · 进程生命周期/取消/节流 │ │
│ └───────────────┘  └──────────────┘  └──────────┬───────────┘ │
│                                        stdin/stdout NDJSON    │
│ Contents/Resources/mole-core/                    │            │
│ ┌────────────────────────────────────────────────▼──────────┐ │
│ │ mole 入口 + lib/**（shell 规则库，单一规则来源）              │ │
│ │ analyze-go（+ --serve） status-go（--watch 已有）           │ │
│ │ 新增 bin/robot.sh + lib/core/robot.sh（emit_event 层）      │ │
│ └───────────────────────────────────────────────────────────┘ │
│                                                               │
│ ┌───────────────────────────────────────────────────────────┐ │
│ │ MoleHelper（SMAppService daemon，可选安装）                  │ │
│ │ XPC：runTask(id) —— 仅白名单任务枚举；校验调用方签名           │ │
│ └───────────────────────────────────────────────────────────┘ │
└───────────────────────────────────────────────────────────────┘
```

### 3.3 进程模型

| 子进程 | 生命周期 | 并发 |
|---|---|---|
| `robot clean/uninstall/optimize/purge/installer …` | 按操作启停（plan 一个进程，apply 一个进程） | 同类破坏性操作全局串行（App 内全局互斥锁 `OperationGate`）；plan 类只读操作可与状态订阅并行 |
| `analyze-go --serve` | 分析页打开时启动，离开页面 60s 后回收 | 单实例，内部自并发 |
| `status-go --watch --interval 2s` | 状态页可见时运行；App 失焦/页面切走即 SIGTERM | 单实例 |
| MoleHelper | 常驻由 launchd 管理，无任务时 idle exit | 任务串行 |

规则：**任意时刻最多一个破坏性操作在执行**。清理执行中切到软件页发起卸载 → UI 排队并提示"等待当前清理完成"。

---

## 4. 通信协议规范（Robot Protocol v1）

这是 GUI 与核心之间的唯一契约。CLI 侧实现于 `bin/robot.sh` + `lib/core/robot.sh`；Swift 侧实现于 `MoleKit/RobotSession.swift`。**双方都必须以本节为准；改协议必须先改本节并同步 bump 协议版本。**

### 4.1 调用形式

```
mole robot <domain> <verb> [options] [< request.json]
  domain ∈ { clean, uninstall, optimize, purge, installer, history, whitelist, apps }
  verb   ∈ { plan, apply, list, run, restore }
```

- 请求参数小的走 argv；大的（如勾选 id 列表）走 stdin 一次性 JSON 文档。
- 所有输出到 stdout，一行一个 JSON 事件（NDJSON）；stderr 仅用于协议外崩溃诊断，GUI 收集进日志不解析。
- 环境变量：`MOLE_ROBOT=1`（核心内部据此走 emit_event 分支）由 robot 入口自动设置；GUI 不需要设置其他变量。测试时可叠加 `MOLE_DRY_RUN=1` / `MOLE_TEST_NO_AUTH=1`。

### 4.2 命令总表

| 命令 | 输入 | 输出事件流 | 破坏性 |
|---|---|---|---|
| `robot clean plan [--sections a,b]` | 可选 section 过滤 | progress* → item* → insight* → done | 否 |
| `robot clean apply` | stdin: `{"plan_id":"…","ids":[…]}` | progress* → result* → done | **是** |
| `robot apps list` | — | item*（app 条目）→ done | 否 |
| `robot uninstall plan` | stdin: `{"bundle_ids":[…]}` 或 `{"paths":[…]}` | item*（主体+残留，含分组）→ done | 否 |
| `robot uninstall apply` | stdin: `{"plan_id":"…","ids":[…]}` | progress* → result* → done | **是** |
| `robot optimize list` | — | item*（任务描述）→ done | 否 |
| `robot optimize run` | stdin: `{"task_ids":[…]}` | task_status* → done | **部分** |
| `robot purge plan [--paths …]` | 扫描根 | 同 clean plan | 否 |
| `robot purge apply` | 同 clean apply | 同 clean apply | **是** |
| `robot installer plan/apply` | 同上 | 同上 | plan 否 / apply 是 |
| `robot history list [--limit n] [--json]` | — | item*（历史记录）→ done | 否 |
| `robot whitelist list/add/remove` | pattern | done（含更新后列表） | 否（改配置） |

### 4.3 事件 Schema

所有事件公共字段：`{"v":1,"event":"<type>","ts":"<RFC3339>"}`。

**progress** — 扫描/执行进度（节流：≥100ms 或每 20 项合并一次）
```json
{"v":1,"event":"progress","phase":"scan","section":"app_caches",
 "current":"~/Library/Caches/com.tencent.xinWeChat","done":36,"total":129,
 "bytes_found":331350016}
```
`total` 未知时为 -1（GUI 显示不确定进度）。

**item** — plan 产出的候选项 / list 产出的条目
```json
{"v":1,"event":"item","id":"cl.app_caches.7f3a9c","section":"app_caches",
 "label":"微信 缓存","path":"~/Library/Containers/com.tencent.xinWeChat/…",
 "bytes":58720256,"kind":"cache","reversible":true,"default_selected":true,
 "risk":"safe","detail":"应用重启后自动重建"}
```
- `id`：`<domain缩写>.<section>.<path短哈希>`，**仅在本次 plan 会话内有效**。
- `kind ∈ {cache, log, leftover, installer_pkg, project_artifact, app_bundle, app_data, launch_item}`。
- **i18n 约定**：`section`、`kind`、`risk` 是稳定机器键，GUI 侧本地化其显示名；`label` 中的应用名/路径片段为原样数据不翻译；`detail` 同时携带 `detail_key` + `detail_params`（如 `{"detail_key":"rebuilt_on_relaunch"}`），GUI 优先按 key 查本地化表渲染，未知 key 时回退显示核心输出的英文 `detail` 文本。核心（shell 层）保持英文单语，不做多语言。
- `risk ∈ {safe, caution, info}`：`caution` 默认不勾选且 UI 需要展开确认；`info` 仅展示（对应 Large files / System Data clues 这类洞察 section）。
- `reversible=false` 的项（如某些系统级缓存）UI 必须单独标注。

**insight** — 提示类信息（不可执行）
```json
{"v":1,"event":"insight","section":"system_data_clues","label":"系统数据占用异常",
 "detail":"~/Library/Group Containers 占 21.4 GB","bytes":22975741952}
```

**result** — apply 阶段逐项结果
```json
{"v":1,"event":"result","id":"cl.app_caches.7f3a9c","status":"trashed",
 "freed_bytes":58720256}
```
`status ∈ {trashed, deleted, skipped_whitelisted, skipped_protected, skipped_missing, failed}`；failed 时附 `error{code,message}`。

**task_status** — optimize 任务状态机
```json
{"v":1,"event":"task_status","task_id":"opt.dns_flush","status":"running"}
{"v":1,"event":"task_status","task_id":"opt.dns_flush","status":"done",
 "detail":"DNS 缓存已刷新","duration_ms":840}
```
`status ∈ {pending, running, done, skipped, failed, needs_admin}`。

**done** — 会话终结（每次调用有且仅有一条，成功失败都发）
```json
{"v":1,"event":"done","ok":true,"plan_id":"pl_20260706_1a2b3c",
 "summary":{"items":129,"bytes_total":9273483264,"selected_default":86,
            "failed":0,"skipped":2,"freed_bytes":8912345600}}
```
plan 类命令的 `plan_id` 是后续 apply 的凭据：apply 时核心侧校验 plan 文件（写在 `~/.cache/mole/robot/<plan_id>.json`，含每个 id → 路径映射与生成时间）存在且未超过 30 分钟，超时要求 GUI 重新 plan。**GUI 永远不向 apply 传路径，只传 id。**

**error** — 错误（`fatal:true` 后进程即退出，退出码非 0）
```json
{"v":1,"event":"error","code":"E_PLAN_EXPIRED","message":"plan expired, re-run plan",
 "fatal":true}
```
错误码全表见 §14.1。

### 4.4 生命周期与健壮性约定

- **取消**：GUI 发 SIGTERM。plan 阶段立即退出；apply 阶段完成"当前单项"后输出 done（`ok:false, summary.cancelled:true`）再退出，不留半删状态。核心侧沿用现有 `trap cleanup_temp_files EXIT INT TERM`。
- **超时**：GUI 侧对 plan 设 10 分钟兜底、apply 设 30 分钟兜底；超时 = SIGTERM → 3 秒 → SIGKILL，UI 报"操作超时"。核心侧扫描沿用 CLI 既有 wall-clock 预算与检查点（CLAUDE.md 工作规则），超时降级为部分结果 + `insight` 说明跳过了慢扫描。
- **背压**：Swift 侧按行读取，事件进 `AsyncThrowingStream`（buffer 上限 10k，超限丢弃 progress 保留 item/result）。
- **崩溃恢复**：子进程非零退出且无 `done` 事件 → GUI 显示统一错误卡片，附 stderr 尾部 50 行进诊断日志。apply 崩溃后，GUI 用 `robot history list` 对账实际删除了哪些。
- **幂等**：apply 对同一 plan_id 可重放，已删项返回 `skipped_missing`，不报错。

### 4.5 CLI 侧实现要点（给实现者）

- 新增 `lib/core/robot.sh`：`robot_emit <event-json>`（含节流缓冲）、`robot_item`、`robot_progress` 等辅助函数；`MOLE_ROBOT!=1` 时这些函数是 no-op，**现有 TUI 输出路径一行不改**。
- clean 各 section 函数中，现有"发现一个可删目标"的落点在调用 `mole_delete` 处；robot plan 模式下改为经一个新包装 `robot_collect <path> <label> <kind>`（内部：dry-run 语义 + emit item + 记入 plan 文件）。改造按 section 逐个进行，每个 section 一个 PR，配 bats。
- `execute_optimization`（`lib/optimize/tasks.sh:1401`）已经是任务调度器；robot optimize 在其外围包一层：任务注册表导出为 list、逐任务 emit task_status。任务元数据（名称/说明/是否需要 admin/预估时长）新建 `lib/optimize/task_meta.sh` 数据文件维护。
- **本区域全部属于 destructive-sink 改造，遵守 CLAUDE.md：逐行 review、fallback 分支重点审、不放宽任何匹配。**

---

## 5. 功能模块详细设计

每个模块给出：数据流 / UI 状态机 / 交互细节 / 边界情况 / 验收标准（AC）。UI 状态机是 Swift Store 的实现依据。

### 5.0 通用交互骨架

所有"扫描-清理"型模块共享状态机：

```
idle → scanning(progress) → review(items, 可勾选) → applying(results) → summary
   ↖──────── cancel ────────┘                                          │
   └────────────────────────── "再来一次" ←─────────────────────────────┘
```

- scanning 可取消回 idle；review 停留不限时（但 plan 30 分钟过期后置灰执行钮并提示重扫）；applying 可取消（完成当前项后停止）。
- summary 展示：释放空间、成功/跳过/失败计数、"在历史中查看"、失败项可展开重试。

### 5.1 清理（Clean）

**数据流**：进入页面不自动扫描（尊重用户）；点"开始扫描"→ `robot clean plan` → item 流实时入列 → done 后进 review。执行 → `robot clean apply`。

**UI 结构**：
- 扫描态：中央动态视觉（见 §8）+ 实时上翻的"已发现可清理量"+ 当前扫描路径（单行、中间截断）。
- review 态：左侧 section 分组列表（每组：名称、条数、总大小、组级勾选）；右侧当前组的条目表（label、路径 tooltip、大小、risk 徽标）；顶部大数字"已选 X.X GB"；`caution` 项需展开该组时才可单独勾选。
- `insight` 事件渲染为 review 顶部的"洞察卡片"（如"System Data 里 Group Containers 占 21 GB"），只有"去分析页看"动作，无删除按钮。
- 执行态：逐项 result 滚动日志（成功打钩、跳过灰色、失败红色可展开原因）。

**purge / installer**：清理页顶部三个 tab：`快速清理`（clean）、`项目产物`（purge，首次进入引导设置扫描根，读写 CLI 同一份 `purge --paths` 配置）、`安装包`（installer）。三者共用骨架，只是 domain 不同。

**边界情况**：
- sudo section（System）：GUI 版 v1 **不做**系统级 sudo 清理（价值/风险比低），plan 时传 `--sections` 排除；helper 成熟后再评估。
- 扫描中磁盘文件变化：apply 时核心侧逐项重新 stat，消失即 `skipped_missing`。
- 白名单命中项在 review 中以"已保护"分组展示（不可勾选），入口跳设置页白名单管理。

**AC**：
1. `MOLE_DRY_RUN=1` 下 GUI 全流程可走通且磁盘零变更。
2. 同一台机器上，GUI plan 的 item 集合 == `mo clean --dry-run` 导出清单（抽样脚本自动比对，见 §11.4）。
3. apply 后所有 `reversible:true` 项可在废纸篓找到。
4. 扫描 10 万文件级目录不卡 UI 主线程（Instruments 验证）。

### 5.2 软件（Apps）

**数据流**：`robot apps list`（复用 `uninstall_list_apps`）→ GUI 侧补充装饰数据（并行、可失败降级）：图标 `NSWorkspace.icon(forFile:)`、最近使用 `mdls kMDItemLastUsedDate`、安装来源（core 已能判定 brew cask；App Store 用收据存在性 `Contents/_MASReceipt` 判定）。

**UI 结构**：
- 主视图：应用网格/列表可切换；排序（大小/名称/最近使用）；筛选（全部/大体积>1GB/超过 180 天未用/brew 安装）；搜索。
- 详情抽屉：图标、版本、bundle id、路径、占用构成（app 本体 + 数据），操作：卸载 / 在 Finder 显示。
- 卸载确认页 = `robot uninstall plan` 结果：主体 + 残留文件分组清单（Application Support / Caches / Preferences / Containers / LaunchAgents…），逐项路径与大小，全部默认勾选但可去勾。红字提示"将移至废纸篓"。
- 批量卸载：多选 → 一次 plan 多个 bundle id → 合并确认页。
- **残留清理 tab**：展示已卸载应用的孤儿文件（数据来自 clean 的 App leftovers section，plan 时 `--sections app_leftovers`），按"疑似所属应用"分组。

**安全红线（原样平移，实现者不得放宽）**：残留匹配只用 bundle id / 应用名精确变体（`lib/core/app_protection.sh` 现有逻辑）；批量卸载执行序完全走 `lib/uninstall/batch.sh`（含 sibling guard、launch service teardown）；受保护应用（`app_protection_data.sh`）在 GUI 中显示盾牌徽标且卸载按钮禁用并说明原因。

**AC**：
1. 应用列表与 `mo uninstall --list` 输出一致（数量、大小）。
2. 卸载一个测试应用后，`robot uninstall plan` 对同一 bundle id 再次执行返回空主体。
3. 受保护应用（如 CLI 自身、浏览器默认保护名单）无法从 GUI 发起卸载。
4. 装有同 bundle id 的 /Volumes 副本时，卸载不误删副本（sibling guard 的 bats 场景在 GUI 链路重放）。

### 5.3 优化（Optimize）

**数据流**：`robot optimize list` → 任务清单（含 category / needs_admin / 预估时长 / 人话说明）→ 用户勾选 → `robot optimize run` → task_status 流。

**任务分组建议**（映射现有 `opt_*` 函数）：
- 日常维护：DNS 缓存刷新、Saved State 清理、定期维护脚本、通知中心清理。
- 修复小毛病：Dock 重启、输入法/LaunchServices 重建、损坏配置修复、共享文件列表修复、Spotlight 孤儿规则清理。
- 深度维护（部分需 admin）：SQLite vacuum、Spotlight 索引优化、磁盘权限修复、内存压力释放、网络栈优化。
- 审计类（只读报告）：登录项审计（`opt_login_items_audit`）、LaunchAgents 体检、磁盘校验（`opt_disk_verify`）。

**UI**：任务清单卡片式，每张卡：名称、一句话说明、"会做什么"展开详情（内容来自 task_meta，等价于 CLI 的 explain-before-execute）、预估时长、admin 徽标。执行时整页变为参考图式的任务打钩流 + 当前任务高亮。

**权限编排**：勾选集中含 `needs_admin` 任务时，执行前一次性弹 helper 授权说明；helper 不可用 → 这些任务标 `skipped`（"需要管理员权限，可在设置中启用"），**绝不弹 osascript 密码框**。

**白名单联动**：优化任务涉及 plist 清理时沿用 CLI 的 protected/whitelisted 跳过逻辑（CLAUDE.md 工作规则），跳过项在结果中如实展示为 skipped 而非隐藏。

**AC**：
1. `MOLE_TEST_NO_AUTH=1` 下全部任务可跑完（admin 任务 skipped），无任何授权弹窗。
2. 每个任务的 detail 文案在 done 后如实反映动作（不允许"优化成功"这类空话，必须像 CLI 一样给出具体数字/动作）。
3. 任务失败不中断队列，队列结束后统一呈现。

### 5.4 分析（Analyze）

**引擎改造**：`cmd/analyze` 新增 `--serve` 模式：stdin 接收请求、stdout 回 NDJSON，常驻单进程：

```jsonc
→ {"op":"scan","id":"q1","path":"/Users/x","mode":"overview"}
← {"event":"scan_progress","id":"q1","files":183025,"bytes":214748364800}
← {"event":"node","id":"q1","path":"/Users/x/Library","size":89123456789,"is_dir":true,
   "cleanable":false,"child_count":42,"last_access":"2026-06-01"}   // 当前层子项逐个吐出
← {"event":"scan_done","id":"q1","dir":"/Users/x","total_size":…,"item_count":228}
→ {"op":"children","id":"q2","path":"/Users/x/Library"}   // 下钻：已扫过命中缓存，未扫过触发扫描
→ {"op":"rescan","id":"q4","path":"/Users/x/Library"}     // 刷新按钮：绕过缓存强制重扫当前目录
→ {"op":"cancel","id":"q1"}
```

复用点：并发扫描器（`scanner.go`）、结果缓存（`cache.go`，同会话内下钻/回退不重扫）、cleanable 判定（`cleanable.go`）、大文件堆（`heap.go`）。引擎返回**当前层的完整子项列表**（含每项 size / is_dir / cleanable / child_count / last_access）；**聚合与渲染是 GUI 侧职责**（见下）。delete 不在 analyze-serve 内实现——由 GUI 直接对选中路径调 `mole robot`（保证 Trash + oplog + 保护判定单源），**analyze-serve 保持纯只读**，权责清晰。

**UI 结构**（对照参考图逐点落实）：

- **左栏**：
  - 顶部：当前目录头像/图标 + 汇总"N 项, X GB"。
  - 目录条目列表（大小降序、占比条、文件/目录图标）；**cleanable 目录用专属图标 + 主题色**标注（如开发缓存 `.cache`）。
  - 每个条目：**单击 = 下钻进入**（等同点击 treemap 对应块）；条目尾部 `>` 箭头提示可进入；**右键菜单 = 在 Finder 中打开 / 移到废纸篓**（与 treemap 块的右键菜单完全对等）。
  - 列表可滚动，展示当前层全部真实子项（不做聚合——聚合只发生在 treemap 视觉层）。
- **主区 Treemap**（Squarified，自绘 Canvas）：
  - 块内容：文件夹/文件图标 + 名称 + 大小；块太小放不下标签时仅 hover tooltip。
  - **小项聚合（核心特性，参考图的"186 项 54.05 GB""49 项 960.8 MB"）**：占比过小、渲染出来标签不可读的尾部子项，**合并为一个聚合块**，块内用网格图标 + "N 项 · X GB"（中性灰着色，区别于真实目录块）。聚合规则见下方"聚合策略"。**点击聚合块** = 进入"其他 N 项"子视图（面包屑追加"其他 N 项"，该子集自成一张 treemap，可继续下钻），而不是无操作。
  - 着色：真实目录块按大小/层级走暖色系深浅；cleanable 块用主题强调色；聚合块中性灰；hover 提亮 + 阴影抬升 + tooltip（完整路径 / 大小 / 最后访问时间）。
  - 交互：**单击块 = 下钻**（未扫过的目录触发扫描，块上显示 loading；扫完进入该层，面包屑更新）；右键菜单 = 在 Finder 中打开 / 移到废纸篓 / 加入白名单。
  - 下钻转场：被点击块放大铺满 → 内部子块级联浮现（~350ms）；返回为逆过程。
- **顶部**：
  - **面包屑**（`根目录 > jiangding > … > Application Support > Google > Chrome`）：可点击任意层级跳转到对应目录视图；**路径过深时中间层折叠为 `…`**，点击 `…` 展开被折叠层级的下拉选择。首段固定为"根目录"带 home 图标。
  - 右侧状态区：**当前目录总量 + 磁盘用量（`当前 X GB · 磁盘 已用/总量 GB`，`df` 来自 status snapshot）**；扫描进行中显示**旋转进度指示**，完成后显示**刷新按钮**（触发 `rescan` op 重扫当前目录）。
- **首屏**：overview 模式先出用户目录/应用/Library 等一级快照（对应 `insights.go` 的 insight entries），点击任意块进入精确扫描。
- **大文件视图 tab**：全盘 Top-N 大文件列表（来自 large_files），支持直接 Trash。

**聚合策略**（GUI 侧，参考 DaisyDisk/GrandPerspective 的做法）：在当前视口内，保留能容纳可读标签的大块（约 top 若干项 + 面积高于最小可读阈值的项），其余尾部合并为一个"N 项 · X GB"聚合块。阈值随视口面积自适应（窗口越大展示越多真实块）；聚合是纯渲染决策，底层数据完整保留，`rescan`/删除后重算。左栏列表始终展示完整真实子项，用户想看被聚合的项可在左栏找到或点聚合块展开。

**性能策略**：Treemap 只渲染当前层级 + hover 预取下一层；聚合避免海量小块渲染；扫描进度事件节流 200ms；`children` 懒加载避免全树驻留内存（目标 <300MB，见 §10）。

**删除安全**：删除动作一律经 robot（mole_delete 语义：保护路径拒绝、Trash、oplog）。保护路径节点在 UI 上直接禁用"移到废纸篓"项并显示原因（GUI 侧预判用 robot 提供的 `whitelist list` + 只读判定命令 `robot guard check <path>`，M2 实现）。

**AC**：
1. 扫描 300GB 家目录：首屏 overview <3s，全量精确扫描期间 UI 可交互可取消。
2. Treemap 与左栏列表数据一致；下钻-返回后不重扫（命中缓存）；刷新按钮强制重扫。
3. 面包屑任意层级、`…` 折叠层级均可跳转，路径与视图始终同步。
4. 聚合块点击可进入并继续下钻；聚合不丢数据（左栏可见全部真实项）。
5. 删除节点后父链大小即时修正（无需全量重扫）。
6. 对 `/System` 等保护路径"移到废纸篓"入口不可用。

### 5.5 状态（Status）

**数据流**：`status-go --watch --interval 2s` 常驻订阅（**现成能力**）。GUI 只解码 `MetricsSnapshot` 渲染。刷新率设置 1s/2s/5s 三档，映射 `--interval`。

**卡片布局**（两行 + 进程表）：
- 健康分（`metrics_health.go` 的评分 + 诊断短语）+ 硬件摘要徽标（芯片/内存/系统版本）+ uptime。
- CPU：使用率大数字 + 温度徽标 + 近 60 采样柱状历史（Swift Charts）+ 负载/核数。
- GPU：使用率 + 温度。内存：压力 + 使用/交换。磁盘：可用量 + 容量条。网络：上下行速率 + sparkline。电池：电量/循环/健康/功率/温度。风扇：转速（无风扇机型隐藏该卡）。
- 进程表：Top-N（默认 20，可展开 50），列 = 名称+图标 / PID / CPU / 能耗 / 内存，列头排序；行尾菜单：结束进程（`NSRunningApplication.terminate()`，失败降级 SIGTERM，二次确认；不提供默认 SIGKILL）、在活动监视器打开。
- 高 CPU 持续告警（`process_watch.go` 已有 `proc-cpu-threshold` 机制）在进程行上以火焰徽标呈现，不弹系统通知。

**边界**：页面不可见即停订阅（NSWindow occlusion + tab 切换）；窗口最小化 10s 后 SIGTERM 子进程；回到页面重启（1s 内首帧用上次快照回填避免闪空）。**严格只读**，不做阈值配置、不做常驻。

**AC**：
1. 状态页开启时 App 总 CPU 增量 <5%（M4 基准机，2s 档）。
2. 断流（子进程被 kill）3s 内自动重连，UI 显示重连中而非冻结数据。
3. JSON 字段缺失（如无电池的台式机）对应卡片优雅隐藏，无占位错误。

### 5.6 历史（History）

- 数据：`robot history list --json`（M0 给 `bin/history.sh` 加 JSON 出口，底层日志已结构化）。
- UI：按操作会话分组的时间线（"7月6日 14:32 · 清理 · 释放 8.9 GB · 129 项"），展开看逐项路径与大小；条目动作：在废纸篓显示（若仍在）、复制路径。
- **撤销**：v1 提供"在废纸篓中显示"引导手动恢复；v2 做结构化恢复（§6.4）。

### 5.7 设置（Settings）

设置以窗口内浮层（sheet/panel）呈现，顶部小胶囊分 tab。逐 tab 定义：

**通用**
- 语言：`自动（跟随系统）/ 简体中文 / English`（运行时切换，见 §8.6）。
- 温度单位：`自动 / °C / °F`（自动 = 按 Locale 测量体系推断；作用于状态页全部温度读数）。
- 开机自动启动：`SMAppService.mainApp` 注册 Login Item（macOS 13+ 原生 API，系统设置中用户可见可撤销）。
- 启动页：默认智能扫描，可改为任一模块；"跳过引导动画直接进入功能面板"开关。
- 状态刷新率：1s / 2s / 5s。
- 全局快捷键：唤起 Mole 主窗口（默认 ⌃⌥⌘M，可改可清空；用 KeyboardShortcuts 类实现录制控件）。

**清理**
- 白名单管理：列表 + 添加（路径选择器或手输 pattern）+ 删除，读写 `~/.config/mole/whitelist`（经 `robot whitelist`），与 CLI 完全互通。
- 删除方式：`废纸篓（默认，可恢复）/ 立即删除（不可恢复）`。选择"立即删除"需要一次带后果说明的确认弹层，且该模式下清理确认页顶部常驻红色提示条"当前为立即删除模式"。实现上映射 robot apply 的 `--permanent` 选项（Phase 4 实现，核心侧仍经 `mole_delete` 的非 Trash 分支，oplog 照记）。**智能扫描一键流程强制废纸篓**，permanent 只对手动 review 后的执行生效。

**权限**
- 完全磁盘访问状态（实时检测 + 深链 `x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles`）、helper 安装状态（安装/卸载按钮）。每项右侧为状态徽标（已授权=绿 / 未授权=行动按钮），样式区分清楚"状态展示"与"可点击操作"。

**菜单栏**（v1.3 模块启用后出现，见 §6.7）
- 菜单栏图标开关、左键/右键行为对调、Cmd+Q 行为（`退出 Mole / 仅关窗口保留菜单栏`）、图标样式（`指标数字 / 奔跑的鼹鼠`）。

**高级**
- 诊断日志导出（App 日志 + 子进程 stderr 尾部 + 版本信息打包 zip）、重置 plan 缓存。

**许可证**（商业化开启后出现，见 §7.7）
- 未激活：显示试用剩余天数 + "输入许可证密钥"；已激活：显示"已激活，停用后可换到另一台 Mac" + "管理"（停用本机 / 查看已激活设备数）。

**关于**
- 版本、内嵌核心版本与 SHA、开源许可、指向 CLI 的 cross-link、检查更新。

### 5.8 首启引导（Onboarding）

三步，均可跳过（跳过则功能降级并在对应页面常驻提示条）：
1. 产品说明：三个承诺（可预览 / 进废纸篓 / 有记录）。
2. 完全磁盘访问：说明为什么需要（列出没有 FDA 时扫不到的目录类别）→ 打开系统设置 → 轮询 FDA 检测（探测法：尝试读 `~/Library/Mail` 等 TCC 目录的可访问性）→ 授权成功自动进下一步。
3. 可选 helper：只影响"深度维护"少数任务，默认跳过。

---

## 6. 超出现有 CLI 的新增功能设计

以下是 CLI 没有、但 GUI 场景下我会做的功能。每项标注价值、风险、落地版本（对应 §13 ROADMAP）。共同原则：**新增功能不得引入新的删除判定规则来源**——凡涉及删除，仍走 robot/mole_delete。

### 6.1 智能扫描首页（Smart Scan）— v1.0

打开 App 的默认页：一键运行"清理 plan + 残留 plan + installer plan + 大文件洞察"的聚合扫描，输出一屏结论卡片："可安全清理 X GB / 发现 N 个卸载残留 / M 个安装包 / 最大目录是 …"，每张卡点进对应模块的 review 态。
- 价值：普通用户不需要理解模块划分；这是 GUI 相对 CLI 的核心体验增量。
- 实现：纯 GUI 编排（并行跑多个 plan），核心零改造。

### 6.2 重复文件与相似大文件查找 — v1.2

扫描用户指定目录（默认 ~/Downloads、~/Documents、~/Desktop），三级匹配：size 分桶 → 首/尾 64KB 采样哈希 → 全量 BLAKE3。结果按重复组展示，默认保留每组最新一份，其余可勾选 Trash。
- 新建 Go 子命令 `analyze-go --dupes <paths>`（NDJSON 流式输出重复组），删除仍走 robot。
- 风险控制：默认排除 `~/Library`、应用 Bundle、包内文件（避免破坏 app）；硬链接/克隆文件（APFS clone，`st_blocks` 判定）识别后标注"实际不占双份空间"，默认不列为可清理。
- 价值高（CleanMyMac 同类功能使用率最高之一），但判定复杂，放 v1.2 单独打磨。

### 6.3 空间趋势与清理成效（Space Timeline）— v1.1

每次 App 启动及每次清理前后，记录一条磁盘快照（总量/可用/各顶级目录大小，来自 analyze overview 缓存，<1KB/条，存本地 SQLite）。设置页展示 90 天可用空间曲线 + 每次清理的"节省标记"。
- 价值：让"清理有没有用"可见，建立信任；数据全本地。
- 明确不做：后台定时采样（只在 App 使用时记录）。

### 6.4 结构化撤销（Undo Restore）— v1.1

oplog 已记录每个被 Trash 项的原路径。历史页对最近一次操作提供"恢复此项/全部恢复"：在废纸篓中按名称+时间戳定位对应项移回原路径（冲突时加后缀并提示）。
- CLI 侧新增 `robot history restore`（stdin 传 oplog 记录 id 列表），实现于 `lib/core/history.sh` 扩展；不可恢复（已清空废纸篓）时如实报告。
- 这是"可撤销"承诺的完整闭环，CLI 未来也可受益（`mo history restore`）。

### 6.5 登录项与启动项管理器 — v1.2

`opt_login_items_audit` 目前只读审计。GUI 升级为管理器：列出 Login Items / LaunchAgents / LaunchDaemons，标注归属应用、是否孤儿（对应 app 已卸载）、上次加载状态；支持禁用（launchctl bootout + 文件移入隔离区而非删除）与恢复。
- 安全约束：系统与 `com.apple.*` 项只读展示；禁用而非删除；隔离区放 `~/Library/Application Support/Mole/Quarantine/` 并入 oplog。
- CLI 侧新增 `robot launchitems list/disable/enable`，逻辑放 `lib/optimize/launch_items.sh`，遵守既有 plist 解析规则（绝对路径 Program 解析，CLAUDE.md 既有约定）。

### 6.6 卸载监听（Uninstall Watcher）— v1.3，默认关闭

用户从 Finder 删除 app 时（App 运行期间通过 FSEvents 监听 /Applications），弹一条应用内提示"检测到 X 已删除，存在 N 项残留，是否清理？"。
- 明确边界：仅 App 前台运行时监听，不做 launchd 常驻（与产品克制原则一致）；设置中默认关闭。

### 6.7 菜单栏模式 — v1.3，默认关闭（谨慎项）

可选的菜单栏 extra，默认关闭。启用后的完整行为规格：

- **图标样式二选一**：`指标`（可用磁盘 + 内存压力两个小数字）或 `奔跑的鼹鼠`（像素小动物动画，速度随 CPU 负载轻微变化——品牌趣味项，帧动画 ≤10fps、GPU 占用可忽略）。
- **点击行为**：左键打开迷你状态 popover（磁盘/内存/CPU 三行快照 + "打开 Mole"按钮），右键打开菜单（打开 Mole / 快速清理 / 设置 / 退出）；提供"对调左右键"开关。
- **仅菜单栏模式**：开关"不显示 Dock 图标，通过菜单栏运行"（`NSApp.setActivationPolicy(.accessory)`）；随之提供 **Cmd+Q 行为**选择：`退出 Mole / 仅关闭主窗口保留菜单栏`。
- 数据采样 30s 一次（popover 打开时临时提到 2s），无告警、无通知。
- 与 CLI"不做菜单栏"准则的关系：CLI 准则约束的是 CLI 产品面；App 用户对此有真实需求。以**默认关闭 + 只读**的形态提供，作为一次有边界的试验。若数据表明使用率低于 10%，v2 移除。

### 6.8 清理计划提醒 — v1.3，默认关闭

非后台方案：基于 UNUserNotificationCenter 的本地日历通知（如每月 1 日"该体检了"），点击通知打开 App。App 不运行任何后台进程。

### 6.9 诊断报告导出 — v1.0

一键生成人类可读的系统健康报告（Markdown/PDF）：健康分、硬件、磁盘构成、Top 占用、建议动作。给用户发给"家里懂电脑的人"或自查用。数据全部来自已有 status/analyze 接口。

### 6.10 明确评估后不做的

| 想法 | 不做的理由 |
|---|---|
| 内存加速/一键释放 RAM 常驻球 | 伪优化，损害产品可信度（`opt_memory_pressure_relief` 保留为手动任务即可） |
| 浏览器隐私清理 | 触碰会话/凭据，违反安全红线 |
| 应用自动更新器 | 与 brew/App Store 职责重叠，维护面大 |
| 云端规则下发（远程更新清理规则） | 规则必须随版本走审计流程，远程下发破坏"单一来源 + 可 review"链条 |
| 擦屏模式（清洁屏幕时锁键盘） | 与清理/维护产品域无关的小工具，稀释产品定位 |
| 屏幕常亮（咖啡因）快捷键 | 同上，Amphetamine 等专门工具已做得很好 |
| 摄像头/麦克风使用提醒 | 需要常驻监控，违反"不做后台监控"原则，且系统自带指示灯 |
| 蓝牙配件低电量提醒 | 需要常驻监控；状态页只读展示蓝牙设备电量即可 |
| 电池充电上限（80% 养护）/ 风扇转速控制 | 需要 SMC 硬件层写入权限，风险域远超清理工具；充电管理 macOS 自带优化，风扇保持只读展示 |

（后五项来自竞品设置页对照评估：竞品把系统小工具打包进清理软件，我们选择保持"清理与维护"的窄定位——这些功能每加一个，"这软件到底干什么"就模糊一分。）

---

## 7. 权限与安全设计

### 7.1 权限矩阵

| 能力 | 所需权限 | 获取方式 | 降级行为 |
|---|---|---|---|
| 扫描/清理用户域 | 完全磁盘访问（FDA） | 引导授予 | 无 FDA：可扫非 TCC 目录；结果页顶部显示"N 个受保护目录未扫描"（扫描器统计 EPERM 计数，robot progress 带 `denied_dirs` 字段） |
| Trash 删除 | 无特殊权限 | — | — |
| 深度维护任务（少数） | root（helper） | SMAppService 安装 | 任务标记 skipped |
| 进程结束 | 同用户进程无需授权 | — | 他人/系统进程按钮禁用 |

### 7.2 FDA 检测实现

探测法：依次尝试 `open()` 若干 TCC 保护路径（`~/Library/Mail/V*`、`~/Library/Safari/CloudTabs.db`、TCC.db 本身），任一可读即视为已授权。检测封装在 MoleKit `PermissionProbe`，onboarding 轮询用 1s 间隔、其余场景进入页面时检一次。

### 7.3 Privileged Helper（MoleHelper）

- 注册：`SMAppService.daemon(plistName:)`，macOS 13+ 原生流程（无 SMJobBless 遗留）。
- XPC 协议（全部接口，禁止扩展出通用执行）：
```swift
@objc protocol MoleHelperProtocol {
    // taskID 必须命中 helper 二进制内编译期白名单，否则返回 E_TASK_UNKNOWN
    func runTask(_ taskID: String, reply: @escaping (Int32, String) -> Void)
    func helperVersion(reply: @escaping (String) -> Void)
}
```
- 调用方校验：helper 用 `SecCodeCopyGuestWithAttributes` 验证连接方 audit token 的签名 requirement（同 Team ID + bundle id `com.mole.mac`），不匹配即断连。
- 任务白名单初始集（对应 `opt_*` 中确需 root 的子步骤）：`periodic_maintenance`、`spotlight_reindex`、`disk_permissions_repair`、`network_stack_optimize`。每项在 helper 内是**写死的具体命令序列**，不接受参数化路径。
- helper 与 App 版本严格配对（版本握手不一致时提示重装 helper）。

### 7.4 删除与审计链

```
GUI 勾选(id) → robot apply → 核心逐项: 重新 stat → should_protect_path
  → whitelist 检查 → mole_delete(Trash) → oplog 追加 → result 事件 → GUI/历史页
```
任何一环失败该项即 skip/fail，不影响其余项。**GUI 代码中不允许出现 `FileManager.removeItem` / `trashItem` 对用户数据的直接调用**（lint 规则挡住，见 §11.6；App 自身缓存除外，路径前缀白名单）。

### 7.5 内嵌核心完整性

构建期把 `mole-core/` 内容清单 + SHA256 写入 App 资源；MoleKit 启动子进程前校验入口脚本与二进制哈希，不匹配即拒绝执行并提示重装（防篡改 + 防半更新状态）。Hardened Runtime 下需要 `com.apple.security.cs.allow-unsigned-executable-memory` 吗——不需要；两个 Go 二进制与 shell 脚本正常随 App 签名。

### 7.6 隐私

- 零遥测默认。可选的匿名崩溃报告（Sentry self-host 或 off-the-shelf，opt-in）。
- 所有扫描数据、快照、历史仅存本地（`~/Library/Application Support/Mole/`）。
- 网络访问仅：Sparkle 更新检查、（可选）崩溃上报、（商业化开启后）许可证激活/停用。文档化在隐私声明中。

### 7.7 付费与授权（Licensing，预留设计）

产品可能走付费授权。**v1.0 先免费发布建立口碑，但授权基础设施从 Phase 4 起随包交付（feature flag 暗置）**，商业化开关打开时无需改架构。

**商业模型（预设，可由业务决策调整）**
- 买断制 + 大版本付费升级（同类工具的主流模型），单许可证默认可激活 2 台 Mac，支持**自助停用换机**（参考竞品的"停用后可换到另一台 Mac"）。
- 全功能试用 14 天（不阉割功能，到期后降级），不注册即可试用。
- 支付与许可证签发托管给 Paddle 或 Lemon Squeezy（含全球税务/发票，自建成本不值得）。
- **边界承诺**：CLI 永远开源免费；付费只发生在 GUI 层。robot 核心不含任何授权检查——授权是 App 的事，不是规则引擎的事。

**LicenseKit 模块（MoleKit 内）**
- 状态机：`unlicensed(trial_active) → trial_expired → activated → grace(离线宽限) / deactivated`。
- **离线优先验证**：许可证为 Ed25519 签名的 license 文件（含 key、设备指纹哈希、版本上限、签发时间），公钥编译进 App；日常启动只做本地签名校验，**不联网**。激活/停用时才调用供应商 API（发送：license key + 匿名设备指纹哈希，不含任何个人/系统数据）。
- 存储：license 文件在 Application Support，密钥材料入 Keychain；时间回拨检测（记录单调递增的最后见到时间）。
- 离线宽限：激活后永久离线可用（买断制不做定期回连验证——对用户友好，也减少被破解的动机面）。
- **功能门控**：`Entitlement` 枚举 + 各 Feature Store 入口处的 `gate.check(.pro)` 调用点。免费/付费功能怎么切由业务后定，代码侧只需要在模块入口预埋检查点；试用期内全开。门控降级行为必须是**温和禁用 + 说明**（按钮变"升级解锁"），禁止扫描到一半弹付费墙。
- UI 交付物：设置页许可证行（§5.7）、激活 sheet（输入 key / 购买链接 / 恢复购买）、试用剩余天数的低调顶栏提示（仅最后 3 天出现）、到期降级说明页。
- 反滥用姿态：不做激进 DRM。本地校验 + 设备数限制足够；把工程精力花在产品上。

**测试**：LicenseKit 全状态机单测（含时间回拨、签名篡改、宽限)；UI 测试覆盖试用/激活/到期三态；商业化 flag 关闭时所有授权 UI 不可见且零网络调用（自动化断言）。

---

## 8. UI / 设计系统

### 8.1 信息架构

单窗口（默认 1200×760，最小 980×640），顶部居中胶囊分段导航：`智能扫描 · 清理 · 软件 · 优化 · 分析 · 状态`，左端 App 徽标（点击回智能扫描页），右端历史与设置图标。深色优先，完整适配浅色与增强对比度。

### 8.2 视觉语言（原创方向）

- 每个模块一个主题色相 + 统一的"焦点视觉"承载扫描/执行状态：**光谱环（Spectrum Ring）**——一枚精密仪表般的圆环，原则是"形态跟随数据"：静息为呼吸的径向刻度环；扫描时为环形均衡器（扫描头沿环行进、刻度 ∝ 发现量、环心仪表滚动总量、进度双色弧）；完成时环**就地重组为甜甜圈占比图**（弧段角度 ∝ 各类真实占比，作为与结果卡片色彩联动的活图例）。数据驱动而非装饰、每状态都有职责（无残留自转小球）、完成态可交互（hover/点击弧段）。避免写实星球素材与通用粒子球，程序化生成（Canvas，Metal 备选）。完整状态机规格见 `docs/UI_DESIGN_PROMPT.md` §2.5、§4.1。
- 数字优先排版：结论用大号等宽数字（SF Mono/SF Pro Rounded），说明文字退后。
- 列表密度中等，行高 36，路径类文本中间截断 + hover 完整 tooltip。
- 动效克制：数值滚动、卡片过渡 ≤200ms，全部 `reduceMotion` 适配。

### 8.3 组件库（DesignSystem 模块的交付清单）

`MoleCard`、`StatBadge`、`SpectrumRingView`（光谱环焦点视觉，含 idle/scanning/donut 三态 + 结果重组转场）、`DonutBreakdownView`（占比图例，可与结果卡片联动）、`ResultCard`（含编号角标的结论卡）、`SectionList`（分组勾选列表）、`ResultLog`（滚动结果流）、`TreemapView`、`SparklineView`、`RiskBadge`、`EmptyState`、`PermissionBanner`。每个组件配 Preview + 快照测试。

### 8.4 文案语气

- 说人话、说清楚后果（"将把 129 项移入废纸篓，共 8.9 GB"），禁止"深度优化你的 Mac"式空话。所有语言版本同一语气标准。

### 8.5 国际化（i18n）架构

首发语言：**简体中文 + English**；架构上为 zh-Hant / ja 等后续语言零改造预留。

- **资源**：Xcode String Catalog（`.xcstrings`）单一来源，key 采用 `feature.semantic` 命名（如 `clean.summary.freed`）；禁止代码内硬编码用户可见字符串（SwiftLint 自定义规则拦截 `Text("汉字|[A-Za-z]{2,}...")` 形态的字面量）。
- **应用内语言切换**：设置项 `自动/简体中文/English`，实现为覆盖 `AppleLanguages` 后提示重启，或运行时自定义 Bundle 加载（选后者，免重启；MoleKit 提供 `L10n.bundle` 间接层）。
- **格式化一律走 Locale**：字节数 `ByteCountFormatter`、日期 `Date.FormatStyle`、数字分隔符、相对时间（"3 天前"）；温度单位按 §5.7 设置（自动档从 `Locale.measurementSystem` 推断）。
- **robot 协议的 i18n 分层**（见 §4.3）：核心输出稳定机器键（section/kind/detail_key），GUI 按 key 本地化；应用名与路径为数据不翻译；未知 key 回退英文原文。核心 shell 层保持英文单语，避免把本地化复杂度带进安全关键代码。
- **布局韧性**：英文文案通常比中文长 30–60%，所有按钮/徽标/表头不允许定死宽度；快照测试矩阵覆盖 `zh-Hans × en × 深色 × 浅色`；CI 加伪本地化（pseudo-locale，加长 40% + 重音字符）巡检截断。
- 不做 RTL（阿拉伯语等）适配承诺；若未来需要再立项。
- 文档/官网/release notes 同步双语（沿用 CLI 仓库 release-notes skill 的双语规范）。

### 8.6 可访问性

VoiceOver 全流程可完成一次清理（AC 化）；键盘可达（tab 序、空格勾选、⌘↵ 执行）；色彩对比 ≥ WCAG AA；risk 信息不只靠颜色（配图标+文本）。

---

## 9. 工程结构与编码规范

### 9.1 仓库与目录

App 独立仓库 `mole-mac`（本 CLI 仓库保持纯 CLI，互相 cross-link）：

```
mole-mac/
├── Project.yml                    # XcodeGen 声明式工程
├── MoleApp/
│   ├── App/                       # 入口、AppDelegate、窗口、导航
│   ├── Features/
│   │   ├── SmartScan/  Clean/  Apps/  Optimize/  Analyze/  Status/
│   │   ├── History/  Settings/  Onboarding/
│   │   └── <Feature>/{<Feature>View.swift, <Feature>Store.swift, Components/}
│   ├── DesignSystem/              # §8.3 组件 + 主题 token
│   └── Resources/                 # Assets, xcstrings
├── MoleKit/                       # SwiftPM 包，独立可测
│   ├── Robot/                     # RobotSession, RobotEvent(Codable), 命令构造
│   ├── Core/                      # CoreBundleLocator(哈希校验), ProcessRunner
│   ├── Status/                    # MetricsSnapshot 模型 + watch 订阅
│   ├── Analyze/                   # serve 客户端 + Treemap 布局算法(纯函数)
│   └── Permissions/               # FDA 探测, helper 客户端
├── MoleHelper/                    # privileged helper target
├── CoreBundle/
│   ├── core.lock                  # 锁定 CLI 仓库 tag + 各文件 SHA256
│   └── fetch_core.sh              # 从 CLI 仓库 tag 拉取并打包 mole-core
├── Tests/{MoleKitTests, SnapshotTests, UITests, ContractTests}
└── scripts/{build.sh, sign_notarize.sh, release.sh, verify_contract.sh}
```

CLI 仓库侧新增（在本仓库、按其规范开发与测试）：`bin/robot.sh`、`lib/core/robot.sh`、`lib/optimize/task_meta.sh`、`cmd/analyze --serve`、`bin/history.sh --json`、对应 bats + Go tests。

### 9.2 Swift 侧规范

- Swift 5.10+，`@Observable` Store（不引 TCA 等重框架，保持依赖极简）；并发一律 async/await + AsyncSequence，禁止裸 DispatchQueue 新代码。
- 每个 Feature：View 只做渲染与用户意图转发；Store 持状态机（枚举建模 §5.0 的状态）与对 MoleKit 的调用；MoleKit 不 import SwiftUI。
- 依赖白名单：Sparkle（更新）、swift-collections（如需）、可选 Sentry。新增第三方依赖需在 PR 说明理由。
- SwiftLint + SwiftFormat 进 CI；自定义 lint 规则：Features/ 内禁止 `Process(`、`FileManager.default.removeItem`、`NSWorkspace...recycle`（只能出现在 MoleKit 指定文件，见 §7.4）。

### 9.3 CLI 侧改造规范（重申仓库既有规则）

robot 层改造全程遵守 CLAUDE.md：不放宽匹配、destructive sink 逐行 review、每 section 独立 PR 配 bats、bash 3.2 兼容（空数组 nounset、短路返回值等已知坑）、`./scripts/check.sh --format` 通过。

---

## 10. 性能预算

发布门禁指标（M 系列基准机，Release 构建，Instruments/自动化脚本验证）：

| 指标 | 预算 |
|---|---|
| 冷启动到首帧 | <1.0s |
| App 常驻内存（状态页开启） | <180MB |
| 分析页扫描 300GB 家目录峰值内存 | <300MB（GUI 进程）+ <500MB（analyze-serve） |
| 状态页 CPU 增量（2s 档） | <5% |
| 空闲时（无页面活动）CPU | ≈0%（无轮询、无定时器泄漏） |
| 清理 plan 10 万项 review 列表滚动 | 60fps（列表虚拟化） |
| 包体（dmg） | <40MB |
| 能耗徽标（Activity Monitor Energy） | 空闲时 "Low" |

---

## 11. 测试与质量保障体系

质量目标：**任何一个 Agent/工程师提交的 PR，通过 CI 即达到可合并质量**。为此把验收尽量自动化。

### 11.1 测试金字塔

| 层 | 内容 | 工具 | 门槛 |
|---|---|---|---|
| CLI 单测 | robot 层每个命令/事件/错误码；现有 bats 全量 | bats（`MOLE_TEST_NO_AUTH=1`）| 新增 robot 代码行覆盖 ≥85% |
| Go 单测 | analyze --serve 协议、dupes、status 既有 | go test | `go test ./...` 全绿 |
| **协议契约测试** | 双向：CLI 侧用 golden NDJSON 文件断言输出；Swift 侧用同一批 golden 文件断言解码 | `Tests/ContractTests` + CLI `tests/robot_contract.bats` 共享 `contracts/*.ndjson` | 协议改动必须同时更新 golden + 两端测试，缺一 CI 红 |
| MoleKit 单测 | Store 状态机、进程编排（用假子进程脚本 mock）、节流、取消、崩溃恢复 | XCTest | 覆盖 ≥80% |
| 快照测试 | DesignSystem 全组件 × 深浅色 × 中英 | swift-snapshot-testing | 全绿 |
| UI 测试 | 每模块 1 条主链路（用 `MOLE_DRY_RUN=1` + fixture 目录） | XCUITest | 全绿 |
| E2E 冒烟 | 真机脚本：造 fixture 垃圾目录 → GUI 清理 → 断言进废纸篓 + oplog 正确 | 自研脚本，release 前手动+CI macos runner | 发布门禁 |

### 11.2 Fixture 体系

`Tests/Fixtures/make_dirty_mac.sh`：在临时 HOME 造出确定性的"脏"环境（各类缓存目录、假 app bundle、假残留、假安装包、重复文件），CLI bats 与 App UI 测试共用。robot 全链路测试跑在 `HOME=$FIXTURE_HOME` 下，保证 CI（GitHub macOS runner）可重复。

### 11.3 安全回归集（每次发布必跑）

把 CLI 历史事故场景在 GUI 链路重放为自动化用例：
1. TeamID 通配残留误删场景（PR #874/875 形状）→ GUI 卸载 plan 不得出现越界路径。
2. /Volumes 同 bundle id 副本 → sibling guard 生效。
3. 白名单路径 → plan 中标记保护，apply 被拒。
4. `com.apple.*` / /System → 任何入口均不可删。
5. sudo 密码框 → `MOLE_TEST_NO_AUTH=1` 下全流程零弹窗。

### 11.4 双端一致性校验

`scripts/verify_contract.sh`：同一 fixture HOME 下分别跑 `mo clean --dry-run`（导出清单）与 `robot clean plan`，比对路径集合完全一致。进 CI；不一致即证明 robot 层与 TUI 层产生了规则分叉——这是本架构最需要守住的不变量。

### 11.5 CI 流水线（GitHub Actions, macos-14）

PR：lint(swift+shell) → CLI bats(robot 相关) → go test → MoleKit 单测 → 契约测试 → 快照 → UI 冒烟（~15min）。
main nightly：全量 bats + E2E + 性能脚本（启动时间/内存采样，超预算报警）。
release tag：全量 + 签名 + 公证 + dmg + Sparkle appcast 生成 + §12 checklist。

### 11.6 代码审查规则

- 触碰 robot/删除链路的 PR：必须两人（或人+安全 reviewer agent）审查，按 CLAUDE.md destructive-sink 清单逐项打勾。
- Features/ 出现受禁 API（§9.2 lint）直接 CI 红。
- 协议变更 PR 模板强制包含：schema diff、golden 更新、两端测试更新、向后兼容说明。

### 11.7 Beta 与灰度

TestFlight 不可用（非 MAS），用 Sparkle 双通道：`beta` appcast + `stable` appcast。每个 minor 先 beta ≥1 周，收集崩溃率（<0.5% 会话）与关键漏斗（扫描完成率、清理完成率）后推 stable。

---

## 12. 构建、签名与发布

1. `CoreBundle/fetch_core.sh`：按 `core.lock` 的 tag 从 CLI 仓库导出 `mole` + `lib/` + `bin/`（剔除 tests/scripts），`make build` 出两个 universal Go 二进制，生成清单 SHA256。
2. XcodeGen 生成工程 → `xcodebuild archive`（App + Helper 两 target，Hardened Runtime，Developer ID Application 证书；Helper 嵌入 `Contents/Library/LaunchDaemons` 相应 plist）。
3. `notarytool submit` 公证 + staple；打 dmg（create-dmg，含拖拽安装背景）。
4. 生成 Sparkle appcast（EdDSA 签名），上传 GitHub Release；appcast 指向 Release 资产。
5. 发布 checklist：性能预算全绿、安全回归集全绿、双端一致性全绿、helper 版本握手、新旧版本升级路径实测（Sparkle 从上一 stable 升级）、FDA 引导在全新系统镜像上实测。

版本策略：App `1.x.y` 独立于 CLI 版本；`core.lock` 记录内嵌 CLI tag；关于页同时展示两者。

---

## 13. ROADMAP

> 估算按"1 名全职工程师 + AI 辅助"折算；并行度标注了可同时开工的轨道。M0 是一切前提；CLI 轨道（本仓库）与 App 轨道（新仓库）在 M0 后可并行。

### Phase 0 — 协议与地基（M0，约 2–3 周）【CLI 仓库】

| 交付 | 验收 |
|---|---|
| `lib/core/robot.sh`（emit/节流/plan 文件管理）+ `bin/robot.sh` 路由 | bats：事件格式、错误码、plan 过期、取消语义 |
| `robot clean plan/apply`（先做 3 个代表性 section：user essentials / app caches / app leftovers） | §11.4 一致性脚本对这 3 个 section 通过 |
| `robot apps list` / `robot history list --json` / `robot whitelist *` | bats 全绿 |
| `cmd/analyze --serve`（scan/children/cancel，先不含 delete） | go test 协议用例 |
| `contracts/*.ndjson` golden 初版 | 契约测试框架在两端跑通 |

**里程碑判据**：不写一行 Swift，用 `jq` 脚本即可完成一次"plan → 勾选 → apply → 废纸篓验证"的完整演练。

### Phase 1 — App 骨架与只读双页（M1，约 3 周）【App 仓库】

- 工程脚手架（XcodeGen、CI、lint、DesignSystem 基础 token 与 5 个核心组件）。
- MoleKit：ProcessRunner、RobotSession、契约测试接入。
- **状态页**（现成 `--watch` 数据源）与**软件页列表**（现成 `--list`）先行——风险最低、见效最快。
- Onboarding + FDA 检测。
- 判据：内部 alpha 可日常当 iStat 替代品用；崩溃率为 0 的一周。

### Phase 2 — 清理闭环（M2，约 4 周）【双仓库并行】

- CLI：clean 其余 section 的 robot 化（每 section 一 PR）；`robot uninstall plan/apply`；`robot guard check`。
- App：清理页全交互（§5.1 状态机）、软件页卸载流、历史页 v1。
- 安全回归集（§11.3）落地为自动化。
- 判据：E2E 冒烟绿；内部用户用 GUI 完成真实清理且可在废纸篓/历史中对账。

### Phase 3 — 分析与优化（M3，约 4 周）

- CLI：`robot optimize list/run` + task_meta；purge/installer robot 化。
- App：分析页（Treemap + 下钻 + Trash 删除 + 大文件 tab）；优化页任务流；清理页接入 purge/installer tab。
- Helper（SMAppService + 白名单 4 任务）+ 权限中心。
- 判据：五大模块全通；性能预算首次全量测量并达标。

### Phase 4 — 1.0 发布（M4，约 3 周）

- 智能扫描首页（§6.1）、诊断报告导出（§6.9）。
- 设置页收尾：温度单位、开机自启、全局快捷键、删除方式（永久删除高级选项，含 robot `--permanent`）。
- i18n 硬化（§8.5）：伪本地化巡检、zh×en 快照矩阵、双语文案审校。
- **LicenseKit 基础设施随包交付但 feature flag 关闭**（§7.7）：状态机 + 本地校验 + 全部授权 UI（暗置），商业化开关打开时无需发新架构。
- 可访问性 AC、Sparkle 双通道、签名公证流水线、官网下载页与 CLI README cross-link。
- Beta ≥2 周 → **v1.0 stable**。

### Phase 5 — 信任增强（v1.1，约 3 周）

- 结构化撤销（§6.4，含 CLI `robot history restore`）。
- 空间趋势 Timeline（§6.3）。
- 根据 1.0 反馈的体验修补。

### Phase 6 — 能力扩展（v1.2，约 4 周）

- 重复文件查找（§6.2，`analyze-go --dupes`）。
- 登录项/启动项管理器（§6.5）。

### Phase 7 — 边界试验与商业化（v1.3，按数据决策）

- 卸载监听（§6.6）、菜单栏模式（§6.7，含仅菜单栏运行/Cmd+Q 行为/奔跑鼹鼠样式）、清理提醒（§6.8）——三者均默认关闭、独立开关、带使用率埋点（opt-in），数据不好即移除。
- **商业化开关评估点**：v1.0 发布后依据装机量/留存决定是否开启付费（打开 §7.7 的 feature flag、接入 Paddle/Lemon Squeezy、上线购买页）。开启前完成免费/付费功能切分的业务决策，并保证存量用户的既得功能不回收。

### 长期观察项（不承诺）

- GUI 侧 sudo 系统清理 section（等 helper 模式被验证稳定后评估）。
- iCloud/云盘占用洞察、Time Machine 快照管理（只读分析形态）。
- CLI 与 App 共享的规则包版本化（若两端节奏差异变大再立项）。

---

## 14. 附录

### 14.1 错误码表

| code | 含义 | GUI 处理 |
|---|---|---|
| `E_PLAN_EXPIRED` | plan 超 30 分钟 | 提示重新扫描 |
| `E_PLAN_NOT_FOUND` | plan_id 无效 | 同上 |
| `E_PATH_PROTECTED` | 命中保护路径 | 该项标记跳过并说明 |
| `E_WHITELISTED` | 命中白名单 | 同上，附白名单管理入口 |
| `E_PERMISSION` | EPERM/TCC 拒绝 | 引导 FDA |
| `E_TASK_UNKNOWN` | 未知任务 id | 版本不匹配提示（App/核心哈希校验兜底） |
| `E_ADMIN_REQUIRED` | 需 helper | 任务 skipped + 设置入口 |
| `E_BUSY` | 已有破坏性操作在跑 | GUI 侧本应拦住；出现即 bug 上报 |
| `E_CANCELLED` | 用户取消 | 静默，summary 标注 |
| `E_INTERNAL` | 其他 | 错误卡片 + 诊断日志 |

### 14.2 事件 JSON Schema

正式 JSON Schema 文件随 M0 交付在 CLI 仓库 `docs/robot_schema/`（`item.schema.json` 等），契约测试用它校验 golden 文件。本文 §4.3 的示例为规范性示例。

### 14.3 术语表

| 术语 | 含义 |
|---|---|
| robot 模式 | CLI 面向 GUI 的机器可读命令层（`MOLE_ROBOT=1`） |
| plan / apply | 破坏性操作的两段式：只读生成计划 / 按计划 id 执行 |
| section | clean 的清理分组（§2.4 的 16 个） |
| insight | 只报告不执行的洞察类输出 |
| oplog | 操作日志（`lib/core/file_ops.sh` 写入，历史页数据源） |
| FDA | Full Disk Access，完全磁盘访问权限 |
| helper | SMAppService 注册的 root 权限守护进程 |
| golden 文件 | 契约测试用的标准 NDJSON 样本，两端共享 |

### 14.4 与参考图的功能对应（仅功能范围，不复制设计）

图 1/2（清理扫描与逐项结果流）→ §5.1；图 3（优化任务打钩流）→ §5.3；图 4（Treemap + 目录列表）→ §5.4；图 5（健康分 + 指标卡 + 进程表）→ §5.5。
