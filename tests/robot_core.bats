#!/usr/bin/env bats
# Robot protocol core (lib/core/robot.sh) unit tests.
# Pure bash + coreutils: runs on macOS and Linux CI alike.
# Contract reference: docs/MAC_APP_DESIGN.md §4.3 / §14.1.

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    export MOLE_ROBOT=1
    export MOLE_ROBOT_PLAN_DIR="$BATS_TEST_TMPDIR/plans"
    export MOLE_ROBOT_PLAN_TTL=1800
    source "$REPO_ROOT/lib/core/robot.sh"
}

require_jq() {
    command -v jq > /dev/null 2>&1 || skip "jq not installed"
}

# --- emit layer ---------------------------------------------------------------

@test "robot_emit_item produces valid JSON with envelope" {
    require_jq
    run robot_emit_item "cl.app_caches.1a2b" "app_caches" "Chrome Cache" "/tmp/x" 1024 "safe" "true"
    [ "$status" -eq 0 ] || return 1
    echo "$output" | jq -e '.v == 1 and .event == "item" and .id == "cl.app_caches.1a2b" and .bytes == 1024 and .default_selected == true' > /dev/null || return 1
}

@test "robot_json_escape handles quotes backslashes and newlines" {
    require_jq
    run robot_emit_item "id1" "s" "$(printf 'a"b\\c')" "/tmp/p" 1 "safe" "true"
    [ "$status" -eq 0 ] || return 1
    echo "$output" | jq -e '.label == "a\"b\\c"' > /dev/null || return 1
}

@test "robot_emit_done includes plan id and summary" {
    require_jq
    run robot_emit_done "true" "pl_x" '"items":3,"bytes_total":99'
    echo "$output" | jq -e '.ok == true and .plan_id == "pl_x" and .summary.items == 3' > /dev/null || return 1
}

@test "robot_emit_error carries code and fatal flag" {
    require_jq
    run robot_emit_error "E_PLAN_EXPIRED" "plan expired" "true"
    echo "$output" | jq -e '.code == "E_PLAN_EXPIRED" and .fatal == true' > /dev/null || return 1
}

# --- size parsing --------------------------------------------------------------

@test "robot_human_to_bytes converts bytes_to_human compact 1000-base format" {
    # Real format from lib/core/base.sh bytes_to_human: no space, 1000 base.
    [ "$(robot_human_to_bytes '545B')" = "545" ] || return 1
    [ "$(robot_human_to_bytes '743KB')" = "743000" ] || return 1
    [ "$(robot_human_to_bytes '198.5MB')" = "198500000" ] || return 1
    [ "$(robot_human_to_bytes '1.20GB')" = "1200000000" ] || return 1
    # Spaced input tolerated
    [ "$(robot_human_to_bytes '97 KB')" = "97000" ] || return 1
    # Garbage degrades to 0, never breaks the stream
    [ "$(robot_human_to_bytes 'n/a')" = "0" ] || return 1
}

@test "robot_section_slug produces stable machine keys" {
    [ "$(robot_section_slug 'App caches')" = "app_caches" ] || return 1
    [ "$(robot_section_slug 'Cloud & Office')" = "cloud_and_office" ] || return 1
    [ "$(robot_section_slug 'System Data clues')" = "system_data_clues" ] || return 1
}

# --- plan files ------------------------------------------------------------------

@test "plan lifecycle: new, append, lookup" {
    plan_id=$(robot_plan_new "clean")
    [ -f "$MOLE_ROBOT_PLAN_DIR/$plan_id.plan" ] || return 1
    robot_plan_append "$plan_id" "cl.a.1" "/tmp/cache one" 2048 true || return 1
    row=$(robot_plan_lookup "$plan_id" "cl.a.1")
    [ "$(printf '%s' "$row" | cut -f1)" = "/tmp/cache one" ] || return 1
    [ "$(printf '%s' "$row" | cut -f2)" = "2048" ] || return 1
}

@test "plan check: fresh, missing, expired" {
    plan_id=$(robot_plan_new "clean")
    run robot_plan_check "$plan_id"
    [ "$status" -eq 0 ] || return 1
    run robot_plan_check "pl_missing"
    [ "$status" -eq 1 ] || return 1
    MOLE_ROBOT_PLAN_TTL=0 ROBOT_PLAN_TTL=0
    sleep 1
    ROBOT_PLAN_TTL=0 run robot_plan_check "$plan_id"
    [ "$status" -eq 2 ] || return 1
}

