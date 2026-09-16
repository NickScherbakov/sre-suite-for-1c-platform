#!/usr/bin/env bash
# ==============================================================================
# SRE-Suite-for-1C-platform — Production Health Check & Diagnostic Tool (v1.3)
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

VERSION="1.3"
GENERATE_FIX=false
FIX_FILE=""

# Обработка аргументов командной строки
for arg in "$@"; do
    case "$arg" in
        --generate-fix)
            GENERATE_FIX=true
            ;;
        --version|-v)
            echo "SRE-Suite-for-1C-platform Health Check v${VERSION}"
            exit 0
            ;;
        --help|-h)
            echo "Использование: $0 [--generate-fix] [--version] [--help]"
            echo "  --generate-fix    Сгенерировать безопасный скрипт устранения проблем"
            exit 0
            ;;
        *)
            echo "Неизвестный параметр: $arg (см. $0 --help)"
            exit 1
            ;;
    esac
done

if [[ "$GENERATE_FIX" == true ]]; then
    FIX_FILE="$(mktemp /tmp/sre-healthcheck-fix.XXXXXX.sh)"
    cat << 'EOF' > "$FIX_FILE"
#!/usr/bin/env bash
# ==============================================================================
# SRE-Suite-for-1C-platform — Auto-Remediation Script
# Generated automatically by sre-1c-pg-healthcheck.sh
# ==============================================================================
set -euo pipefail

echo "[*] Применение рекомендованных параметров ядра Linux..."
EOF
    chmod 700 "$FIX_FILE"
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
        echo -e "        ${CYAN}--> РЕКОМЕНДАЦИЯ:${NC} $2"
    fi
    ((++WARN_COUNT))
}

log_fail() {
    echo -e " [${RED}FAIL${NC}] $1"
    if [[ -n "${2:-}" ]]; then
        echo -e "        ${CYAN}--> ДЕЙСТВИЕ:${NC} $2"
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
    echo -e "${BOLD}${CYAN} SRE-Suite-for-1C-platform — System & Database Health Check (v${VERSION})${NC}"
    echo -e " Узел: ${BOLD}$(hostname)${NC} | Ядро: $(uname -r) | Время: $(date '+%Y-%m-%d %H:%M:%S')"
    echo -e "${BOLD}${BLUE}================================================================================${NC}"
    echo ""
}

