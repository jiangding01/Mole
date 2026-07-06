# Mole Mac App 技术方案（Mole for Mac）

> 状态：设计稿 v1（2026-07）
> 范围：基于现有 Mole CLI（shell + Go）构建一个原生 macOS 可视化应用，覆盖清理、软件管理、优化、磁盘分析、系统状态五大功能。
> 说明：本方案是原创设计，参考图仅用于功能范围说明；UI 视觉、交互、文案均按自身产品理解设计。

---

## 1. 目标与非目标

### 1.1 目标

| 模块 | 对应 CLI 能力 | App 形态 |
|------|--------------|----------|
| 清理（Clean） | `mo clean` / `mo purge` / `mo installer` | 一键扫描 → 分类预览 → 勾选清理，全程可撤销（Trash） |
| 软件（Apps） | `mo uninstall`（含 `--list` JSON） | 已装应用清单、体积、残留检测、批量卸载 |
| 优化（Optimize） | `mo optimize` | 任务清单式维护：逐项说明 → 执行 → 结果反馈 |
| 分析（Analyze） | `mo analyze`（含 `--json`） | 磁盘占用可视化（Treemap + 目录列表）、下钻、ad hoc 删除进 Trash |
| 状态（Status） | `mo status`（含 `--json` / NDJSON watch） | 实时健康仪表盘：CPU/GPU/内存/磁盘/网络/电池/风扇/进程 |

核心原则沿用 CLI 的安全观：**默认安全、可预览、可撤销、可审计**。GUI 不是新增能力面，而是给已有能力一个可视化壳。

### 1.2 非目标

- 不做后台常驻监控、菜单栏 App、通知告警、定时任务（与 CLI 产品准则一致，除非未来单独立项）。
- 不做通用系统设置中心、隐私重置、包管理器 GUI。
- 不追求与 CLI 100% 功能对等；不适合 GUI 的能力（如 completion、touchid）不进 App。
- App 与 CLI 是两个发行物；App 不要求用户先安装 CLI（内嵌核心，见 §3）。

---

## 2. 现有 CLI 能力盘点（可复用资产）

设计前先明确"哪些已经是接口、哪些还是纯 TUI"，这决定复用策略。

### 2.1 已有机器可读接口（直接复用）

| 接口 | 位置 | 输出 |
|------|------|------|
| `status --json` / watch 模式 | `cmd/status/main.go`（`-json` flag） | 全量指标 JSON；watch 可持续输出（NDJSON） |
| `analyze --json <path>` | `cmd/analyze/main.go`（`-json` flag）、`cmd/analyze/json.go` | 目录扫描结果 JSON（大小、子项） |
| `mo uninstall --list` | `bin/uninstall.sh`（`uninstall_list_apps`，只读短路路径） | 每个应用的 name / bundle id / path / size 的 JSON |
| 健康检查 JSON | `lib/check/health_json.sh` | 内存 / 磁盘等健康数据 JSON |
| 操作日志（oplog）/ history | `lib/core/file_ops.sh` + `lib/core/history.sh`、`bin/history.sh` | 每次删除的结构化记录，可做 App 内"清理历史" |

### 2.2 已有安全基础设施（必须复用，不得绕过）

- `mole_delete`（`lib/core/file_ops.sh`）：Trash 路由、dry-run、路径保护、操作日志四合一，是唯一删除入口。
- `should_protect_path` + `lib/core/app_protection*.sh`：保护路径与受保护应用策略。
- 白名单体系（`lib/manage/whitelist.sh`）。
- `MOLE_DRY_RUN=1` / `MOLE_TEST_NO_AUTH=1` 环境变量约定。

### 2.3 纯交互式、需要新增结构化出口的部分

- `mo clean`：目前输出面向终端（section 文本 + 颜色），**没有** JSON 预览/结果流。
- `mo optimize`：任务注册在 `lib/optimize/tasks.sh`，同样是终端输出。
- `mo purge` / `mo installer`：菜单交互式。

结论：**GUI 项目最大的一块 CLI 侧工作，是给 clean / optimize / purge / installer 增加"计划（plan）→ 执行（apply）"两段式的 JSON/NDJSON 接口**（详见 §5），而不是在 GUI 里重写清理逻辑。清理规则只维护一份（shell 库），这是安全上的硬要求。

---

## 3. 总体架构

### 3.1 架构选型

三个候选：