@test "plan_append rejects paths with tabs" {
    plan_id=$(robot_plan_new "clean")
    run robot_plan_append "$plan_id" "cl.a.2" "$(printf '/tmp/bad\tpath')" 1 true
    [ "$status" -ne 0 ] || return 1
}

# --- export parsing ---------------------------------------------------------------

make_export_fixture() {
    cat > "$BATS_TEST_TMPDIR/export.txt" << 'EOF'
# Mole Cleanup Preview - 2026-07-06 12:00:00
#
# comment lines are ignored

=== App caches ===
/Users/x/Library/Caches/com.google.Chrome  # 487.0MB
/Users/x/Library/Caches/com.tencent.xinWeChat  # 1.20GB, 3 items

=== Developer tools ===
/Users/x/.docker/buildx  # 4KB

=== Large files ===
/Users/x/Movies/big.mov  # 8.00GB
EOF
}

@test "clean plan parses export into items, insights, and plan rows" {
    require_jq
    make_export_fixture
    plan_id=$(robot_plan_new "clean")
    run robot_clean_plan_from_export "$BATS_TEST_TMPDIR/export.txt" "$plan_id" ""
    [ "$status" -eq 0 ] || return 1

    items=$(echo "$output" | jq -s '[.[] | select(.event == "item")] | length')
    [ "$items" -eq 3 ] || return 1
    insights=$(echo "$output" | jq -s '[.[] | select(.event == "insight")] | length')
    [ "$insights" -eq 1 ] || return 1
    echo "$output" | jq -se '.[-1].event == "done" and .[-1].summary.items == 3' > /dev/null || return 1

    # plan rows recorded for every item (id -> path)
    rows=$(grep -c '^item' "$MOLE_ROBOT_PLAN_DIR/$plan_id.plan")
    [ "$rows" -eq 3 ] || return 1
}

@test "clean plan honors --sections filter" {
    require_jq
    make_export_fixture
    plan_id=$(robot_plan_new "clean")
    run robot_clean_plan_from_export "$BATS_TEST_TMPDIR/export.txt" "$plan_id" "developer_tools"
    items=$(echo "$output" | jq -s '[.[] | select(.event == "item")] | length')
    [ "$items" -eq 1 ] || return 1
    echo "$output" | jq -se '[.[] | select(.event == "item")][0].section == "developer_tools"' > /dev/null || return 1
}

# --- apply (deletion helpers stubbed) ----------------------------------------------

setup_apply_plan() {
    mkdir -p "$BATS_TEST_TMPDIR/data"
    echo x > "$BATS_TEST_TMPDIR/data/exists"
    echo x > "$BATS_TEST_TMPDIR/data/protected"
    echo x > "$BATS_TEST_TMPDIR/data/whitelisted"
    plan_id=$(robot_plan_new "clean")
    robot_plan_append "$plan_id" "cl.a.exists" "$BATS_TEST_TMPDIR/data/exists" 100 true
    robot_plan_append "$plan_id" "cl.a.missing" "$BATS_TEST_TMPDIR/data/missing" 50 true
    robot_plan_append "$plan_id" "cl.a.protected" "$BATS_TEST_TMPDIR/data/protected" 10 true
    robot_plan_append "$plan_id" "cl.a.white" "$BATS_TEST_TMPDIR/data/whitelisted" 10 true

    should_protect_path() { [[ "$1" == *"/protected" ]]; }
    is_whitelisted() { [[ "$1" == *"/whitelisted" ]]; }
    mole_delete() { rm -f "$1"; }
    export -f should_protect_path is_whitelisted mole_delete 2> /dev/null || true
}

