#!/usr/bin/env bats
# robot apps updates list / apps update —— GUI 软件页·更新子 tab 的数据源与委派执行。
# brew 全程 PATH stub：零真实升级、零网络、零 .app 改写（§5.2.2 红线）。
# 纯 fixture，跨平台可跑（不依赖 macOS 上真的装了 brew）。

setup() {
    export MOLE_TEST_NO_AUTH=1
    export MO_NO_OPLOG=1
    REPO_DIR="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    export HOME="$BATS_TEST_TMPDIR/home"
    mkdir -p "$HOME"

    # PATH stub 目录：测试按需写入 brew 假实现。
    STUB_DIR="$BATS_TEST_TMPDIR/stub"
    mkdir -p "$STUB_DIR"
    export PATH="$STUB_DIR:$PATH"
}

require_jq() {
    command -v jq > /dev/null 2>&1 || skip "jq not installed"
}

write_brew() { # $1 = body of the fake brew script
    cat > "$STUB_DIR/brew" << EOF
#!/bin/bash
$1
EOF
    chmod +x "$STUB_DIR/brew"
}

remove_brew() { rm -f "$STUB_DIR/brew"; }

@test "updates list emits one item per outdated cask with brew-cask detail" {
    require_jq
    write_brew '
if [[ "$1" == "outdated" ]]; then
  echo "google-chrome (120.0.6099) != 121.0.6167"
  echo "iterm2 (3.4.19) != 3.4.23"
  exit 0
fi
exit 0'
    run "$REPO_DIR/bin/robot.sh" apps updates list
    [ "$status" -eq 0 ] || return 1
    echo "$output" | jq -se '[.[] | select(.event == "item")] | length == 2' > /dev/null || return 1
    echo "$output" | jq -se '[.[] | select(.event == "item") | select(.id == "cask:google-chrome")][0].label == "google-chrome"' > /dev/null || return 1
    echo "$output" | jq -se '[.[] | select(.event == "item") | select(.id == "cask:google-chrome")][0].detail == "brew-cask · 120.0.6099 · 121.0.6167"' > /dev/null || return 1
    echo "$output" | jq -se '[.[] | select(.event == "item") | select(.id == "cask:google-chrome")][0].default_selected == true' > /dev/null || return 1
    echo "$output" | jq -se '[.[] | select(.event == "item") | select(.id == "cask:google-chrome")][0].risk == "safe"' > /dev/null || return 1
    echo "$output" | jq -se '[.[] | select(.event == "done")][0].ok == true' > /dev/null || return 1
    echo "$output" | jq -se '[.[] | select(.event == "done")][0].summary.items == 2' > /dev/null || return 1
}

@test "updates list degrades honestly when brew is absent" {
    require_jq
    remove_brew
    run "$REPO_DIR/bin/robot.sh" apps updates list
    [ "$status" -eq 0 ] || return 1
    echo "$output" | jq -se '[.[] | select(.event == "item")] | length == 0' > /dev/null || return 1
    echo "$output" | jq -se '[.[] | select(.event == "done")][0].ok == true' > /dev/null || return 1
    echo "$output" | jq -se '[.[] | select(.event == "done")][0].summary.items == 0' > /dev/null || return 1
    echo "$output" | jq -se '[.[] | select(.event == "error")] | length == 0' > /dev/null || return 1
}

@test "updates list reports zero when nothing is outdated" {
    require_jq
    write_brew 'exit 0'
    run "$REPO_DIR/bin/robot.sh" apps updates list
    [ "$status" -eq 0 ] || return 1
    echo "$output" | jq -se '[.[] | select(.event == "item")] | length == 0' > /dev/null || return 1
    echo "$output" | jq -se '[.[] | select(.event == "done")][0].summary.items == 0' > /dev/null || return 1
}

@test "updates list emits protocol v1 NDJSON only" {
    require_jq
    write_brew 'if [[ "$1" == "outdated" ]]; then echo "vlc (3.0.18) != 3.0.20"; fi; exit 0'
    run "$REPO_DIR/bin/robot.sh" apps updates list
    [ "$status" -eq 0 ] || return 1
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        echo "$line" | jq -e '.v == 1' > /dev/null || return 1
    done <<< "$output"
}

@test "apps update delegates a cask to brew upgrade and reports done" {
    require_jq
    # 假 brew 记录被调用的参数，断言只发生 upgrade --cask，绝不碰 .app。
    write_brew '
echo "brew $*" >> "'"$BATS_TEST_TMPDIR"'/brew.calls"
if [[ "$1" == "upgrade" ]]; then exit 0; fi
exit 0'
    run "$REPO_DIR/bin/robot.sh" apps update --id cask:vlc
    [ "$status" -eq 0 ] || return 1
    echo "$output" | jq -se '[.[] | select(.event == "task_status") | select(.task_id == "cask:vlc")] | map(.status) == ["running","done"]' > /dev/null || return 1
    echo "$output" | jq -se '[.[] | select(.event == "done")][0].summary.failed == 0' > /dev/null || return 1
    grep -q 'brew upgrade --cask vlc' "$BATS_TEST_TMPDIR/brew.calls" || return 1
}

