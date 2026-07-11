#!/bin/bash
# Mole - App update detection & delegation (robot domain: apps updates / apps update).
# Spec: docs/MAC_APP_DESIGN.md §5.2.2. Sourced by bin/robot.sh; emits protocol
# v1 NDJSON via lib/core/robot.sh helpers (must already be sourced).
#
# HARD RED LINE (§5.2.2, CLAUDE.md): Mole NEVER downloads, unpacks, replaces or
# patches a .app bundle. "Update" == pure delegation to the app's own trusted
# updater. v1 supports the single most reliable source only: Homebrew casks,
# delegated to `brew upgrade --cask`. Sparkle / App Store / Electron land in
# v1.2+; until then we stay honest (§5.2.2 "降级诚实"): sources we cannot detect
# reliably are simply not listed, never reported as "up to date".

# Prevent multiple sourcing.
if [[ -n "${MOLE_UPDATES_LOADED:-}" ]]; then
    return 0
fi
readonly MOLE_UPDATES_LOADED=1

# --- detection --------------------------------------------------------------
# We parse `brew outdated --cask --verbose`, whose line format is stable and
# documented: "<token> (<installed>[, <installed>...]) != <latest>". This is the
# same text-parsing style lib/uninstall/brew.sh already uses for brew output,
# and avoids a JSON parser dependency on bash 3.2. Display name degrades to the
# cask token (§5.2.2 permits the token fallback); a version string never
# contains " · ", so the App-side detail parser is unambiguous.

_updates_brew_available() {
    local b
    b=$(command -v brew 2> /dev/null) || return 1
    [[ -n "$b" ]] || return 1
    # Under test/no-auth the *real* brew must never run (CLAUDE.md: mocked brew
    # only, zero real upgrades in verification). A PATH stub (tests) resolves
    # outside the standard install prefixes and is allowed through — same guard
    # shape as the osascript/launchctl guards in lib/optimize/launch_items.sh.
    if [[ "${MOLE_TEST_MODE:-0}" == "1" || "${MOLE_TEST_NO_AUTH:-0}" == "1" ]]; then
        case "$b" in
            /opt/homebrew/* | /usr/local/* | /home/linuxbrew/*) return 1 ;;
        esac
    fi
    return 0
}

# Cask tokens are lowercase alnum plus a small punctuation set and never start
# with "-": anything else could be smuggled to brew as a flag (`cask:--greedy`
# would otherwise upgrade every installed cask). Same charset stance as
# _extract_cask_token_from_path in lib/uninstall/brew.sh, extended for @/./+.
_updates_token_valid() {
    [[ "$1" =~ ^[a-z0-9][a-z0-9@._+-]*$ ]]
}

# apps updates list: emit one item per outdated cask, then a done summary.
# Degrades honestly: no brew, or a failed/empty `brew outdated`, both yield a
# clean "done, 0 items" instead of an error that would abort the stream.
updates_list() {
    if ! _updates_brew_available; then
        robot_emit_done "true" "" "\"items\":0"
        return 0
    fi

    local out rc=0
    out=$(HOMEBREW_NO_ENV_HINTS=1 HOMEBREW_NO_AUTO_UPDATE=1 \
        brew outdated --cask --verbose 2> /dev/null) || rc=$?
    if [[ $rc -ne 0 ]]; then
        robot_emit_done "true" "" "\"items\":0"
        return 0
    fi

    local count=0 line token installed latest
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        # Only lines carrying the "!= <latest>" marker are version-diff rows.
        case "$line" in
            *" != "*) ;;
            *) continue ;;
        esac
        token="${line%% *}"
        [[ -n "$token" ]] || continue
        latest="${line##* != }"
        # Installed version(s) live inside the first parentheses; take the last
        # comma-separated entry (most recent installed) when several are kept.
        installed="${line#*(}"
        installed="${installed%%) != *}"
        installed="${installed##*, }"
        [[ -n "$installed" ]] || installed="?"
        [[ -n "$latest" ]] || latest="?"

        robot_emit_item "cask:$token" "updates" "$token" "" 0 "safe" "true" \
            "brew-cask · $installed · $latest"
        count=$((count + 1))
    done <<< "$out"

    robot_emit_done "true" "" "\"items\":$count"
}

# --- delegation -------------------------------------------------------------
# apps update --id cask:<token>: delegate to `brew upgrade --cask <token>`.
# brew (not Mole) performs the actual bundle replacement, exactly as if the user
# typed the command. Non-cask ids are refused with E_UNSUPPORTED: the App routes
# those to App Store / the app's own updater. There is no code path here that
# touches a .app bundle directly.
updates_update() {
    local id="$1"

    case "$id" in
        cask:*) ;;
        *)
            robot_emit_error "E_UNSUPPORTED" \
                "only Homebrew casks update inside Mole; use App Store or the app's own updater" "false"
            robot_emit_done "false" "" "\"items\":0,\"failed\":1"
            return 0
            ;;
    esac

    local token="${id#cask:}"
    if ! _updates_token_valid "$token"; then
        # Flag-injection guard: a token like "--greedy" must never reach brew
        # as an option. Refuse before any brew invocation.
        robot_emit_error "E_UNSUPPORTED" "invalid cask token" "false"
        robot_emit_done "false" "" "\"items\":0,\"failed\":1"
        return 0
    fi

    # Dry-run: preview-first Homebrew contract — report, never invoke brew.
    if [[ "${MOLE_DRY_RUN:-0}" == "1" ]]; then
        robot_emit_task_status "$id" "skipped" "dry_run"
        robot_emit_done "true" "" "\"items\":1,\"failed\":0,\"skipped\":1"
        return 0
    fi

    if ! _updates_brew_available; then
        robot_emit_task_status "$id" "failed" "Homebrew not available"
        robot_emit_done "true" "" "\"items\":1,\"failed\":1"
        return 0
    fi

    robot_emit_task_status "$id" "running" ""

    local err rc=0
    # Delegate verbatim to brew; NONINTERACTIVE keeps it prompt-free. brew is
    # PATH-stubbed in tests (run_with_timeout is deliberately avoided so a
    # function/PATH stub is honored — real brew never runs under test).
    err=$(HOMEBREW_NO_ENV_HINTS=1 HOMEBREW_NO_AUTO_UPDATE=1 NONINTERACTIVE=1 \
        brew upgrade --cask "$token" 2>&1) || rc=$?

    if [[ $rc -eq 0 ]]; then
        robot_emit_task_status "$id" "done" ""
        robot_emit_done "true" "" "\"items\":1,\"failed\":0"
    else
        local summary
        # `|| summary=""`: with empty brew output, grep -v exits 1 and pipefail
        # would otherwise kill the whole router under set -e, swallowing the
        # failed/done events entirely.
        summary=$(printf '%s' "$err" | tr -d '\r' | grep -v '^[[:space:]]*$' | tail -1) || summary=""
        [[ -n "$summary" ]] || summary="brew upgrade failed (exit $rc)"
        robot_emit_task_status "$id" "failed" "$summary"
        robot_emit_done "true" "" "\"items\":1,\"failed\":1"
    fi
}
