#!/bin/bash
# Mole - Robot command router (machine mode for the GUI).
# Spec: docs/MAC_APP_DESIGN.md §4. Stdout is pure NDJSON; human output from
# wrapped commands is discarded (diagnostics go to stderr only).
#
# M0 scope: clean plan / clean apply. Further domains land per ROADMAP.
#
# Wire format (§4.1, M0 simplification): apply takes --plan <id> on argv and
# reads item ids one per line from stdin. The core deliberately avoids JSON
# *parsing* on bash 3.2; it only emits JSON.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

export MOLE_ROBOT=1

# shellcheck source=lib/core/robot.sh
source "$SCRIPT_DIR/lib/core/robot.sh"

robot_usage() {
    cat >&2 << 'EOF'
Usage: robot.sh <domain> <verb> [options]
  clean plan [--sections a,b] [--external <path>]
  clean apply --plan <plan_id>     (item ids on stdin, one per line)
  apps list                        (passthrough: JSON document, not NDJSON)
  apps plan <path> <bundle_id> [name]    read-only discovery + plan (NDJSON items)
  apps apply --plan <id>           ids via stdin; Trash-routed removal
  history list [--limit n] [--deletions]
  whitelist list|add|remove --mode clean|optimize [pattern]
EOF
    exit 2
}

# Poll the export file while the wrapped clean runs, emitting progress events
# so the GUI shows liveness during the multi-minute scan (§4.3 progress).
robot_watch_clean_export() {
    local pid="$1" export_file="$2"
    local last_line=0 total bytes_acc=0 items_acc=0 section="" delta

    while kill -0 "$pid" 2> /dev/null; do
        sleep 1
        [[ -f "$export_file" ]] || continue
        total=$(wc -l < "$export_file" | tr -d ' ')
        [[ "$total" -gt "$last_line" ]] || continue
        delta=$(robot_scan_export_delta "$export_file" "$last_line" "$section" | tail -1)
        section=$(printf '%s' "$delta" | cut -f1)
        local current
        current=$(printf '%s' "$delta" | cut -f2)
        bytes_acc=$((bytes_acc + $(printf '%s' "$delta" | cut -f3)))
        items_acc=$((items_acc + $(printf '%s' "$delta" | cut -f4)))
        robot_emit_progress "scan" "$section" "$current" "$items_acc" "-1" "$bytes_acc"
        last_line=$total
    done
}

run_clean_plan() {
    local sections="" external="" export_file=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --sections)
                shift
                sections="${1:-}"
                ;;
            --external)
                shift
                external="${1:-}"
                ;;
            *)
                robot_emit_error "E_INTERNAL" "unknown plan option: $1" "true"
                exit 2
                ;;
        esac
        shift
    done

    # Test hook: parse a pre-generated export file instead of running clean.
    export_file="${MOLE_ROBOT_EXPORT_FILE:-}"

    if [[ -z "$export_file" ]]; then
        if [[ "$(uname)" != "Darwin" ]]; then
            robot_emit_error "E_INTERNAL" "clean plan requires macOS (or MOLE_ROBOT_EXPORT_FILE for tests)" "true"
            exit 1
        fi
        export_file="$HOME/.config/mole/clean-list.txt"
        # The dry run writes the authoritative candidate list to the export
        # file; its human-facing stdout is not part of the protocol. Run it
        # in the background and stream progress from the growing export file
        # so the GUI shows liveness during the multi-minute scan.
        local clean_pid clean_rc=0
        if [[ -n "$external" ]]; then
            MOLE_TEST_NO_AUTH="${MOLE_TEST_NO_AUTH:-1}" "$SCRIPT_DIR/bin/clean.sh" --dry-run --external "$external" > /dev/null 2>&2 &
        else
            MOLE_TEST_NO_AUTH="${MOLE_TEST_NO_AUTH:-1}" "$SCRIPT_DIR/bin/clean.sh" --dry-run > /dev/null 2>&2 &
        fi
        clean_pid=$!
        robot_watch_clean_export "$clean_pid" "$export_file"
        wait "$clean_pid" || clean_rc=$?
        if [[ $clean_rc -ne 0 ]]; then
            robot_emit_error "E_INTERNAL" "clean dry-run exited with $clean_rc" "true"
            exit 1
        fi
    fi

    if [[ ! -f "$export_file" ]]; then
        robot_emit_error "E_INTERNAL" "clean export not produced: $export_file" "true"
        exit 1
    fi

    local plan_id
    plan_id=$(robot_plan_new "clean")
    robot_clean_plan_from_export "$export_file" "$plan_id" "$sections"
}