@test "apps update surfaces a brew failure as failed with stderr detail" {
    require_jq
    write_brew '
if [[ "$1" == "upgrade" ]]; then echo "Error: Download failed on cask" >&2; exit 1; fi
exit 0'
    run "$REPO_DIR/bin/robot.sh" apps update --id cask:vlc
    [ "$status" -eq 0 ] || return 1
    echo "$output" | jq -se '[.[] | select(.event == "task_status") | select(.task_id == "cask:vlc")][-1].status == "failed"' > /dev/null || return 1
    echo "$output" | jq -se '[.[] | select(.event == "task_status") | select(.task_id == "cask:vlc")][-1].detail | contains("Download failed")' > /dev/null || return 1
    echo "$output" | jq -se '[.[] | select(.event == "done")][0].summary.failed == 1' > /dev/null || return 1
}

@test "apps update rejects a flag-shaped token (cask:--greedy) without calling brew" {
    require_jq
    write_brew 'echo "brew $*" >> "'"$BATS_TEST_TMPDIR"'/brew.calls"; exit 0'
    run "$REPO_DIR/bin/robot.sh" apps update --id "cask:--greedy"
    [ "$status" -eq 0 ] || return 1
    echo "$output" | jq -se '[.[] | select(.event == "error")][0].code == "E_UNSUPPORTED"' > /dev/null || return 1
    echo "$output" | jq -se '[.[] | select(.event == "done")][0].ok == false' > /dev/null || return 1
    # brew 绝不被调用（flag 注入会升级全部已装 cask）。
    [ ! -f "$BATS_TEST_TMPDIR/brew.calls" ] || return 1
}

@test "apps update survives a brew failure with empty stderr (pipefail regression)" {
    require_jq
    # brew 失败且零输出：grep -v 对空输入退出 1，pipefail + set -e 曾会杀死
    # 整个 router，failed/done 事件全部丢失。
    write_brew 'if [[ "$1" == "upgrade" ]]; then exit 1; fi; exit 0'
    run "$REPO_DIR/bin/robot.sh" apps update --id cask:vlc
    [ "$status" -eq 0 ] || return 1
    echo "$output" | jq -se '[.[] | select(.event == "task_status") | select(.task_id == "cask:vlc")][-1].status == "failed"' > /dev/null || return 1
    echo "$output" | jq -se '[.[] | select(.event == "task_status") | select(.task_id == "cask:vlc")][-1].detail == "brew upgrade failed (exit 1)"' > /dev/null || return 1
    echo "$output" | jq -se '[.[] | select(.event == "done")] | length == 1' > /dev/null || return 1
}

@test "apps update under MOLE_DRY_RUN never invokes brew" {
    require_jq
    write_brew 'echo "brew $*" >> "'"$BATS_TEST_TMPDIR"'/brew.calls"; exit 0'
    run env MOLE_DRY_RUN=1 "$REPO_DIR/bin/robot.sh" apps update --id cask:vlc
    [ "$status" -eq 0 ] || return 1
    echo "$output" | jq -se '[.[] | select(.event == "task_status") | select(.task_id == "cask:vlc")][0].status == "skipped"' > /dev/null || return 1
    echo "$output" | jq -se '[.[] | select(.event == "task_status") | select(.task_id == "cask:vlc")][0].detail == "dry_run"' > /dev/null || return 1
    echo "$output" | jq -se '[.[] | select(.event == "done")][0].ok == true' > /dev/null || return 1
    [ ! -f "$BATS_TEST_TMPDIR/brew.calls" ] || return 1
}

@test "apps update refuses a non-cask id with E_UNSUPPORTED" {
    require_jq
    write_brew 'echo "brew $*" >> "'"$BATS_TEST_TMPDIR"'/brew.calls"; exit 0'
    run "$REPO_DIR/bin/robot.sh" apps update --id appstore:497799835
    [ "$status" -eq 0 ] || return 1
    echo "$output" | jq -se '[.[] | select(.event == "error")][0].code == "E_UNSUPPORTED"' > /dev/null || return 1
    echo "$output" | jq -se '[.[] | select(.event == "done")][0].ok == false' > /dev/null || return 1
    # 拒绝路径绝不调用 brew。
    [ ! -f "$BATS_TEST_TMPDIR/brew.calls" ] || ! grep -q upgrade "$BATS_TEST_TMPDIR/brew.calls" || return 1
}