@test "clean apply validates every id through the safety chain" {
    require_jq
    setup_apply_plan
    output=$(printf 'cl.a.exists\ncl.a.missing\ncl.a.protected\ncl.a.white\ncl.a.unknown\n' | MOLE_DELETE_MODE=trash robot_clean_apply "$plan_id")

    echo "$output" | jq -se '[.[] | select(.event == "result")] | length == 5' > /dev/null || return 1
    echo "$output" | jq -se '[.[] | select(.id == "cl.a.exists")][0].status == "trashed"' > /dev/null || return 1
    echo "$output" | jq -se '[.[] | select(.id == "cl.a.missing")][0].status == "skipped_missing"' > /dev/null || return 1
    echo "$output" | jq -se '[.[] | select(.id == "cl.a.protected")][0].status == "skipped_protected"' > /dev/null || return 1
    echo "$output" | jq -se '[.[] | select(.id == "cl.a.white")][0].status == "skipped_whitelisted"' > /dev/null || return 1
    echo "$output" | jq -se '[.[] | select(.id == "cl.a.unknown")][0].status == "failed"' > /dev/null || return 1
    [ ! -e "$BATS_TEST_TMPDIR/data/exists" ] || return 1
    [ -e "$BATS_TEST_TMPDIR/data/protected" ] || return 1
    [ -e "$BATS_TEST_TMPDIR/data/whitelisted" ] || return 1
}

@test "clean apply reports the real deletion mode, never claims trash for permanent" {
    require_jq
    setup_apply_plan
    # Without trash mode the result must say "deleted" — claiming "trashed"
    # for a permanent removal was the PR #1 audit blocker
    # (docs/ROBOT_AUDIT_FOLLOWUP.md).
    output=$(printf 'cl.a.exists\n' | MOLE_DELETE_MODE=permanent robot_clean_apply "$plan_id")
    echo "$output" | jq -se '[.[] | select(.event == "result")][0].status == "deleted"' > /dev/null || return 1
}

@test "clean apply under MOLE_DRY_RUN deletes nothing" {
    require_jq
    setup_apply_plan
    MOLE_DRY_RUN=1
    output=$(printf 'cl.a.exists\n' | MOLE_DRY_RUN=1 robot_clean_apply "$plan_id")
    echo "$output" | jq -se '[.[] | select(.event == "result")][0].status == "dry_run"' > /dev/null || return 1
    [ -e "$BATS_TEST_TMPDIR/data/exists" ] || return 1
}

@test "clean apply SIGTERM finishes current item then reports the rest cancelled" {
    require_jq
    setup_apply_plan
    # 模拟删除进行中收到 SIGTERM：bash 会等 mole_delete 返回后才跑 trap，
    # 所以当前项必须完整出账，其余项归入 cancelled，绝不半删。
    mole_delete() {
        kill -TERM "$BASHPID"
        rm -f "$1"
    }
    output=$(printf 'cl.a.exists\ncl.a.missing\ncl.a.protected\n' | MOLE_DELETE_MODE=trash robot_clean_apply "$plan_id")

    echo "$output" | jq -se '[.[] | select(.id == "cl.a.exists")][0].status == "trashed"' > /dev/null || return 1
    echo "$output" | jq -se '[.[] | select(.event == "result")] | length == 1' > /dev/null || return 1
    echo "$output" | jq -se '[.[] | select(.event == "done")][0].summary.cancelled == 2' > /dev/null || return 1
    echo "$output" | jq -se '[.[] | select(.event == "done")][0].ok == true' > /dev/null || return 1
    # 被取消的项一个都没动
    [ -e "$BATS_TEST_TMPDIR/data/protected" ] || return 1
}

@test "clean apply fails closed when a safety dependency is missing" {
    require_jq
    setup_apply_plan
    unset -f is_whitelisted
    output=$(printf 'cl.a.exists\n' | robot_clean_apply "$plan_id" || true)
    echo "$output" | jq -se '.[0].code == "E_INTERNAL" and .[0].fatal == true' > /dev/null || return 1
    # Nothing deleted: the run was refused before entering the loop.
    [ -e "$BATS_TEST_TMPDIR/data/exists" ] || return 1
}

# --- progress ledger scanning ----------------------------------------------------

