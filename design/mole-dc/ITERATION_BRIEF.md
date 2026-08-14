# Mole for Mac 设计稿迭代需求（致 Claude Design）

> 2026-08-15 · 基于 `Mole.dc.html` 当前版本的走查 + CLI 上游 main 合并（2026-08-14，372 提交）带来的能力变化 + ROADMAP Phase 4/5 规划。
> 阅读方式：每项含【现状 → 需求 → 交互细节 → 边界态】。P1 是设计稿与已交付实现的偏差（对齐现实），P2 是数据已就绪待设计的新能力，P3 是 Phase 4 发布件，P4 是 Phase 5 预设计（可后置）。
> **不变的部分**：视觉语言、三个信任承诺、Look×Accent 主题系统、焦点环引擎、九页信息架构——全部保持，本文件只做增量。

---

## P1 · 对齐现实（设计稿 ↔ 已实现代码的偏差）

### 1. 优化页任务清单真实化（12 → 21 项，名称全换）

**现状**：mock `OPT_TASKS` 是 12 个虚构任务（刷新 DNS 缓存/重建字体缓存/重启 Finder 与 Dock…），带"约 N 秒"时长估计和"管理员"徽标。
**现实**：CLI 已收敛为 catalog 注册表 21 个任务，全部免管理员即可安全执行（robot 模式无 sudo，任务内部自动降级）；协议不提供时长估计。

**需求**：mock 数据换成真实清单（下表），布局（双列卡片 × 三分类）保留。分类建议沿用实现侧映射：

| 分类 | action id | 英文名 | 描述（英文原文，中文文案请设计侧润写） |
|---|---|---|---|
| 日常维护 | cache_refresh | Finder Cache Refresh | Refresh QuickLook thumbnails & icon services cache |
| 日常维护 | saved_state_cleanup | App State Cleanup | Remove old saved application states (30+ days) |
| 日常维护 | sqlite_vacuum | Database Optimization | Compress SQLite databases for Mail, Safari & Messages (skips if apps are running) |
| 日常维护 | notification_cleanup | Notifications | Clean old delivered notifications to reduce database bloat |
| 日常维护 | coreduet_cleanup | Usage Data | Clean old usage tracking data |
| 修复小毛病 | fix_broken_configs | Broken Config Repair | Fix corrupted preferences files |
| 修复小毛病 | launch_services_rebuild | Launch Services Rebuild | Rebuild the "Open With" database |
| 修复小毛病 | shared_file_list_repair | Shared File Lists | Repair corrupted Finder favorites and recent documents |
| 修复小毛病 | quarantine_cleanup | Quarantine Database Cleanup | Clear Gatekeeper download tracking history |
| 修复小毛病 | prevent_network_dsstore | Prevent Finder .DS_Store | Stop writing .DS_Store on network/USB volumes |
| 修复小毛病 | spotlight_orphan_rules_cleanup | Spotlight Orphan Rules | Remove search-rule entries for uninstalled apps |
| 修复小毛病 | launch_agents_cleanup | Launch Agents Cleanup | Remove broken LaunchAgents whose binaries no longer exist |
| 修复小毛病 | login_items_audit | Login Items | Audit login items for broken entries |
| 深度维护 | system_maintenance | DNS & Spotlight Check | Refresh DNS cache & verify Spotlight status |
| 深度维护 | network_optimization | Network Cache Refresh | Optimize DNS cache & restart mDNSResponder |
| 深度维护 | network_stack_optimize | Network Stack Refresh | Flush routing table and ARP cache |
| 深度维护 | disk_permissions_repair | Permission Repair | Fix user directory permission issues |
| 深度维护 | spotlight_index_optimize | Spotlight Optimization | Rebuild index if search is slow (smart detection) |
| 深度维护 | periodic_maintenance | Periodic Maintenance | Run macOS daily/weekly/monthly scripts if stale |
| 深度维护 | disk_verify | Disk Health | Verify filesystem integrity |
| 深度维护 | legacy_overrides_audit | Legacy Overrides | Remove hidden App Nap / disk-image verification overrides left by old tweak tools |

