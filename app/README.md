# Mole for Mac (App)

原生 macOS GUI，基于 Mole CLI 核心构建。完整技术方案见 [`docs/MAC_APP_DESIGN.md`](../docs/MAC_APP_DESIGN.md)，UI 规格见 [`docs/UI_DESIGN_PROMPT.md`](../docs/UI_DESIGN_PROMPT.md)。

> 状态（2026-08-14）：**六大页面全部接通真实数据**——智能扫描/清理（robot
> clean plan+apply，进度来自预览 ledger 轮询）、软件三 tab（卸载 apps
> plan/apply + 更新 brew cask + 启动项 launchitems）、优化（catalog 注册表
> 21 任务）、分析（`analyze --serve` 流式 Treemap）、状态（`status --watch`
> NDJSON）。历史/设置 sheet、首启 Onboarding（FDA 轮询）、FDA 横幅、
> i18n（zh-Hans/en 运行时切换）均已落地。ROADMAP Phase 0–3 基本完成，
> Phase 4（1.0 发布：Sparkle/公证/诊断导出/可访问性）未开始。
> 上游 CLI main 已于 2026-08-14 合并同步（含 robot 层适配，见
> `docs/ROBOT_AUDIT_FOLLOWUP.md` 余留项）。
>
> 设计真源：`design/mole-dc/Mole.dc.html`（高保真交互原型，**拿不准的细节
> 以它的实际运行效果为准**，浏览器直接打开可交互）+ `HANDOFF.md`（实现前
> 必读，尤其 §3 信任承诺）。设计 token 在 `DesignSystem/Theme.swift`
> （Look×Accent 双轴），光谱环引擎在 `DesignSystem/SpectrumRingView.swift`。
> `support.js` 是原型运行时，仅供参考，**不移植**。

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
