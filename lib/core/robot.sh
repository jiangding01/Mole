#!/bin/bash
# Mole - Robot protocol core (machine-readable command layer for the GUI).
# Spec: docs/MAC_APP_DESIGN.md §4 (Robot Protocol v1).
# Emits NDJSON events on stdout; manages plan files (id -> path mapping)
# so destructive apply calls never receive raw paths from the GUI.
#
# This file is dependency-free at source time (pure bash + coreutils) so it
# can be unit-tested on any platform. Runtime deletion helpers (mole_delete,
# should_protect_path, is_whitelisted) are resolved at call time and must be
# provided by lib/core/file_ops.sh / whitelist.sh (or test stubs).

# Protocol version (§4.3): bump only with a documented schema change.
ROBOT_PROTOCOL_VERSION=1

# Plan files live outside the oplog dir; override for tests.
ROBOT_PLAN_DIR="${MOLE_ROBOT_PLAN_DIR:-$HOME/.cache/mole/robot}"
# Plan TTL in seconds (§4.3: 30 minutes). Override for tests.
ROBOT_PLAN_TTL="${MOLE_ROBOT_PLAN_TTL:-1800}"

robot_active() {
    [[ "${MOLE_ROBOT:-0}" == "1" ]]
}

# --- JSON helpers -----------------------------------------------------------

