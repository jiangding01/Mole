#!/usr/bin/env bats
# robot optimize list/run —— GUI 优化页数据源与执行流。
# run 全程 MOLE_TEST_NO_AUTH=1：sudo 分支硬拒绝（tasks.sh 测试守卫），零弹窗。

setup() {
    export MOLE_TEST_NO_AUTH=1
    export MO_NO_OPLOG=1
    export MOLE_DRY_RUN=1
    REPO_DIR="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    export HOME="$BATS_TEST_TMPDIR/home"
    mkdir -p "$HOME"
}

require_jq() {
    command -v jq > /dev/null 2>&1 || skip "jq not installed"
}

@test "optimize list emits the closed task enum as items with details" {
    require_jq
    run "$REPO_DIR/bin/optimize.sh" --robot-list
    [ "$status" -eq 0 ] || return 1
    echo "$output" | jq -se '[.[] | select(.event == "item")] | length >= 10' > /dev/null || return 1
    echo "$output" | jq -se '[.[] | select(.event == "item") | select(.id == "cache_refresh")][0].detail | length > 0' > /dev/null || return 1
    echo "$output" | jq -se '[.[] | select(.event == "done")][0].ok == true' > /dev/null || return 1
}

@test "optimize run streams task_status and rejects unknown actions" {
    require_jq
    output=$(printf 'cache_refresh\nnot_a_real_task\n' | "$REPO_DIR/bin/optimize.sh" --robot-run)
    [ $? -eq 0 ] || return 1
    # 合法任务：running → done
    echo "$output" | jq -se '[.[] | select(.event == "task_status") | select(.task_id == "cache_refresh")] | map(.status) == ["running","done"]' > /dev/null || return 1
    # 未知任务：failed（闭合枚举校验）
    echo "$output" | jq -se '[.[] | select(.event == "task_status") | select(.task_id == "not_a_real_task")][0].status == "failed"' > /dev/null || return 1
    echo "$output" | jq -se '[.[] | select(.event == "done")][0].summary.failed == 1' > /dev/null || return 1
}

@test "optimize run honors the optimize whitelist with skipped status" {
    require_jq
    mkdir -p "$HOME/.config/mole"
    echo "cache_refresh" > "$HOME/.config/mole/whitelist_optimize"
    output=$(printf 'cache_refresh\n' | "$REPO_DIR/bin/optimize.sh" --robot-run)
    echo "$output" | jq -se '[.[] | select(.event == "task_status")][0].status == "skipped"' > /dev/null || return 1
    echo "$output" | jq -se '[.[] | select(.event == "done")][0].summary.skipped == 1' > /dev/null || return 1
}

@test "optimize run emits protocol v1 NDJSON only" {
    require_jq
    output=$(printf 'cache_refresh\n' | "$REPO_DIR/bin/optimize.sh" --robot-run)
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        echo "$line" | jq -e '.v == 1' > /dev/null || return 1
    done <<< "$output"
}
