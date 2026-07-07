#!/usr/bin/env bats
# robot apps plan/apply —— 残留发现 + 计划创建 + 安全链执行（GUI 卸载链路）。
# 纯 fixture：假 HOME + 假 .app，跨平台可跑；不触任何删除路径。

setup() {
    export MOLE_TEST_NO_AUTH=1
    export MO_NO_OPLOG=1
    REPO_DIR="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

    export HOME="$BATS_TEST_TMPDIR/home"
    mkdir -p "$HOME"

    APP_DIR="$BATS_TEST_TMPDIR/Applications/TestMole.app"
    mkdir -p "$APP_DIR/Contents"

    # 用户级残留（应为 safe + 默认勾选）
    mkdir -p "$HOME/Library/Caches/com.testmole.app"
    echo cache > "$HOME/Library/Caches/com.testmole.app/blob"
    mkdir -p "$HOME/Library/Application Support/TestMole"
    echo data > "$HOME/Library/Application Support/TestMole/state"
}

require_jq() {
    command -v jq > /dev/null 2>&1 || skip "jq not installed"
}

@test "apps plan discovers user leftovers as safe default-selected items" {
    require_jq
    run "$REPO_DIR/bin/uninstall.sh" --robot-plan "$APP_DIR" "com.testmole.app" "TestMole"
    [ "$status" -eq 0 ] || return 1

    echo "$output" | jq -se '[.[] | select(.event == "item")] | length >= 3' > /dev/null || return 1
    # 首项 = 应用本体（section "app"，GUI 摘要的"移除本体"）
    echo "$output" | jq -se '[.[] | select(.event == "item")][0].section == "app"' > /dev/null || return 1
    echo "$output" | jq -se '[.[] | select(.event == "item")][0].path | endswith("TestMole.app")' > /dev/null || return 1
    echo "$output" | jq -se '[.[] | select(.event == "item") | select(.path | endswith("Caches/com.testmole.app"))][0].risk == "safe"' > /dev/null || return 1
    echo "$output" | jq -se '[.[] | select(.event == "item") | select(.path | endswith("Caches/com.testmole.app"))][0].default_selected == true' > /dev/null || return 1
    echo "$output" | jq -se '[.[] | select(.event == "item") | select(.path | contains("Application Support/TestMole"))] | length == 1' > /dev/null || return 1
    # done 汇总：项数与字节都为正
    echo "$output" | jq -se '[.[] | select(.event == "done")][0].ok == true' > /dev/null || return 1
    echo "$output" | jq -se '[.[] | select(.event == "done")][0].summary.items >= 2' > /dev/null || return 1
    # 只读：残留原样健在
    [ -e "$HOME/Library/Caches/com.testmole.app/blob" ] || return 1
    [ -e "$HOME/Library/Application Support/TestMole/state" ] || return 1
}

@test "apps plan never emits the same path twice" {
    require_jq
    run "$REPO_DIR/bin/uninstall.sh" --robot-plan "$APP_DIR" "com.testmole.app" "TestMole"
    [ "$status" -eq 0 ] || return 1
    # 路径全局唯一（多命名变体在大小写不敏感盘上会重复命中同一目录，
    # 曾在真机把 widgetextension 容器发了两遍并重复计入总量）
    echo "$output" | jq -se '[.[] | select(.event == "item") | .path] | length == (. | unique | length)' > /dev/null || return 1
}

@test "apps plan rejects a missing app path with a fatal error" {
    require_jq
    run "$REPO_DIR/bin/uninstall.sh" --robot-plan "$BATS_TEST_TMPDIR/nope.app" "com.x" "X"
    [ "$status" -ne 0 ] || return 1
    echo "$output" | jq -se '[.[] | select(.event == "error")][0].fatal == true' > /dev/null || return 1
}

@test "apps plan emits valid protocol v1 NDJSON only" {
    require_jq
    run "$REPO_DIR/bin/uninstall.sh" --robot-plan "$APP_DIR" "com.testmole.app" "TestMole"
    [ "$status" -eq 0 ] || return 1
    # 每行都是带 v:1 的 JSON（无杂散 stdout 污染协议流）
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        echo "$line" | jq -e '.v == 1' > /dev/null || return 1
    done <<< "$output"
}

@test "apps plan persists every item to the plan file with matching ids" {
    require_jq
    run "$REPO_DIR/bin/uninstall.sh" --robot-plan "$APP_DIR" "com.testmole.app" "TestMole"
    [ "$status" -eq 0 ] || return 1
    plan_id=$(echo "$output" | jq -rs '[.[] | select(.event == "done")][0].plan_id')
    [ -n "$plan_id" ] && [ "$plan_id" != "null" ] || return 1
    plan_file="$HOME/.cache/mole/robot/$plan_id.plan"
    [ -f "$plan_file" ] || return 1
    items=$(echo "$output" | jq -s '[.[] | select(.event == "item")] | length')
    rows=$(grep -c $'^item\t' "$plan_file")
    [ "$rows" -eq "$items" ] || return 1
    # 每个事件 id 都能在计划文件中找到
    for id in $(echo "$output" | jq -rs '.[] | select(.event == "item") | .id'); do
        grep -q $'^item\t'"$id"$'\t' "$plan_file" || return 1
    done
}