check_kernel_and_vm() {
    echo -e "${BOLD}[1. LINUX KERNEL & VIRTUAL MEMORY (OS HEALTH)]${NC}"

    # 1. Проверка Transparent Huge Pages (THP)
    local thp_file="/sys/kernel/mm/transparent_hugepage/enabled"
    if [[ -f "$thp_file" ]]; then
        local thp_status
        thp_status=$(cat "$thp_file")
        if [[ "$thp_status" == *"[never]"* ]]; then
            log_ok "Transparent Huge Pages (THP): отключены (never)"
        else
            log_fail "Transparent Huge Pages: $thp_status" \
                     "Отключите через sysfs и зафиксируйте 'transparent_hugepage=never' в GRUB"
            add_fix_command ""
            add_fix_command "# --- Отключение THP в рантайме ---"
            add_fix_command "echo never > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true"
            add_fix_command "echo never > /sys/kernel/mm/transparent_hugepage/defrag 2>/dev/null || true"
        fi
    else
        log_warn "Интерфейс THP в sysfs не найден ($thp_file)"
    fi

    # 2. vm.swappiness
    local swappiness
    swappiness=$(sysctl -n vm.swappiness 2>/dev/null || echo "60")
    if [[ "$swappiness" -le 10 ]]; then
        log_ok "vm.swappiness = $swappiness (Оптимально для PostgreSQL и 1С)"
    else
        log_warn "vm.swappiness = $swappiness (Рекомендуется <= 10 для защиты от задержек I/O)" \
                 "Задайте vm.swappiness=10 в /etc/sysctl.d/99-1c-postgresql.conf"
        add_fix_command "sysctl -w vm.swappiness=10"
    fi

    # 3. Dirty Pages (Байтовые лимиты vs Проценты)
    local dirty_bytes dirty_bg_bytes
    dirty_bytes=$(sysctl -n vm.dirty_bytes 2>/dev/null || echo "0")
    dirty_bg_bytes=$(sysctl -n vm.dirty_background_bytes 2>/dev/null || echo "0")

    if [[ "$dirty_bytes" -gt 0 && "$dirty_bg_bytes" -gt 0 ]]; then
        local bg_mb=$(( dirty_bg_bytes / 1024 / 1024 ))
        local limit_mb=$(( dirty_bytes / 1024 / 1024 ))
        log_ok "Грязные страницы (байты): фоновый сброс=${bg_mb}MB, лимит=${limit_mb}MB (Плавный I/O)"
    else
        local dirty_bg dirty_ratio
        dirty_bg=$(sysctl -n vm.dirty_background_ratio 2>/dev/null || echo "10")
        dirty_ratio=$(sysctl -n vm.dirty_ratio 2>/dev/null || echo "20")
        if [[ "$dirty_bg" -le 10 && "$dirty_ratio" -le 20 ]]; then
            log_ok "Грязные страницы (проценты): фоновый сброс=$dirty_bg%, жесткий блок=$dirty_ratio%"
        else
            log_warn "Пороги сброса грязных страниц завышены (bg=$dirty_bg%, limit=$dirty_ratio%)" \
                     "Рекомендуется перейти на байты: dirty_background_bytes=1073741824, dirty_bytes=4294967296"
            add_fix_command "sysctl -w vm.dirty_background_bytes=1073741824"
            add_fix_command "sysctl -w vm.dirty_bytes=4294967296"
        fi
    fi

    # 4. vm.overcommit_memory (Контекстный аудит)
    local overcommit has_1c_local
    overcommit=$(sysctl -n vm.overcommit_memory 2>/dev/null || echo "0")
    has_1c_local=$(pgrep -x "rphost" 2>/dev/null | head -n 1 || true)

    if [[ -n "$has_1c_local" ]]; then
        if [[ "$overcommit" -eq 0 ]]; then
            log_ok "vm.overcommit_memory = 0 (Эвристический режим — Безопасно для VIRT-памяти rphost)"
        elif [[ "$overcommit" -eq 2 ]]; then
            log_warn "vm.overcommit_memory = 2 на ноде сервера приложений 1С!" \
                     "Риск отказов 'Cannot allocate memory' при высоком VIRT. Убедитесь в наличии Swap >= 100% RAM"
        else
            log_info "vm.overcommit_memory = $overcommit (Проверьте соответствие архитектуре)"
        fi
    else
        if [[ "$overcommit" -eq 2 ]]; then
            log_ok "vm.overcommit_memory = 2 (Строгий запрет оверкоммита — Идеально для выделенной СУБД)"
        else
            log_info "vm.overcommit_memory = $overcommit (Для выделенного сервера СУБД рекомендуется значение 2)"
        fi
    fi

    # 5. net.ipv4.ip_nonlocal_bind (Критично для vip-manager)
    local nonlocal_bind
    nonlocal_bind=$(sysctl -n net.ipv4.ip_nonlocal_bind 2>/dev/null || echo "0")
    if [[ "$nonlocal_bind" -eq 1 ]]; then
        log_ok "net.ipv4.ip_nonlocal_bind = 1 (Готовность к перехвату VIP утилитой vip-manager)"
    else
        log_fail "net.ipv4.ip_nonlocal_bind = $nonlocal_bind (vip-manager не сможет поднять Virtual IP!)" \
                 "Выполните: sysctl -w net.ipv4.ip_nonlocal_bind=1"
        add_fix_command "sysctl -w net.ipv4.ip_nonlocal_bind=1"
    fi

    # 6. net.core.somaxconn
    local somaxconn
    somaxconn=$(sysctl -n net.core.somaxconn 2>/dev/null || echo "128")
    if [[ "$somaxconn" -ge 4096 ]]; then
        log_ok "net.core.somaxconn = $somaxconn (Очередь сокетов готова к шторму подключений)"
    else
        log_warn "net.core.somaxconn = $somaxconn (Рекомендуется >= 4096 при массовом входе в 1С)" \
                 "Задайте net.core.somaxconn=4096 в sysctl"
        add_fix_command "sysctl -w net.core.somaxconn=4096"
    fi

    echo ""
}