# Escape a string for embedding in a JSON string literal.
# Handles backslash, double quote, newline, tab, CR. Paths containing other
# control bytes are rejected at collect time (robot_plan_append).
#
# Two forms: `_robot_escape_to_var` writes the result into the global
# ROBOT_ESCAPED (bash 3.2 has no namerefs) so hot emit paths avoid one
# subshell fork per field — a 1650-item plan used to pay ~10k command
# substitutions in its emission tail. `robot_json_escape` stays as the
# stdout wrapper for cold call sites and tests.
ROBOT_ESCAPED=""
_robot_escape_to_var() {
    local s="$1"
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    s=${s//$'\n'/\\n}
    s=${s//$'\t'/\\t}
    s=${s//$'\r'/\\r}
    ROBOT_ESCAPED="$s"
}

robot_json_escape() {
    _robot_escape_to_var "$1"
    printf '%s' "$ROBOT_ESCAPED"
}

# Emit one NDJSON event line. Callers pass pre-built JSON body fragments
# (without the version/event envelope).
robot_emit() {
    local event="$1" body="${2:-}"
    if [[ -n "$body" ]]; then
        printf '{"v":%s,"event":"%s",%s}\n' "$ROBOT_PROTOCOL_VERSION" "$event" "$body"
    else
        printf '{"v":%s,"event":"%s"}\n' "$ROBOT_PROTOCOL_VERSION" "$event"
    fi
}

robot_emit_progress() {
    # $1 phase, $2 section, $3 current, $4 done, $5 total, $6 bytes_found
    local e_phase e_section e_current
    _robot_escape_to_var "$1"
    e_phase="$ROBOT_ESCAPED"
    _robot_escape_to_var "$2"
    e_section="$ROBOT_ESCAPED"
    _robot_escape_to_var "$3"
    e_current="$ROBOT_ESCAPED"
    robot_emit "progress" "\"phase\":\"$e_phase\",\"section\":\"$e_section\",\"current\":\"$e_current\",\"done\":${4:-0},\"total\":${5:--1},\"bytes_found\":${6:-0}"
}

robot_emit_item() {
    # $1 id, $2 section, $3 label, $4 path, $5 bytes, $6 risk, $7 default_selected,
    # $8 detail (optional; task 说明等，GUI 未知 id 时的回退文案)
    local e_id e_section e_label e_path body
    _robot_escape_to_var "$1"
    e_id="$ROBOT_ESCAPED"
    _robot_escape_to_var "$2"
    e_section="$ROBOT_ESCAPED"
    _robot_escape_to_var "$3"
    e_label="$ROBOT_ESCAPED"
    _robot_escape_to_var "$4"
    e_path="$ROBOT_ESCAPED"
    body="\"id\":\"$e_id\",\"section\":\"$e_section\",\"label\":\"$e_label\",\"path\":\"$e_path\",\"bytes\":${5:-0},\"kind\":\"cache\",\"reversible\":true,\"default_selected\":${7:-true},\"risk\":\"${6:-safe}\""
    if [[ -n "${8:-}" ]]; then
        _robot_escape_to_var "$8"
        body="$body,\"detail\":\"$ROBOT_ESCAPED\""
    fi
    robot_emit "item" "$body"
}

robot_emit_task_status() {
    # $1 task_id, $2 status(pending/running/done/skipped/failed/needs_admin),
    # $3 detail (may be empty), $4 duration_ms (may be empty)
    local body
    body=$(printf '"task_id":"%s","status":"%s"' \
        "$(robot_json_escape "$1")" "$(robot_json_escape "$2")")
    [[ -n "${3:-}" ]] && body="$body,\"detail\":\"$(robot_json_escape "$3")\""
    [[ -n "${4:-}" ]] && body="$body,\"duration_ms\":$4"
    robot_emit "task_status" "$body"
}

robot_emit_insight() {
    # $1 section, $2 label, $3 bytes
    local e_section e_label
    _robot_escape_to_var "$1"
    e_section="$ROBOT_ESCAPED"
    _robot_escape_to_var "$2"
    e_label="$ROBOT_ESCAPED"
    robot_emit "insight" "\"section\":\"$e_section\",\"label\":\"$e_label\",\"bytes\":${3:-0}"
}

robot_emit_result() {
    # $1 id, $2 status, $3 freed_bytes
    local e_id e_status
    _robot_escape_to_var "$1"
    e_id="$ROBOT_ESCAPED"
    _robot_escape_to_var "$2"
    e_status="$ROBOT_ESCAPED"
    robot_emit "result" "\"id\":\"$e_id\",\"status\":\"$e_status\",\"freed_bytes\":${3:-0}"
}

robot_emit_done() {
    # $1 ok(true/false), $2 plan_id (may be empty), $3 summary json fragment (may be empty)
    local body="\"ok\":$1"
    [[ -n "${2:-}" ]] && body="$body,\"plan_id\":\"$(robot_json_escape "$2")\""
    [[ -n "${3:-}" ]] && body="$body,\"summary\":{$3}"
    robot_emit "done" "$body"
}

robot_emit_error() {
    # $1 code, $2 message, $3 fatal(true/false)
    robot_emit "error" "$(printf '"code":"%s","message":"%s","fatal":%s' \
        "$(robot_json_escape "$1")" "$(robot_json_escape "$2")" "${3:-false}")"
}

# --- Size parsing ------------------------------------------------------------

# Convert human sizes from the dry-run export back to approximate bytes.
# bytes_to_human (lib/core/base.sh) emits compact 1000-base values with no
# space ("198.5MB", "743KB", "1.20GB", "545B"); accept spaced input too.
# Pure bash on purpose: the old sed+tr+awk pipeline cost ~6 process spawns
# per call, and the plan emission tail calls this once per item (1650 calls
# on a real scan). Fixed-point math keeps the exact truncation semantics of
# the awk version; 64-bit shell arithmetic holds through TB with 6 fraction
# digits.
robot_human_to_bytes() {
    local value="$1"
    local number="${value%%[!0-9.]*}"
    [[ -n "$number" ]] || {
        printf '0'
        return 0
    }
    local unit="${value#"$number"}"
    unit="${unit//[!A-Za-z]/}"
    local mult
    case "$unit" in
        [Bb] | "") mult=1 ;;
        [Kk][Bb]) mult=1000 ;;
        [Mm][Bb]) mult=1000000 ;;
        [Gg][Bb]) mult=1000000000 ;;
        [Tt][Bb]) mult=1000000000000 ;;
        *)
            printf '0'
            return 0
            ;;
    esac
    local int_part="${number%%.*}" frac_part=""
    [[ "$number" == *.* ]] && frac_part="${number#*.}"
    frac_part="${frac_part%%.*}"
    frac_part="${frac_part:0:6}"
    [[ -n "$int_part" ]] || int_part=0
    local total=$((10#$int_part * mult))
    if [[ -n "$frac_part" ]]; then
        local scale=1 _i
        for ((_i = 0; _i < ${#frac_part}; _i++)); do
            scale=$((scale * 10))
        done
        total=$((total + 10#$frac_part * mult / scale))
    fi
    printf '%d' "$total"
}

# Section display name -> stable machine slug (§4.3 i18n contract).
robot_section_slug() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -e 's/&/and/g' -e 's/[^a-z0-9]\{1,\}/_/g' -e 's/^_//' -e 's/_$//'
}

# Insight-only sections (report, never delete) per §2.4.
robot_section_is_insight() {
    case "$1" in
        large_files | system_data_clues) return 0 ;;
        *) return 1 ;;
    esac
}

# --- Plan files --------------------------------------------------------------
# Format (TSV, one plan per file <plan_id>.plan):
#   # mole robot plan v1
#   domain<TAB><domain>
#   created<TAB><epoch>
#   item<TAB><item_id><TAB><path><TAB><bytes><TAB><reversible>

robot_plan_file() {
    printf '%s/%s.plan' "$ROBOT_PLAN_DIR" "$1"
}

robot_plan_new() {
    local domain="$1" plan_id
    plan_id="pl_$(date +%Y%m%d%H%M%S)_$$_${RANDOM}"
    mkdir -p "$ROBOT_PLAN_DIR"
    chmod 700 "$ROBOT_PLAN_DIR" 2> /dev/null || true
    {
        printf '# mole robot plan v1\n'
        printf 'domain\t%s\n' "$domain"
        printf 'created\t%s\n' "$(date +%s)"
    } > "$(robot_plan_file "$plan_id")"
    printf '%s' "$plan_id"
}

# Stable item id: <domain-prefix>.<section>.<hash-of-path>
robot_item_id() {
    local prefix="$1" section="$2" path="$3" sum
    sum=$(printf '%s' "$path" | cksum | awk '{printf "%08x", $1}')
    printf '%s.%s.%s' "$prefix" "$section" "$sum"
}

# Batch form of the id hash: stdin one path per line, stdout one 8-hex hash
# per line. One perl process replaces three processes per path — the clean
# plan emission tail used to spend ~5k forks here on a 1650-item scan.
# Output must stay byte-identical to `cksum | awk '{printf "%08x", $1}'`
# (POSIX cksum CRC: poly 0x04C11DB7, MSB-first, length bytes appended,
# final complement): item ids are pinned by contracts/robot_v1 goldens and
# regression-tested against real cksum. Paths reaching this point never
# contain \n (they came from line-split parsing), so line framing is exact.
# No perl → per-path cksum fallback, same output.
robot_batch_item_hashes() {
    if command -v perl > /dev/null 2>&1; then
        perl -e '
            my @t;
            for my $i (0..255) {
                my $c = $i << 24;
                for (1..8) {
                    $c = ($c & 0x80000000)
                        ? ((($c << 1) & 0xFFFFFFFF) ^ 0x04C11DB7)
                        : (($c << 1) & 0xFFFFFFFF);
                }
                $t[$i] = $c;
            }
            while (defined(my $line = <STDIN>)) {
                chomp $line;
                my $crc = 0;
                for my $b (unpack "C*", $line) {
                    $crc = ((($crc << 8) & 0xFFFFFFFF) ^ $t[(($crc >> 24) ^ $b) & 0xFF]);
                }
                my $n = length $line;
                while ($n) {
                    $crc = ((($crc << 8) & 0xFFFFFFFF) ^ $t[(($crc >> 24) ^ ($n & 0xFF)) & 0xFF]);
                    $n >>= 8;
                }
                printf "%08x\n", (~$crc) & 0xFFFFFFFF;
            }
        '
    else
        local p sum
        while IFS= read -r p; do
            sum=$(printf '%s' "$p" | cksum | awk '{printf "%08x", $1}')
            printf '%s\n' "$sum"
        done
    fi
}

robot_plan_append() {
    local plan_id="$1" item_id="$2" path="$3" bytes="$4" reversible="${5:-true}"
    # Reject paths that would corrupt the TSV or JSON stream.
    case "$path" in
        *$'\t'* | *$'\n'*)
            return 1
            ;;
    esac
    printf 'item\t%s\t%s\t%s\t%s\n' "$item_id" "$path" "$bytes" "$reversible" >> "$(robot_plan_file "$plan_id")"
}

robot_plan_created_at() {
    local file
    file=$(robot_plan_file "$1")
    [[ -f "$file" ]] || return 1
    awk -F'\t' '$1 == "created" {print $2; exit}' "$file"
}

# Returns 0 when plan exists and is still fresh; 1 missing; 2 expired.
robot_plan_check() {
    local plan_id="$1" created now
    created=$(robot_plan_created_at "$plan_id") || return 1
    [[ -n "$created" ]] || return 1
    now=$(date +%s)
    if ((now - created > ROBOT_PLAN_TTL)); then
        return 2
    fi
    return 0
}

# Look up the path recorded for an item id. Echoes "path<TAB>bytes<TAB>reversible".
robot_plan_lookup() {
    local plan_id="$1" item_id="$2" file
    file=$(robot_plan_file "$plan_id")
    [[ -f "$file" ]] || return 1
    awk -F'\t' -v id="$item_id" '$1 == "item" && $2 == id {print $3 "\t" $4 "\t" $5; exit}' "$file"
}

# --- clean plan: parse the dry-run export ------------------------------------
# The clean dry-run already writes the authoritative candidate list to
# EXPORT_LIST_FILE (bin/clean.sh). Building the robot plan from that same file
# makes "GUI plan == CLI dry-run" true by construction (§11.4).

robot_clean_plan_from_export() {
    local export_file="$1" plan_id="$2" sections_filter="${3:-}"
    local line section_name section_slug path size_part bytes item_id
    local items=0 bytes_total=0

    # 两遍式：第一遍纯 bash 解析/过滤并收集记录，第二遍批量算 id 后按原序
    # 发射。id 哈希批量化（robot_batch_item_hashes）把发射尾巴从每项 3 个
    # 进程降到全程 1 个进程；记录重放保持 insight 与 item 的相对顺序不变。
    local -a rec_type=() rec_section=() rec_path=() rec_bytes=() rec_bytes_json=()

    section_name=""
    section_slug=""

    while IFS= read -r line; do
        case "$line" in
            "" | "#"*) continue ;;
            "=== "*" ===")
                section_name="${line#=== }"
                section_name="${section_name% ===}"
                section_slug=$(robot_section_slug "$section_name")
                continue
                ;;
        esac
        [[ -n "$section_slug" ]] || continue

        if [[ -n "$sections_filter" ]]; then
            case ",$sections_filter," in
                *",$section_slug,"*) ;;
                *) continue ;;
            esac
        fi

        # Entry format: "<path>  # <size_human>[, <N> items]". A line without
        # the size marker is not a plan entry (defense against fragments of
        # unrepresentable multi-line paths aliasing real paths).
        [[ "$line" == *"  #"* ]] || continue
        path="${line%%  \#*}"
        size_part="${line##*  \# }"
        size_part="${size_part%%,*}"
        # "size unknown" (sizing timed out) is not 0 bytes: emit JSON null so
        # the GUI can say "unknown" instead of lying with 0 B. The plan file
        # still stores 0 — apply's freed math treats unknown as nothing found.
        local bytes_json
        if [[ "$size_part" == "size unknown"* ]]; then
            bytes=0
            bytes_json="null"
        else
            bytes=$(robot_human_to_bytes "$size_part")
            bytes_json="$bytes"
        fi

        if robot_section_is_insight "$section_slug"; then
            # Insights carry the same unknown-size honesty: null, not 0.
            rec_type+=("insight")
            rec_section+=("$section_slug")
            rec_path+=("$path")
            rec_bytes+=("0")
            rec_bytes_json+=("$bytes_json")
            continue
        fi

        # Zero-byte targets never enter the GUI plan (documented transform,
        # MAC_APP_DESIGN §4.2): empty dirs free nothing, apps recreate them,
        # and 200+ noise rows dilute the review the sized rows deserve.
        # Filtered here — not in clean.sh — so the CLI keeps its own
        # preview==real behavior and stays unforked from upstream; apply
        # only ever deletes plan ids, so what leaves the plan leaves apply.
        # "size unknown" (null) is NOT zero and always stays.
        if [[ "$bytes_json" != "null" && "$bytes" -eq 0 ]]; then
            continue
        fi

        rec_type+=("item")
        rec_section+=("$section_slug")
        rec_path+=("$path")
        rec_bytes+=("$bytes")
        rec_bytes_json+=("$bytes_json")
    done < "$export_file"

    # 批量 id：只对 item 记录取哈希，序与收集序一致。
    local -a item_hashes=()
    if [[ ${#rec_type[@]} -gt 0 ]]; then
        local _idx
        local hash_input=""
        for ((_idx = 0; _idx < ${#rec_type[@]}; _idx++)); do
            [[ "${rec_type[$_idx]}" == "item" ]] || continue
            hash_input+="${rec_path[$_idx]}"$'\n'
        done
        if [[ -n "$hash_input" ]]; then
            local hash_line
            while IFS= read -r hash_line; do
                item_hashes+=("$hash_line")
            done < <(printf '%s' "$hash_input" | robot_batch_item_hashes)
        fi
    fi

    # 重放：insight 与 item 按收集序发射；哈希游标只随 item 前进。
    local hash_cursor=0
    local _r
    for ((_r = 0; _r < ${#rec_type[@]}; _r++)); do
        section_slug="${rec_section[$_r]}"
        path="${rec_path[$_r]}"
        if [[ "${rec_type[$_r]}" == "insight" ]]; then
            robot_emit_insight "$section_slug" "$path" "${rec_bytes_json[$_r]}"
            continue
        fi
        # 批量哈希与 item 数必须一一对应；对不上说明哈希器异常，
        # 回退逐项 cksum，绝不让 id 错位（id 错位 = apply 删错对象）。
        if [[ $hash_cursor -lt ${#item_hashes[@]} ]]; then
            item_id="cl.$section_slug.${item_hashes[$hash_cursor]}"
        else
            item_id=$(robot_item_id "cl" "$section_slug" "$path")
        fi
        hash_cursor=$((hash_cursor + 1))
        bytes="${rec_bytes[$_r]}"
        if ! robot_plan_append "$plan_id" "$item_id" "$path" "$bytes"; then
            robot_emit_error "E_INTERNAL" "skipped unrepresentable path in section $section_slug" "false"
            continue
        fi
        robot_emit_item "$item_id" "$section_slug" "$path" "$path" "${rec_bytes_json[$_r]}" "safe" "true"
        items=$((items + 1))
        bytes_total=$((bytes_total + bytes))
    done

    robot_emit_done "true" "$plan_id" "\"items\":$items,\"bytes_total\":$bytes_total"
}

# --- clean plan: incremental progress -----------------------------------------
# While the wrapped clean dry-run runs, candidates stream into the NUL-delimited
# preview ledger (bin/clean.sh append_dry_run_cleanup_target): six fields per
# tuple — identity, size_kb, item_count, size_known, section, path. The final
# export file is only rendered after the whole scan (render_clean_preview_from_
# ledger), so scan liveness must come from the ledger. Stateless full-file parse
# per tick: the ledger stays small, and an incomplete trailing tuple simply
# fails the six-read sextet and is picked up complete on the next tick.
# Echoes: "<items>\t<bytes>\t<section_slug>\t<last_path>".

# --- clean plan: guard-skipped families ---------------------------------------
# clean 的进程守卫把"应用运行中被跳过"的家族名写进 NUL 分隔的 deferred 文件
# （bin/clean.sh defer_cleanup_family，router 经 MOLE_CLEAN_DEFERRED_FILE 注入）。
# 逐家族发 insight 事件：section=guard_skipped、label=应用名、bytes=null——
# 未扫描的目标没有体积可言，诚实用 null（GUI 红线：不承诺任何字节数）。

robot_emit_guard_insights() {
    local file="$1" family
    [[ -f "$file" ]] || return 0
    while IFS= read -r -d '' family; do
        [[ -n "$family" ]] || continue
        robot_emit_insight "guard_skipped" "$family" "null"
    done < "$file"
}

robot_clean_ledger_snapshot() {
    local file="$1"
    local identity size_kb count size_known section path
    local items=0 bytes=0 last_section="" last_path=""

    if [[ -f "$file" ]]; then
        while IFS= read -r -d '' identity &&
            IFS= read -r -d '' size_kb &&
            IFS= read -r -d '' count &&
            IFS= read -r -d '' size_known &&
            IFS= read -r -d '' section &&
            IFS= read -r -d '' path; do
            [[ "$size_kb" =~ ^[0-9]+$ ]] || size_kb=0
            items=$((items + 1))
            bytes=$((bytes + size_kb * 1024))
            last_section="$section"
            last_path="$path"
        done < "$file"
    fi

    # Progress is display-only: flatten any control whitespace a hostile or
    # merely weird filename could carry, so the TSV line and the NDJSON
    # progress event it feeds stay single-line.
    last_path=${last_path//$'\n'/ }
    last_path=${last_path//$'\r'/ }
    last_path=${last_path//$'\t'/ }
    printf '%s\t%s\t%s\t%s\n' "$items" "$bytes" \
        "$(robot_section_slug "$last_section")" "$last_path"
}

# --- history: parse the structured logs ----------------------------------------
# deletions.log line format (lib/core/file_ops.sh):
#   <iso_ts>\t<mode>\t<size_kb>\t<status>\t<path>
# operations.log session markers (lib/core/log.sh):
#   # ========== <cmd> session started at <ts> ==========
#   # ========== <cmd> session ended at <ts>, <N> items, <SIZE> ==========

robot_history_deletions() {
    local log_file="$1" limit="${2:-100}"
    local count=0 n=0
    local ts mode size_kb status path bytes size_flag

    [[ -f "$log_file" ]] || {
        robot_emit_done "true" "" "\"items\":0"
        return 0
    }

    while IFS=$'\t' read -r ts mode size_kb status path; do
        [[ -n "$path" ]] || continue
        n=$((n + 1))
        # file_ops.sh writes size_kb="unknown" when du sizing is blocked;
        # arithmetic on it would abort the stream under set -u.
        if [[ "$size_kb" =~ ^[0-9]+$ ]]; then
            bytes=$((size_kb * 1024))
            size_flag=""
        else
            bytes=0
            size_flag=',"size_unknown":true'
        fi
        robot_emit "item" "$(printf '"id":"hist.del.%s","section":"deletions","label":"%s","path":"%s","bytes":%s%s,"kind":"log_entry","detail":"%s %s %s"' \
            "$n" "$(robot_json_escape "$path")" "$(robot_json_escape "$path")" "$bytes" "$size_flag" \
            "$(robot_json_escape "$ts")" "$(robot_json_escape "$mode")" "$(robot_json_escape "$status")")"
        count=$((count + 1))
    done < <(tail -n "$limit" "$log_file")

    robot_emit_done "true" "" "\"items\":$count"
}

robot_history_sessions() {
    local log_file="$1" limit="${2:-20}"
    local count=0

    [[ -f "$log_file" ]] || {
        robot_emit_done "true" "" "\"items\":0"
        return 0
    }

    # Emit one item per completed session (the "ended" marker carries the
    # command, timestamp, item count and freed size).
    while IFS=$'\t' read -r cmd ts items size; do
        [[ -n "$cmd" ]] || continue
        count=$((count + 1))
        robot_emit "item" "$(printf '"id":"hist.ses.%s","section":"sessions","label":"%s","bytes":%s,"kind":"log_entry","detail":"%s · %s items"' \
            "$count" "$(robot_json_escape "$cmd")" \
            "$(robot_human_to_bytes "$size")" \
            "$(robot_json_escape "$ts")" "$(robot_json_escape "$items")")"
    done < <(awk '
        /^# ========== .* session ended at / {
            line = $0
            sub(/^# ========== /, "", line)
            cmd = line
            sub(/ session ended at .*/, "", cmd)
            rest = line
            sub(/^.* session ended at /, "", rest)
            sub(/ ==========$/, "", rest)
            # rest: "<ts>, <N> items, <SIZE>"
            n = split(rest, parts, ", ")
            ts = parts[1]
            items = parts[2]
            sub(/ items$/, "", items)
            size = (n >= 3) ? parts[3] : "0B"
            printf "%s\t%s\t%s\t%s\n", cmd, ts, items, size
        }
    ' "$log_file" | tail -n "$limit")

    robot_emit_done "true" "" "\"items\":$count"
}

# --- whitelist ------------------------------------------------------------------
# Thin structured wrapper over lib/manage/whitelist.sh. Dependencies
# (load_whitelist, save_whitelist_patterns, CURRENT_WHITELIST_PATTERNS) must
# be loaded by the router (or stubbed in tests); fails closed when missing.

robot_whitelist_cmd() {
    local verb="$1" mode="$2" pattern="${3:-}"
    local dep p found=0 count=0
    local -a next=()

    for dep in load_whitelist save_whitelist_patterns; do
        if ! type "$dep" > /dev/null 2>&1; then
            robot_emit_error "E_INTERNAL" "whitelist dependency not loaded: $dep" "true"
            return 1
        fi
    done
    case "$mode" in
        clean | optimize) ;;
        *)
            robot_emit_error "E_INTERNAL" "invalid whitelist mode: $mode" "true"
            return 1
            ;;
    esac

    load_whitelist "$mode"

    case "$verb" in
        list) ;;
        add)
            [[ -n "$pattern" ]] || {
                robot_emit_error "E_INTERNAL" "add requires a pattern" "true"
                return 1
            }
            if [[ ${#CURRENT_WHITELIST_PATTERNS[@]} -gt 0 ]]; then
                for p in "${CURRENT_WHITELIST_PATTERNS[@]}"; do
                    [[ "$p" == "$pattern" ]] && found=1
                done
            fi
            if [[ $found -eq 0 ]]; then
                CURRENT_WHITELIST_PATTERNS+=("$pattern")
                save_whitelist_patterns "$mode" "${CURRENT_WHITELIST_PATTERNS[@]}"
            fi
            ;;
        remove)
            [[ -n "$pattern" ]] || {
                robot_emit_error "E_INTERNAL" "remove requires a pattern" "true"
                return 1
            }
            if [[ ${#CURRENT_WHITELIST_PATTERNS[@]} -gt 0 ]]; then
                for p in "${CURRENT_WHITELIST_PATTERNS[@]}"; do
                    [[ "$p" == "$pattern" ]] || next+=("$p")
                done
            fi
            CURRENT_WHITELIST_PATTERNS=()
            if [[ ${#next[@]} -gt 0 ]]; then
                CURRENT_WHITELIST_PATTERNS=("${next[@]}")
                save_whitelist_patterns "$mode" "${CURRENT_WHITELIST_PATTERNS[@]}"
            else
                save_whitelist_patterns "$mode"
            fi
            ;;
        *)
            robot_emit_error "E_INTERNAL" "unsupported whitelist verb: $verb" "true"
            return 1
            ;;
    esac

    # Always emit the resulting list so add/remove callers see the new state.
    if [[ ${#CURRENT_WHITELIST_PATTERNS[@]} -gt 0 ]]; then
        for p in "${CURRENT_WHITELIST_PATTERNS[@]}"; do
            count=$((count + 1))
            robot_emit "item" "$(printf '"id":"wl.%s.%s","section":"whitelist_%s","label":"%s","kind":"whitelist_pattern"' \
                "$mode" "$count" "$mode" "$(robot_json_escape "$p")")"
        done
    fi
    robot_emit_done "true" "" "\"items\":$count"
}

# --- clean apply --------------------------------------------------------------
# Re-validates every id against the live filesystem and the CLI safety layers
# before deleting (§7.4 chain). Deletion goes through mole_delete only.
# Reads item ids one per line from stdin.

robot_clean_apply() {
    local plan_id="$1"
    local item_id row path bytes freed=0 ok=0 skipped=0 failed=0 cancelled=0

    # Graceful cancel (design §4.4): SIGTERM/SIGINT set a flag; bash defers
    # trap delivery until the in-flight command (mole_delete) returns, so the
    # current item always finishes and gets its result event. Remaining items
    # are counted as cancelled in the final done event -- never half-deleted,
    # never unaccounted.
    local _robot_cancel=0
    trap '_robot_cancel=1' TERM INT

    # Fail closed: if any safety-chain dependency is missing we refuse to run.
    # A missing is_whitelisted would otherwise silently evaluate false and
    # delete paths the user explicitly protected.
    local dep
    for dep in mole_delete should_protect_path is_whitelisted; do
        if ! type "$dep" > /dev/null 2>&1; then
            robot_emit_error "E_INTERNAL" "safety dependency not loaded: $dep" "true"
            return 1
        fi
    done

    case "$(
        robot_plan_check "$plan_id"
        echo $?
    )" in
        1)
            robot_emit_error "E_PLAN_NOT_FOUND" "plan $plan_id not found" "true"
            return 1
            ;;
        2)
            robot_emit_error "E_PLAN_EXPIRED" "plan expired, re-run plan" "true"
            return 1
            ;;
    esac

    while IFS= read -r item_id; do
        [[ -n "$item_id" ]] || continue

        if [[ $_robot_cancel -eq 1 ]]; then
            cancelled=$((cancelled + 1))
            continue
        fi

        row=$(robot_plan_lookup "$plan_id" "$item_id") || row=""
        if [[ -z "$row" ]]; then
            robot_emit_result "$item_id" "failed" 0
            failed=$((failed + 1))
            continue
        fi
        path=$(printf '%s' "$row" | cut -f1)
        bytes=$(printf '%s' "$row" | cut -f2)

        if [[ ! -e "$path" ]]; then
            robot_emit_result "$item_id" "skipped_missing" 0
            skipped=$((skipped + 1))
            continue
        fi
        if should_protect_path "$path"; then
            robot_emit_result "$item_id" "skipped_protected" 0
            skipped=$((skipped + 1))
            continue
        fi
        if is_whitelisted "$path"; then
            robot_emit_result "$item_id" "skipped_whitelisted" 0
            skipped=$((skipped + 1))
            continue
        fi

        if [[ "${MOLE_DRY_RUN:-0}" == "1" ]]; then
            robot_emit_result "$item_id" "dry_run" 0
            skipped=$((skipped + 1))
            continue
        fi

        if mole_delete "$path"; then
            # Report what actually happened: mole_delete honors
            # MOLE_DELETE_MODE (permanent unless the router set trash).
            if [[ "${MOLE_DELETE_MODE:-permanent}" == "trash" ]]; then
                robot_emit_result "$item_id" "trashed" "$bytes"
            else
                robot_emit_result "$item_id" "deleted" "$bytes"
            fi
            ok=$((ok + 1))
            freed=$((freed + bytes))
        else
            robot_emit_result "$item_id" "failed" 0
            failed=$((failed + 1))
        fi
    done

    trap - TERM INT

    robot_emit_done "true" "$plan_id" \
        "\"items\":$((ok + skipped + failed)),\"failed\":$failed,\"skipped\":$skipped,\"cancelled\":$cancelled,\"freed_bytes\":$freed"
}