1. **A：GUI 直接驱动 CLI 子进程（解析现有文本输出）** — 最快，但文本输出不是契约，颜色/文案一改就断；否决。
2. **B：用 Swift 重写全部清理逻辑** — 清理规则出现两份实现，安全规则漂移风险极高，且违反"清理逻辑单一来源"；否决。
3. **C（推荐）：SwiftUI 原生壳 + 内嵌 `mole-core` 结构化命令层**。App 通过稳定的 JSON/NDJSON 协议驱动内嵌的 CLI 核心（shell 库 + Go 二进制），CLI 侧为此新增 `--robot`（机器模式）出口。

选 C 的理由：

- 清理/保护/白名单逻辑保持单一来源（shell 库），GUI 与 CLI 行为天然一致，安全测试（bats）继续覆盖真实执行路径。
- `status` 与 `analyze` 本来就是 Go 二进制且已有 `-json`，GUI 复用成本接近零。
- Swift 侧只做展示、编排、权限，不做任何删除决策。

### 3.2 组件图

```
┌──────────────────────────────────────────────────────────┐
│  Mole.app（SwiftUI, macOS 13+）                           │
│                                                          │
│  ┌────────────┐ ┌────────────┐ ┌───────────────────────┐ │
│  │  五大功能   │ │ AppCore     │ │ MoleKit (Swift Pkg)   │ │
│  │  Feature   │→│ 状态管理     │→│ 进程编排/协议解码/模型  │ │
│  │  Views     │ │ (Observable)│ │ (Codable + AsyncSeq)  │ │
│  └────────────┘ └────────────┘ └──────────┬────────────┘ │
│                                           │ stdin/stdout │
│  Contents/Resources/mole-core/            │ NDJSON       │
│  ┌────────────────────────────────────────▼────────────┐ │
│  │ mole（entry）+ lib/**（shell 库）                      │ │
│  │ analyze-go / status-go（通用二进制，随 App 打包）        │ │
│  │ 新增：bin/robot.sh —— plan/apply/list 机器模式出口      │ │
│  └─────────────────────────────────────────────────────┘ │
│                                                          │
│  ┌─────────────────────────────────────────────────────┐ │
│  │ MoleHelper（SMAppService privileged helper, 可选）    │ │
│  │ 仅承接需要 root 的优化任务；XPC 白名单化命令             │ │
│  └─────────────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────────────┘
```

### 3.3 关键决策

| 决策 | 结论 | 理由 |
|------|------|------|
| App Sandbox | **不启用**（Developer ID 直发 + 公证，不上 Mac App Store） | 清理工具需要遍历 `~/Library` 全域、访问 Trash、可选 root 任务，沙盒下不可行。CleanMyMac 等同类均为直发。 |
| 磁盘权限 | 首启引导用户授予**完全磁盘访问权限**（Full Disk Access），未授权时功能降级并明确提示 | TCC 保护目录（Mail、Safari、Containers 等）扫描需要 |
| root 权限 | 默认不需要。仅"深度优化"中少数任务（如系统级维护）通过 `SMAppService` 注册的 privileged helper 执行，helper 只接受**枚举白名单内的任务 ID**，不接受任意命令/路径 | 把 CLI 的"sudo 任务需 guard"原则平移到 XPC 边界 |
| 删除路径 | 一律走 `mole_delete` → Trash | 与 CLI 的可撤销原则一致 |
| CLI 内嵌方式 | `mole` + `lib/` + 两个 Go 二进制打进 `Contents/Resources/mole-core/`，App 每个版本锁定内嵌版本（不做运行时自更新 CLI） | 协议与实现同版本演进，避免 GUI/核心版本漂移 |
| 最低系统 | macOS 13 Ventura（SMAppService、SwiftUI 成熟度）；arm64 + x86_64 universal | 与 CLI 的用户面基本一致 |

---

## 4. 五大功能模块设计

统一交互骨架：每个模块 = **扫描（可中断，流式进度）→ 结果预览（分组、勾选、显示将发生什么）→ 执行（流式进度 + 逐项结果）→ 小结（释放空间/完成项/失败项 + 历史入口）**。

### 4.1 清理（Clean）

