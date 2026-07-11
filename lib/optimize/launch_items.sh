#!/bin/bash
# Mole - Login items & background service management (robot domain: launchitems).
# Spec: docs/MAC_APP_DESIGN.md §5.2.3. Sourced by bin/robot.sh; emits protocol
# v1 NDJSON via lib/core/robot.sh helpers (must already be sourced).
#
# Three read-only groups on `list`: login items (user), user LaunchAgents, and
# system LaunchAgents / LaunchDaemons (display only). Mutations (disable/enable)
# are user-level ONLY and REVERSIBLE: never a delete. A disabled user agent is
# launchctl-booted-out and its plist is MOVED (never rm) into a quarantine dir
# recorded in index.tsv; enable moves it back and bootstraps it again. System
# items and any com.apple.* label are read-only and refuse mutation.
#
# plist parsing follows the CLAUDE.md contract: Program / ProgramArguments are
# accepted only as absolute paths; plutil error text ("Does Not Exist", ...) is
# never treated as data; unreadable root plists are skipped, never escalated
# into an interactive auth prompt.
#
# Enumeration roots and the quarantine dir are overridable for tests (CI has no
# writable /Library); the defaults are the real macOS locations.

# Prevent multiple sourcing.
if [[ -n "${MOLE_LAUNCHITEMS_LOADED:-}" ]]; then
    return 0
fi
readonly MOLE_LAUNCHITEMS_LOADED=1

_li_user_agents_dir() { printf '%s' "${MOLE_LAUNCHITEMS_USER_AGENTS_DIR:-$HOME/Library/LaunchAgents}"; }
_li_sys_agents_dir() { printf '%s' "${MOLE_LAUNCHITEMS_SYS_AGENTS_DIR:-/Library/LaunchAgents}"; }
_li_sys_daemons_dir() { printf '%s' "${MOLE_LAUNCHITEMS_SYS_DAEMONS_DIR:-/Library/LaunchDaemons}"; }
_li_quarantine_dir() { printf '%s' "${MOLE_QUARANTINE_DIR:-$HOME/Library/Application Support/Mole/Quarantine/launchitems}"; }

# --- plist readers (safe: absolute-path only, error text rejected) ----------

# Read the Label key; degrade to the filename stem. plutil returns nonzero and
# prints error text to stderr (discarded) on a missing key, so $label stays
# empty; the case guard is belt-and-suspenders against error text leaking in.
_li_plist_label() {
    local f="$1" label
    label=$(plutil -extract Label raw "$f" 2> /dev/null) || label=""
    case "$label" in
        *"Does Not Exist"* | *"error"* | *"No value"* | "") label="" ;;
    esac
    if [[ -z "$label" ]]; then
        label=$(basename "$f")
        label="${label%.plist}"
    fi
    printf '%s' "$label"
}

# Best-effort absolute program path (Program, else ProgramArguments[0]).
# Relative values are rejected: a launchd program path is always absolute.
_li_plist_program() {
    local f="$1" p
    p=$(plutil -extract Program raw "$f" 2> /dev/null) || p=""
    if [[ -z "$p" ]]; then
        p=$(plutil -extract ProgramArguments.0 raw "$f" 2> /dev/null) || p=""
    fi
    case "$p" in
        *"Does Not Exist"* | *"error"* | *"No value"*) p="" ;;
    esac
    case "$p" in
        /*) printf '%s' "$p" ;;
        *) printf '' ;;
    esac
}

# Owning app display name derived from an absolute program path (X.app -> X).
_li_owner_app() {
    local prog="$1" name=""
    case "$prog" in
        *.app/*)
            name="${prog%%.app/*}"
            name="${name##*/}"
            ;;
    esac
    printf '%s' "$name"
}

