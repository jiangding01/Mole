#!/usr/bin/env bats
# robot launchitems list/disable/enable —— GUI 软件页·启动项子 tab。
# launchctl / osascript 全程 PATH stub：零真实 launchctl 变更、零交互授权。
# 枚举根与隔离区目录经环境变量注入（CI 无可写 /Library）。
# 隔离 = mv 到隔离区（非删除），可恢复。

setup() {
    export MOLE_TEST_NO_AUTH=1
    export MO_NO_OPLOG=1
    REPO_DIR="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    export HOME="$BATS_TEST_TMPDIR/home"
    mkdir -p "$HOME"

    # 枚举根 + 隔离区（环境变量覆盖真实路径）。
    export MOLE_LAUNCHITEMS_USER_AGENTS_DIR="$BATS_TEST_TMPDIR/user-agents"
    export MOLE_LAUNCHITEMS_SYS_AGENTS_DIR="$BATS_TEST_TMPDIR/sys-agents"
    export MOLE_LAUNCHITEMS_SYS_DAEMONS_DIR="$BATS_TEST_TMPDIR/sys-daemons"
    export MOLE_QUARANTINE_DIR="$BATS_TEST_TMPDIR/quarantine"
    mkdir -p "$MOLE_LAUNCHITEMS_USER_AGENTS_DIR" \
        "$MOLE_LAUNCHITEMS_SYS_AGENTS_DIR" \
        "$MOLE_LAUNCHITEMS_SYS_DAEMONS_DIR"

    # PATH stub：launchctl + osascript 记录调用、返回可断言的假数据。
    STUB_DIR="$BATS_TEST_TMPDIR/stub"
    mkdir -p "$STUB_DIR"
    export CALLS="$BATS_TEST_TMPDIR/calls.log"

    cat > "$STUB_DIR/launchctl" << EOF
#!/bin/bash
echo "launchctl \$*" >> "$CALLS"
case "\$1" in
  print-disabled)
    echo "disabled services = {"
    printf '\t"%s" => %s\n' "com.test.disabled" "true"
    printf '\t"%s" => %s\n' "com.test.foo" "false"
    echo "}"
    ;;
esac
exit 0
EOF
    chmod +x "$STUB_DIR/launchctl"

    cat > "$STUB_DIR/osascript" << EOF
#!/bin/bash
echo "osascript \$*" >> "$CALLS"
if [[ "\$1" == "-e" ]]; then exit 0; fi
printf 'TestLoginApp\t/Applications/TestLoginApp.app\n'
exit 0
EOF
    chmod +x "$STUB_DIR/osascript"
    export PATH="$STUB_DIR:$PATH"
}

require_jq() {
    command -v jq > /dev/null 2>&1 || skip "jq not installed"
}

write_agent() { # $1 dir, $2 label (== filename stem), $3 program(optional)
    local prog="${3:-}"
    local prog_block=""
    if [[ -n "$prog" ]]; then
        prog_block="<key>ProgramArguments</key><array><string>$prog</string></array>"
    fi
    cat > "$1/$2.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>Label</key><string>$2</string>
$prog_block
</dict></plist>
PLIST
}