- **数据流**：`robot clean plan` → NDJSON 逐条输出候选项 `{id, section, label, path, size, kind, reversible, default_selected}` → GUI 分组展示（用户缓存 / 应用缓存 / 开发者缓存 / 日志 / 安装包 / 已卸载应用残留…，与 `lib/clean/*` 的 section 一一对应）。
- **执行**：GUI 把勾选的 `id` 列表传给 `robot clean apply --ids …`，核心侧对每个 id 重新校验（存在性、保护路径、白名单）后走 `mole_delete`，逐条回报 `{id, status, freed_bytes, error?}`。**GUI 传的是计划项 id，不是路径**——路径只在核心侧解析，杜绝 GUI 拼路径造成的注入面。
- **UI**：中央进度视觉（扫描动画 + 累计可清理量实时上翻）+ 底部滚动的逐项日志；完成页给"已释放 X GB，全部进入废纸篓，可在历史中查看/撤销"。
- **默认勾选策略**：沿用 CLI 的保守默认（AI 工具缓存、可能有会话状态的开发工具默认不勾选；微小 UI 状态缓存不出现在候选里）。
- purge（项目产物）与 installer（安装包）作为清理页内的两个独立入口/标签，同样 plan/apply 两段式。

### 4.2 软件（Apps）

- **清单**：直接复用 `mo uninstall --list` 的 JSON（name、bundle id、path、size），GUI 补充图标（`NSWorkspace.shared.icon(forFile:)`）、最近使用时间（`mdls kMDItemLastUsedDate`）、来源（App Store / brew cask / 手动，核心侧已有 brew 判定逻辑）。
- **卸载**：选中应用 → `robot uninstall plan --bundle-id …` 输出主体 + 残留文件清单（逐项含路径与大小，全部来自现有 `find_app_files` 精确匹配逻辑）→ 用户确认 → `apply`。残留匹配规则**完全不改**：bundle id / 应用名精确变体，禁止放宽（CLAUDE.md 红线）。
- **残留清理**：单独一个"残留"视图，列出已删除应用的孤儿文件（复用 clean 流程中的 leftovers section）。
- 批量卸载复用 `lib/uninstall/batch.sh` 的执行序（含 shared-bundle-id sibling guard、launch service/login item teardown），GUI 不重排执行顺序。

### 4.3 优化（Optimize）

- **任务清单**：`robot optimize list` 输出任务注册表（来自 `lib/optimize/tasks.sh`）：`{id, name, description, what_it_does, needs_admin, estimated_seconds, category}`。GUI 呈现为可勾选清单，每项**先解释再执行**（CLI 的"explainable before execution"原则）。
- **执行**：逐任务流式回报 `{task_id, status: running|done|skipped|failed, detail}`，UI 做成参考图那种任务打钩流。
- **权限分层**：无需授权的任务直接执行；`needs_admin` 任务批量收集后一次性触发 helper（一次授权，避免多次弹窗）；helper 未安装/被拒时这批任务标记"已跳过（需要管理员权限）"而不是失败。
- 白名单（`--whitelist`）在 App 设置页提供可视化管理，读写同一份 CLI 配置文件，保证两端一致。

### 4.4 分析（Analyze）

- **引擎**：复用 `cmd/analyze` 的扫描器。为 GUI 增加 `analyze --serve` 模式：常驻子进程，接受 `{op: scan|children|delete, path}` 请求，流式返回扫描进度与节点数据（现有 `json.go` 一次性输出改为可增量订阅）。扫描器的并发遍历、缓存（`cache.go`）、cleanable 识别（`cleanable.go`）全部沿用。
- **可视化**：SwiftUI 自绘 Treemap（squarified 算法）+ 左侧目录列表（大小排序、占比条），点击下钻、面包屑返回；顶部显示当前层级总量与磁盘用量。识别为 cleanable 的节点（缓存类）用颜色标出。
- **删除**：Treemap/列表中删除 = 调 `delete` op → 核心侧 `mole_delete` 进 Trash + oplog。保护路径的节点直接禁用删除按钮并说明原因，而不是执行时才报错。
- **性能**：首屏策略沿用 CLI（先出一级目录快照再细化）；Treemap 只渲染当前层级 + 一层预取，避免全树内存化。

### 4.5 状态（Status）

- **数据源**：`status-go` 增加 `--watch-json` 常驻模式（现有 watch + `-json` 的组合），按周期（默认 2s，GUI 可调 1–5s）输出全量指标 NDJSON。GUI 只做订阅与绘图，不自采指标。
- **卡片**：健康分（复用 `metrics_health.go` 的评分与诊断文案）、CPU（负载/温度/核数柱状历史）、GPU、内存（压力/交换）、磁盘（容量/剩余）、网络（上下行 sparkline）、电池（循环/健康/功率）、风扇转速。
- **进程表**：来自 `metrics_process.go`，支持按 CPU/内存/能耗排序；行内操作只提供"结束进程"（`NSRunningApplication.terminate` / SIGTERM，二次确认，不做 SIGKILL 默认）。
- **边界**：严格只读仪表盘。不做告警、阈值配置、常驻菜单栏（CLI 产品准则同款约束）；App 退到后台即暂停采样。

