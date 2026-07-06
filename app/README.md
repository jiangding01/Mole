# Mole for Mac (App)

原生 macOS GUI，基于 Mole CLI 核心构建。完整技术方案见 [`docs/MAC_APP_DESIGN.md`](../docs/MAC_APP_DESIGN.md)，UI 规格见 [`docs/UI_DESIGN_PROMPT.md`](../docs/UI_DESIGN_PROMPT.md)。

> 状态：工程骨架（Phase 1 起点），已在 macOS 上编译验证（MoleKit 8 测试全绿 + App target 构建通过）。
> robot 协议层（CLI 侧，M0）的 `clean plan/apply` 已落地并经真机端到端验证
> （`bin/robot.sh` + `lib/core/robot.sh`，`tests/robot_core.bats` 15 用例）；
> 剩余 domain（apps/history/whitelist）按 ROADMAP 推进，契约 golden 文件随之接入。
>
> **⚠️ UI 开发冻结（2026-07-06 起）**：Claude Design 的设计稿进行中，定稿前
> **不要动** `MoleApp/Features/*`（占位状态）、`DesignSystem/`（视觉 token/组件）、
> 任何动效实现。可以继续的工作：CLI robot 层、MoleKit 非视觉逻辑
> （协议模型/进程编排/ScanSession/权限探测）、契约 golden、`status-go --proc` 等
> Go 侧只读增量。设计稿到位后解除本条。

## 技术栈

| 层 | 选型 | 版本约束 |
|---|---|---|
| UI | SwiftUI（`@Observable` Store，无第三方状态框架） | macOS 14.0+（Observation 框架要求）  |
| 语言 | Swift | 5.10+（Xcode 16+） |
| 工程生成 | XcodeGen（`Project.yml` 声明式，`.xcodeproj` 不入库） | 2.41+ |
| 核心逻辑包 | MoleKit（本地 SwiftPM 包，不 import SwiftUI） | — |
| 内嵌核心 | Mole CLI（shell 库 + analyze/status Go 二进制），由 `CoreBundle/fetch_core.sh` 按 `core.lock` 拉取构建 | 见 core.lock |
| Lint/格式 | SwiftLint + SwiftFormat（CI 强制） | — |
| 测试 | XCTest（MoleKit 单测 + 协议契约测试）；快照/UI 测试按 ROADMAP 接入 | — |
| 更新 | Sparkle（Phase 4 接入，暂未添加依赖） | — |

依赖白名单见设计文档 §9.2：新增第三方依赖必须在 PR 说明理由。

## 快速开始（需 macOS + Xcode 16）

```bash
brew install xcodegen swiftlint swiftformat
cd app
./CoreBundle/fetch_core.sh          # 拉取并构建内嵌 CLI 核心（首次可跳过，App 可空核心启动）
xcodegen generate                   # 生成 Mole.xcodeproj
open Mole.xcodeproj
```

MoleKit 可独立测试（不需要 Xcode 工程）：

```bash
cd app/MoleKit && swift test
```

## 目录结构

```
app/
├── Project.yml            # XcodeGen 工程声明（唯一工程真源）
├── MoleApp/               # App target
│   ├── App/               # 入口、根导航
│   ├── Features/          # 每页一个 Feature（View + Store）
│   ├── DesignSystem/      # 主题 token 与通用组件
│   └── Resources/         # 资产、本地化（String Catalog）
├── MoleKit/               # SwiftPM 包：协议模型、进程编排、会话（可独立 swift test）
├── CoreBundle/            # 内嵌 CLI 核心的锁定与构建脚本
├── .swiftlint.yml         # 含安全 lint：Features 层禁止直接删文件/起进程
└── .swiftformat
```

## 安全边界（对贡献者）

- Features/ 内**禁止**出现 `Process(`、`FileManager…removeItem`、`NSWorkspace…recycle`——一切删除必须经 MoleKit → robot → CLI 安全层（SwiftLint custom rules 强制，设计文档 §7.4）。
- 破坏性 robot 命令只传 plan 产出的 id，不传路径。
- 测试与本地验证遵守 CLI 仓库约定：`MOLE_DRY_RUN=1` / `MOLE_TEST_NO_AUTH=1`，不触真实授权弹窗。
