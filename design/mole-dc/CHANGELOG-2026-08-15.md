# Mole for Mac 设计稿变更说明 · 2026-08-15

> 本文件对应 `ITERATION_BRIEF.md` 这一轮需求的全部落地内容,是 `HANDOFF.md` 的增量补充。
> 交接对象:Claude Code。请与 `HANDOFF.md`(架构 / 假数据对照 / Token 速查)、`PROJECT_CONTEXT.md`(设计来龙去脉)一起阅读。
> 变更文件只有一个:`Mole.dc.html`(设计稿主文件)。`support.js` 未动。

---

## 一、P1 对齐现实(三项)

### 1.1 优化页任务清单 → CLI catalog 真实 21 项

**改动位置**:逻辑类 `OPT_TASKS`(三个分组)+ 模板任务卡片。

- 任务从原来编造的 12 项换成 CLI catalog 的真实 21 项,`id` 与 catalog 注册表一一对应,便于直接接线:
  - **日常维护(5)**:`cache_refresh`、`saved_state_cleanup`、`sqlite_vacuum`、`notification_cleanup`、`coreduet_cleanup`
  - **修复小毛病(8)**:`fix_broken_configs`、`launch_services_rebuild`、`shared_file_list_repair`、`quarantine_cleanup`、`prevent_network_dsstore`、`spotlight_orphan_rules_cleanup`、`launch_agents_cleanup`、`login_items_audit`
  - **深度维护(8)**:`system_maintenance`、`network_optimization`、`network_stack_optimize`、`disk_permissions_repair`、`spotlight_index_optimize`、`periodic_maintenance`、`disk_verify`、`legacy_overrides_audit`
- **移除「约 N 秒」时长估计**:协议不提供时长,设计里不得再出现。任务卡的第三行(原 `t.dur`)已整行删除。
- **移除「管理员」徽标**:21 项全部无需 sudo(robot 模式内部自动降级)。
- **新增「只读」徽标**:仅 `login_items_audit`、`disk_verify` 两项。样式为冷灰胶囊(`rgba(124,144,168,.14)` / `#9DB0C6`)+ 眼睛图标,`title` = 「只读检查,不会做任何修改」。
- 每项保留 `result` 字段(执行完成后写进滚动日志的真实措辞),已按新任务重写。
- 默认全选成立,底部计数显示「已选 21 项」。

> **保留待用**:管理员授权弹层 `optAuth` 的代码与视觉**没有删**,只是现阶段不会被任何任务触发。等 Phase 3 后台助手落地、出现真正需要授权的任务时再挂回去。

### 1.2 「大小未知」边界态(协议 `bytes: null`)

**设计红线:任何「大小未知」项都不得显示为 `0 B` / `0.00 GB`。**

数据侧:`CLEAN_GROUPS` 里用 `{size:0, unknown:true}` 标记(当前两项:CocoaPods 缓存、安装器日志)。对应真实协议的 `bytes: null`(尺寸测量有时间预算,超时项返回 null)。

三处呈现:

1. **清理确认页明细行**:尺寸列显示「大小未知」(mono / 10.5px / `--text-mute`),`title` = 「测量超时,删除后按实际释放量记录」。**该项仍可勾选、仍可删除**。
2. **总计行**:总计只累加已知项;旁边出现微文案「另有 N 项大小未知」(10.5px 大写微标签风格,仅 N>0 时渲染)。
3. **智能扫描洞察卡**:大数字位显示 `—`、单位隐藏,body 文案照常。此态由 DC prop `insightUnknown` 驱动(默认 false),方便走查两种状态。

### 1.3 软件·更新 tab 按来源分流

**改动位置**:`UPDATES` 数据、新增运行态 `_upds` 与 `brewUpd/retryUpd/ignoreUpd/updAll` 方法、更新 tab 整块模板。

- **只有 Homebrew cask 能在 Mole 内更新**(`brew upgrade --cask <token>`)。App Store / Sparkle / Electron 只做**检测 + 引导跳转**,Mole 不代为执行。
- 来源徽标各自配色 + hover 说明:
  | 来源 | 色值 | 徽标含义 |
  |---|---|---|
  | Homebrew | `#C9862F` | Mole 可代为执行 brew upgrade |
  | App Store | `#4C8FD8` | 需在 App Store 中更新 |
  | Sparkle | `#8E72CE` | 需在应用内检查更新 |
  | Electron | `#7C90A8` | 需在应用内检查更新 |