@test "launchitems list enumerates login + user agents + system items" {
    require_jq
    write_agent "$MOLE_LAUNCHITEMS_USER_AGENTS_DIR" "com.test.foo" "/Applications/Foo.app/Contents/MacOS/foo"
    write_agent "$MOLE_LAUNCHITEMS_USER_AGENTS_DIR" "com.test.disabled"
    write_agent "$MOLE_LAUNCHITEMS_SYS_AGENTS_DIR" "com.vendor.sysagent"
    write_agent "$MOLE_LAUNCHITEMS_SYS_DAEMONS_DIR" "com.vendor.daemon"

    run "$REPO_DIR/bin/robot.sh" launchitems list
    [ "$status" -eq 0 ] || return 1

    # 登录项（osascript stub）
    echo "$output" | jq -se '[.[] | select(.event == "item") | select(.id == "login:TestLoginApp")][0].detail | startswith("login · true · false")' > /dev/null || return 1
    # 用户 agent：type agent, sys false, owner Foo（Program 绝对路径解析）
    echo "$output" | jq -se '[.[] | select(.event == "item") | select(.id == "agent:com.test.foo")] | length == 1' > /dev/null || return 1
    # disabled map 命中 → enabled false
    echo "$output" | jq -se '[.[] | select(.event == "item") | select(.id == "agent:com.test.disabled")][0].detail | startswith("agent · false")' > /dev/null || return 1
    # 系统 agent → agent-sys 前缀, sys true
    echo "$output" | jq -se '[.[] | select(.event == "item") | select(.id == "agent-sys:com.vendor.sysagent")][0].detail | contains("· true ·")' > /dev/null || return 1
    # 系统 daemon → daemon 前缀, type daemon
    echo "$output" | jq -se '[.[] | select(.event == "item") | select(.id == "daemon:com.vendor.daemon")][0].detail | startswith("daemon · true · true")' > /dev/null || return 1
    echo "$output" | jq -se '[.[] | select(.event == "done")][0].ok == true' > /dev/null || return 1
}

@test "launchitems list marks com.apple.* user items as sys and emits v1 NDJSON only" {
    require_jq
    write_agent "$MOLE_LAUNCHITEMS_USER_AGENTS_DIR" "com.apple.userthing"
    run "$REPO_DIR/bin/robot.sh" launchitems list
    [ "$status" -eq 0 ] || return 1
    # com.apple.* 即便在用户目录也标 sys:true
    echo "$output" | jq -se '[.[] | select(.event == "item") | select(.id == "agent:com.apple.userthing")][0].detail | contains(" · true · ")' > /dev/null || return 1
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        echo "$line" | jq -e '.v == 1' > /dev/null || return 1
    done <<< "$output"
}

@test "launchitems list never treats plutil error text as a label" {
    require_jq
    # 无 Label 键的 plist：应回退到文件名 stem，绝不出现 "Does Not Exist" 之类错误文本。
    cat > "$MOLE_LAUNCHITEMS_USER_AGENTS_DIR/com.test.nolabel.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>RunAtLoad</key><true/>
</dict></plist>
PLIST
    run "$REPO_DIR/bin/robot.sh" launchitems list
    [ "$status" -eq 0 ] || return 1
    echo "$output" | jq -se '[.[] | select(.event == "item") | select(.id == "agent:com.test.nolabel")][0].label == "com.test.nolabel"' > /dev/null || return 1
    echo "$output" | grep -q "Does Not Exist" && return 1
    echo "$output" | grep -qi "No value" && return 1
    return 0
}

@test "launchitems disable boots out a user agent and quarantines the plist" {
    require_jq
    write_agent "$MOLE_LAUNCHITEMS_USER_AGENTS_DIR" "com.test.foo" "/Applications/Foo.app/Contents/MacOS/foo"
    src="$MOLE_LAUNCHITEMS_USER_AGENTS_DIR/com.test.foo.plist"
    [ -f "$src" ] || return 1

    output=$(printf 'agent:com.test.foo\n' | "$REPO_DIR/bin/robot.sh" launchitems disable)
    echo "$output" | jq -se '[.[] | select(.event == "result") | select(.id == "agent:com.test.foo")][0].status == "disabled"' > /dev/null || return 1
    echo "$output" | jq -se '[.[] | select(.event == "done")][0].summary.failed == 0' > /dev/null || return 1

    # bootout 被调用（PATH stub 记录）
    grep -q "bootout gui/.*com.test.foo" "$CALLS" || return 1
    # 原 plist 已移出（非删除）：出现在隔离区 + index.tsv
    [ ! -e "$src" ] || return 1
    [ -f "$MOLE_QUARANTINE_DIR/com.test.foo.plist" ] || return 1
    grep -q $'^agent:com.test.foo\t' "$MOLE_QUARANTINE_DIR/index.tsv" || return 1
}