**交互细节**：
- **移除"约 N 秒"时长估计**（协议无此数据，不编造）。可保留"只读"徽标给纯审计类任务（login_items_audit、disk_verify 若适用）。
- **"管理员"徽标降级为"后台助手"概念**：当前版本全部任务无需授权即可执行；管理员徽标仅在 Phase 3 后台助手落地后用于需要它的新任务。现阶段设计里不出现管理员徽标（或做成 hidden 变体备用）。
- 21 项默认全选仍成立（全部 safe）。

**边界态**：某任务执行失败 → 卡片级失败标记与已有"1 项无法移除"同语言；执行中列表锁定不可改选（已有）。

---

### 2. "大小未知"状态（新增边界态，协议已上线）

**现状**：设计稿所有条目都有确定大小；"大小未知"字样在原型中出现 0 次。
**现实**：上游给尺寸测量加了时间预算，超时项在协议中 `bytes: null`。实现侧已按"诚实显示"处理，需要设计定稿视觉。

**需求**：为以下三处定义"大小未知"的呈现：
1. **清理页确认列表行**：尺寸列显示"大小未知"（mono、`--text-mute`），项仍可勾选删除；
2. **智能扫描洞察卡**：大数字位置显示"—"，单位隐藏（body 文案照常）；
3. **分组/总计**：总计只含已知项。建议在总计旁加微文案"另有 N 项大小未知"（仅 N>0 时出现，10.5px 大写微标签风格）。

**交互细节**：hover 未知项时 tooltip 说明"测量超时，删除后按实际释放量记录"。

---

### 3. 软件·更新 tab 的来源体系对齐

**现状**：mock `UPDATES` 的来源是 App Store / Sparkle / Electron，每行都有"更新"按钮。
**现实**：v1.1 仅 **Homebrew cask** 支持一键更新（委派 brew，已实现）；App Store/Sparkle/Electron 是后续版本的**检测 + 引导跳转**，Mole 不代为执行。

**需求**：
- 来源徽标体系加入 **Homebrew**（当前唯一可一键更新的来源）；
- 按来源区分行动作：Homebrew 行 = "更新"主按钮；App Store 行 = "前往 App Store"（跳转）；Sparkle/Electron 行 = "打开应用检查更新"（跳转）；
- "全部更新"批量按钮语义 = 仅执行 Homebrew 项，按钮旁注明（如"3 项可在 Mole 内更新"——TR 词表已有'可在 Mole 内更新'词条，沿用）。

**边界态**：brew 更新失败行内错误 + 重试；无 brew 环境时 Homebrew 来源整体缺席（空态文案不提 brew）。

---

## P2 · 新能力设计（CLI 数据已就绪，待呈现）

### 4. 状态页"持续高 CPU"告警细化

**现状**：进程行已有火焰图标（`p.hot`，title=持续高 CPU）——概念存在但只有一个 13px 图标承载。
**现实**：CLI `status --watch` 已输出 `process_alerts`（阈值默认 100%、持续窗口默认 5 分钟，均可配），含触发进程与持续时长——数据比图标丰富得多。

**需求**：
1. **进程详情弹窗**（§9.6 用户 App 变体）加一行：告警态进程显示"持续高 CPU · 已持续 12 分钟 > 100%"（琥珀语义色 + 图标 + 文字三通道）；
2. **进程表**：火焰图标保留，但仅绑定"持续告警"（非瞬时高 CPU），hover tooltip 显示持续时长；
3. **可选增强**：健康分卡的问题行（现有"CPU 负载偏高 → 去处理"模式）增加持续告警来源，点击滚动到进程表并高亮该行。

**边界态**：告警进程在查看时已退出 → 沿用§9.6"已退出"极简卡；多个告警并存 → 进程表按告警优先置顶排序不做（保持用户排序权），仅图标标记。

---

### 5. 大文件"新鲜度日期"（协议字段随 Phase 5 上线）

**现状**：设计稿大文件/洞察行无时间维度。
**现实**：CLI TUI 已为"不可重建数据"（备份、归档、影音）标注最新子项日期——设计哲学是"上月的手机备份是唯一副本，两年前卖掉的设备备份是死重"。GUI 侧待协议加字段后跟进（已列入 Phase 5）。