- **行动作按来源分级**:Homebrew = 渐变主按钮「更新」;App Store = 描边次级按钮「前往 App Store」+ 外链箭头;Sparkle / Electron = 同款次级按钮「打开应用检查更新」。可执行动作与跳转动作在视觉上必须分级。
- **顶部**:「可在 Mole 内更新 N 个 · 另有 M 项需前往来源更新」,右侧「全部更新(N 项)」**只作用于 Homebrew 项**。该行已加 `nowrap` + 省略,窄视口不折行。
- **行内状态机**:`idle → running`(spinner「更新中…」)`→ done`(绿色「已更新」,1s 后该行淡出)或 `failed`。
- **失败行**:边框转红 + 行内错误卡(brew stderr 摘要,例:`brew upgrade --cask iina: SHA-256 不匹配 · 更新已中止,应用未被修改`)+ 「重试」按钮;重试成功即走 done。示例数据里 IINA 首次必定失败,便于走查。
- 筛选器循环加入了 Homebrew。
- **待实现的边界态**:无 brew 环境时 Homebrew 来源整体缺席,空态文案不提 brew。

---

## 二、P2 持续高 CPU 告警(`process_alerts`)

- 数据侧:`_proc[].alert` = 持续分钟数(当前 Final Cut Pro 12 分钟、photoanalysisd 7 分钟)。对应 `status --watch` 推送的 `process_alerts`(默认阈值 100%、持续窗口 5 分钟,均可配)。
- **火焰图标只绑定持续告警**,不再由瞬时 CPU 触发(原来 `cpu>=45` 就亮,会闪烁)。`title` = 「持续高 CPU · 已持续 N 分钟 > 100%」。
- **进程详情弹窗**(用户 App / 系统进程两个变体)在进程树下方插入琥珀告警条:图标 + 文案 + `ALERT` 微标签,颜色 + 图标 + 文字三通道,不靠单一颜色传达。
- 告警进程在查看时已退出 → 沿用既有「已退出」极简卡。
- **明确不做**:进程表按告警自动重排序(保留用户排序权),仅图标标记。

---

## 三、P3 三个发布必备件

### 3.1 全局快捷键(设置·通用)

- 交互:「未设置」→ 点击进入录制态(输入框文案「按下组合键…」+ 脉冲点提示行「正在录制 · 请按下包含修饰键的组合,esc 取消」)→ 捕获后显示 `⇧⌘M` 样式(mono)+ 右侧清除按钮。
- 必须包含修饰键才被接受;esc 取消。
- **冲突检测**:与系统快捷键冲突时行下方出现琥珀提示「与系统快捷键「聚焦搜索」冲突,建议换一组」。冲突表在逻辑类 `CONFLICT` 常量里(`⌘Space` / `⌃Space` / `⌘Tab` / `⌘⇧3`),实现时换成真实的系统快捷键查询。
- 默认为空;作用 = 唤起 / 隐藏 Mole 主窗口。

### 3.2 诊断报告导出(设置·高级 + 菜单栏「运行诊断」)

- 三态:**进行中**(按钮内 spinner +「导出中…」,文字转主题色)→ **成功**(底部居中 toast「已导出到 ~/Desktop/Mole-诊断-YYYY-MM-DD.zip」+「在 Finder 中显示」+ 关闭 ×,6 秒自动消失)/ **失败**(红色 toast「导出失败:桌面目录不可写入(权限不足)」+「重试」)。
- 原型里每第 3 次导出走失败态,方便走查。
- 说明文案固定为:「导出运行日志与系统摘要,不含文件内容。」
- 菜单栏「运行诊断」现在会跳到设置·高级并直接触发导出。

### 3.3 应用自更新 sheet(Sparkle)

- 两个入口共用同一个 sheet:设置·关于「检查更新 → 有新版本 1.3.0 ›」、菜单栏「检查更新」。
- 内容:版本对比 `1.2.0 (412) → 1.3.0 (437) · 18.4 MB`、更新说明列表(要点加粗、修复项用灰点)、下载进度条(百分比 mono)。
- 按钮层级:主「下载更新」→ 下载中(禁用态 + spinner)→「重启并安装」;次「稍后」;弱「跳过此版本」(左下,不与主动作争夺注意力)。
- 跳过 / 安装均落一条 toast 回执。

---

## 四、字体一致性修复(用户走查后追加)

**问题**:扫描进行中的环心数字用 JetBrains Mono,而扫描结果数字用 Instrument Serif,同一个位置字体不一致。

**改动**:三处扫描态计数器统一改为 Instrument Serif(智能扫描 56px、清理扫描 48px、分析扫描 48px),与结果态、执行态(原本就是衬线)拉齐。单位 `GB` 保持 mono 不变。

**随之而来的技术约束(实现时务必保留)**:Instrument Serif **不含 `tnum` OpenType 特性**,`font-variant-numeric: tabular-nums` 在它上面静默失效,数字回落成比例宽度(`1` = .249em,`0` = .46em),按 60fps 刷新的计数器会横向抖动。