@test "apps plan then apply trashes selected ids through the safety chain" {
    require_jq
    run "$REPO_DIR/bin/uninstall.sh" --robot-plan "$APP_DIR" "com.testmole.app" "TestMole"
    [ "$status" -eq 0 ] || return 1
    plan_id=$(echo "$output" | jq -rs '[.[] | select(.event == "done")][0].plan_id')
    cache_id=$(echo "$output" | jq -rs '.[] | select(.event == "item") | select(.path | endswith("Caches/com.testmole.app")) | .id')
    [ -n "$cache_id" ] || return 1

    # 直接驱动库层 apply（与 robot_core.bats 同套路：删除助手打桩）
    source "$REPO_DIR/lib/core/robot.sh"
    should_protect_path() { return 1; }
    is_whitelisted() { return 1; }
    mole_delete() { rm -rf "$1"; }
    apply_out=$(printf '%s\n' "ap.1" "$cache_id" | MOLE_DELETE_MODE=trash robot_clean_apply "$plan_id")

    echo "$apply_out" | jq -se '[.[] | select(.event == "result")] | length == 2' > /dev/null || return 1
    echo "$apply_out" | jq -se '[.[] | select(.event == "result") | select(.status == "trashed")] | length == 2' > /dev/null || return 1
    echo "$apply_out" | jq -se '[.[] | select(.event == "done")][0].ok == true' > /dev/null || return 1
    # 本体与勾选残留被移除；未勾选残留原样健在
    [ ! -e "$APP_DIR" ] || return 1
    [ ! -e "$HOME/Library/Caches/com.testmole.app" ] || return 1
    [ -e "$HOME/Library/Application Support/TestMole/state" ] || return 1
}

# --- 兄弟安装守卫（CLAUDE.md：每个 teardown 变体一条回归） -------------------

make_survivor() { # $1 dir-name, bundle id 固定 com.testmole.app
    mkdir -p "$HOME/Applications/$1.app/Contents"
    cat > "$HOME/Applications/$1.app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.testmole.app</string>
</dict></plist>
PLIST
}

@test "apps plan demotes bundle id when a same-bundle sibling survives" {
    require_jq
    make_survivor "SurvivorMole"
    run "$REPO_DIR/bin/uninstall.sh" --robot-plan "$APP_DIR" "com.testmole.app" "TestMole"
    [ "$status" -eq 0 ] || return 1
    # bundle-id 键控的路径（幸存者仍在用）绝不能进计划
    echo "$output" | jq -se '[.[] | select(.event == "item") | select(.path // "" | endswith("Caches/com.testmole.app"))] | length == 0' > /dev/null || return 1
    # 名称键控（TestMole 独有、与幸存者名不撞）仍允许
    echo "$output" | jq -se '[.[] | select(.event == "item") | select(.path // "" | contains("Application Support/TestMole"))] | length == 1' > /dev/null || return 1
    # 计划文件里同样不含 bundle-id 键控路径
    plan_id=$(echo "$output" | jq -rs '[.[] | select(.event == "done")][0].plan_id')
    ! grep -q "Caches/com.testmole.app" "$HOME/.cache/mole/robot/$plan_id.plan" || return 1
}

@test "apps plan drops name discovery too when survivor name collides" {
    require_jq
    make_survivor "TestMole 2"
    run "$REPO_DIR/bin/uninstall.sh" --robot-plan "$APP_DIR" "com.testmole.app" "TestMole"
    [ "$status" -eq 0 ] || return 1
    # 名字撞车（"testmole 2" 含 "testmole"）→ 只剩应用本体一项
    echo "$output" | jq -se '[.[] | select(.event == "item")] | length == 1' > /dev/null || return 1
    echo "$output" | jq -se '[.[] | select(.event == "item")][0].section == "app"' > /dev/null || return 1
}

@test "apps plan refuses system-critical bundles with E_PATH_PROTECTED" {
    require_jq
    run "$REPO_DIR/bin/uninstall.sh" --robot-plan "$APP_DIR" "com.apple.finder" "Finder"
    [ "$status" -ne 0 ] || return 1
    echo "$output" | jq -se '[.[] | select(.event == "error")][0].code == "E_PATH_PROTECTED"' > /dev/null || return 1
    # 拒绝发生在建计划之前：不留计划文件
    [ -z "$(ls "$HOME/.cache/mole/robot" 2>/dev/null)" ] || return 1
}
