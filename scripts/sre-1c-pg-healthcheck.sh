#!/usr/bin/env bash
# ==============================================================================
# SRE-Suite-for-1C-platform — Production Health Check & Diagnostic Tool (v1.2)
# Subsystem: Linux Kernel ↔ PostgreSQL/Patroni ↔ 1C:Enterprise Cluster
# License: MIT (NickScherbakov/1c-sre-suite)
# ==============================================================================

set -uo pipefail

# --- Терминальная палитра ---
RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
CYAN='\033[1;36m'
BOLD='\033[1m'
NC='\033[0m'

GENERATE_FIX=false
FIX_FILE=""

if [[ "${1:-}" == "--generate-fix" ]]; then
    GENERATE_FIX=true
    FIX_FILE="$(mktemp /tmp/sre-healthcheck-fix.XXXXXX.sh)"
    cat << 'EOF' > "$FIX_FILE"
#!/usr/bin/env bash
# SRE-Suite-for-1C-platform Auto-Remediation Script
set -euo pipefail
echo "[*] Applying kernel and system remediations..."
EOF
    chmod +x "$FIX_FILE"
fi

OK_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0

log_ok() {
    echo -e " [${GREEN}OK${NC}]   $1"
    ((++OK_COUNT))
}

log_info() {
    echo -e " [${BLUE}INFO${NC}] $1"
}

log_warn() {
    echo -e " [${YELLOW}WARN${NC}] $1"
    if [[ -n "${2:-}" ]]; then
        echo -e "        ${CYAN}--> RECOMMENDATION:${NC} $2"
    fi
    ((++WARN_COUNT))
}

log_fail() {
    echo -e " [${RED}FAIL${NC}] $1"
    if [[ -n "${2:-}" ]]; then
        echo -e "        ${CYAN}--> FIX ACTION:${NC} $2"
    fi
    ((++FAIL_COUNT))
}

add_fix_command() {
    if [[ "$GENERATE_FIX" == true ]] && [[ -n "${1:-}" ]]; then
        echo "$1" >> "$FIX_FILE"
    fi
}

header() {
    echo -e "${BOLD}${BLUE}================================================================================${NC}"
    echo -e "${BOLD}${CYAN} SRE-Suite-for-1C-platform — System & Database Health Check (v1.2)${NC}"
    echo -e " Host: ${BOLD}$(hostname)${NC} | Kernel: $(uname -r) | Date: $(date '+%Y-%m-%d %H:%M:%S')"
    echo -e "${BOLD}${BLUE}================================================================================${NC}"
    echo ""
}