@test "robot_clean_ledger_snapshot parses NUL-delimited ledger tuples" {
    printf '%s\0' id1 100 1 true "User Caches" "/Users/x/Library/Caches/foo" \
        > "$BATS_TEST_TMPDIR/ledger"
    printf '%s\0' id2 50 3 true "Developer Tools" "/Users/x/.cache/bar" \
        >> "$BATS_TEST_TMPDIR/ledger"
    run robot_clean_ledger_snapshot "$BATS_TEST_TMPDIR/ledger"
    [ "$status" -eq 0 ] || return 1
    [ "$(printf '%s' "$output" | cut -f1)" = "2" ] || return 1
    # (100 + 50) KB * 1024
    [ "$(printf '%s' "$output" | cut -f2)" = "153600" ] || return 1
    [ "$(printf '%s' "$output" | cut -f3)" = "developer_tools" ] || return 1
    [ "$(printf '%s' "$output" | cut -f4)" = "/Users/x/.cache/bar" ] || return 1
}

@test "robot_clean_ledger_snapshot ignores a partial trailing tuple" {
    printf '%s\0' id1 100 1 true Logs /tmp/a > "$BATS_TEST_TMPDIR/ledger"
    # Simulate the writer caught mid-tuple: only two of six fields flushed.
    printf '%s\0' id2 >> "$BATS_TEST_TMPDIR/ledger"
    printf '%s' 999 >> "$BATS_TEST_TMPDIR/ledger"
    run robot_clean_ledger_snapshot "$BATS_TEST_TMPDIR/ledger"
    [ "$status" -eq 0 ] || return 1
    [ "$(printf '%s' "$output" | cut -f1)" = "1" ] || return 1
    [ "$(printf '%s' "$output" | cut -f2)" = "102400" ] || return 1
    [ "$(printf '%s' "$output" | cut -f4)" = "/tmp/a" ] || return 1
}

@test "robot_clean_ledger_snapshot flattens newline paths to one TSV line" {
    printf '%s\0' id1 10 1 true Logs "$(printf '/tmp/evil\n,')" \
        > "$BATS_TEST_TMPDIR/ledger"
    run robot_clean_ledger_snapshot "$BATS_TEST_TMPDIR/ledger"
    [ "$status" -eq 0 ] || return 1
    line_count=$(printf '%s\n' "$output" | wc -l | tr -d ' ')
    [ "$line_count" = "1" ] || return 1
    [ "$(printf '%s' "$output" | cut -f4)" = "/tmp/evil ," ] || return 1
}

@test "clean plan emits null bytes for size-unknown entries, not zero" {
    require_jq
    {
        printf '=== Logs ===\n'
        printf '/Users/x/Library/Logs/slow-dir  # size unknown\n'
        printf '/Users/x/Library/Logs/fast-dir  # 2KB\n'
        printf '=== Large Files ===\n'
        printf '/Users/x/Movies/huge.mov  # size unknown\n'
    } > "$BATS_TEST_TMPDIR/export.txt"
    plan_id=$(robot_plan_new "clean")
    run robot_clean_plan_from_export "$BATS_TEST_TMPDIR/export.txt" "$plan_id"
    [ "$status" -eq 0 ] || return 1
    echo "$output" | jq -se '[.[] | select(.event == "item")][0].bytes == null' > /dev/null || return 1
    echo "$output" | jq -se '[.[] | select(.event == "item")][1].bytes == 2000' > /dev/null || return 1
    # Unknown sizes stay out of the plan total instead of counting as 0-and-true.
    echo "$output" | jq -se '[.[] | select(.event == "done")][0].summary.bytes_total == 2000' > /dev/null || return 1
    # Insights carry the same semantics: unknown emits null, not 0.
    echo "$output" | jq -se '[.[] | select(.event == "insight")][0].bytes == null' > /dev/null || return 1
}

@test "clean plan parser skips lines without the size marker" {
    require_jq
    {
        printf '=== Logs ===\n'
        # Fragment of an unrepresentable multi-line path: no "  #" marker.
        printf '/Users/x/Library/Logs/real-dir\n'
        printf '/Users/x/Library/Logs/junk  # 1KB\n'
    } > "$BATS_TEST_TMPDIR/export.txt"
    plan_id=$(robot_plan_new "clean")
    run robot_clean_plan_from_export "$BATS_TEST_TMPDIR/export.txt" "$plan_id"
    [ "$status" -eq 0 ] || return 1
    echo "$output" | jq -se '[.[] | select(.event == "item")] | length == 1' > /dev/null || return 1
    echo "$output" | jq -se '[.[] | select(.event == "item")][0].path | endswith("junk")' > /dev/null || return 1
}

