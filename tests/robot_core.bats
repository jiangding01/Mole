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

@test "robot_human_to_bytes converts units" {
    [ "$(robot_human_to_bytes '545 B')" = "545" ] || return 1
    [ "$(robot_human_to_bytes '97 KB')" = "99328" ] || return 1
    [ "$(robot_human_to_bytes '1.5 MB')" = "1572864" ] || return 1
    [ "$(robot_human_to_bytes '2 GB')" = "2147483648" ] || return 1
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
/Users/x/Library/Caches/com.google.Chrome  # 487 MB
/Users/x/Library/Caches/com.tencent.xinWeChat  # 1.2 GB, 3 items

=== Developer tools ===
/Users/x/.docker/buildx  # 4 KB

=== Large files ===
/Users/x/Movies/big.mov  # 8 GB
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
    output=$(printf 'cl.a.exists\ncl.a.missing\ncl.a.protected\ncl.a.white\ncl.a.unknown\n' | robot_clean_apply "$plan_id")

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

@test "clean apply under MOLE_DRY_RUN deletes nothing" {
    require_jq
    setup_apply_plan
    MOLE_DRY_RUN=1
    output=$(printf 'cl.a.exists\n' | MOLE_DRY_RUN=1 robot_clean_apply "$plan_id")
    echo "$output" | jq -se '[.[] | select(.event == "result")][0].status == "dry_run"' > /dev/null || return 1
    [ -e "$BATS_TEST_TMPDIR/data/exists" ] || return 1
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