check_postgres_patroni() {
    echo -e "${BOLD}[2. POSTGRESQL & PATRONI HIGH-AVAILABILITY CLUSTER]${NC}"

    # Опрос Patroni REST API с жестким таймаутом
    if command -v curl &>/dev/null; then
        local patroni_url="http://localhost:8008"
        local http_code
        http_code=$(curl -s --connect-timeout 2 --max-time 3 -o /dev/null -w "%{http_code}" "$patroni_url/cluster" 2>/dev/null || echo "000")

        if [[ "$http_code" =~ ^[0-9]+$ ]] && [[ "$http_code" -eq 200 ]]; then
            local role_raw role_clean
            role_raw=$(curl -s --connect-timeout 2 --max-time 3 "$patroni_url/patroni" 2>/dev/null || echo "")
            role_clean=$(echo "$role_raw" | sed -n 's/.*"role"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | tr '[:lower:]' '[:upper:]')
            [[ -z "$role_clean" ]] && role_clean="ACTIVE"
            log_ok "Patroni REST API: узел в роли ${BOLD}${role_clean}${NC} | Кластер: running"
        else
            log_warn "Patroni REST API недоступен по адресу $patroni_url/cluster (HTTP $http_code)" \
                     "Проверьте статус службы демона: systemctl status patroni"
        fi
    else
        log_info "Утилита curl не найдена; опрос Patroni REST API пропущен"
    fi

    # Определение команды прямого подключения к PostgreSQL
    local psql_cmd=""
    if command -v psql &>/dev/null; then
        if [[ $EUID -eq 0 ]] && id -u postgres &>/dev/null; then
            psql_cmd="sudo -n -u postgres psql -d postgres -t -A"
        elif psql -U postgres -d postgres -c '\q' 2>/dev/null; then
            psql_cmd="psql -U postgres -d postgres -t -A"
        elif psql -c '\q' 2>/dev/null; then
            psql_cmd="psql -t -A"
        fi
    fi

    if [[ -n "$psql_cmd" ]]; then
        local locks
        locks=$($psql_cmd -c "SHOW max_locks_per_transaction;" 2>/dev/null || echo "0")
        if [[ "$locks" =~ ^[0-9]+$ ]] && [[ "$locks" -ge 256 ]]; then
            log_ok "max_locks_per_transaction = $locks"

            # Точный расчёт пикового числа блокировок на ОДИН процесс (транзакцию)
            local peak_locks_query="SELECT COALESCE(max(c), 0) FROM (SELECT count(*) c FROM pg_locks WHERE pid IS NOT NULL GROUP BY pid) s;"
            local peak_locks
            peak_locks=$($psql_cmd -c "$peak_locks_query" 2>/dev/null || echo "0")

            if [[ "$peak_locks" =~ ^[0-9]+$ ]] && [[ "$peak_locks" -gt 0 ]]; then
                local lock_density=$(( peak_locks * 100 / locks ))
                if [[ "$lock_density" -ge 70 ]]; then
                    log_warn "Пик блокировок на транзакцию: $peak_locks / $locks (утилизация слота ~${lock_density}%)" \
                             "Плотность блокировок высока; увеличьте max_locks_per_transaction в patroni.yml"
                else
                    log_ok "Пик блокировок на транзакцию: $peak_locks / $locks (утилизация слота ~${lock_density}%)"
                fi
            fi
        elif [[ "$locks" =~ ^[0-9]+$ ]] && [[ "$locks" -gt 0 ]]; then
            log_fail "max_locks_per_transaction = $locks (Критично мало для 1С:ERP! Требуется >= 256)" \
                     "Задайте max_locks_per_transaction: 256 в patroni.yml / postgresql.conf"
        fi

        local max_conn
        max_conn=$($psql_cmd -c "SHOW max_connections;" 2>/dev/null || echo "0")
        if [[ "$max_conn" =~ ^[0-9]+$ ]] && [[ "$max_conn" -ge 250 ]]; then
            log_ok "max_connections = $max_conn (Достаточно для пула фоновых заданий)"
        elif [[ "$max_conn" =~ ^[0-9]+$ ]] && [[ "$max_conn" -gt 0 ]]; then
            log_warn "max_connections = $max_conn (Рекомендуется >= 250 для корпоративных баз)"
        fi
    else
        log_info "Прямой доступ через psql отсутствует; проверка параметров СУБД пропущена"
    fi

    echo ""
}

check_1c_cluster() {
    echo -e "${BOLD}[3. 1C:ENTERPRISE CLUSTER & RPHOST PROCESS ANALYSIS]${NC}"

    # Строгий поиск бинарных процессов rphost (без захвата скриптов и tail)
    local rphost_pids
    rphost_pids=$(pgrep -x "rphost" 2>/dev/null || true)

    if [[ -z "$rphost_pids" ]]; then
        log_info "Активные процессы 'rphost' не обнаружены (Норма для выделенного узла СУБД)"
    else
        local rphost_count
        rphost_count=$(printf '%s\n' "$rphost_pids" | sed '/^$/d' | wc -l)
        log_ok "Обнаружено активных рабочих процессов rphost: $rphost_count"

        for pid in $rphost_pids; do
            local proc_status="/proc/$pid/status"
            if [[ -f "$proc_status" ]]; then
                local rss_kb swap_kb
                rss_kb=$(awk '/VmRSS:/ {print $2}' "$proc_status" 2>/dev/null || echo "0")
                swap_kb=$(awk '/VmSwap:/ {print $2}' "$proc_status" 2>/dev/null || echo "0")

                # Точный расчёт через awk с плавающей точкой
                local mem_stats
                mem_stats=$(awk -v r="$rss_kb" -v s="$swap_kb" 'BEGIN {
                    printf "%.2f %.2f", r/1048576, s/1048576
                }')
                local rss_gb swap_gb
                rss_gb=$(echo "$mem_stats" | awk '{print $1}')
                swap_gb=$(echo "$mem_stats" | awk '{print $2}')

                # Эвристика детекции утечки в своп:
                # 1. Swap > 1 ГБ (безусловная аномалия)
                # 2. Swap > 256 МБ И Swap составляет более 15% от RSS процесса
                local is_leaking=false
                if (( swap_kb > 1048576 )); then
                    is_leaking=true
                elif (( swap_kb > 262144 )); then
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
                    log_warn "PID $pid (rphost): RSS = ${rss_gb} GB, SWAP = ${swap_gb} GB (Интенсивный свопинг!)" \
                             "Кандидат на мягкую ротацию через orchestrator/admincluster_run.sh"
                else
                    log_ok "PID $pid (rphost): RSS = ${rss_gb} GB, SWAP = ${swap_gb} GB (Стабильное потребление)"
                fi
            fi
        done
    fi

    echo ""
}

summary() {
    echo -e "${BOLD}${BLUE}================================================================================${NC}"
    echo -e "${BOLD} СВОДКА:${NC} ${GREEN}${OK_COUNT} УСПЕШНО${NC} | ${YELLOW}${WARN_COUNT} ПРЕДУПРЕЖДЕНИЙ${NC} | ${RED}${FAIL_COUNT} СБОЕВ${NC}"

    if [[ "$GENERATE_FIX" == true ]]; then
        echo -e "${BOLD}${GREEN} Сформирован скрипт авто-исправления:${NC} $FIX_FILE"
        echo -e " Проверьте содержимое и выполните: '${BOLD}sudo bash $FIX_FILE${NC}'"
    else
        echo -e " Совет: запустите '${BOLD}$0 --generate-fix${NC}' для генерации команд устранения проблем."
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