check_kernel_and_vm() {
    echo -e "${BOLD}[1. LINUX KERNEL & VIRTUAL MEMORY (OS HEALTH)]${NC}"

    # 1. Transparent Huge Pages (THP)
    local thp_file="/sys/kernel/mm/transparent_hugepage/enabled"
    if [[ -f "$thp_file" ]]; then
        local thp_status
        thp_status=$(cat "$thp_file")
        if [[ "$thp_status" == *"[never]"* ]]; then
            log_ok "Transparent Huge Pages (THP): disabled (never)"
        else
            log_fail "Transparent Huge Pages: $thp_status" \
                     "Disable via sysfs now and set 'transparent_hugepage=never' in GRUB"
            add_fix_command "# Runtime THP Disable"
            add_fix_command "echo never > /sys/kernel/mm/transparent_hugepage/enabled"
            add_fix_command "echo never > /sys/kernel/mm/transparent_hugepage/defrag"
        fi
    else
        log_warn "THP sysfs interface not found ($thp_file)"
    fi

    # 2. vm.swappiness
    local swappiness
    swappiness=$(sysctl -n vm.swappiness 2>/dev/null || echo "60")
    if [[ "$swappiness" -le 10 ]]; then
        log_ok "vm.swappiness = $swappiness (Optimal for PostgreSQL & 1C)"
    else
        log_warn "vm.swappiness = $swappiness (Recommended <= 10 to prevent premature swapping)" \
                 "Set vm.swappiness=10 in /etc/sysctl.d/99-1c-postgresql.conf"
        add_fix_command "sysctl -w vm.swappiness=10"
    fi

    # 3. Dirty Pages (Байты vs Проценты)
    local dirty_bytes dirty_bg_bytes
    dirty_bytes=$(sysctl -n vm.dirty_bytes 2>/dev/null || echo "0")
    dirty_bg_bytes=$(sysctl -n vm.dirty_background_bytes 2>/dev/null || echo "0")

    if [[ "$dirty_bytes" -gt 0 && "$dirty_bg_bytes" -gt 0 ]]; then
        local bg_mb=$(( dirty_bg_bytes / 1024 / 1024 ))
        local limit_mb=$(( dirty_bytes / 1024 / 1024 ))
        log_ok "Dirty memory (absolute): background=${bg_mb}MB, limit=${limit_mb}MB (Smooth I/O)"
    else
        local dirty_bg dirty_ratio
        dirty_bg=$(sysctl -n vm.dirty_background_ratio 2>/dev/null || echo "10")
        dirty_ratio=$(sysctl -n vm.dirty_ratio 2>/dev/null || echo "20")
        if [[ "$dirty_bg" -le 10 && "$dirty_ratio" -le 20 ]]; then
            log_ok "Dirty page ratios: background=$dirty_bg%, ratio=$dirty_ratio% (Acceptable)"
        else
            log_warn "Dirty page ratios high (bg=$dirty_bg%, ratio=$dirty_ratio%)" \
                     "Configure absolute limits: dirty_background_bytes=1073741824, dirty_bytes=4294967296"
            add_fix_command "sysctl -w vm.dirty_background_bytes=1073741824"
            add_fix_command "sysctl -w vm.dirty_bytes=4294967296"
        fi
    fi

    # 4. vm.overcommit_memory
    local overcommit
    overcommit=$(sysctl -n vm.overcommit_memory 2>/dev/null || echo "0")
    if [[ "$overcommit" -eq 2 ]]; then
        log_ok "vm.overcommit_memory = 2 (Strict Don't Overcommit — Safe for dedicated DB)"
    else
        log_warn "vm.overcommit_memory = $overcommit (Recommended 2 for dedicated PostgreSQL/1C nodes)" \
                 "Set vm.overcommit_memory=2 in /etc/sysctl.d/99-1c-postgresql.conf"
    fi

    # 5. net.ipv4.ip_nonlocal_bind (Критично для vip-manager)
    local nonlocal_bind
    nonlocal_bind=$(sysctl -n net.ipv4.ip_nonlocal_bind 2>/dev/null || echo "0")
    if [[ "$nonlocal_bind" -eq 1 ]]; then
        log_ok "net.ipv4.ip_nonlocal_bind = 1 (vip-manager ready)"
    else
        log_fail "net.ipv4.ip_nonlocal_bind = $nonlocal_bind (vip-manager cannot bind Virtual IP!)" \
                 "Execute sysctl -w net.ipv4.ip_nonlocal_bind=1"
        add_fix_command "sysctl -w net.ipv4.ip_nonlocal_bind=1"
    fi

    # 6. net.core.somaxconn
    local somaxconn
    somaxconn=$(sysctl -n net.core.somaxconn 2>/dev/null || echo "128")
    if [[ "$somaxconn" -ge 4096 ]]; then
        log_ok "net.core.somaxconn = $somaxconn (High-concurrency sockets ready)"
    else
        log_warn "net.core.somaxconn = $somaxconn (Recommended >= 4096 for heavy 1C client pools)" \
                 "Set net.core.somaxconn=4096 in sysctl"
        add_fix_command "sysctl -w net.core.somaxconn=4096"
    fi

    echo ""
}

check_postgres_patroni() {
    echo -e "${BOLD}[2. POSTGRESQL & PATRONI HIGH-AVAILABILITY CLUSTER]${NC}"

    # Проверка REST API Patroni с таймаутом
    if command -v curl &>/dev/null; then
        local patroni_url="http://localhost:8008"
        local http_code
        http_code=$(curl -s --connect-timeout 2 --max-time 3 -o /dev/null -w "%{http_code}" "$patroni_url/cluster" 2>/dev/null || echo "000")

        if [[ "$http_code" =~ ^[0-9]+$ ]] && [[ "$http_code" -eq 200 ]]; then
            local role_raw role_clean
            role_raw=$(curl -s --connect-timeout 2 --max-time 3 "$patroni_url/patroni" 2>/dev/null || echo "")
            role_clean=$(echo "$role_raw" | awk -F'"role":"' '{print $2}' | awk -F'"' '{print $1}' | tr '[:lower:]' '[:upper:]')
            [[ -z "$role_clean" ]] && role_clean="UNKNOWN"
            log_ok "Patroni REST API: ${BOLD}${role_clean}${NC} node active | Cluster State: running"
        else
            log_warn "Patroni REST API unreachable on $patroni_url/cluster (HTTP $http_code)" \
                     "Verify Patroni daemon service: systemctl status patroni"
        fi
    else
        log_info "curl not installed; skipping Patroni REST API probe"
    fi

    # Безопасное подключение к PostgreSQL
    local psql_cmd=""
    if command -v psql &>/dev/null; then
        if [[ $EUID -eq 0 ]] && id -u postgres &>/dev/null; then
            psql_cmd="sudo -n -u postgres psql -d postgres -t -A"
        elif psql -U postgres -d postgres -c '\q' 2>/dev/null; then
            psql_cmd="psql -U postgres -d postgres -t -A"
        fi
    fi

    if [[ -n "$psql_cmd" ]]; then
        local locks
        locks=$($psql_cmd -c "SHOW max_locks_per_transaction;" 2>/dev/null || echo "0")
        if [[ "$locks" =~ ^[0-9]+$ ]] && [[ "$locks" -ge 256 ]]; then
            log_ok "max_locks_per_transaction = $locks"

            local active_locks
            active_locks=$($psql_cmd -c "SELECT count(*) FROM pg_locks;" 2>/dev/null || echo "0")
            if [[ "$active_locks" =~ ^[0-9]+$ ]] && [[ "$active_locks" -gt 0 ]]; then
                local lock_density=$(( active_locks * 100 / locks ))
                if [[ "$lock_density" -ge 70 ]]; then
                    log_warn "Lock heuristic: $active_locks active locks, max_locks_per_transaction=$locks (density ~${lock_density}%)" \
                             "High lock pressure detected; consider increasing max_locks_per_transaction"
                else
                    log_ok "Lock heuristic: $active_locks active locks, max_locks_per_transaction=$locks (density ~${lock_density}%)"
                fi
            fi
        elif [[ "$locks" =~ ^[0-9]+$ ]] && [[ "$locks" -gt 0 ]]; then
            log_fail "max_locks_per_transaction = $locks (Dangerous for 1C! Recommended >= 256)" \
                     "Update patroni.yml / postgresql.conf with max_locks_per_transaction: 256"
        fi

        local max_conn
        max_conn=$($psql_cmd -c "SHOW max_connections;" 2>/dev/null || echo "0")
        if [[ "$max_conn" =~ ^[0-9]+$ ]] && [[ "$max_conn" -ge 250 ]]; then
            log_ok "max_connections = $max_conn (Ready for high background task volume)"
        elif [[ "$max_conn" =~ ^[0-9]+$ ]] && [[ "$max_conn" -gt 0 ]]; then
            log_warn "max_connections = $max_conn (Recommended >= 250)"
        fi
    else
        log_info "No direct PostgreSQL peer-access; skipping in-engine parameter checks"
    fi

    echo ""
}

