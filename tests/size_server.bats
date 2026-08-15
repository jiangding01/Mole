#!/usr/bin/env bats

# 常驻测量服务（analyze-go --du-serve + FIFO 快路径）契约测试：
# 快路径与经典路径同值、T/E 语义映射（rc124/rc1）、服务异常整体降级、
# 总开关拒启、.app 不走服务（保持 mdls 基准）。

setup_file() {
    PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    export PROJECT_ROOT
}

setup() {
    SANDBOX="$(mktemp -d "${BATS_TEST_DIRNAME}/tmp-size-server.XXXXXX")"
    export SANDBOX
    export MOLE_TEST_NO_AUTH=1
    mkdir -p "$SANDBOX/data/inner"
    dd if=/dev/zero of="$SANDBOX/data/f1" bs=1024 count=64 2> /dev/null
    dd if=/dev/zero of="$SANDBOX/data/inner/f2" bs=1024 count=32 2> /dev/null
}

teardown() {
    rm -rf "$SANDBOX"
}

prelude() {
    cat << EOF
set -euo pipefail
export MOLE_TEST_NO_AUTH=1
source "$PROJECT_ROOT/lib/core/common.sh"
EOF
}

# 固定应答的假服务（协议兼容）：验证 T/E 语义与请求确实经过服务。
_write_fake_serve() {
    # $1 script path, $2 constant reply, $3 request log file
    cat > "$1" << FAKE
#!/bin/bash
while IFS= read -r -d '' req; do
    printf '%s\n' "\$req" >> "$3"
    printf '%s' "$2"
    printf '\0'
done
FAKE
    chmod +x "$1"
}

@test "server fast path returns the same KB as the classic path" {
    run /bin/bash --noprofile --norc << EOF
$(prelude)
classic=\$(get_path_size_kb "$SANDBOX/data")
mole_size_server_start || { echo "START_FAILED"; exit 1; }
served=\$(get_path_size_kb "$SANDBOX/data")
mole_size_server_stop
[[ "\$classic" == "\$served" ]] || { echo "MISMATCH classic=\$classic served=\$served"; exit 1; }
echo "EQUAL \$served"
EOF
    [ "$status" -eq 0 ]
    [[ "$output" == EQUAL* ]] || {
        echo "$output"
        return 1
    }
}

@test "T reply maps to rc 124 (size unknown, item kept)" {
    _write_fake_serve "$SANDBOX/fake-serve" "T" "$SANDBOX/req.log"
    run /bin/bash --noprofile --norc << EOF
$(prelude)
export MOLE_ANALYZE_GO_BIN="$SANDBOX/fake-serve"
mole_size_server_start || exit 1
rc=0
get_path_size_kb "$SANDBOX/data" || rc=\$?
mole_size_server_stop
echo "RC=\$rc"
EOF
    [ "$status" -eq 0 ]
    [[ "$output" == *"RC=124"* ]] || {
        echo "$output"
        return 1
    }
    # 请求确实经过了服务
    [ -s "$SANDBOX/req.log" ]
}

@test "E reply maps to rc 1 (same as a du failure)" {
    _write_fake_serve "$SANDBOX/fake-serve" "E" "$SANDBOX/req.log"
    run /bin/bash --noprofile --norc << EOF
$(prelude)
export MOLE_ANALYZE_GO_BIN="$SANDBOX/fake-serve"
mole_size_server_start || exit 1
rc=0
get_path_size_kb "$SANDBOX/data" || rc=\$?
mole_size_server_stop
echo "RC=\$rc"
EOF
    [ "$status" -eq 0 ]
    [[ "$output" == *"RC=1"* ]] || {
        echo "$output"
        return 1
    }
}

@test "garbage reply degrades to the classic path, never a wrong answer" {
    _write_fake_serve "$SANDBOX/fake-serve" "bogus!" "$SANDBOX/req.log"
    run /bin/bash --noprofile --norc << EOF
$(prelude)
export MOLE_ANALYZE_GO_BIN="$SANDBOX/fake-serve"
classic=\$(get_path_size_kb "$SANDBOX/data")
mole_size_server_start || exit 1
degraded=\$(get_path_size_kb "$SANDBOX/data")
# 降级必须粘滞：子壳里发现协议异常 → down 文件对父进程与后续调用可见
[[ -e "\$MOLE_SIZE_SERVER_DIR/down" ]] && echo "DOWN=1" || echo "DOWN=0"
mole_size_server_stop
[[ "\$classic" == "\$degraded" ]] || { echo "MISMATCH \$classic vs \$degraded"; exit 1; }
echo "OK"
EOF
    [ "$status" -eq 0 ]
    [[ "$output" == *"DOWN=1"* ]] || {
        echo "$output"
        return 1
    }
    [[ "$output" == *"OK"* ]]
}

@test "MOLE_SIZE_BATCH_DISABLE refuses to start the server" {
    run /bin/bash --noprofile --norc << EOF
$(prelude)
export MOLE_SIZE_BATCH_DISABLE=1
rc=0
mole_size_server_start || rc=\$?
echo "RC=\$rc UP=\$MOLE_SIZE_SERVER_UP"
EOF
    [ "$status" -eq 0 ]
    [[ "$output" == *"RC=1 UP=0"* ]]
}

@test ".app bundles bypass the server (mdls basis preserved)" {
    mkdir -p "$SANDBOX/Fake.app/Contents"
    dd if=/dev/zero of="$SANDBOX/Fake.app/Contents/bin" bs=1024 count=16 2> /dev/null
    _write_fake_serve "$SANDBOX/fake-serve" "999999" "$SANDBOX/req.log"
    run /bin/bash --noprofile --norc << EOF
$(prelude)
export MOLE_ANALYZE_GO_BIN="$SANDBOX/fake-serve"
mole_size_server_start || exit 1
size=\$(get_path_size_kb "$SANDBOX/Fake.app")
mole_size_server_stop
echo "SIZE=\$size"
EOF
    [ "$status" -eq 0 ]
    # 假服务的 999999 不得出现；.app 请求也不得进入服务日志
    [[ "$output" != *"SIZE=999999"* ]] || return 1
    [ ! -s "$SANDBOX/req.log" ]
}
