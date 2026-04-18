#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="game_nat_forward.sh"
APP_NAME="game-nat-forward"
BASE_DIR="/etc/game-nat-forward"
DB_FILE="$BASE_DIR/rules.db"
STATS_FILE="$BASE_DIR/stats.db"
TC_STATE_FILE="$BASE_DIR/tc_state.db"
BACKEND_FILE="$BASE_DIR/backend.conf"
NFT_CONF_FILE="$BASE_DIR/nftables-game-nat.nft"
SYSCTL_FILE="/etc/sysctl.d/99-game-nat-forward.conf"
RUNTIME_SCRIPT="/usr/local/sbin/game_nat_forward.sh"

RESTORE_SERVICE_NAME="game_nat_forward.service"
RESTORE_SERVICE_FILE="/etc/systemd/system/$RESTORE_SERVICE_NAME"
CHECK_SERVICE_NAME="game_nat_forward_check.service"
CHECK_SERVICE_FILE="/etc/systemd/system/$CHECK_SERVICE_NAME"
CHECK_TIMER_NAME="game_nat_forward_check.timer"
CHECK_TIMER_FILE="/etc/systemd/system/$CHECK_TIMER_NAME"

COMMENT_TAG="game-nat-forward"
IPTABLES_NAT_PREROUTING_CHAIN="GAME_NAT_FORWARD_PREROUTING"
IPTABLES_NAT_POSTROUTING_CHAIN="GAME_NAT_FORWARD_POSTROUTING"
IPTABLES_FILTER_FORWARD_CHAIN="GAME_NAT_FORWARD_FORWARD"

DEFAULT_PROTOCOL_MODE="tcp+udp"
DEFAULT_MAX_TOTAL_MODE="sum"
EXPORT_MAGIC="# game-nat-forward export v1"
BEST_EFFORT_NOTICE="已按开放型 NAT / best-effort Full Cone 方向配置，实际 NAT 类型仍取决于内核能力、运营商网络、上级路由和测试平台判定。"
RATE_LIMIT_NOTICE="速率限制使用 tc policing / flower 进行 best-effort 限速，不改变 NAT 核心实现；实际吞吐仍会受内核、网卡驱动、上级网络与报文特征影响。"
APT_UPDATED=0

RULE_ID=""
RULE_PROTOCOL_MODE=""
RULE_EXTERNAL_PORT=""
RULE_TARGET_IP=""
RULE_TARGET_PORT=""
RULE_IFACE=""
RULE_UP_RATE_KBIT=""
RULE_DOWN_RATE_KBIT=""
RULE_UP_TOTAL_LIMIT=""
RULE_DOWN_TOTAL_LIMIT=""
RULE_MAX_TOTAL_LIMIT=""
RULE_MAX_TOTAL_MODE=""
RULE_DISABLED_REASON=""

log() {
    printf '[*] %s\n' "$*"
}

warn() {
    printf '[!] %s\n' "$*" >&2
}

die() {
    printf '[x] %s\n' "$*" >&2
    exit 1
}

require_root() {
    if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
        die "请以 root 身份运行此脚本。"
    fi
}

init_storage() {
    mkdir -p "$BASE_DIR"

    if [[ ! -f "$DB_FILE" ]]; then
        printf '# id|protocol_mode|external_port|target_ip|target_port|iface|up_rate_kbit|down_rate_kbit|up_total_limit_bytes|down_total_limit_bytes|max_total_limit_bytes|max_total_mode|disabled_reason\n' > "$DB_FILE"
        chmod 600 "$DB_FILE"
    fi

    if [[ ! -f "$STATS_FILE" ]]; then
        printf '# id|persist_down_bytes|persist_up_bytes|last_down_bytes|last_up_bytes\n' > "$STATS_FILE"
        chmod 600 "$STATS_FILE"
    fi

    if [[ ! -f "$TC_STATE_FILE" ]]; then
        printf '# iface|direction|pref\n' > "$TC_STATE_FILE"
        chmod 600 "$TC_STATE_FILE"
    fi
}

run_apt_update_once() {
    if [[ "$APT_UPDATED" -eq 0 ]]; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -y
        APT_UPDATED=1
    fi
}

ensure_command() {
    local cmd="$1"
    local pkg="$2"

    if command -v "$cmd" >/dev/null 2>&1; then
        return 0
    fi

    run_apt_update_once
    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y "$pkg"

    command -v "$cmd" >/dev/null 2>&1 || die "安装依赖失败：$pkg"
}

load_backend() {
    if [[ -f "$BACKEND_FILE" ]]; then
        tr -d '[:space:]' < "$BACKEND_FILE"
    fi
}

save_backend() {
    local backend="$1"
    printf '%s\n' "$backend" > "$BACKEND_FILE"
    chmod 600 "$BACKEND_FILE"
}

select_backend() {
    local backend
    backend="$(load_backend || true)"

    case "$backend" in
        nft)
            ensure_command nft nftables
            printf 'nft\n'
            return 0
            ;;
        iptables)
            ensure_command iptables iptables
            printf 'iptables\n'
            return 0
            ;;
        "")
            ;;
        *)
            warn "检测到未知 NAT 后端：$backend，准备重新选择。"
            ;;
    esac

    ensure_command ip iproute2

    if command -v nft >/dev/null 2>&1; then
        backend="nft"
    else
        run_apt_update_once
        export DEBIAN_FRONTEND=noninteractive
        if apt-get install -y nftables >/dev/null 2>&1; then
            backend="nft"
        else
            ensure_command iptables iptables
            backend="iptables"
        fi
    fi

    if [[ "$backend" == "nft" ]]; then
        ensure_command nft nftables
    else
        ensure_command iptables iptables
    fi

    save_backend "$backend"
    printf '%s\n' "$backend"
}

install_runtime_script() {
    if [[ ! -f "$0" ]]; then
        warn "当前无法定位脚本实体文件，已跳过安装持久化运行脚本；请从保存后的文件路径运行本脚本以启用重启自动恢复。"
        return 0
    fi

    if [[ "$0" != "$RUNTIME_SCRIPT" ]]; then
        install -m 0755 "$0" "$RUNTIME_SCRIPT"
    else
        chmod 0755 "$RUNTIME_SCRIPT"
    fi
}

install_systemd_units() {
    install_runtime_script

    cat > "$RESTORE_SERVICE_FILE" <<EOF
[Unit]
Description=Game NAT Forward Restore Service
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/bin/env bash $RUNTIME_SCRIPT --restore
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

    cat > "$CHECK_SERVICE_FILE" <<EOF
[Unit]
Description=Game NAT Forward Limit Check Service
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/bin/env bash $RUNTIME_SCRIPT --check-limits
EOF

    cat > "$CHECK_TIMER_FILE" <<EOF
[Unit]
Description=Game NAT Forward Limit Check Timer

[Timer]
OnBootSec=2min
OnUnitActiveSec=1min
AccuracySec=30s
Persistent=true
Unit=$CHECK_SERVICE_NAME

[Install]
WantedBy=timers.target
EOF

    chmod 0644 "$RESTORE_SERVICE_FILE" "$CHECK_SERVICE_FILE" "$CHECK_TIMER_FILE"
    systemctl daemon-reload
    systemctl enable "$RESTORE_SERVICE_NAME" >/dev/null
    systemctl enable "$CHECK_TIMER_NAME" >/dev/null
}

enable_ipv4_forward() {
    ensure_command sysctl procps

    cat > "$SYSCTL_FILE" <<EOF
# Managed by $APP_NAME
# 为了让 DNAT / MASQUERADE 正常工作，必须开启 IPv4 转发。
net.ipv4.ip_forward=1
EOF

    chmod 0644 "$SYSCTL_FILE"
    sysctl -w net.ipv4.ip_forward=1 >/dev/null
}

