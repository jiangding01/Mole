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
  clean apply --plan <plan_id>   (item ids on stdin, one per line)
EOF
    exit 2
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
        # file; its human-facing stdout is not part of the protocol.
        if [[ -n "$external" ]]; then
            MOLE_TEST_NO_AUTH="${MOLE_TEST_NO_AUTH:-1}" "$SCRIPT_DIR/bin/clean.sh" --dry-run --external "$external" > /dev/null 2>&2
        else
            MOLE_TEST_NO_AUTH="${MOLE_TEST_NO_AUTH:-1}" "$SCRIPT_DIR/bin/clean.sh" --dry-run > /dev/null 2>&2
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

    # Deletion chain dependencies (mole_delete / should_protect_path /
    # is_whitelisted) come from the shared core libs.
    # shellcheck source=lib/core/common.sh
    source "$SCRIPT_DIR/lib/core/common.sh"

    robot_clean_apply "$plan_id"
}

main() {
    [[ $# -ge 2 ]] || robot_usage
    local domain="$1" verb="$2"
    shift 2

    case "$domain/$verb" in
        clean/plan) run_clean_plan "$@" ;;
        clean/apply) run_clean_apply "$@" ;;
        *)
            robot_emit_error "E_INTERNAL" "unsupported command: $domain $verb" "true"
            exit 2
            ;;
    esac
}

main "$@"