@test "robot_clean_ledger_snapshot on a missing file reports zero progress" {
    run robot_clean_ledger_snapshot "$BATS_TEST_TMPDIR/absent-ledger"
    [ "$status" -eq 0 ] || return 1
    [ "$(printf '%s' "$output" | cut -f1)" = "0" ] || return 1
    [ "$(printf '%s' "$output" | cut -f2)" = "0" ] || return 1
}

# --- history parsing --------------------------------------------------------------

@test "robot_history_deletions parses the TSV deletions log" {
    require_jq
    printf '2026-07-06T10:00:00\ttrash\t1024\tTRASHED\t/Users/x/Library/Caches/foo\n' > "$BATS_TEST_TMPDIR/deletions.log"
    printf '2026-07-06T10:00:01\trm\t50\tREMOVED\t/Users/x/Library/Logs/bar.log\n' >> "$BATS_TEST_TMPDIR/deletions.log"
    run robot_history_deletions "$BATS_TEST_TMPDIR/deletions.log" 100
    echo "$output" | jq -se '[.[] | select(.event == "item")] | length == 2' > /dev/null || return 1
    echo "$output" | jq -se '[.[] | select(.event == "item")][0].bytes == 1048576' > /dev/null || return 1
    echo "$output" | jq -se '.[-1].event == "done" and .[-1].summary.items == 2' > /dev/null || return 1
}

@test "robot_history_deletions survives non-numeric size_kb entries" {
    require_jq
    # file_ops.sh writes size_kb="unknown" when du sizing is sudo-blocked;
    # the stream must keep flowing past it and still emit the done event.
    printf '2026-07-08T00:21:25+0800\ttrash\tunknown\tok\t/some/unreadable/path\n' > "$BATS_TEST_TMPDIR/deletions.log"
    printf '2026-07-08T00:21:26+0800\ttrash\t2048\tok\t/some/later/path\n' >> "$BATS_TEST_TMPDIR/deletions.log"
    run robot_history_deletions "$BATS_TEST_TMPDIR/deletions.log" 100
    [ "$status" -eq 0 ] || return 1
    echo "$output" | jq -se '[.[] | select(.event == "item")] | length == 2' > /dev/null || return 1
    echo "$output" | jq -se '[.[] | select(.event == "item")][0].bytes == 0' > /dev/null || return 1
    echo "$output" | jq -se '[.[] | select(.event == "item")][0].size_unknown == true' > /dev/null || return 1
    echo "$output" | jq -se '[.[] | select(.event == "item")][1].bytes == 2097152' > /dev/null || return 1
    echo "$output" | jq -se '[.[] | select(.event == "item")][1] | has("size_unknown") | not' > /dev/null || return 1
    echo "$output" | jq -se '.[-1].event == "done" and .[-1].summary.items == 2' > /dev/null || return 1
}

@test "robot_history_sessions parses session end markers" {
    require_jq
    cat > "$BATS_TEST_TMPDIR/operations.log" << 'EOF'

# ========== clean session started at 2026-07-06 14:30:00 ==========
[2026-07-06 14:30:01] [clean] TRASH /Users/x/Library/Caches/foo
# ========== clean session ended at 2026-07-06 14:32:10, 129 items, 8.90GB ==========

# ========== uninstall session started at 2026-07-06 15:00:00 ==========
# ========== uninstall session ended at 2026-07-06 15:01:00, 4 items, 493.8MB ==========
EOF
    run robot_history_sessions "$BATS_TEST_TMPDIR/operations.log" 20
    echo "$output" | jq -se '[.[] | select(.event == "item")] | length == 2' > /dev/null || return 1
    echo "$output" | jq -se '[.[] | select(.event == "item")][0].label == "clean"' > /dev/null || return 1
    echo "$output" | jq -se '[.[] | select(.event == "item")][0].bytes == 8900000000' > /dev/null || return 1
    echo "$output" | jq -se '[.[] | select(.event == "item")][1].detail | contains("4 items")' > /dev/null || return 1
}

@test "robot_history handles missing log files gracefully" {
    require_jq
    run robot_history_deletions "$BATS_TEST_TMPDIR/nope.log" 10
    echo "$output" | jq -se '.[0].event == "done" and .[0].summary.items == 0' > /dev/null || return 1
}