**需求**（预设计，实施时间不定）：
- 分析页大文件列表 + 清理页大文件洞察行，在尺寸旁加 mono 日期（如 `2024-06`）；
- 超过阈值（如 1 年）的项加微标签"两年未变动"类措辞（具体文案设计侧定，保持"说清后果"原则）；
- **只对不可重建数据显示**——缓存类永不显示日期（它们的年龄不改变结论）。此取舍要在 HANDOFF 增补里写明，防止后续实现者扩大化。

---

## P3 · Phase 4 发布件补全（1.0 前必须）

### 6. 全局快捷键（设置·通用，目前完全缺失）

原型中"快捷键"出现 0 次。需求：设置·通用加"全局快捷键"行——录制交互（点击进入录制态/按键组合显示/清除按钮）、与系统冲突时的琥珀提示、默认为空。作用建议：唤起/隐藏 Mole 主窗口。

### 7. 诊断报告导出流（§6.9，半成品）

现状：设置里已有"运行诊断/诊断日志/导出…"入口，但无过程与结果设计。需求：导出进行中态（按钮内 spinner）→ 完成 toast（"已导出到 ~/Desktop/… · 在 Finder 中显示"）→ 失败态。报告内容说明一句话："运行日志与系统摘要，不含文件内容"（TR 已有相近词条）。

### 8. Sparkle 应用自更新流（设置·关于 + 系统菜单）

现状："检查更新/当前已是最新 ›"文案存在，但"发现新版本"之后的流程未设计。需求：发现新版 sheet——版本号对比、更新说明（Markdown 摘要区）、下载进度条、"重启并安装"主按钮、"跳过此版本/稍后"次按钮。菜单栏"检查更新…"同入口复用。

---

## P4 · Phase 5 预设计（可后置，有闲再做）

### 9. 历史页结构化撤销（§6.4）

现状：历史卡纯展示，无恢复动作（现有"恢复"字样全部是废纸篓说明文案）。需求：
- 会话卡展开后，每个文件行尾加"恢复"文字按钮（危险操作的逆操作，用中性色不用危险色）；
- 会话级"全部恢复"次按钮；
- 恢复结果反馈：行内变为"已恢复 ✓"或失败原因（"废纸篓中已不存在"/"原位置已有同名文件"两个核心边界态）；
- 依赖 CLI `robot history restore`（未实现），设计可先行。

### 10. 空间趋势 Timeline（§6.3）

无任何现状。建议位置：智能扫描页结论区下方或历史页顶部，一张"磁盘可用空间随时间"面积图卡（复用状态页网络图的视觉语言），数据点 = 每次扫描/清理的记录。空态（<2 个数据点）显示"再完成一次扫描即可看到趋势"。**克制要求**：不做可配置时间范围，固定近 30 天。

### 11. 外置卷清理入口（§5.1，CLI 能力现成）

原型中"外置"出现 0 次，但 `robot clean plan --external <path>` 已可用。需求：清理页 idle 态加目标切换（默认"启动磁盘"，检测到外置卷时出现 segmented/下拉），选外置卷后扫描按钮文案与结果页标注卷名。边界态：扫描中卷被拔出 → 错误卡"外置卷已断开连接"。

---

## 交付物要求

1. 更新 `Mole.dc.html`（P1 三项为主，P2-P4 按余力）；
2. `HANDOFF.md` 增补对应小节（尤其 §5 mock 与真实 API 对照表要加 process_alerts、bytes:null、Homebrew 来源三行）；
3. `TR` 词表同步新增文案（大小未知/持续时长/来源动作等），保持中英对照完整；
4. 沿用既有验收自检（HANDOFF §8），新增两条：任一"大小未知"项不得显示为 0 B；更新 tab 每行动作与其来源能力一致。

## 明确不做（防走样）

- 菜单栏模式、清理计划提醒、卸载监听（v1.3 试验项，勿顺手设计）；
- 优化任务的时长估计（协议无数据）；
- 进程表按告警自动重排序；
- 空间趋势的时间范围配置。