---

## 5. GUI ↔ 核心通信协议（robot 模式）

新增 `bin/robot.sh`（或 `mole robot <cmd>`），为 GUI 提供稳定契约。所有输出 NDJSON，一行一个事件：

```jsonc
{"v":1,"event":"progress","phase":"scan","current":"~/Library/Caches/…","done":36,"total":129,"bytes_found":331350016}
{"v":1,"event":"item","id":"clean.user_cache.a1b2","section":"user_cache","label":"Chrome GPU 缓存","path":"~/Library/Caches/Google/Chrome/GPUCache","bytes":58720256,"default_selected":true,"reversible":true}
{"v":1,"event":"result","id":"clean.user_cache.a1b2","status":"trashed","freed_bytes":58720256}
{"v":1,"event":"done","summary":{"items":129,"selected":86,"freed_bytes":9273483264,"failed":0}}
{"v":1,"event":"error","code":"path_protected","message":"…","fatal":false}
```

协议要点：

- **版本字段 `v`**：协议演进只加字段不改语义；GUI 与内嵌核心同包发布，跨版本兼容压力小，但字段仍保持向后兼容以便调试。
- **plan/apply 分离**：所有破坏性命令必须两段式；`apply` 只接受 plan 产出的 id。`plan` 内部即 `MOLE_DRY_RUN=1` 语义的结构化版本。
- **进度节流**：核心侧每 ≥100ms 或每 N 项合并一次 progress，避免 GUI 被事件洪泛。
- **取消**：GUI 关闭 stdin / 发 SIGTERM，核心侧沿用现有 trap 清理临时文件；apply 阶段收到取消则完成当前单项后停止（不留半删除状态）。
- **实现方式**：robot 模式内部直接调用现有 shell 函数（clean 各 section、optimize 任务注册表），把原本 `echo` 到终端的 section/item 信息改为经由一个 `emit_event()` 辅助函数输出 JSON（TUI 路径不受影响，双路输出由 `MOLE_ROBOT=1` 环境变量切换）。这是本项目 CLI 侧的主要改造点，需按 CLAUDE.md 的 hotspot 规则逐文件小步改、跑对应 bats。

Swift 侧（MoleKit）：

```swift
for try await event in MoleCore.run(.cleanPlan) {   // AsyncThrowingStream<RobotEvent>
    switch event { case .item(let i): model.append(i) … }
}
```

---

## 6. 权限、安全与审计

1. **首启引导**：三步 onboarding——说明工具做什么 → 引导授予完全磁盘访问（深链到系统设置对应页，检测授权状态轮询刷新）→ 可选安装 helper（可跳过，跳过只影响少数优化任务）。
2. **Helper 安全边界**：XPC 接口仅暴露 `runOptimizeTask(taskID: String)`，taskID 必须命中编译期内置的白名单；helper 校验调用方 code signature（同 Team ID + bundle id）；不暴露任何"执行命令/删除路径"通用接口。
3. **删除审计**：所有删除经 oplog；App 内提供"历史"页（读 `bin/history.sh` 同一份日志），展示每次操作删了什么、多大、何时，并提供"在废纸篓中显示"。
4. **保护规则单一来源**：`should_protect_path`、app protection 数据、whitelist 都只在 shell 库维护；GUI 只读展示，编辑白名单也是写同一配置文件。
5. **更新与完整性**：App 走 Sparkle（EdDSA 签名）或自建检查 + dmg 重装；内嵌核心随 App 更新，校验 SHA256 后才执行。
6. **测试红线平移**：robot 模式全部支持 `MOLE_TEST_NO_AUTH=1` / `MOLE_DRY_RUN=1`；CI 与本地验证永远不触真实授权弹窗。

---

## 7. UI / 视觉方向（原创）