@test "launchitems disable refuses system items with skipped_system" {
    require_jq
    write_agent "$MOLE_LAUNCHITEMS_SYS_DAEMONS_DIR" "com.vendor.daemon"
    write_agent "$MOLE_LAUNCHITEMS_SYS_AGENTS_DIR" "com.vendor.sysagent"
    write_agent "$MOLE_LAUNCHITEMS_USER_AGENTS_DIR" "com.apple.userthing"

    output=$(printf 'daemon:com.vendor.daemon\nagent-sys:com.vendor.sysagent\nagent:com.apple.userthing\n' \
        | "$REPO_DIR/bin/robot.sh" launchitems disable)
    echo "$output" | jq -se '[.[] | select(.event == "result")] | map(.status) | all(. == "skipped_system")' > /dev/null || return 1
    echo "$output" | jq -se '[.[] | select(.event == "done")][0].summary.skipped == 3' > /dev/null || return 1
    # 系统项文件原样健在，没有任何 launchctl mutation。
    [ -f "$MOLE_LAUNCHITEMS_SYS_DAEMONS_DIR/com.vendor.daemon.plist" ] || return 1
    [ ! -f "$CALLS" ] || ! grep -q "bootout" "$CALLS" || return 1
}

@test "launchitems enable restores a quarantined agent back to its origin" {
    require_jq
    write_agent "$MOLE_LAUNCHITEMS_USER_AGENTS_DIR" "com.test.foo" "/Applications/Foo.app/Contents/MacOS/foo"
    src="$MOLE_LAUNCHITEMS_USER_AGENTS_DIR/com.test.foo.plist"

    printf 'agent:com.test.foo\n' | "$REPO_DIR/bin/robot.sh" launchitems disable > /dev/null
    [ ! -e "$src" ] || return 1
    [ -f "$MOLE_QUARANTINE_DIR/com.test.foo.plist" ] || return 1

    output=$(printf 'agent:com.test.foo\n' | "$REPO_DIR/bin/robot.sh" launchitems enable)
    echo "$output" | jq -se '[.[] | select(.event == "result") | select(.id == "agent:com.test.foo")][0].status == "enabled"' > /dev/null || return 1

    # 回到原路径；隔离区文件与 index 行清除；bootstrap 被调用。
    [ -f "$src" ] || return 1
    [ ! -e "$MOLE_QUARANTINE_DIR/com.test.foo.plist" ] || return 1
    ! grep -q $'^agent:com.test.foo\t' "$MOLE_QUARANTINE_DIR/index.tsv" 2> /dev/null || return 1
    grep -q "bootstrap gui/" "$CALLS" || return 1
}

@test "launchitems disable fails (never overwrites) on a quarantine target conflict" {
    require_jq
    write_agent "$MOLE_LAUNCHITEMS_USER_AGENTS_DIR" "com.test.foo" "/Applications/Foo.app/Contents/MacOS/foo"
    src="$MOLE_LAUNCHITEMS_USER_AGENTS_DIR/com.test.foo.plist"
    # 预置隔离区中已存在同名文件（冲突）。
    mkdir -p "$MOLE_QUARANTINE_DIR"
    echo "existing" > "$MOLE_QUARANTINE_DIR/com.test.foo.plist"

    output=$(printf 'agent:com.test.foo\n' | "$REPO_DIR/bin/robot.sh" launchitems disable)
    echo "$output" | jq -se '[.[] | select(.event == "result") | select(.id == "agent:com.test.foo")][0].status == "failed"' > /dev/null || return 1
    echo "$output" | jq -se '[.[] | select(.event == "done")][0].summary.failed == 1' > /dev/null || return 1
    # 冲突文件未被覆盖；原 plist 未被移动。
    [ "$(cat "$MOLE_QUARANTINE_DIR/com.test.foo.plist")" = "existing" ] || return 1
    [ -f "$src" ] || return 1
}

