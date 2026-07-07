# Robot 层安全审计跟进清单（PR #1 合并后）

> 来源：2026-07-07 对 robot 机器模式层的双代理审计（安全契约 + bash 3.2 可移植性）。
> bash 3.2 审计：**零地雷**（全部已知类别显式排除）。以下为安全契约审计发现。
> 状态标记会随修复更新；全部清零后本文件可归档删除。

## 🔴 Blocker

- [x] **apply 声称 trashed 实为永久删除** — `run_clean_apply` 未设 `MOLE_DELETE_MODE`，
  `mole_delete` 默认 `permanent`（`lib/core/file_ops.sh:538`），而协议 emit
  `reversible:true` + `status:"trashed"`。修复：router 默认 `trash` 模式（对齐
  `bin/uninstall.sh:1369`）+ `MOLE_CURRENT_COMMAND=clean`；lib 层按实际 mode
  如实 emit `trashed`/`deleted`。**已修（本分支）**，配 bats 回归。

## 🟠 Should-fix（后续修）

- [ ] **plan_id 路径穿越** — `robot_plan_file` 未校验 `--plan` argv，`../../tmp/evil`
  可指向 plan 目录外的伪造 TSV（下游 protect/whitelist 链仍生效，风险有界，
  但破坏 ids-not-paths 不变量）。修法：所有 plan 文件访问前校验
  `^pl_[0-9]+_[0-9]+_[0-9]+$`。
- [ ] **item id CRC 碰撞** — `robot_item_id` 用 32 位 `cksum`，同 section 两路径
  碰撞时 `robot_plan_lookup` 返回先写入的路径（可能删到用户没勾的项）。
  修法：id 追加 plan 内序号（id 本就 plan 域内有效，构造即唯一）。
  注意：会改变 `contracts/robot_v1/clean_plan.ndjson` 的 id 形状。
- [ ] **apply 缺 operations.log 会话标记** — 未调
  `log_operation_session_start/_end`，GUI 驱动的清理不出现在
  `robot history list` 自己解析的会话视图里。修法：apply 外围包会话标记
  （条数 + 释放 KB）。

## 🟡 Nit（后续修）

- [ ] **控制字符转义不全** — `robot_json_escape` 只处理 `\ " \n \t \r`，
  0x00–0x1F 其余字节会产出严格解码器拒收的 JSON（流损坏，非删除风险）。
- [ ] **进度轮询边界** — watch 首个 tick 可能读到上一次运行的陈旧导出
  （轮询先于 clean 截断文件）；`cut` 空字段在 `set -e` 下中断路由。
  修法：启动 clean 前 `rm -f` 导出文件；数值字段空缺默认 0。
  另：并发 `robot clean plan` 共享同一导出文件（安全无虞——apply 重验，
  但 plan 可能交错），记录在案。

## 已验证干净（免重复审计）

apply 安全链（mole_delete 单一出口、逐项 protect/whitelist/exists、fail-closed、
dry-run 短路）、plan 文件卫生（0700、tab/换行拒绝、TTL）、plan 只读包装、
`mole` 早期分发与 history 分发同构、whitelist 清空边界。

## 2026-07-07 apps plan/apply 落地审查（GUI 卸载链）

safety-reviewer 全量审查后整改完毕，全部结论已代码化：

- **P0 已修**：robot 模式下 batch.sh 兄弟守卫因 `apps_data` 为空而失效（fail-open）
  → `uninstall_robot_sibling_names` 直接探测文件系统（/Applications、~/Applications、
  Setapp、/Volumes 副本），XML plist 兜底供 CI。守卫语义与 batch.sh 逐条对齐：
  bundle id 降级 unknown、名称撞车整体放弃发现（bats：`robot_apps_plan.bats` 7/8）。
- **P0 已修**：plan 前置保护门——`should_protect_from_uninstall` 拒绝系统关键
  bundle（E_PATH_PROTECTED），`official_uninstaller_vendor` 拒绝需官方卸载器的应用。
- **P1 已修**：系统级残留（LaunchDaemons、/Library 诊断报告）与 CLI 姿态一致改为
  纯展示（id 前缀 `info.`，不入计划、GUI 无复选框）；`run_apps_apply` 补
  `MOLE_UNINSTALL_MODE=1` 使 plan/apply 保护策略一致。
- **P2 遗留**：运行中应用检查由 GUI 承担（AppsStore.requestRemoval 用
  NSWorkspace 拦截 + 退出并继续）；核心侧 `running:true` 标记待 `--proc` 一并考虑。