# --- whitelist ----------------------------------------------------------------------

setup_whitelist_stubs() {
    CURRENT_WHITELIST_PATTERNS=("~/keep/one" "~/keep/two")
    load_whitelist() { :; }
    # robot_whitelist_cmd runs inside $(...) in these tests, so report the
    # save call through files rather than shell variables.
    save_whitelist_patterns() {
        printf '%s\n' "$1" > "$BATS_TEST_TMPDIR/saved_mode"
        shift
        printf '%s\n' "$@" > "$BATS_TEST_TMPDIR/saved_patterns"
    }
}

@test "whitelist list emits current patterns" {
    require_jq
    setup_whitelist_stubs
    output=$(robot_whitelist_cmd list clean "")
    echo "$output" | jq -se '[.[] | select(.event == "item")] | length == 2' > /dev/null || return 1
    echo "$output" | jq -se '.[-1].summary.items == 2' > /dev/null || return 1
}

@test "whitelist add appends and saves; duplicate add is a no-op" {
    require_jq
    setup_whitelist_stubs
    output=$(robot_whitelist_cmd add clean "~/keep/three")
    echo "$output" | jq -se '.[-1].summary.items == 3' > /dev/null || return 1
    grep -q 'keep/three' "$BATS_TEST_TMPDIR/saved_patterns" || return 1
    [ "$(cat "$BATS_TEST_TMPDIR/saved_mode")" = "clean" ] || return 1

    # Duplicate add: pattern already present -> no save call.
    # (robot_whitelist_cmd ran in a subshell above, so seed the parent
    # array explicitly to model the post-add state.)
    CURRENT_WHITELIST_PATTERNS+=("~/keep/three")
    rm -f "$BATS_TEST_TMPDIR/saved_patterns"
    output=$(robot_whitelist_cmd add clean "~/keep/three")
    [ ! -f "$BATS_TEST_TMPDIR/saved_patterns" ] || return 1
}

@test "whitelist remove drops the pattern; invalid mode fails closed" {
    require_jq
    setup_whitelist_stubs
    output=$(robot_whitelist_cmd remove optimize "~/keep/one")
    [ "$(cat "$BATS_TEST_TMPDIR/saved_mode")" = "optimize" ] || return 1
    echo "$output" | jq -se '.[-1].summary.items == 1' > /dev/null || return 1

    output=$(robot_whitelist_cmd list bogus "" || true)
    echo "$output" | jq -se '.[0].code == "E_INTERNAL" and .[0].fatal == true' > /dev/null || return 1
}

@test "whitelist fails closed when save/load helpers are missing" {
    require_jq
    output=$(robot_whitelist_cmd list clean "" || true)
    echo "$output" | jq -se '.[0].code == "E_INTERNAL" and .[0].fatal == true' > /dev/null || return 1
}

# --- golden contract files -----------------------------------------------------------

@test "golden contract files are valid protocol v1 NDJSON" {
    require_jq
    for f in "$REPO_ROOT"/contracts/robot_v1/*.ndjson; do
        [ -f "$f" ] || return 1
        # Every line is JSON with the v1 envelope and a known event type.
        jq -se 'all(.[]; .v == 1 and (.event | IN("progress","item","insight","result","task_status","done","error")))' "$f" > /dev/null || return 1
        # Every result status is from the documented set.
        jq -se 'all(.[] | select(.event == "result"); .status | IN("trashed","deleted","skipped_whitelisted","skipped_protected","skipped_missing","dry_run","failed"))' "$f" > /dev/null || return 1
        # Every error code is from the documented table (§14.1).
        jq -se 'all(.[] | select(.event == "error"); .code | startswith("E_"))' "$f" > /dev/null || return 1
    done
}

@test "clean apply rejects expired plan with E_PLAN_EXPIRED" {
    require_jq
    setup_apply_plan
    ROBOT_PLAN_TTL=0
    sleep 1
    output=$(printf 'cl.a.exists\n' | robot_clean_apply "$plan_id" || true)
    echo "$output" | jq -se '.[0].code == "E_PLAN_EXPIRED" and .[0].fatal == true' > /dev/null || return 1
    [ -e "$BATS_TEST_TMPDIR/data/exists" ] || return 1
}