check_1c_cluster() {
    echo -e "${BOLD}[3. 1C:ENTERPRISE CLUSTER & RPHOST PROCESS ANALYSIS]${NC}"

    # Ищем строго исполняемые процессы rphost без захвата grep и вспомогательных скриптов
    local rphost_pids
    rphost_pids=$(pgrep -x "rphost" 2>/dev/null || true)

    if [[ -z "$rphost_pids" ]]; then
        log_info "No active 'rphost' processes found on this host (Normal for dedicated DB node)"
    else
        local rphost_count
        rphost_count=$(printf '%s\n' "$rphost_pids" | sed '/^$/d' | wc -l)
        log_ok "Active rphost worker processes: $rphost_count"

        for pid in $rphost_pids; do
            local proc_status="/proc/$pid/status"
            if [[ -f "$proc_status" ]]; then
                local rss_kb swap_kb
                rss_kb=$(awk '/VmRSS:/ {print $2}' "$proc_status" 2>/dev/null || echo "0")
                swap_kb=$(awk '/VmSwap:/ {print $2}' "$proc_status" 2>/dev/null || echo "0")

                # Точный расчёт через awk с округлением до одного знака
                local mem_stats
                mem_stats=$(awk -v r="$rss_kb" -v s="$swap_kb" 'BEGIN {
                    printf "%.1f %.1f", r/1048576, s/1048576
                }')
                local rss_gb swap_gb
                rss_gb=$(echo "$mem_stats" | awk '{print $1}')
                swap_gb=$(echo "$mem_stats" | awk '{print $2}')

                # Логика детекции: Swap > 256 МБ И Swap составляет более 15% от текущего RSS
                local is_leaking=false
                if (( swap_kb > 262144 )); then
                    if (( rss_kb > 0 )); then
                        local ratio=$(( swap_kb * 100 / rss_kb ))
                        if (( ratio > 15 )); then
                            is_leaking=true
                        fi
                    else
                        is_leaking=true
                    fi
                fi

                if [[ "$is_leaking" == true ]]; then
                    log_warn "PID $pid (rphost): RSS = ${rss_gb} GB, SWAP = ${swap_gb} GB (Active swapping!)" \
                             "Candidate for soft rotation via admincluster_run.sh / RAS API"
                else
                    log_ok "PID $pid (rphost): RSS = ${rss_gb} GB, SWAP = ${swap_gb} GB (Stable allocation)"
                fi
            fi
        done
    fi

    echo ""
}

summary() {
    echo -e "${BOLD}${BLUE}================================================================================${NC}"
    echo -e "${BOLD} SUMMARY:${NC} ${GREEN}${OK_COUNT} OK${NC} | ${YELLOW}${WARN_COUNT} WARNINGS${NC} | ${RED}${FAIL_COUNT} FAILURES${NC}"

    if [[ "$GENERATE_FIX" == true ]]; then
        echo -e "${BOLD}${GREEN} Auto-fix script generated:${NC} $FIX_FILE"
        echo -e " Review and run: '${BOLD}sudo bash $FIX_FILE${NC}'"
    else
        echo -e " Tip: Run '${BOLD}$0 --generate-fix${NC}' to generate an automated remediation script."
    fi
    echo -e "${BOLD}${BLUE}================================================================================${NC}"
}

main() {
    header
    check_kernel_and_vm
    check_postgres_patroni
    check_1c_cluster
    summary
}

main