- **布局**：无侧栏、顶部居中胶囊分段导航（清理 / 软件 / 优化 / 分析 / 状态），单窗口五页签；深色优先、同时适配浅色。
- **视觉语言**：每个模块一个主题色与一枚"主视觉焦点"（如清理页中央的动态进度球体/环），扫描与执行阶段用它承载状态，避免表格轰炸；执行细节收进底部半透明滚动日志区。
- **信息密度**：延续 CLI 的"一屏摘要 + 可下钻"哲学——首屏永远是结论（可清理 X GB / 健康分 N / 最大目录是谁），细节按需展开。
- **文案**：中英双语（跟随系统语言），语气与 CLI 一致：说清楚"将要发生什么、可否撤销"。
- 组件基于 SwiftUI + Swift Charts（状态页历史曲线）；Treemap、进度球体自绘（Canvas/Metal 视性能而定，先 Canvas）。

---

## 8. 工程结构与技术栈

```
mole-mac/                      # 建议独立仓库（CLI 仓库保持纯 CLI，互相 cross-link）
├── MoleApp/                   # SwiftUI App target
│   ├── Features/{Clean,Apps,Optimize,Analyze,Status,History,Settings}/
│   ├── DesignSystem/          # 色彩、字体、卡片、进度球体等组件
│   └── Onboarding/
├── MoleKit/                   # Swift Package：RobotEvent 模型、进程编排、NDJSON 解码
├── MoleHelper/                # privileged helper (SMAppService)
├── CoreBundle/                # 构建脚本从 mole 仓库指定 tag 拉取并打包 mole-core
└── scripts/                   # build / sign / notarize / release
```

- 语言：Swift 5.10+ / SwiftUI；核心：现有 bash + Go（不改语言）。
- CLI 仓库侧新增内容（在本仓库开发）：`bin/robot.sh`、`lib/core/robot.sh`（emit_event 等）、`cmd/analyze --serve`、`cmd/status --watch-json`、对应 bats/Go 测试。
- 构建：Xcode + XcodeGen（或纯 xcodeproj）；CI 用 GitHub Actions macOS runner，产物 dmg + 公证。

---

## 9. 里程碑

| 阶段 | 内容 | 产出 |
|------|------|------|
| M0（1–2 周） | CLI 侧协议层：robot plan/apply 骨架、status --watch-json、analyze --serve、bats 覆盖 | 可用 `echo`/`jq` 手工驱动的机器接口 |
| M1（2–3 周） | App 壳 + MoleKit + 状态页（只读、风险最低，最快见效） | 可运行的仪表盘 App |
| M2（2–3 周） | 软件页（--list 现成）+ 卸载 plan/apply | 应用管理闭环 |
| M3（3–4 周） | 清理页（plan/apply 全量接入 clean sections）+ 历史页 | 核心清理闭环 |
| M4（2–3 周） | 分析页（serve 模式 + Treemap） | 磁盘可视化 |
| M5（2 周） | 优化页 + helper + onboarding/FDA 引导 | 功能齐备 |
| M6（1–2 周） | 打磨：签名公证、Sparkle 更新、双语、性能与内存 profile、beta | 可发布 1.0 |

依赖关系：M0 是一切前提；M1/M2 可与 M3 的 CLI 改造并行。

## 10. 风险与对策

| 风险 | 对策 |
|------|------|
| clean/optimize 改造引入回归（hotspot 文件） | robot 输出走独立 `MOLE_ROBOT=1` 分支，TUI 路径零改动；每个 section 改造配 bats；destructive sink 改动按 CLAUDE.md 要求逐行 review |
| 无 FDA 授权时扫描结果偏小误导用户 | 检测 TCC 拒绝（扫描器统计 EPERM 目录数），结果页显式提示"N 个受保护目录未扫描" |
| helper 被滥用 | 任务 ID 白名单 + 签名校验 + 无通用命令接口；helper 代码量控制在最小 |
| 子进程僵尸/事件洪泛 | MoleKit 统一进程生命周期管理（超时、取消、backpressure）；协议层节流 |
| 双端行为漂移 | 清理规则单一来源；App 每版本锁定核心 tag；发布 checklist 加"GUI plan 结果 == CLI dry-run 结果"抽样比对 |

---

## 附：与参考图的功能对应（仅功能，不复制设计）

- 图 1/2（清理扫描与逐项结果流）→ §4.1 的扫描进度 + 底部日志流。
- 图 3（优化任务打钩流）→ §4.3 的任务清单执行。
- 图 4（磁盘 Treemap + 目录列表）→ §4.4。
- 图 5（健康分 + 指标卡片 + 进程表）→ §4.5。