detect_default_iface() {
    ip -4 route list default 2>/dev/null | awk '{print $5; exit}'
}

validate_port() {
    local port="$1"
    [[ "$port" =~ ^[0-9]+$ ]] || return 1
    (( port >= 1 && port <= 65535 ))
}

validate_ip() {
    local ip="$1"
    local IFS=.
    local -a octets
    local octet

    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    read -r -a octets <<< "$ip"
    [[ "${#octets[@]}" -eq 4 ]] || return 1

    for octet in "${octets[@]}"; do
        [[ "$octet" =~ ^[0-9]+$ ]] || return 1
        (( octet >= 0 && octet <= 255 )) || return 1
    done
}

validate_protocol_mode() {
    case "$1" in
        tcp+udp|tcp|udp)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

validate_nonnegative_int() {
    [[ "$1" =~ ^[0-9]+$ ]]
}

validate_traffic_limit_input() {
    [[ "$1" =~ ^[0-9]+([Gg])?$ ]]
}

normalize_traffic_limit_input() {
    local value="$1"
    local gib=1073741824

    if [[ "$value" =~ ^([0-9]+)[Gg]$ ]]; then
        printf '%s\n' "$(( ${BASH_REMATCH[1]} * gib ))"
        return 0
    fi

    printf '%s\n' "$value"
}

validate_max_total_mode() {
    case "$1" in
        none|either|up|down|sum)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

protocol_number() {
    case "$1" in
        tcp)
            printf '6\n'
            ;;
        udp)
            printf '17\n'
            ;;
        *)
            return 1
            ;;
    esac
}

protocols_for_mode() {
    case "$1" in
        tcp+udp)
            printf 'tcp\nudp\n'
            ;;
        tcp)
            printf 'tcp\n'
            ;;
        udp)
            printf 'udp\n'
            ;;
        *)
            return 1
            ;;
    esac
}