@test "launchitems disable rejects path-traversal labels and moves nothing" {
    require_jq
    # 受害 plist 位于 user agents dir 之外：穿越 label 绝不能把它 mv 走。
    mkdir -p "$BATS_TEST_TMPDIR/victim"
    write_agent "$BATS_TEST_TMPDIR/victim" "com.test.victim"

    output=$(printf 'agent:../victim/com.test.victim\nagent:../../evil\n' \
        | "$REPO_DIR/bin/robot.sh" launchitems disable)
    echo "$output" | jq -se '[.[] | select(.event == "result")] | map(.status) | all(. == "failed")' > /dev/null || return 1
    echo "$output" | jq -se '[.[] | select(.event == "done")][0].summary.failed == 2' > /dev/null || return 1

    # 受害文件原样健在；隔离区未生成；零 launchctl 调用。
    [ -f "$BATS_TEST_TMPDIR/victim/com.test.victim.plist" ] || return 1
    [ ! -e "$MOLE_QUARANTINE_DIR" ] || return 1
    [ ! -f "$CALLS" ] || ! grep -q "bootout" "$CALLS" || return 1
}

@test "launchitems login toggle passes hostile names as argv, never script text" {
    require_jq
    # 覆写 osascript stub：逐参数记录，验证 on run argv 传参而非字符串拼接。
    cat > "$STUB_DIR/osascript" << EOF
#!/bin/bash
for a in "\$@"; do printf 'ARG:%s\n' "\$a" >> "$CALLS"; done
exit 0
EOF
    chmod +x "$STUB_DIR/osascript"

    # 注意载荷不含 "/"：含 "/" 的 label 会在白名单校验就被拒绝（另一条防线），
    # 这里要专门验证通过校验的带引号注入在 argv 传参下无法逃逸成脚本代码。
    mal='pwn" & do shell script "touch owned'
    output=$(printf 'login:%s\n' "$mal" | "$REPO_DIR/bin/robot.sh" launchitems disable)

    # 安全传参下操作成功（stub 返回 0），且可恢复（index 记录在案）。
    echo "$output" | jq -se '[.[] | select(.event == "result")][0].status == "disabled"' > /dev/null || return 1
    grep -qF $'login:'"$mal"$'\t' "$MOLE_QUARANTINE_DIR/index.tsv" || return 1

    # argv 模式：脚本文本固定引用 (item 1 of argv)，恶意 name 只以独立 argv 出现。
    grep -qx 'ARG:on run argv' "$CALLS" || return 1
    grep -q 'item 1 of argv' "$CALLS" || return 1
    grep -qxF "ARG:$mal" "$CALLS" || return 1
    # 任何脚本文本行（delete login item ...）都不包含被插值的恶意 name。
    ! grep 'delete login item' "$CALLS" | grep -qF 'pwn' || return 1
    # 象征性兜底：注入命令从未被执行。
    [ ! -e "$BATS_TEST_TMPDIR/owned" ] || return 1
    [ ! -e "owned" ] || return 1
}

@test "launchitems disable under MOLE_DRY_RUN mutates nothing" {
    require_jq
    write_agent "$MOLE_LAUNCHITEMS_USER_AGENTS_DIR" "com.test.foo" "/Applications/Foo.app/Contents/MacOS/foo"
    src="$MOLE_LAUNCHITEMS_USER_AGENTS_DIR/com.test.foo.plist"

    output=$(printf 'agent:com.test.foo\n' | MOLE_DRY_RUN=1 "$REPO_DIR/bin/robot.sh" launchitems disable)
    echo "$output" | jq -se '[.[] | select(.event == "result")][0].status == "dry_run"' > /dev/null || return 1
    echo "$output" | jq -se '[.[] | select(.event == "done")][0].summary.skipped == 1' > /dev/null || return 1
    echo "$output" | jq -se '[.[] | select(.event == "done")][0].summary.failed == 0' > /dev/null || return 1

    # 零 mv、零 bootout、零隔离区。
    [ -f "$src" ] || return 1
    [ ! -e "$MOLE_QUARANTINE_DIR" ] || return 1
    [ ! -f "$CALLS" ] || ! grep -q "bootout" "$CALLS" || return 1
}