# --- disabled-state map (read-only) -----------------------------------------
# `launchctl print-disabled gui/<uid>` prints:
#     "com.example.foo" => true
# where true means DISABLED. Returns "<label>\t<true|false>" lines. launchctl is
# PATH-stubbed in tests; a real read here needs no auth and is tolerated to fail.
_li_user_disabled_map() {
    local uid
    uid=$(id -u)
    launchctl print-disabled "gui/$uid" 2> /dev/null | awk -F'"' '
        /=>/ && NF >= 2 {
            label = $2
            state = ($0 ~ /true/) ? "true" : "false"
            print label "\t" state
        }
    ' || true
}

_li_label_disabled() {
    local label="$1" map="$2"
    case $'\n'"$map"$'\n' in
        *$'\n'"$label"$'\t'"true"$'\n'*) return 0 ;;
    esac
    return 1
}

# --- login items snapshot (osascript, read-only) ----------------------------
# Same System Events call as _login_items_snapshot in lib/optimize/tasks.sh.
# Under test/no-auth we skip the *system* osascript to avoid a TCC automation
# prompt (honoring "never trigger interactive authorization"); a PATH stub in
# tests points `osascript` into the stub dir, so tests still exercise this path.
# Output: "<name>\t<path>" lines.
_li_login_snapshot() {
    if [[ "${MOLE_TEST_MODE:-0}" == "1" || "${MOLE_TEST_NO_AUTH:-0}" == "1" ]]; then
        local oscmd
        oscmd=$(command -v osascript 2> /dev/null || echo "")
        case "$oscmd" in
            /usr/bin/osascript | /System/* | "") return 0 ;;
        esac
    fi
    osascript << 'APPLESCRIPT' 2> /dev/null || true
set oldDelimiters to AppleScript's text item delimiters
set tabChar to ASCII character 9
set linefeedChar to ASCII character 10
set outputLines to {}
tell application "System Events"
    repeat with loginItem in login items
        set itemName to ""
        set itemPath to ""
        try
            set itemName to name of loginItem as text
        end try
        try
            set itemPath to POSIX path of (path of loginItem as alias)
        on error
            try
                set itemPath to path of loginItem as text
            end try
        end try
        set end of outputLines to itemName & tabChar & itemPath
    end repeat
end tell
set AppleScript's text item delimiters to linefeedChar
set outputText to outputLines as text
set AppleScript's text item delimiters to oldDelimiters
return outputText
APPLESCRIPT
}

# Look up the current path of a named login item (used before removing it, so
# enable can re-add it later). Empty on failure.
_li_login_item_path() {
    local name="$1" line
    while IFS=$'\t' read -r iname ipath; do
        [[ "$iname" == "$name" ]] || continue
        printf '%s' "$ipath"
        return 0
    done < <(_li_login_snapshot)
    printf ''
}

# --- list -------------------------------------------------------------------
# detail = "<type> · <enabled> · <sys> · <owner_app_or_->" per §5.2.3.
#   type    login | agent | daemon
#   enabled true  | false
#   sys     true  | false   (any /Library item or com.apple.* label is sys)
_li_is_sys_label() {
    case "$1" in
        com.apple.*) return 0 ;;
        *) return 1 ;;
    esac
}

_li_emit_row() {
    # $1 id, $2 label(display), $3 path, $4 type, $5 enabled, $6 sys, $7 owner
    local owner="${7:-}"
    [[ -n "$owner" ]] || owner="-"
    robot_emit_item "$1" "launchitems" "$2" "$3" 0 "safe" "false" \
        "$4 · $5 · $6 · $owner"
}

launchitems_list() {
    local user_dir sys_agents sys_daemons quarantine
    user_dir=$(_li_user_agents_dir)
    sys_agents=$(_li_sys_agents_dir)
    sys_daemons=$(_li_sys_daemons_dir)
    quarantine=$(_li_quarantine_dir)

    local count=0 disabled_map
    disabled_map=$(_li_user_disabled_map)

    # 1) Login items (user, always shown as enabled).
    local iname ipath owner
    while IFS=$'\t' read -r iname ipath; do
        [[ -n "$iname" ]] || continue
        owner=""
        case "$ipath" in
            *.app*)
                owner="${ipath%%.app*}"
                owner="${owner##*/}"
                ;;
        esac
        _li_emit_row "login:$iname" "$iname" "$ipath" "login" "true" "false" "$owner"
        count=$((count + 1))
    done < <(_li_login_snapshot)

    # 2) User LaunchAgents (mutable). enabled = not in the disabled map.
    local f label prog owner sys enabled
    if [[ -d "$user_dir" ]]; then
        for f in "$user_dir"/*.plist; do
            [[ -e "$f" ]] || continue
            label=$(_li_plist_label "$f")
            prog=$(_li_plist_program "$f")
            owner=$(_li_owner_app "$prog")
            if _li_is_sys_label "$label"; then sys="true"; else sys="false"; fi
            if _li_label_disabled "$label" "$disabled_map"; then enabled="false"; else enabled="true"; fi
            _li_emit_row "agent:$label" "$label" "$f" "agent" "$enabled" "$sys" "$owner"
            count=$((count + 1))
        done
    fi

    # 3) System LaunchAgents (read-only display).
    if [[ -d "$sys_agents" ]]; then
        for f in "$sys_agents"/*.plist; do
            [[ -e "$f" ]] || continue
            label=$(_li_plist_label "$f")
            prog=$(_li_plist_program "$f")
            owner=$(_li_owner_app "$prog")
            _li_emit_row "agent-sys:$label" "$label" "$f" "agent" "true" "true" "$owner"
            count=$((count + 1))
        done
    fi

    # 4) System LaunchDaemons (read-only display).
    if [[ -d "$sys_daemons" ]]; then
        for f in "$sys_daemons"/*.plist; do
            [[ -e "$f" ]] || continue
            label=$(_li_plist_label "$f")
            prog=$(_li_plist_program "$f")
            owner=$(_li_owner_app "$prog")
            _li_emit_row "daemon:$label" "$label" "$f" "daemon" "true" "true" "$owner"
            count=$((count + 1))
        done
    fi

    # 5) Quarantined (already disabled) user items still belong in the list so
    #    the GUI can offer "enable". They were moved out of their live dir, so
    #    there is no duplicate. Reconstruct type from the recorded id prefix.
    if [[ -f "$quarantine/index.tsv" ]]; then
        local qid qpath qts qtype qlabel
        while IFS=$'\t' read -r qid qpath qts; do
            [[ -n "$qid" ]] || continue
            qlabel="${qid#*:}"
            case "$qid" in
                login:*) qtype="login" ;;
                *) qtype="agent" ;;
            esac
            _li_emit_row "$qid" "$qlabel" "$qpath" "$qtype" "false" "false" ""
            count=$((count + 1))
        done < "$quarantine/index.tsv"
    fi

    robot_emit_done "true" "" "\"items\":$count"
}

# --- quarantine index (TSV: <id>\t<original_path>\t<iso_ts>) -----------------

_li_index_append() {
    local q="$1" id="$2" path="$3" ts
    # A tab or newline in the recorded path would corrupt the TSV (and could
    # smuggle extra index rows). Refuse; the caller reports failed.
    case "$path" in
        *$'\t'* | *$'\n'*) return 1 ;;
    esac
    case "$id" in
        *$'\t'* | *$'\n'*) return 1 ;;
    esac
    ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2> /dev/null || date '+%Y-%m-%dT%H:%M:%S')
    mkdir -p "$q"
    printf '%s\t%s\t%s\n' "$id" "$path" "$ts" >> "$q/index.tsv"
}

_li_index_lookup() {
    local q="$1" id="$2"
    [[ -f "$q/index.tsv" ]] || return 1
    awk -F'\t' -v id="$id" '$1 == id {print $2; exit}' "$q/index.tsv"
}

_li_index_remove() {
    local q="$1" id="$2" tmp
    [[ -f "$q/index.tsv" ]] || return 0
    tmp="$q/index.tsv.tmp.$$"
    awk -F'\t' -v id="$id" '$1 != id {print}' "$q/index.tsv" > "$tmp" 2> /dev/null || return 1
    mv "$tmp" "$q/index.tsv"
}

# --- oplog (reversible action, never a delete) ------------------------------
# Reuse the shared operation logger when present (sourced via common.sh in the
# router). log_operation only honors MO_NO_OPLOG; dry-run short-circuits in
# _li_toggle before any mutation (and before this logger) is reached.
_li_oplog() {
    local op="$1" id="$2" path="$3" action
    if [[ "$op" == "disable" ]]; then action="DISABLED"; else action="ENABLED"; fi
    if declare -f log_operation > /dev/null 2>&1; then
        log_operation "optimize" "$action" "$path" "$id"
    fi
}

# --- launchctl wrappers (PATH-stubbed in tests; real calls are user-scope) ---
# Under test/no-auth the *system* launchctl must never mutate real services
# (same guard shape as _li_osascript_*): if launchctl resolves to a system
# binary, skip the call; a PATH stub (tests) is allowed through.
_li_launchctl_blocked() {
    if [[ "${MOLE_TEST_MODE:-0}" == "1" || "${MOLE_TEST_NO_AUTH:-0}" == "1" ]]; then
        local lc
        lc=$(command -v launchctl 2> /dev/null || echo "")
        case "$lc" in
            /bin/launchctl | /usr/bin/launchctl | /sbin/* | /usr/sbin/* | /System/* | "") return 0 ;;
        esac
    fi
    return 1
}

_li_bootout() {
    local label="$1" uid
    _li_launchctl_blocked && return 0
    uid=$(id -u)
    launchctl bootout "gui/$uid/$label" 2> /dev/null || return 1
}

_li_bootstrap() {
    local plist="$1" uid
    _li_launchctl_blocked && return 0
    uid=$(id -u)
    launchctl bootstrap "gui/$uid" "$plist" 2> /dev/null || return 1
}

# --- system-guard -----------------------------------------------------------
# Reject anything that is not an explicitly user-level id, and any com.apple.*
# label regardless of prefix.
_li_is_system_id() {
    case "$1" in
        agent-sys:* | daemon:*) return 0 ;;
    esac
    local label="${1#*:}"
    _li_is_sys_label "$label"
}

# Label whitelist (ids arrive raw on stdin). Rejects path traversal outright:
# no "/", no "..", no tab/newline, no leading "-". Agent labels are launchd
# labels and additionally restricted to a strict charset; login item names may
# contain spaces (they are display names) but are only ever passed as argv to
# osascript, never interpolated into script text.
_li_label_valid() {
    local kind="$1" label="$2"
    [[ -n "$label" ]] || return 1
    case "$label" in
        */* | *..* | *$'\t'* | *$'\n'* | -*) return 1 ;;
    esac
    if [[ "$kind" == "agent" ]]; then
        [[ "$label" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
    fi
    return 0
}

# Resolve the live plist for a user-agent label (filename == label by default,
# else scan the dir for a matching Label key).
_li_find_agent_plist() {
    local dir="$1" label="$2" f flabel
    if [[ -f "$dir/$label.plist" ]]; then
        printf '%s' "$dir/$label.plist"
        return 0
    fi
    [[ -d "$dir" ]] || return 1
    for f in "$dir"/*.plist; do
        [[ -e "$f" ]] || continue
        flabel=$(_li_plist_label "$f")
        if [[ "$flabel" == "$label" ]]; then
            printf '%s' "$f"
            return 0
        fi
    done
    return 1
}

# --- disable / enable (user-level, reversible) ------------------------------

_li_disable_agent() {
    local label="$1" dir="$2" q="$3" plist dest
    plist=$(_li_find_agent_plist "$dir" "$label") || plist=""
    if [[ -z "$plist" || ! -f "$plist" ]]; then
        printf 'skipped_missing'
        return 0
    fi
    # Containment: the resolved plist must live inside the user agents dir.
    # Belt-and-suspenders with _li_label_valid; a traversal-shaped label can
    # never move a file from anywhere else.
    case "$plist" in
        "$dir"/*) ;;
        *)
            printf 'failed'
            return 0
            ;;
    esac
    # A tab/newline in the path would corrupt index.tsv; refuse BEFORE the mv
    # so we never strand a moved file without an index row.
    case "$plist" in
        *$'\t'* | *$'\n'*)
            printf 'failed'
            return 0
            ;;
    esac
    if declare -f should_protect_path > /dev/null 2>&1 && should_protect_path "$plist"; then
        printf 'skipped_protected'
        return 0
    fi
    _li_bootout "$label" || true # bootout failure is non-fatal
    mkdir -p "$q"
    dest="$q/$label.plist"
    if [[ -e "$dest" ]]; then
        # Never overwrite an existing quarantined file.
        printf 'failed'
        return 0
    fi
    if mv "$plist" "$dest" 2> /dev/null; then
        _li_index_append "$q" "agent:$label" "$plist" || true # pre-validated above
        _li_oplog disable "agent:$label" "$plist"
        printf 'disabled'
    else
        printf 'failed'
    fi
}

_li_enable_agent() {
    local label="$1" dir="$2" q="$3" src orig dest
    src="$q/$label.plist"
    if [[ ! -f "$src" ]]; then
        printf 'skipped_missing'
        return 0
    fi
    orig=$(_li_index_lookup "$q" "agent:$label") || orig=""
    dest="${orig:-$dir/$label.plist}"
    # Containment: restore only into the user agents dir, even if index.tsv
    # was tampered with. Original paths are inside $dir by construction.
    case "$dest" in
        "$dir"/*) ;;
        *)
            printf 'failed'
            return 0
            ;;
    esac
    if declare -f should_protect_path > /dev/null 2>&1 && should_protect_path "$dest"; then
        printf 'failed'
        return 0
    fi
    if [[ -e "$dest" ]]; then
        # Never overwrite an existing live file.
        printf 'failed'
        return 0
    fi
    mkdir -p "$(dirname "$dest")"
    if mv "$src" "$dest" 2> /dev/null; then
        _li_bootstrap "$dest" || true # bootstrap failure is non-fatal
        _li_index_remove "$q" "agent:$label"
        _li_oplog enable "agent:$label" "$dest"
        printf 'enabled'
    else
        printf 'failed'
    fi
}

_li_osascript_remove_login() {
    local name="$1"
    if [[ "${MOLE_TEST_MODE:-0}" == "1" || "${MOLE_TEST_NO_AUTH:-0}" == "1" ]]; then
        local oscmd
        oscmd=$(command -v osascript 2> /dev/null || echo "")
        case "$oscmd" in
            /usr/bin/osascript | /System/* | "") return 1 ;;
        esac
    fi
    # argv passing (on run argv): the name reaches AppleScript as a literal
    # argument, never interpolated into script text — a name containing quotes
    # or `& do shell script ...` cannot escape into code.
    osascript \
        -e 'on run argv' \
        -e 'tell application "System Events" to delete login item (item 1 of argv)' \
        -e 'end run' \
        "$name" > /dev/null 2>&1
}

_li_osascript_add_login() {
    local path="$1"
    [[ -n "$path" ]] || return 1
    if [[ "${MOLE_TEST_MODE:-0}" == "1" || "${MOLE_TEST_NO_AUTH:-0}" == "1" ]]; then
        local oscmd
        oscmd=$(command -v osascript 2> /dev/null || echo "")
        case "$oscmd" in
            /usr/bin/osascript | /System/* | "") return 1 ;;
        esac
    fi
    # argv passing, same rationale as _li_osascript_remove_login: the path
    # (read back from index.tsv) is data, never script text.
    osascript \
        -e 'on run argv' \
        -e 'tell application "System Events" to make login item at end with properties {path:(item 1 of argv), hidden:false}' \
        -e 'end run' \
        "$path" > /dev/null 2>&1
}

_li_disable_login() {
    local name="$1" q="$2" path record
    path=$(_li_login_item_path "$name")
    record="${path:-$name}"
    # Validate the index row BEFORE removing the login item, so a failure can
    # never leave the item removed but unrecorded (unrestorable).
    case "$record" in
        *$'\t'* | *$'\n'*)
            printf 'failed'
            return 0
            ;;
    esac
    if ! _li_osascript_remove_login "$name"; then
        printf 'failed'
        return 0
    fi
    _li_index_append "$q" "login:$name" "$record" || true # pre-validated above
    _li_oplog disable "login:$name" "$record"
    printf 'disabled'
}

_li_enable_login() {
    local name="$1" q="$2" path
    path=$(_li_index_lookup "$q" "login:$name") || path=""
    if [[ -z "$path" ]]; then
        printf 'failed'
        return 0
    fi
    if ! _li_osascript_add_login "$path"; then
        printf 'failed'
        return 0
    fi
    _li_index_remove "$q" "login:$name"
    _li_oplog enable "login:$name" "$path"
    printf 'enabled'
}

# Dispatch one id through disable/enable. Always prints a status and returns 0
# (callers capture the status via $(...); a nonzero return would trip set -e).
_li_toggle() {
    local op="$1" id="$2" dir="$3" q="$4" label
    if _li_is_system_id "$id"; then
        printf 'skipped_system'
        return 0
    fi
    label="${id#*:}"
    # Whitelist charset validation (path traversal / injection guard) before
    # anything touches the filesystem or a subprocess.
    case "$id" in
        agent:*)
            if ! _li_label_valid "agent" "$label"; then
                printf 'failed'
                return 0
            fi
            ;;
        login:*)
            if ! _li_label_valid "login" "$label"; then
                printf 'failed'
                return 0
            fi
            ;;
    esac
    # Dry-run: report without mutating (same contract as robot_clean_apply).
    if [[ "${MOLE_DRY_RUN:-0}" == "1" ]]; then
        printf 'dry_run'
        return 0
    fi
    case "$id" in
        agent:*)
            if [[ "$op" == "disable" ]]; then
                _li_disable_agent "$label" "$dir" "$q"
            else
                _li_enable_agent "$label" "$dir" "$q"
            fi
            ;;
        login:*)
            if [[ "$op" == "disable" ]]; then
                _li_disable_login "$label" "$q"
            else
                _li_enable_login "$label" "$q"
            fi
            ;;
        *)
            printf 'failed'
            ;;
    esac
    return 0
}

# ids one per line on stdin (bash 3.2 wire convention, no JSON parsing).
_li_apply() {
    local op="$1" dir q id status
    dir=$(_li_user_agents_dir)
    q=$(_li_quarantine_dir)
    local ok=0 skipped=0 failed=0
    while IFS= read -r id; do
        [[ -n "$id" ]] || continue
        status=$(_li_toggle "$op" "$id" "$dir" "$q")
        case "$status" in
            disabled | enabled) ok=$((ok + 1)) ;;
            skipped_system | skipped_missing | skipped_protected | dry_run) skipped=$((skipped + 1)) ;;
            *) failed=$((failed + 1)) ;;
        esac
        robot_emit_result "$id" "$status" 0
    done
    robot_emit_done "true" "" "\"items\":$((ok + skipped + failed)),\"failed\":$failed,\"skipped\":$skipped"
}

launchitems_disable() { _li_apply "disable"; }
launchitems_enable() { _li_apply "enable"; }