format_bytes() {
    local bytes="${1:-0}"
    local units=("B" "KiB" "MiB" "GiB" "TiB")
    local unit_index=0
    local whole remainder decimal

    [[ "$bytes" =~ ^[0-9]+$ ]] || bytes=0

    while (( bytes >= 1024 && unit_index < ${#units[@]} - 1 )); do
        remainder=$(( bytes % 1024 ))
        bytes=$(( bytes / 1024 ))
        unit_index=$(( unit_index + 1 ))
    done

    if (( unit_index == 0 )); then
        printf '%s %s' "$bytes" "${units[$unit_index]}"
        return 0
    fi

    whole="$bytes"
    decimal=$(( remainder * 10 / 1024 ))
    printf '%s.%s %s' "$whole" "$decimal" "${units[$unit_index]}"
}

format_rate() {
    local kbit="${1:-0}"

    [[ "$kbit" =~ ^[0-9]+$ ]] || kbit=0
    if (( kbit == 0 )); then
        printf 'unlimited'
    elif (( kbit >= 1024 )); then
        printf '%s.%s Mbit/s' "$((kbit / 1024))" "$(((kbit % 1024) * 10 / 1024))"
    else
        printf '%s Kbit/s' "$kbit"
    fi
}

tc_burst_bytes() {
    local kbit="${1:-0}"
    local bytes

    if ! [[ "$kbit" =~ ^[0-9]+$ ]] || (( kbit <= 0 )); then
        printf '16384\n'
        return 0
    fi

    bytes=$(( kbit * 1024 / 8 / 8 ))
    if (( bytes < 16384 )); then
        bytes=16384
    fi
    printf '%s\n' "$bytes"
}

is_rule_disabled() {
    [[ -n "$1" ]]
}

parse_rule_line() {
    local line="$1"

    [[ -n "${line//[[:space:]]/}" ]] || return 1
    [[ ! "$line" =~ ^[[:space:]]*# ]] || return 1

    IFS='|' read -r RULE_ID RULE_PROTOCOL_MODE RULE_EXTERNAL_PORT RULE_TARGET_IP RULE_TARGET_PORT RULE_IFACE RULE_UP_RATE_KBIT RULE_DOWN_RATE_KBIT RULE_UP_TOTAL_LIMIT RULE_DOWN_TOTAL_LIMIT RULE_MAX_TOTAL_LIMIT RULE_MAX_TOTAL_MODE RULE_DISABLED_REASON <<< "$line"

    RULE_UP_RATE_KBIT="${RULE_UP_RATE_KBIT:-0}"
    RULE_DOWN_RATE_KBIT="${RULE_DOWN_RATE_KBIT:-0}"
    RULE_UP_TOTAL_LIMIT="${RULE_UP_TOTAL_LIMIT:-0}"
    RULE_DOWN_TOTAL_LIMIT="${RULE_DOWN_TOTAL_LIMIT:-0}"
    RULE_MAX_TOTAL_LIMIT="${RULE_MAX_TOTAL_LIMIT:-0}"
    RULE_MAX_TOTAL_MODE="${RULE_MAX_TOTAL_MODE:-none}"
    RULE_DISABLED_REASON="${RULE_DISABLED_REASON:-}"

    validate_protocol_mode "$RULE_PROTOCOL_MODE" || return 1
    validate_port "$RULE_EXTERNAL_PORT" || return 1
    validate_ip "$RULE_TARGET_IP" || return 1
    validate_port "$RULE_TARGET_PORT" || return 1
    [[ -n "$RULE_IFACE" ]] || return 1
    validate_nonnegative_int "$RULE_UP_RATE_KBIT" || return 1
    validate_nonnegative_int "$RULE_DOWN_RATE_KBIT" || return 1
    validate_nonnegative_int "$RULE_UP_TOTAL_LIMIT" || return 1
    validate_nonnegative_int "$RULE_DOWN_TOTAL_LIMIT" || return 1
    validate_nonnegative_int "$RULE_MAX_TOTAL_LIMIT" || return 1

    if (( RULE_MAX_TOTAL_LIMIT > 0 )); then
        RULE_MAX_TOTAL_MODE="sum"
    else
        RULE_MAX_TOTAL_MODE="none"
    fi

    return 0
}

serialize_current_rule() {
    printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
        "$RULE_ID" \
        "$RULE_PROTOCOL_MODE" \
        "$RULE_EXTERNAL_PORT" \
        "$RULE_TARGET_IP" \
        "$RULE_TARGET_PORT" \
        "$RULE_IFACE" \
        "$RULE_UP_RATE_KBIT" \
        "$RULE_DOWN_RATE_KBIT" \
        "$RULE_UP_TOTAL_LIMIT" \
        "$RULE_DOWN_TOTAL_LIMIT" \
        "$RULE_MAX_TOTAL_LIMIT" \
        "$RULE_MAX_TOTAL_MODE" \
        "$RULE_DISABLED_REASON"
}

rule_db_has_records() {
    grep -Ev '^[[:space:]]*#|^[[:space:]]*$' "$DB_FILE" >/dev/null 2>&1
}

generate_rule_id() {
    printf '%s-%04d' "$(date +%s%N)" "$((RANDOM % 10000))"
}

rule_exists() {
    local protocol_mode="$1"
    local external_port="$2"
    local target_ip="$3"
    local target_port="$4"
    local line

    while IFS= read -r line; do
        parse_rule_line "$line" || continue
        if [[ "$RULE_PROTOCOL_MODE" == "$protocol_mode" && "$RULE_EXTERNAL_PORT" == "$external_port" && "$RULE_TARGET_IP" == "$target_ip" && "$RULE_TARGET_PORT" == "$target_port" ]]; then
            return 0
        fi
    done < "$DB_FILE"

    return 1
}

append_rule_db() {
    local id="$1"
    local protocol_mode="$2"
    local external_port="$3"
    local target_ip="$4"
    local target_port="$5"
    local iface="$6"
    local up_rate_kbit="$7"
    local down_rate_kbit="$8"
    local up_total_limit="$9"
    local down_total_limit="${10}"
    local max_total_limit="${11}"
    local max_total_mode="${12}"

    printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|\n' \
        "$id" "$protocol_mode" "$external_port" "$target_ip" "$target_port" "$iface" \
        "$up_rate_kbit" "$down_rate_kbit" "$up_total_limit" "$down_total_limit" "$max_total_limit" "$max_total_mode" >> "$DB_FILE"
}

remove_rule_db_by_id() {
    local rule_id="$1"
    local tmp_file
    local found=0
    local line

    tmp_file="$(mktemp)"

    while IFS= read -r line; do
        if ! parse_rule_line "$line"; then
            printf '%s\n' "$line" >> "$tmp_file"
            continue
        fi

        if [[ "$RULE_ID" == "$rule_id" ]]; then
            found=1
            continue
        fi

        printf '%s\n' "$line" >> "$tmp_file"
    done < "$DB_FILE"

    if [[ "$found" -eq 0 ]]; then
        rm -f "$tmp_file"
        return 1
    fi

    mv "$tmp_file" "$DB_FILE"
    chmod 600 "$DB_FILE"
    return 0
}

update_rule_disabled_reason() {
    local rule_id="$1"
    local reason="$2"
    local tmp_file
    local found=0
    local line

    tmp_file="$(mktemp)"

    while IFS= read -r line; do
        if ! parse_rule_line "$line"; then
            printf '%s\n' "$line" >> "$tmp_file"
            continue
        fi

        if [[ "$RULE_ID" == "$rule_id" ]]; then
            RULE_DISABLED_REASON="$reason"
            serialize_current_rule >> "$tmp_file"
            found=1
        else
            printf '%s\n' "$line" >> "$tmp_file"
        fi
    done < "$DB_FILE"

    [[ "$found" -eq 1 ]] || {
        rm -f "$tmp_file"
        return 1
    }

    mv "$tmp_file" "$DB_FILE"
    chmod 600 "$DB_FILE"
}

stats_get_record() {
    local rule_id="$1"
    local record

    record="$(awk -F'|' -v rid="$rule_id" 'BEGIN{found=0} /^[[:space:]]*#/ {next} NF==0 {next} $1==rid {print $2, $3, $4, $5; found=1; exit} END{if(found==0) print "0 0 0 0"}' "$STATS_FILE")"
    printf '%s\n' "${record:-0 0 0 0}"
}

stats_set_record() {
    local rule_id="$1"
    local persist_down="$2"
    local persist_up="$3"
    local last_down="$4"
    local last_up="$5"
    local tmp_file
    local found=0
    local line sid

    tmp_file="$(mktemp)"

    while IFS= read -r line; do
        if [[ "$line" =~ ^[[:space:]]*# ]] || [[ -z "${line//[[:space:]]/}" ]]; then
            printf '%s\n' "$line" >> "$tmp_file"
            continue
        fi

        IFS='|' read -r sid _ <<< "$line"
        if [[ "$sid" == "$rule_id" ]]; then
            printf '%s|%s|%s|%s|%s\n' "$rule_id" "$persist_down" "$persist_up" "$last_down" "$last_up" >> "$tmp_file"
            found=1
        else
            printf '%s\n' "$line" >> "$tmp_file"
        fi
    done < "$STATS_FILE"

    if [[ "$found" -eq 0 ]]; then
        printf '%s|%s|%s|%s|%s\n' "$rule_id" "$persist_down" "$persist_up" "$last_down" "$last_up" >> "$tmp_file"
    fi

    mv "$tmp_file" "$STATS_FILE"
    chmod 600 "$STATS_FILE"
}

stats_remove_record() {
    local rule_id="$1"
    local tmp_file
    local line sid

    tmp_file="$(mktemp)"

    while IFS= read -r line; do
        if [[ "$line" =~ ^[[:space:]]*# ]] || [[ -z "${line//[[:space:]]/}" ]]; then
            printf '%s\n' "$line" >> "$tmp_file"
            continue
        fi

        IFS='|' read -r sid _ <<< "$line"
        [[ "$sid" == "$rule_id" ]] && continue
        printf '%s\n' "$line" >> "$tmp_file"
    done < "$STATS_FILE"

    mv "$tmp_file" "$STATS_FILE"
    chmod 600 "$STATS_FILE"
}

nft_safe_delete_tables() {
    if command -v nft >/dev/null 2>&1; then
        nft delete table ip game_nat_forward_nat >/dev/null 2>&1 || true
        nft delete table inet game_nat_forward_filter >/dev/null 2>&1 || true
    fi
}

iptables_chain_exists() {
    local table="$1"
    local chain="$2"
    iptables -t "$table" -S "$chain" >/dev/null 2>&1
}

iptables_remove_all_managed() {
    if ! command -v iptables >/dev/null 2>&1; then
        return 0
    fi

    if iptables -t nat -C PREROUTING -j "$IPTABLES_NAT_PREROUTING_CHAIN" >/dev/null 2>&1; then
        iptables -t nat -D PREROUTING -j "$IPTABLES_NAT_PREROUTING_CHAIN"
    fi
    if iptables -t nat -C POSTROUTING -j "$IPTABLES_NAT_POSTROUTING_CHAIN" >/dev/null 2>&1; then
        iptables -t nat -D POSTROUTING -j "$IPTABLES_NAT_POSTROUTING_CHAIN"
    fi
    if iptables -C FORWARD -j "$IPTABLES_FILTER_FORWARD_CHAIN" >/dev/null 2>&1; then
        iptables -D FORWARD -j "$IPTABLES_FILTER_FORWARD_CHAIN"
    fi

    if iptables_chain_exists nat "$IPTABLES_NAT_PREROUTING_CHAIN"; then
        iptables -t nat -F "$IPTABLES_NAT_PREROUTING_CHAIN"
        iptables -t nat -X "$IPTABLES_NAT_PREROUTING_CHAIN"
    fi
    if iptables_chain_exists nat "$IPTABLES_NAT_POSTROUTING_CHAIN"; then
        iptables -t nat -F "$IPTABLES_NAT_POSTROUTING_CHAIN"
        iptables -t nat -X "$IPTABLES_NAT_POSTROUTING_CHAIN"
    fi
    if iptables_chain_exists filter "$IPTABLES_FILTER_FORWARD_CHAIN"; then
        iptables -F "$IPTABLES_FILTER_FORWARD_CHAIN"
        iptables -X "$IPTABLES_FILTER_FORWARD_CHAIN"
    fi
}

build_nft_rules_file() {
    local line
    local proto

    : > "$NFT_CONF_FILE"

    cat >> "$NFT_CONF_FILE" <<'EOF'
# This file is managed by game-nat-forward.
# 普通的用户态端口监听/转发（例如单纯 socat 监听）并不等于 Full Cone NAT。
# 原因是 Full Cone NAT 依赖内核 conntrack / NAT 映射行为，而不是单个进程收包再转发。
# 因此这里优先使用 nftables / iptables NAT，让 DNAT / SNAT(MASQUERADE) 由内核处理。
# 这属于“尽量开放型 NAT / best-effort Full Cone NAT”设计，尤其面向游戏 UDP 场景。
# 但它并不保证在所有网络环境下都被严格判定为 Full Cone NAT：
# 运营商 CGNAT、上级路由器、云厂商 ACL、安全组、rp_filter、内核能力与测试平台标准都会影响结果。

table ip game_nat_forward_nat {
    chain prerouting {
        type nat hook prerouting priority dstnat;
        policy accept;
    }

    chain postrouting {
        type nat hook postrouting priority srcnat;
        policy accept;
    }
}

table inet game_nat_forward_filter {
    chain forward {
        type filter hook forward priority filter;
        policy accept;
    }
}
EOF

    while IFS= read -r line; do
        parse_rule_line "$line" || continue
        is_rule_disabled "$RULE_DISABLED_REASON" && continue

        while IFS= read -r proto; do
            [[ -z "$proto" ]] && continue
            printf 'add rule ip game_nat_forward_nat prerouting iifname "%s" %s dport %s dnat to %s:%s comment "%s:%s:%s:dnat"\n' \
                "$RULE_IFACE" "$proto" "$RULE_EXTERNAL_PORT" "$RULE_TARGET_IP" "$RULE_TARGET_PORT" "$COMMENT_TAG" "$RULE_ID" "$proto" >> "$NFT_CONF_FILE"
            printf 'add rule ip game_nat_forward_nat postrouting ct status dnat ip daddr %s %s dport %s masquerade comment "%s:%s:%s:masq"\n' \
                "$RULE_TARGET_IP" "$proto" "$RULE_TARGET_PORT" "$COMMENT_TAG" "$RULE_ID" "$proto" >> "$NFT_CONF_FILE"
            printf 'add rule inet game_nat_forward_filter forward iifname "%s" ip daddr %s %s dport %s ct state new,established,related counter accept comment "%s:%s:%s:fw-in"\n' \
                "$RULE_IFACE" "$RULE_TARGET_IP" "$proto" "$RULE_TARGET_PORT" "$COMMENT_TAG" "$RULE_ID" "$proto" >> "$NFT_CONF_FILE"
            printf 'add rule inet game_nat_forward_filter forward oifname "%s" ip saddr %s %s sport %s ct state established,related counter accept comment "%s:%s:%s:fw-out"\n' \
                "$RULE_IFACE" "$RULE_TARGET_IP" "$proto" "$RULE_TARGET_PORT" "$COMMENT_TAG" "$RULE_ID" "$proto" >> "$NFT_CONF_FILE"
        done < <(protocols_for_mode "$RULE_PROTOCOL_MODE")
    done < "$DB_FILE"

    chmod 600 "$NFT_CONF_FILE"
}

apply_nft_rules() {
    ensure_command nft nftables
    nft_safe_delete_tables

    if ! rule_db_has_records; then
        rm -f "$NFT_CONF_FILE"
        return 0
    fi

    build_nft_rules_file
    nft -f "$NFT_CONF_FILE"
}

apply_iptables_rules() {
    local line
    local proto

    ensure_command iptables iptables
    iptables_remove_all_managed

    if ! rule_db_has_records; then
        return 0
    fi

    iptables -t nat -N "$IPTABLES_NAT_PREROUTING_CHAIN"
    iptables -t nat -N "$IPTABLES_NAT_POSTROUTING_CHAIN"
    iptables -N "$IPTABLES_FILTER_FORWARD_CHAIN"

    iptables -t nat -I PREROUTING 1 -j "$IPTABLES_NAT_PREROUTING_CHAIN"
    iptables -t nat -I POSTROUTING 1 -j "$IPTABLES_NAT_POSTROUTING_CHAIN"
    iptables -I FORWARD 1 -j "$IPTABLES_FILTER_FORWARD_CHAIN"

    while IFS= read -r line; do
        parse_rule_line "$line" || continue
        is_rule_disabled "$RULE_DISABLED_REASON" && continue

        while IFS= read -r proto; do
            [[ -z "$proto" ]] && continue
            iptables -t nat -A "$IPTABLES_NAT_PREROUTING_CHAIN" -i "$RULE_IFACE" -p "$proto" --dport "$RULE_EXTERNAL_PORT" \
                -m comment --comment "$COMMENT_TAG:$RULE_ID:$proto:dnat" \
                -j DNAT --to-destination "$RULE_TARGET_IP:$RULE_TARGET_PORT"

            iptables -t nat -A "$IPTABLES_NAT_POSTROUTING_CHAIN" -p "$proto" -d "$RULE_TARGET_IP" --dport "$RULE_TARGET_PORT" \
                -m conntrack --ctstate DNAT \
                -m comment --comment "$COMMENT_TAG:$RULE_ID:$proto:masq" \
                -j MASQUERADE

            iptables -A "$IPTABLES_FILTER_FORWARD_CHAIN" -i "$RULE_IFACE" -p "$proto" -d "$RULE_TARGET_IP" --dport "$RULE_TARGET_PORT" \
                -m conntrack --ctstate NEW,ESTABLISHED,RELATED \
                -m comment --comment "$COMMENT_TAG:$RULE_ID:$proto:fw-in" \
                -j ACCEPT

            iptables -A "$IPTABLES_FILTER_FORWARD_CHAIN" -o "$RULE_IFACE" -p "$proto" -s "$RULE_TARGET_IP" --sport "$RULE_TARGET_PORT" \
                -m conntrack --ctstate ESTABLISHED,RELATED \
                -m comment --comment "$COMMENT_TAG:$RULE_ID:$proto:fw-out" \
                -j ACCEPT
        done < <(protocols_for_mode "$RULE_PROTOCOL_MODE")
    done < "$DB_FILE"
}

cleanup_nft_only() {
    nft_safe_delete_tables
    rm -f "$NFT_CONF_FILE"
}

cleanup_iptables_only() {
    iptables_remove_all_managed
}

cleanup_tc_filters() {
    local line iface direction pref

    ensure_command tc iproute2

    while IFS= read -r line; do
        [[ -n "${line//[[:space:]]/}" ]] || continue
        [[ ! "$line" =~ ^[[:space:]]*# ]] || continue
        IFS='|' read -r iface direction pref <<< "$line"
        [[ -n "$iface" && -n "$direction" && -n "$pref" ]] || continue
        tc filter del dev "$iface" "$direction" pref "$pref" 2>/dev/null || true
    done < "$TC_STATE_FILE"

    printf '# iface|direction|pref\n' > "$TC_STATE_FILE"
    chmod 600 "$TC_STATE_FILE"
}

append_tc_state() {
    local iface="$1"
    local direction="$2"
    local pref="$3"
    printf '%s|%s|%s\n' "$iface" "$direction" "$pref" >> "$TC_STATE_FILE"
}

apply_tc_limits() {
    local line
    local proto
    local pref=10000
    local burst

    ensure_command tc iproute2
    cleanup_tc_filters

    while IFS= read -r line; do
        parse_rule_line "$line" || continue
        is_rule_disabled "$RULE_DISABLED_REASON" && continue

        if (( RULE_UP_RATE_KBIT <= 0 && RULE_DOWN_RATE_KBIT <= 0 )); then
            continue
        fi

        tc qdisc add dev "$RULE_IFACE" clsact 2>/dev/null || true

        while IFS= read -r proto; do
            [[ -z "$proto" ]] && continue

            if (( RULE_DOWN_RATE_KBIT > 0 )); then
                burst="$(tc_burst_bytes "$RULE_DOWN_RATE_KBIT")"
                if tc filter add dev "$RULE_IFACE" ingress pref "$pref" protocol ip flower \
                    ip_proto "$proto" dst_port "$RULE_EXTERNAL_PORT" \
                    action police rate "${RULE_DOWN_RATE_KBIT}kbit" burst "${burst}"b drop >/dev/null 2>&1; then
                    append_tc_state "$RULE_IFACE" "ingress" "$pref"
                    pref=$((pref + 1))
                else
                    warn "下行限速规则加载失败：ID=$RULE_ID proto=$proto iface=$RULE_IFACE"
                fi
            fi

            if (( RULE_UP_RATE_KBIT > 0 )); then
                burst="$(tc_burst_bytes "$RULE_UP_RATE_KBIT")"
                if tc filter add dev "$RULE_IFACE" egress pref "$pref" protocol ip flower \
                    ip_proto "$proto" src_ip "$RULE_TARGET_IP" src_port "$RULE_TARGET_PORT" \
                    action police rate "${RULE_UP_RATE_KBIT}kbit" burst "${burst}"b drop >/dev/null 2>&1; then
                    append_tc_state "$RULE_IFACE" "egress" "$pref"
                    pref=$((pref + 1))
                else
                    warn "上行限速规则加载失败：ID=$RULE_ID proto=$proto iface=$RULE_IFACE"
                fi
            fi
        done < <(protocols_for_mode "$RULE_PROTOCOL_MODE")
    done < "$DB_FILE"
}

get_nft_comment_bytes() {
    local comment="$1"
    local line
    local bytes

    line="$(nft list chain inet game_nat_forward_filter forward 2>/dev/null | grep -F "comment \"$comment\"" | head -n 1 || true)"
    if [[ -z "$line" ]]; then
        printf '0\n'
        return 0
    fi

    bytes="$(sed -n 's/.*counter packets [0-9]\+ bytes \([0-9]\+\).*/\1/p' <<< "$line" | head -n 1)"
    printf '%s\n' "${bytes:-0}"
}

get_iptables_comment_bytes() {
    local comment="$1"
    local line
    local bytes

    line="$(iptables-save -c -t filter 2>/dev/null | grep -F -- "--comment \"$comment\"" | head -n 1 || true)"
    if [[ -z "$line" ]]; then
        printf '0\n'
        return 0
    fi

    bytes="$(sed -n 's/^\[[0-9]\+:\([0-9]\+\)\].*/\1/p' <<< "$line" | head -n 1)"
    printf '%s\n' "${bytes:-0}"
}

get_rule_current_bytes() {
    local rule_id="$1"
    local protocol_mode="$2"
    local backend
    local proto
    local down_bytes=0
    local up_bytes=0
    local current_bytes

    backend="$(load_backend || true)"

    while IFS= read -r proto; do
        [[ -z "$proto" ]] && continue
        case "$backend" in
            nft)
                current_bytes="$(get_nft_comment_bytes "$COMMENT_TAG:$rule_id:$proto:fw-in")"
                down_bytes=$(( down_bytes + current_bytes ))
                current_bytes="$(get_nft_comment_bytes "$COMMENT_TAG:$rule_id:$proto:fw-out")"
                up_bytes=$(( up_bytes + current_bytes ))
                ;;
            iptables)
                current_bytes="$(get_iptables_comment_bytes "$COMMENT_TAG:$rule_id:$proto:fw-in")"
                down_bytes=$(( down_bytes + current_bytes ))
                current_bytes="$(get_iptables_comment_bytes "$COMMENT_TAG:$rule_id:$proto:fw-out")"
                up_bytes=$(( up_bytes + current_bytes ))
                ;;
            *)
                :
                ;;
        esac
    done < <(protocols_for_mode "$protocol_mode")

    printf '%s %s\n' "$down_bytes" "$up_bytes"
}

sync_rule_stats() {
    local rule_id="$1"
    local protocol_mode="$2"
    local current_down current_up
    local persist_down persist_up last_down last_up

    read -r current_down current_up <<< "$(get_rule_current_bytes "$rule_id" "$protocol_mode")"
    read -r persist_down persist_up last_down last_up <<< "$(stats_get_record "$rule_id")"

    if (( current_down < last_down )); then
        persist_down=$(( persist_down + last_down ))
    fi
    if (( current_up < last_up )); then
        persist_up=$(( persist_up + last_up ))
    fi

    stats_set_record "$rule_id" "$persist_down" "$persist_up" "$current_down" "$current_up"
}

sync_all_rule_stats() {
    local line

    while IFS= read -r line; do
        parse_rule_line "$line" || continue
        sync_rule_stats "$RULE_ID" "$RULE_PROTOCOL_MODE"
    done < "$DB_FILE"
}

get_rule_total_bytes() {
    local rule_id="$1"
    local persist_down persist_up last_down last_up

    read -r persist_down persist_up last_down last_up <<< "$(stats_get_record "$rule_id")"
    printf '%s %s\n' "$((persist_down + last_down))" "$((persist_up + last_up))"
}

apply_rules() {
    local backend

    sync_all_rule_stats
    backend="$(select_backend)"

    case "$backend" in
        nft)
            cleanup_iptables_only
            apply_nft_rules
            ;;
        iptables)
            cleanup_nft_only
            apply_iptables_rules
            ;;
        *)
            die "未知 NAT 后端：$backend"
            ;;
    esac

    apply_tc_limits
}

rule_loaded_nft() {
    local rule_id="$1"
    local protocol_mode="$2"
    local proto
    local nat_dump

    nat_dump="$(nft list table ip game_nat_forward_nat 2>/dev/null || true)"
    [[ -n "$nat_dump" ]] || return 1

    while IFS= read -r proto; do
        [[ -z "$proto" ]] && continue
        grep -Fq "$COMMENT_TAG:$rule_id:$proto:dnat" <<< "$nat_dump" || return 1
    done < <(protocols_for_mode "$protocol_mode")

    return 0
}

rule_loaded_iptables() {
    local rule_id="$1"
    local protocol_mode="$2"
    local proto
    local nat_dump

    nat_dump="$(iptables-save -t nat 2>/dev/null || true)"
    [[ -n "$nat_dump" ]] || return 1

    while IFS= read -r proto; do
        [[ -z "$proto" ]] && continue
        grep -Fq "$COMMENT_TAG:$rule_id:$proto:dnat" <<< "$nat_dump" || return 1
    done < <(protocols_for_mode "$protocol_mode")

    return 0
}

rule_loaded_status() {
    local rule_id="$1"
    local protocol_mode="$2"
    local disabled_reason="$3"
    local backend

    is_rule_disabled "$disabled_reason" && return 1

    backend="$(load_backend || true)"
    case "$backend" in
        nft)
            rule_loaded_nft "$rule_id" "$protocol_mode"
            ;;
        iptables)
            rule_loaded_iptables "$rule_id" "$protocol_mode"
            ;;
        *)
            return 1
            ;;
    esac
}