解决方案 = 逻辑类新增 `setNum(el, str)`:**逐字符渲染为定宽 cell**(数字 `width:.46em`,小数点 `width:.213em`,`display:inline-block; text-align:center`),并在每次调用时清掉宿主 span 里残留的文本节点。三处扫描 tick 都改为调用它。

实测结果:数字与「GB」间距恒为 6px、组中心 drift = 0.0px、四位↔五位切换无位移。

> **给实现的提醒**:如果换字体或换成原生 AppKit 文本,这个定宽处理仍然必要 —— 除非新字体自带等宽数字。用 Instrument Serif 显示任何**高频跳动的数字**都要走 tabular 处理。

**其余数字未动**:状态页 CPU / GPU / 内存 / 磁盘 / 电池 / 风扇读数、智能扫描待扫描态底部的三列状态卡(LAST SCAN / LAST FREED / DISK FREE)、许可价格,仍用 JetBrains Mono。

这是设计语言的**有意分层**,实现时不要统一:

| 类别 | 字体 | 判断依据 | 例 |
|---|---|---|---|
| **英雄数字**(结论) | Instrument Serif | 是这一屏要传达的核心结果,需要分量 | 环心扫描/结果数字、洞察卡 8.92 / 23 / 68 |
| **遥测读数**(记录) | JetBrains Mono | 并排的小型状态/历史读数、时间戳、复合数值 | 状态页各指标卡、`今天 09:14`、`214 / 512 GB`、¥298 |

三列状态卡尤其要保持 mono 的三个具体原因:时间戳(`09:14`)在衬线里冒号与数字排布松散;复合读数(`214 / 512 GB`)需要等宽才对齐;三列被竖线分隔且宽度不等,等宽字宽让三列视觉重量一致。另外它紧邻主按钮,用衬线会与下一步的环心大数字抢层级。

---

## 五、二级分类 Tab 统一左对齐

清理页的胶囊式二级 Tab(快速清理 / 项目产物 / 安装包)原为居中,现改为**左对齐**,与软件页(卸载 / 更新 / 启动项)一致。

**规则**:全应用的二级分类 Tab 一律左对齐,与其下方内容区的左边界对齐。

已核对全稿,胶囊式二级 Tab 只有这两处;分析页面包屑、设置侧栏、状态页刷新率切换本就是左对齐,未改动。

---

## 六、其他

- **DC props(Tweaks)**:新增 `insightUnknown`(布尔,走查「大小未知」洞察卡态);既有 `look` / `reduceMotion` / `tickCount` 保留。
- **i18n**:`TR` 词表补齐本轮全部新增中英对照(21 项任务名 + 描述 + result、来源提示、快捷键 / 诊断 / 自更新全部文案)。机制仍是渲染后 DOM 遍历替换 —— **原型 hack,生产别照抄**,但词表可直接当术语表用。

  **两条 i18n 规则(实现时遵守)**:

  1. **英文以 CLI catalog 原文为准**。设计稿里的任务英文与 catalog 一致,不要另起译法,避免同一句话出现两套英文。已核对的两条:
     - `coreduet_cleanup` 描述 → `Clean old usage tracking data`
     - `quarantine_cleanup` 描述 → `Clear Gatekeeper download tracking history`
  2. **中文统一用「跟踪」,不用「追踪」**(与 macOS 简中系统用语一致)。

  > 修正记录:上一版 `OPT_TASKS` 写「跟踪」而 `TR` 键写「追踪」,键匹配不上,导致这两条描述在英文态不生效(看起来像词表漏条)。现已统一为「跟踪」。
  >
  > **这是 DOM 遍历替换机制的固有脆弱点**:词表键是中文原文的字面量,源文案与键差一个字就静默失效。生产改用正式 i18n(键名 + 资源文件)后此类问题自然消失 —— 这也是别照抄这套机制的原因之一。
- **走查环境说明**:自动化预览里浏览器会冻结后台标签的 rAF(实测 0 帧),扫描动画与下载进度条不会自行推进。这不是稿子的问题,前台正常。

---

## 七、本轮有意未做(Phase 5)

需求文档 P4 的四项按约定后置,设计约束已写进 `HANDOFF.md` §10,实现时请照那份约束做,不要自行发挥:

1. 大文件「新鲜度日期」—— **只对不可重建数据显示**,缓存类永不显示日期。
2. 历史页结构化撤销 —— 用中性色不用危险色(它是危险操作的逆操作)。
3. 空间趋势 Timeline —— 固定 30 天,不做时间范围配置。
4. 外置卷清理入口。

**明确不做**(防走样):菜单栏模式、清理计划提醒、卸载监听、优化任务时长估计、进程表按告警自动重排序、空间趋势时间范围配置。