run_clean_apply() {
    local plan_id=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --plan)
                shift
                plan_id="${1:-}"
                ;;
            *)
                robot_emit_error "E_INTERNAL" "unknown apply option: $1" "true"
                exit 2
                ;;
        esac
        shift
    done

    if [[ -z "$plan_id" ]]; then
        robot_emit_error "E_PLAN_NOT_FOUND" "missing --plan <plan_id>" "true"
        exit 2
    fi

    # User-facing robot deletions are Trash-recoverable by default, exactly
    # like bin/uninstall.sh:1369 — mole_delete would otherwise default to
    # permanent while the protocol promises reversible:true/"trashed"
    # (docs/ROBOT_AUDIT_FOLLOWUP.md blocker). MOLE_CURRENT_COMMAND keeps
    # oplog attribution on [clean].
    export MOLE_DELETE_MODE="${MOLE_DELETE_MODE:-trash}"
    export MOLE_CURRENT_COMMAND="clean"

    # Deletion chain dependencies: mole_delete / should_protect_path from the
    # shared core, is_whitelisted + patterns from the whitelist module.
    # robot_clean_apply refuses to run (fail closed) if any of them is missing.
    # shellcheck source=lib/core/common.sh
    source "$SCRIPT_DIR/lib/core/common.sh"
    # shellcheck source=lib/manage/whitelist.sh
    source "$SCRIPT_DIR/lib/manage/whitelist.sh"
    load_whitelist "clean"

    robot_clean_apply "$plan_id"
}

run_apps_list() {
    if [[ "$(uname)" != "Darwin" ]]; then
        robot_emit_error "E_INTERNAL" "apps list requires macOS" "true"
        exit 1
    fi
    # Passthrough: uninstall --list auto-emits a JSON array when stdout is a
    # pipe (bin/uninstall.sh uninstall_list_apps). Documented protocol
    # exception (§4.2): this command returns a JSON document, not NDJSON.
    exec "$SCRIPT_DIR/bin/uninstall.sh" --list
}

run_apps_plan() {
    # Read-only leftover discovery + plan creation for one app. Passthrough
    # to uninstall.sh, which owns the discovery helpers (find_app_files +
    # sibling guard) and emits protocol v1 NDJSON via lib/core/robot.sh.
    # Usage: mole robot apps plan <app_path> <bundle_id> [app_name]
    exec "$SCRIPT_DIR/bin/uninstall.sh" --robot-plan "$@"
}

run_apps_apply() {
    # Same generic plan/apply machinery as clean apply: plan-file lookup,
    # exists -> should_protect_path -> is_whitelisted -> mole_delete (Trash),
    # graceful SIGTERM cancel. Only the oplog attribution differs.
    local plan_id=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --plan)
                shift
                plan_id="${1:-}"
                ;;
            *)
                robot_emit_error "E_INTERNAL" "unknown apply option: $1" "true"
                exit 2
                ;;
        esac
        shift
    done

    if [[ -z "$plan_id" ]]; then
        robot_emit_error "E_PLAN_NOT_FOUND" "missing --plan <plan_id>" "true"
        exit 2
    fi

    export MOLE_DELETE_MODE="${MOLE_DELETE_MODE:-trash}"
    export MOLE_CURRENT_COMMAND="uninstall"
    # 与 plan 阶段同一套保护策略（CLI batch 流程同款）：apply 复检时
    # 数据保护类应用的自身数据允许随卸载移除，系统关键项仍受保护。
    export MOLE_UNINSTALL_MODE=1

    # shellcheck source=lib/core/common.sh
    source "$SCRIPT_DIR/lib/core/common.sh"
    # shellcheck source=lib/manage/whitelist.sh
    source "$SCRIPT_DIR/lib/manage/whitelist.sh"
    load_whitelist "clean"

    robot_clean_apply "$plan_id"
}

run_history_list() {
    local limit=20 deletions=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --limit)
                shift
                limit="${1:-20}"
                ;;
            --deletions) deletions=1 ;;
            *)
                robot_emit_error "E_INTERNAL" "unknown history option: $1" "true"
                exit 2
                ;;
        esac
        shift
    done

    if [[ $deletions -eq 1 ]]; then
        robot_history_deletions "${MOLE_DELETE_LOG:-$HOME/Library/Logs/mole/deletions.log}" "$limit"
    else
        robot_history_sessions "${MOLE_OPERATIONS_LOG:-$HOME/Library/Logs/mole/operations.log}" "$limit"
    fi
}

run_whitelist() {
    local verb="$1" mode="" pattern=""
    shift
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --mode)
                shift
                mode="${1:-}"
                ;;
            *) pattern="$1" ;;
        esac
        shift
    done
    [[ -n "$mode" ]] || mode="clean"

    # shellcheck source=lib/core/common.sh
    source "$SCRIPT_DIR/lib/core/common.sh"
    # shellcheck source=lib/manage/whitelist.sh
    source "$SCRIPT_DIR/lib/manage/whitelist.sh"

    robot_whitelist_cmd "$verb" "$mode" "$pattern"
}

main() {
    [[ $# -ge 2 ]] || robot_usage
    local domain="$1" verb="$2"
    shift 2

    case "$domain/$verb" in
        clean/plan) run_clean_plan "$@" ;;
        clean/apply) run_clean_apply "$@" ;;
        apps/list) run_apps_list ;;
        apps/plan) run_apps_plan "$@" ;;
        apps/apply) run_apps_apply "$@" ;;
        history/list) run_history_list "$@" ;;
        whitelist/list | whitelist/add | whitelist/remove) run_whitelist "$verb" "$@" ;;
        *)
            robot_emit_error "E_INTERNAL" "unsupported command: $domain $verb" "true"
            exit 2
            ;;
    esac
}

main "$@"