rule_limit_reason() {
    local up_bytes="$1"
    local down_bytes="$2"
    local up_limit="$3"
    local down_limit="$4"
    local max_limit="$5"
    local max_mode="$6"

    if (( up_limit > 0 && up_bytes >= up_limit )); then
        printf '上行累计流量达到限制'
        return 0
    fi

    if (( down_limit > 0 && down_bytes >= down_limit )); then
        printf '下行累计流量达到限制'
        return 0
    fi

    if (( max_limit > 0 )); then
        case "$max_mode" in
            either)
                if (( up_bytes >= max_limit || down_bytes >= max_limit )); then
                    printf '最大累计流量限制触发（任一方向）'
                    return 0
                fi
                ;;
            up)
                if (( up_bytes >= max_limit )); then
                    printf '最大累计流量限制触发（上行）'
                    return 0
                fi
                ;;
            down)
                if (( down_bytes >= max_limit )); then
                    printf '最大累计流量限制触发（下行）'
                    return 0
                fi
                ;;
            sum)
                if (( up_bytes + down_bytes >= max_limit )); then
                    printf '最大累计流量限制触发（上下行合计）'
                    return 0
                fi
                ;;
            none)
                ;;
        esac
    fi

    printf '\n'
}

rule_limit_reason_sum() {
    local up_bytes="$1"
    local down_bytes="$2"
    local up_limit="$3"
    local down_limit="$4"
    local max_limit="$5"

    if (( up_limit > 0 && up_bytes >= up_limit )); then
        printf '上行累计流量达到限制'
        return 0
    fi

    if (( down_limit > 0 && down_bytes >= down_limit )); then
        printf '下行累计流量达到限制'
        return 0
    fi

    if (( max_limit > 0 && up_bytes + down_bytes >= max_limit )); then
        printf '最大累计流量限制触发（上下双向 sum）'
        return 0
    fi

    printf '\n'
}

