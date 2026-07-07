#!/usr/bin/env bats
# robot apps files —— 只读残留发现（GUI 卸载 tab 展开清单的数据源）。
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

@test "apps files discovers user leftovers as safe default-selected items" {
    require_jq
    run "$REPO_DIR/bin/uninstall.sh" --robot-files "$APP_DIR" "com.testmole.app" "TestMole"
    [ "$status" -eq 0 ] || return 1

    echo "$output" | jq -se '[.[] | select(.event == "item")] | length >= 2' > /dev/null || return 1
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

@test "apps files rejects a missing app path with a fatal error" {
    require_jq
    run "$REPO_DIR/bin/uninstall.sh" --robot-files "$BATS_TEST_TMPDIR/nope.app" "com.x" "X"
    [ "$status" -ne 0 ] || return 1
    echo "$output" | jq -se '[.[] | select(.event == "error")][0].fatal == true' > /dev/null || return 1
}

@test "apps files emits valid protocol v1 NDJSON only" {
    require_jq
    run "$REPO_DIR/bin/uninstall.sh" --robot-files "$APP_DIR" "com.testmole.app" "TestMole"
    [ "$status" -eq 0 ] || return 1
    # 每行都是带 v:1 的 JSON（无杂散 stdout 污染协议流）
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        echo "$line" | jq -e '.v == 1' > /dev/null || return 1
    done <<< "$output"
}