check_limits() {
    local quiet="${1:-0}"
    local tmp_file
    local changed=0
    local line
    local up_bytes down_bytes reason

    sync_all_rule_stats

    tmp_file="$(mktemp)"

    while IFS= read -r line; do
        if ! parse_rule_line "$line"; then
            printf '%s\n' "$line" >> "$tmp_file"
            continue
        fi

        if is_rule_disabled "$RULE_DISABLED_REASON"; then
            serialize_current_rule >> "$tmp_file"
            continue
        fi

        read -r down_bytes up_bytes <<< "$(get_rule_total_bytes "$RULE_ID")"
        reason="$(rule_limit_reason_sum "$up_bytes" "$down_bytes" "$RULE_UP_TOTAL_LIMIT" "$RULE_DOWN_TOTAL_LIMIT" "$RULE_MAX_TOTAL_LIMIT")"
        if [[ -n "$reason" ]]; then
            RULE_DISABLED_REASON="$reason"
            changed=1
            if [[ "$quiet" -ne 1 ]]; then
                warn "规则 $RULE_ID 已自动停用：$reason"
            fi
        fi

        serialize_current_rule >> "$tmp_file"
    done < "$DB_FILE"

    if [[ "$changed" -eq 1 ]]; then
        mv "$tmp_file" "$DB_FILE"
        chmod 600 "$DB_FILE"
        apply_rules
        return 10
    fi

    rm -f "$tmp_file"
    return 0
}

export_rules() {
    local export_path

    read -r -p "导出文件路径 [默认 /root/game-nat-forward-export-$(date +%Y%m%d-%H%M%S).db]: " export_path
    export_path="${export_path:-/root/game-nat-forward-export-$(date +%Y%m%d-%H%M%S).db}"

    if [[ -e "$export_path" ]]; then
        die "导出文件已存在：$export_path"
    fi

    sync_all_rule_stats

    {
        printf '%s\n' "$EXPORT_MAGIC"
        printf '# generated_at=%s\n' "$(date -Is)"
        printf '# format=id|protocol_mode|external_port|target_ip|target_port|iface|up_rate_kbit|down_rate_kbit|up_total_limit_bytes|down_total_limit_bytes|max_total_limit_bytes|max_total_mode|disabled_reason\n'
        grep -Ev '^[[:space:]]*#|^[[:space:]]*$' "$DB_FILE" || true
    } > "$export_path"

    chmod 600 "$export_path"
    printf '规则已导出到：%s\n' "$export_path"
}

import_rules() {
    local import_path
    local import_mode
    local line
    local tmp_file
    local merged_count=0

    read -r -p "导入文件路径: " import_path
    [[ -n "$import_path" ]] || die "导入文件路径不能为空。"
    [[ -f "$import_path" ]] || die "导入文件不存在：$import_path"

    read -r -p "导入模式 [默认 merge，可选 merge / replace]: " import_mode
    import_mode="${import_mode:-merge}"
    [[ "$import_mode" == "merge" || "$import_mode" == "replace" ]] || die "导入模式无效。"

    tmp_file="$(mktemp)"
    printf '# id|protocol_mode|external_port|target_ip|target_port|iface|up_rate_kbit|down_rate_kbit|up_total_limit_bytes|down_total_limit_bytes|max_total_limit_bytes|max_total_mode|disabled_reason\n' > "$tmp_file"

    while IFS= read -r line; do
        [[ -n "${line//[[:space:]]/}" ]] || continue
        [[ ! "$line" =~ ^[[:space:]]*# ]] || continue

        parse_rule_line "$line" || die "导入文件中存在无效规则：$line"

        if [[ "$import_mode" == "merge" ]] && rule_exists "$RULE_PROTOCOL_MODE" "$RULE_EXTERNAL_PORT" "$RULE_TARGET_IP" "$RULE_TARGET_PORT"; then
            warn "已跳过重复规则：$RULE_PROTOCOL_MODE $RULE_EXTERNAL_PORT -> $RULE_TARGET_IP:$RULE_TARGET_PORT"
            continue
        fi

        if awk -F'|' -v rid="$RULE_ID" 'BEGIN{found=0} /^[[:space:]]*#/ {next} NF==0 {next} $1==rid {found=1} END{exit found?0:1}' "$DB_FILE" >/dev/null 2>&1; then
            RULE_ID="$(generate_rule_id)"
        fi

        serialize_current_rule >> "$tmp_file"
        merged_count=$((merged_count + 1))
    done < "$import_path"

    if [[ "$import_mode" == "replace" ]]; then
        sync_all_rule_stats
        mv "$tmp_file" "$DB_FILE"
        printf '# id|persist_down_bytes|persist_up_bytes|last_down_bytes|last_up_bytes\n' > "$STATS_FILE"
    else
        while IFS= read -r line; do
            [[ -n "${line//[[:space:]]/}" ]] || continue
            [[ ! "$line" =~ ^[[:space:]]*# ]] || continue
            printf '%s\n' "$line" >> "$DB_FILE"
        done < "$tmp_file"
        rm -f "$tmp_file"
    fi

    install_systemd_units
    enable_ipv4_forward
    apply_rules

    printf '导入完成，共处理 %s 条规则。\n' "$merged_count"
}

show_rules() {
    local found=0
    local line
    local loaded
    local down_bytes up_bytes
    local down_human up_human
    local up_rate_human down_rate_human

    check_limits 1 || true
    sync_all_rule_stats

    printf '%-24s %-10s %-8s %-15s %-8s %-8s %-10s %-10s %-12s %-12s %-10s\n' \
        "ID" "协议" "外端口" "目标IP" "目标端口" "网卡" "已加载" "状态" "下行流量" "上行流量" "限制"
    printf '%-24s %-10s %-8s %-15s %-8s %-8s %-10s %-10s %-12s %-12s %-10s\n' \
        "------------------------" "----------" "--------" "---------------" "--------" "--------" "----------" "----------" "------------" "------------" "----------"

    while IFS= read -r line; do
        parse_rule_line "$line" || continue
        found=1

        if rule_loaded_status "$RULE_ID" "$RULE_PROTOCOL_MODE" "$RULE_DISABLED_REASON"; then
            loaded="yes"
        else
            loaded="no"
        fi

        read -r down_bytes up_bytes <<< "$(get_rule_total_bytes "$RULE_ID")"
        down_human="$(format_bytes "$down_bytes")"
        up_human="$(format_bytes "$up_bytes")"
        up_rate_human="$(format_rate "$RULE_UP_RATE_KBIT")"
        down_rate_human="$(format_rate "$RULE_DOWN_RATE_KBIT")"

        printf '%-24s %-10s %-8s %-15s %-8s %-8s %-10s %-10s %-12s %-12s %-10s\n' \
            "$RULE_ID" \
            "$RULE_PROTOCOL_MODE" \
            "$RULE_EXTERNAL_PORT" \
            "$RULE_TARGET_IP" \
            "$RULE_TARGET_PORT" \
            "$RULE_IFACE" \
            "$loaded" \
            "${RULE_DISABLED_REASON:-active}" \
            "$down_human" \
            "$up_human" \
            "D:${down_rate_human}/U:${up_rate_human}"
    done < "$DB_FILE"

    if [[ "$found" -eq 0 ]]; then
        printf '当前没有规则。\n'
        return 0
    fi

    printf '\n累计流量限制说明：规则命中上/下行阈值，或命中最大累计阈值后，会由定时检查服务自动停用。\n'
}

show_backend_summary() {
    local backend
    backend="$(load_backend || true)"
    if [[ -z "$backend" ]]; then
        printf '后端: 未初始化\n'
    else
        printf '后端: %s\n' "$backend"
    fi
}

show_status() {
    local restore_enabled="unknown"
    local restore_active="unknown"
    local timer_enabled="unknown"
    local timer_active="unknown"

    check_limits 1 || true
    sync_all_rule_stats

    printf '提示: %s\n' "$BEST_EFFORT_NOTICE"
    printf '提示: %s\n' "$RATE_LIMIT_NOTICE"
    printf 'ip_forward: %s\n' "$(sysctl -n net.ipv4.ip_forward 2>/dev/null || printf 'unknown')"
    show_backend_summary

    if [[ -f "$RESTORE_SERVICE_FILE" ]]; then
        restore_enabled="$(systemctl is-enabled "$RESTORE_SERVICE_NAME" 2>/dev/null || true)"
        restore_active="$(systemctl is-active "$RESTORE_SERVICE_NAME" 2>/dev/null || true)"
    fi

    if [[ -f "$CHECK_TIMER_FILE" ]]; then
        timer_enabled="$(systemctl is-enabled "$CHECK_TIMER_NAME" 2>/dev/null || true)"
        timer_active="$(systemctl is-active "$CHECK_TIMER_NAME" 2>/dev/null || true)"
    fi

    printf '恢复服务 enable 状态: %s\n' "${restore_enabled:-unknown}"
    printf '恢复服务 active 状态: %s\n' "${restore_active:-unknown}"
    printf '检查定时器 enable 状态: %s\n' "${timer_enabled:-unknown}"
    printf '检查定时器 active 状态: %s\n' "${timer_active:-unknown}"

    case "$(load_backend || true)" in
        nft)
            printf '\n[nftables 摘要]\n'
            nft list table ip game_nat_forward_nat 2>/dev/null || printf '未检测到 game_nat_forward_nat 表。\n'
            printf '\n'
            nft list table inet game_nat_forward_filter 2>/dev/null || printf '未检测到 game_nat_forward_filter 表。\n'
            ;;
        iptables)
            printf '\n[iptables nat 摘要]\n'
            iptables -t nat -S 2>/dev/null || printf '无法读取 iptables nat 规则。\n'
            printf '\n[iptables filter 摘要]\n'
            iptables -S 2>/dev/null || printf '无法读取 iptables filter 规则。\n'
            ;;
        *)
            printf '尚未初始化 NAT 后端。\n'
            ;;
    esac

    if command -v tc >/dev/null 2>&1; then
        printf '\n[tc 限速摘要]\n'
        awk -F'|' 'BEGIN{count=0} /^[[:space:]]*#/ {next} NF==0 {next} {count++} END{print "已登记 tc 过滤器数: " count}' "$TC_STATE_FILE"
    else
        printf '\n[tc 限速摘要]\n未安装 tc / iproute2。\n'
    fi
}

prompt_protocol_mode() {
    local answer
    while true; do
        read -r -p "协议模式 [默认 tcp+udp，可选 tcp / udp]: " answer
        answer="${answer:-$DEFAULT_PROTOCOL_MODE}"
        if validate_protocol_mode "$answer"; then
            printf '%s\n' "$answer"
            return 0
        fi
        warn "协议模式无效，请输入 tcp+udp、tcp 或 udp。"
    done
}

prompt_port() {
    local label="$1"
    local answer
    while true; do
        read -r -p "$label: " answer
        if validate_port "$answer"; then
            printf '%s\n' "$answer"
            return 0
        fi
        warn "端口无效，请输入 1-65535。"
    done
}

prompt_ip() {
    local answer
    while true; do
        read -r -p "目标内网 IP 或目标远程 IP: " answer
        if validate_ip "$answer"; then
            printf '%s\n' "$answer"
            return 0
        fi
        warn "IP 格式无效。"
    done
}

prompt_iface() {
    local detected default_hint answer
    detected="$(detect_default_iface || true)"
    default_hint="$detected"

    while true; do
        if [[ -n "$default_hint" ]]; then
            read -r -p "出口网卡 [默认 $default_hint]: " answer
            answer="${answer:-$default_hint}"
        else
            read -r -p "出口网卡: " answer
        fi

        if [[ -n "$answer" ]] && ip link show "$answer" >/dev/null 2>&1; then
            printf '%s\n' "$answer"
            return 0
        fi
        warn "网卡不存在，请重新输入。"
    done
}

prompt_nonnegative_int() {
    local label="$1"
    local default_value="$2"
    local answer

    while true; do
        read -r -p "$label [默认 $default_value]: " answer
        answer="${answer:-$default_value}"
        if validate_nonnegative_int "$answer"; then
            printf '%s\n' "$answer"
            return 0
        fi
        warn "请输入大于等于 0 的整数。"
    done
}

prompt_max_total_mode() {
    local answer

    while true; do
        read -r -p "最大累计流量判断模式 [默认 either，可选 none / either / up / down / sum]: " answer
        answer="${answer:-$DEFAULT_MAX_TOTAL_MODE}"
        if validate_max_total_mode "$answer"; then
            printf '%s\n' "$answer"
            return 0
        fi
        warn "模式无效，请输入 none、either、up、down 或 sum。"
    done
}

add_rule() {
    local protocol_mode
    local external_port
    local target_ip
    local target_port
    local iface
    local up_rate_kbit
    local down_rate_kbit
    local up_total_limit
    local down_total_limit
    local max_total_limit
    local max_total_mode
    local rule_id

    protocol_mode="$(prompt_protocol_mode)"
    external_port="$(prompt_port '本地监听端口（外部入口端口）')"
    target_ip="$(prompt_ip)"
    target_port="$(prompt_port '目标端口')"
    iface="$(prompt_iface)"
    up_rate_kbit="$(prompt_nonnegative_int '上行速度限制（Kbit/s，0 为不限）' '0')"
    down_rate_kbit="$(prompt_nonnegative_int '下行速度限制（Kbit/s，0 为不限）' '0')"
    up_total_limit="$(prompt_nonnegative_int '上行累计流量限制（字节，0 为不限）' '0')"
    down_total_limit="$(prompt_nonnegative_int '下行累计流量限制（字节，0 为不限）' '0')"
    max_total_limit="$(prompt_nonnegative_int '最大累计流量限制（字节，0 为不用此项）' '0')"

    if (( max_total_limit > 0 )); then
        max_total_mode="$(prompt_max_total_mode)"
    else
        max_total_mode="none"
    fi

    if rule_exists "$protocol_mode" "$external_port" "$target_ip" "$target_port"; then
        warn "相同规则已存在，已拒绝重复添加。"
        return 0
    fi

    rule_id="$(generate_rule_id)"
    append_rule_db "$rule_id" "$protocol_mode" "$external_port" "$target_ip" "$target_port" "$iface" \
        "$up_rate_kbit" "$down_rate_kbit" "$up_total_limit" "$down_total_limit" "$max_total_limit" "$max_total_mode"
    stats_set_record "$rule_id" 0 0 0 0

    enable_ipv4_forward
    install_systemd_units
    apply_rules
    systemctl restart "$RESTORE_SERVICE_NAME" >/dev/null 2>&1 || true
    systemctl restart "$CHECK_TIMER_NAME" >/dev/null 2>&1 || true

    printf '规则已添加，ID: %s\n' "$rule_id"
    printf '%s\n' "$BEST_EFFORT_NOTICE"
    printf '%s\n' "$RATE_LIMIT_NOTICE"
}

prompt_traffic_limit() {
    local label="$1"
    local default_value="$2"
    local answer

    while true; do
        read -r -p "$label [默认 $default_value，支持直接输入 100G]: " answer
        answer="${answer:-$default_value}"
        if validate_traffic_limit_input "$answer"; then
            normalize_traffic_limit_input "$answer"
            return 0
        fi
        warn "请输入大于等于 0 的整数，或以 G 结尾的数值（例如 100G）。"
    done
}

add_rule_v2() {
    local protocol_mode
    local external_port
    local target_ip
    local target_port
    local iface
    local up_rate_kbit
    local down_rate_kbit
    local up_total_limit
    local down_total_limit
    local max_total_limit
    local max_total_mode
    local rule_id

    protocol_mode="$(prompt_protocol_mode)"
    external_port="$(prompt_port '本地监听端口（外部入口端口）')"
    target_ip="$(prompt_ip)"
    target_port="$(prompt_port '目标端口')"
    iface="$(prompt_iface)"
    up_rate_kbit="$(prompt_nonnegative_int '上行速度限制（kbit/s，0 表示不限速）' '0')"
    down_rate_kbit="$(prompt_nonnegative_int '下行速度限制（kbit/s，0 表示不限速）' '0')"
    up_total_limit="$(prompt_traffic_limit '上行累计流量限制（单位字节，0 表示不限制，按上行累计计算，满足条件暂停转发）' '0')"
    down_total_limit="$(prompt_traffic_limit '下行累计流量限制（单位字节，0 表示不限制，按下行累计计算，满足条件暂停转发）' '0')"
    max_total_limit="$(prompt_traffic_limit '最大累计流量限制（单位字节，0 表示不启用，按上下双向 sum 计算，满足条件暂停转发）' '0')"

    if (( max_total_limit > 0 )); then
        max_total_mode="$DEFAULT_MAX_TOTAL_MODE"
    else
        max_total_mode="none"
    fi

    if rule_exists "$protocol_mode" "$external_port" "$target_ip" "$target_port"; then
        warn "相同规则已存在，已拒绝重复添加。"
        return 0
    fi

    rule_id="$(generate_rule_id)"
    append_rule_db "$rule_id" "$protocol_mode" "$external_port" "$target_ip" "$target_port" "$iface" \
        "$up_rate_kbit" "$down_rate_kbit" "$up_total_limit" "$down_total_limit" "$max_total_limit" "$max_total_mode"
    stats_set_record "$rule_id" 0 0 0 0

    enable_ipv4_forward
    install_systemd_units
    apply_rules
    systemctl restart "$RESTORE_SERVICE_NAME" >/dev/null 2>&1 || true
    systemctl restart "$CHECK_TIMER_NAME" >/dev/null 2>&1 || true

    printf '规则已添加，ID: %s\n' "$rule_id"
    printf '%s\n' "$BEST_EFFORT_NOTICE"
    printf '%s\n' "$RATE_LIMIT_NOTICE"
}

prompt_rule_id() {
    local answer
    read -r -p "请输入要删除的规则 ID: " answer
    printf '%s\n' "$answer"
}

delete_rule() {
    local rule_id

    rule_id="$(prompt_rule_id)"
    [[ -n "$rule_id" ]] || die "规则 ID 不能为空。"

    sync_all_rule_stats

    if ! remove_rule_db_by_id "$rule_id"; then
        warn "未找到 ID 为 $rule_id 的规则。"
        return 0
    fi

    stats_remove_record "$rule_id"
    apply_rules
    systemctl restart "$RESTORE_SERVICE_NAME" >/dev/null 2>&1 || true
    printf '规则已删除: %s\n' "$rule_id"
}

restore_runtime_state() {
    init_storage
    ensure_command ip iproute2
    enable_ipv4_forward
    apply_rules
    check_limits 1 || true
}

uninstall_all() {
    local confirm

    read -r -p "确认卸载全部规则和配置？输入 yes 继续: " confirm
    [[ "$confirm" == "yes" ]] || {
        printf '已取消。\n'
        return 0
    }

    cleanup_nft_only
    cleanup_iptables_only
    cleanup_tc_filters

    systemctl disable --now "$CHECK_TIMER_NAME" >/dev/null 2>&1 || true
    systemctl disable --now "$RESTORE_SERVICE_NAME" >/dev/null 2>&1 || true
    systemctl stop "$CHECK_SERVICE_NAME" >/dev/null 2>&1 || true

    rm -f "$RESTORE_SERVICE_FILE" "$CHECK_SERVICE_FILE" "$CHECK_TIMER_FILE"
    rm -f "$RUNTIME_SCRIPT"
    rm -f "$SYSCTL_FILE"
    rm -rf "$BASE_DIR"
    systemctl daemon-reload

    if sysctl -n net.ipv4.ip_forward >/dev/null 2>&1; then
        warn "已删除本脚本的持久化 sysctl 配置；当前运行中的 net.ipv4.ip_forward 值未强制回退，以避免误伤系统其他转发场景。"
    fi

    printf '已清理本脚本创建的 NAT、限速、持久化配置与 systemd 单元。\n'
}

print_menu() {
    cat <<EOF

==== Game NAT Forward Manager ====
1. 添加转发规则
2. 删除转发规则
3. 查看当前规则
4. 查看当前 NAT / 转发状态
5. 导出规则
6. 导入规则
7. 卸载全部规则和配置
8. 退出
EOF
}

main_menu() {
    local choice

    while true; do
        print_menu
        read -r -p "请选择 [1-8]: " choice
        case "$choice" in
            1)
                add_rule_v2
                ;;
            2)
                delete_rule
                ;;
            3)
                show_rules
                ;;
            4)
                show_status
                ;;
            5)
                export_rules
                ;;
            6)
                import_rules
                ;;
            7)
                uninstall_all
                ;;
            8)
                exit 0
                ;;
            *)
                warn "无效选项，请重新输入。"
                ;;
        esac
    done
}

main() {
    require_root
    init_storage

    case "${1:-}" in
        --restore)
            restore_runtime_state
            ;;
        --show-rules)
            show_rules
            ;;
        --status)
            show_status
            ;;
        --check-limits)
            check_limits 1 || true
            ;;
        --export)
            export_rules
            ;;
        --import)
            import_rules
            ;;
        --uninstall)
            uninstall_all
            ;;
        "")
            printf '%s\n' "$BEST_EFFORT_NOTICE"
            printf '%s\n' "$RATE_LIMIT_NOTICE"
            main_menu
            ;;
        *)
            die "不支持的参数：$1"
            ;;
    esac
}

main "$@"
