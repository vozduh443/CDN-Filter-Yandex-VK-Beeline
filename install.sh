#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
#                 MOBILE CDN FILTER
# ============================================================
#
# Universal mobile-network filter for NGINX.
#
# Supported infrastructure:
#
#   VK Cloud
#   Yandex Cloud
#   Beeline Cloud
#   CDN Video
#   Turboflare
#   Beget
#   Timeweb
#   Selectel
#   and any other CDN / VPS / proxy infrastructure
#   where NGINX handles HTTP/HTTPS traffic.
#
# Modes:
#
#   1. Native NGINX
#   2. NGINX inside Docker
#
# The installer DOES NOT require a specific nginx config layout.
#
# It:
#
#   - runs nginx -T
#   - parses loaded server blocks
#   - finds proxy locations
#   - lets the user select the target server/location
#   - creates backups
#   - installs the mobile IP database separately
#   - injects only the filter into the selected location
#   - runs nginx -t
#   - reloads only after successful validation
#
# Caddy is NOT supported.
#
# Version: 5.0.0
#
# ============================================================

VERSION="5.0.0"

# ============================================================
# COLORS
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
WHITE='\033[1;37m'
GRAY='\033[0;90m'
BOLD='\033[1m'
NC='\033[0m'

# ============================================================
# PATHS
# ============================================================

BASE_DIR="/etc/mobile-filter"

CUSTOM_ASNS="${BASE_DIR}/custom-asns.conf"
CUSTOM_IPS="${BASE_DIR}/custom-ips.conf"

INSTALLATION_CONF="${BASE_DIR}/installation.conf"

MOBILE_RANGES="/etc/nginx/mobile-ranges.conf"
FILTER_CONF="/etc/nginx/conf.d/mobile-filter.conf"

UPDATE_SCRIPT="/usr/local/bin/update-mobile-ranges.sh"
MANAGER_SCRIPT="/usr/local/bin/mobile-filter"

CRON_FILE="/etc/cron.d/mobile-filter"

LOG_FILE="/var/log/mobile-filter-update.log"

# ============================================================
# RUNTIME
# ============================================================

MODE=""

DOCKER_CONTAINER=""

NGINX_CONFIG=""
NGINX_DUMP=""

TARGET_SERVER=""
TARGET_LOCATION=""

IP_SOURCE=""

BACKUP_FILE=""

# ============================================================
# FILTER VARIABLES
# ============================================================

FILTER_VARIABLE="mobile_filter_allowed"
CLIENT_IP_VARIABLE="mobile_filter_client_ip"

# ============================================================
# MOBILE ASN LIST
#
# The supplied mobile ASN pool.
#
# AS12389 is intentionally NOT included here.
#
# Rostelecom is handled through explicit static networks.
# ============================================================

BASE_MOBILE_ASN=(
    # MTS
    8359

    # Beeline / VimpelCom
    3216
    16345
    42842

    # MegaFon
    31133
    47395
    35298
    31224
    31213
    31208
    31205
    31195
    31163
    25159

    # T2
    12958
    15378
    42437
    48092
    48190
    41330
    39374

    # Miranda
    201776

    # Sberbank-Telecom
    206673

    # Sevastar
    35816

    # T-mobile + Alfa-mobile
    205638
    214257
    202498

    # Volna-Mobile
    203451
    203561

    # MCS
    47204

    # MOTIV
    31499

    # Phoenix
    214721
    204108

    # Sevtelecom
    59833
    47203
)

# ============================================================
# ROSTELECOM STATIC NETWORKS
#
# AS12389 is NOT part of the full ASN pool.
# ============================================================

ROSTELECOM_IPS=(
    "5.141.100.0/22"
    "5.141.192.0/22"
    "5.142.40.0/21"
    "83.219.13.0/24"
    "87.226.172.0/24"
    "87.226.203.0/24"
    "87.226.204.0/23"
    "87.226.206.0/24"
    "87.226.209.0/24"
    "87.226.210.0/23"
    "87.226.212.0/24"
    "87.226.218.0/24"
    "88.205.192.0/20"
    "89.20.97.0/24"
    "89.20.102.0/24"
    "89.204.112.0/20"
    "95.86.213.0/24"
    "95.86.214.0/23"
    "95.152.44.0/24"
    "95.152.62.0/24"
    "95.167.104.0/24"
    "176.119.160.0/21"
    "176.119.168.0/24"
    "176.119.173.0/24"
    "176.119.174.0/23"
    "178.47.161.0/24"
    "178.67.192.0/21"
    "188.254.122.0/23"
    "195.38.60.0/22"
    "212.120.169.0/24"
    "213.24.147.0/24"
    "217.107.106.0/24"
)

# ============================================================
# OTHER STATIC NETWORKS
# ============================================================

EXTRA_OPERATOR_IPS=(
    "5.101.18.0/24"
    "91.107.97.0/24"
    "84.18.108.0/24"
)

# ============================================================
# UI
# ============================================================

clear_screen() {
    clear 2>/dev/null || true
}

line() {
    echo -e "${GRAY}────────────────────────────────────────────────────────────${NC}"
}

header() {
    echo
    echo -e "${BOLD}${CYAN}$1${NC}"
    line
}

ok() {
    echo -e "  ${GREEN}✓${NC} $1"
}

warn() {
    echo -e "  ${YELLOW}⚠${NC} $1"
}

error() {
    echo -e "  ${RED}✘${NC} $1"
}

info() {
    echo -e "  ${CYAN}➜${NC} $1"
}

pause_screen() {
    echo
    read -r -p "  Нажмите Enter для продолжения..." _
}

banner() {

    clear_screen

    echo -e "${CYAN}"
    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║                                                            ║"
    echo "║                 MOBILE CDN FILTER                         ║"
    echo "║                                                            ║"
    echo "║        Universal NGINX Mobile Network Filter              ║"
    echo "║                                                            ║"
    echo "║        VK • Yandex • Beeline • CDN Video                  ║"
    echo "║        Turboflare • Beget • Timeweb • Selectel            ║"
    echo "║                                                            ║"
    echo "╚════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"

    echo -e "${GRAY}Version ${VERSION}${NC}"
    echo
}

# ============================================================
# ROOT
# ============================================================

check_root() {

    if [[ "$EUID" -ne 0 ]]; then

        error "Скрипт необходимо запускать от root."

        echo
        echo "Пример:"
        echo
        echo "  sudo bash $0"
        echo

        exit 1
    fi
}

# ============================================================
# BASE DIRECTORY
# ============================================================

prepare_directories() {

    mkdir -p "$BASE_DIR"

    touch "$CUSTOM_ASNS"
    touch "$CUSTOM_IPS"

    chmod 600 "$CUSTOM_ASNS"
    chmod 600 "$CUSTOM_IPS"
}

# ============================================================
# DEPENDENCIES
# ============================================================

install_dependencies() {

    header "ПРОВЕРКА ЗАВИСИМОСТЕЙ"

    local missing=()

    command -v curl >/dev/null 2>&1 || missing+=("curl")
    command -v python3 >/dev/null 2>&1 || missing+=("python3")

    if [[ "$MODE" == "native" ]]; then
        command -v nginx >/dev/null 2>&1 || missing+=("nginx")
    fi

    if [[ "$MODE" == "docker" ]]; then
        command -v docker >/dev/null 2>&1 || missing+=("docker")
    fi

    if [[ ${#missing[@]} -eq 0 ]]; then

        ok "Все зависимости установлены"
        echo

        return
    fi

    info "Не хватает: ${missing[*]}"
    echo

    if ! command -v apt-get >/dev/null 2>&1; then

        error "apt-get не найден."

        echo
        echo "Установите вручную:"
        echo "  ${missing[*]}"
        echo

        exit 1
    fi

    apt-get update -qq
    apt-get install -y -qq "${missing[@]}"

    ok "Зависимости установлены"
    echo
}

# ============================================================
# SELECT MODE
# ============================================================

select_mode() {

    header "РЕЖИМ NGINX"

    echo
    echo -e "  ${WHITE}1${NC}) ${GREEN}Обычный Nginx${NC}"
    echo -e "     Nginx установлен непосредственно на сервере"
    echo

    echo -e "  ${WHITE}2${NC}) ${BLUE}Nginx в Docker${NC}"
    echo -e "     Nginx работает внутри Docker-контейнера"
    echo

    line
    echo

    local choice

    while true; do

        read -r -p "  Выберите [1-2]: " choice

        case "$choice" in

            1)

                MODE="native"
                break
                ;;

            2)

                MODE="docker"
                break
                ;;

            *)

                error "Введите 1 или 2."
                ;;

        esac

    done

    echo

    if [[ "$MODE" == "native" ]]; then

        ok "Выбран обычный Nginx"

    else

        ok "Выбран Docker Nginx"

        echo

        read -r -p \
            "  Имя контейнера [cdn-nginx]: " container

        DOCKER_CONTAINER="${container:-cdn-nginx}"

    fi

    echo
}

# ============================================================
# DOCKER CHECK
# ============================================================

check_docker_container() {

    [[ "$MODE" == "docker" ]] || return

    header "ПРОВЕРКА DOCKER-КОНТЕЙНЕРА"

    if ! docker ps --format '{{.Names}}' |
        grep -Fxq "$DOCKER_CONTAINER"; then

        error "Контейнер '${DOCKER_CONTAINER}' не найден или не запущен."

        echo
        echo "Запущенные контейнеры:"
        echo

        docker ps --format \
            '  {{.Names}}\t{{.Image}}\t{{.Status}}'

        echo

        exit 1
    fi

    ok "Контейнер найден: ${DOCKER_CONTAINER}"
    echo
}

# ============================================================
# NGINX DUMP
# ============================================================

get_nginx_dump() {

    if [[ "$MODE" == "docker" ]]; then

        docker exec "$DOCKER_CONTAINER" nginx -T 2>&1

    else

        nginx -T 2>&1

    fi
}

# ============================================================
# NGINX TEST
# ============================================================

nginx_test() {

    if [[ "$MODE" == "docker" ]]; then

        docker exec "$DOCKER_CONTAINER" nginx -t

    else

        nginx -t

    fi
}

# ============================================================
# NGINX RELOAD
# ============================================================

nginx_reload() {

    if [[ "$MODE" == "docker" ]]; then

        docker exec "$DOCKER_CONTAINER" nginx -s reload

    else

        nginx -s reload

    fi
}

# ============================================================
# GET NGINX VERSION
# ============================================================

show_nginx_info() {

    header "NGINX"

    if [[ "$MODE" == "docker" ]]; then

        docker exec "$DOCKER_CONTAINER" nginx -v 2>&1

    else

        nginx -v 2>&1

    fi

    echo
}

# ============================================================
# PARSE NGINX CONFIG
#
# We use nginx -T instead of assuming:
#
#   /etc/nginx/sites-enabled/default
#
# or:
#
#   /etc/nginx/conf.d/default.conf
#
# Nginx itself outputs configuration-file markers in -T.
# ============================================================

parse_targets() {

    local dump="$1"

    python3 - "$dump" <<'PY'
import sys
import re

text = sys.argv[1]

lines = text.splitlines()

current_file = ""

servers = []

server_start = None
server_depth = 0
server_lines = []
server_file = ""

for index, line in enumerate(lines):

    # nginx -T file marker
    marker = re.match(
        r'^# configuration file (.+):$',
        line
    )

    if marker:
        current_file = marker.group(1).strip()

    stripped = line.strip()

    if server_start is None:

        if re.match(
            r'^server\s*\{',
            stripped
        ):

            server_start = index
            server_lines = [line]
            server_file = current_file

            server_depth = (
                line.count("{") -
                line.count("}")
            )

            if server_depth == 0:

                server_start = None
                server_lines = []

    else:

        if index != server_start:
            server_lines.append(line)

        server_depth += (
            line.count("{") -
            line.count("}")
        )

        if server_depth == 0:

            block = "\n".join(server_lines)

            names = re.findall(
                r'(?m)^\s*server_name\s+([^;]+);',
                block
            )

            listens = re.findall(
                r'(?m)^\s*listen\s+([^;]+);',
                block
            )

            locations = []

            # ------------------------------------------------
            # Find locations
            # ------------------------------------------------

            for loc_match in re.finditer(
                r'(?m)^\s*location\s+([^{]+)\{',
                block
            ):

                location_header = (
                    loc_match.group(1).strip()
                )

                open_pos = block.find(
                    "{",
                    loc_match.start()
                )

                depth = 0
                close_pos = None

                for pos in range(
                    open_pos,
                    len(block)
                ):

                    char = block[pos]

                    if char == "{":
                        depth += 1

                    elif char == "}":

                        depth -= 1

                        if depth == 0:

                            close_pos = pos
                            break

                if close_pos is None:
                    continue

                location_block = block[
                    loc_match.start():
                    close_pos + 1
                ]

                proxy_pass = re.findall(
                    r'(?m)^\s*proxy_pass\s+([^;]+);',
                    location_block
                )

                if proxy_pass:

                    locations.append(
                        (
                            location_header,
                            proxy_pass[0].strip()
                        )
                    )

            servers.append(
                {
                    "file": server_file,
                    "names": names,
                    "listens": listens,
                    "locations": locations
                }
            )

            server_start = None
            server_lines = []
            server_file = ""

# ------------------------------------------------------------
# Output
# ------------------------------------------------------------

for idx, server in enumerate(
    servers,
    1
):

    file = server["file"]
    names = " ".join(server["names"])
    listens = " ".join(server["listens"])

    print(
        "SERVER|{}|{}|{}|{}".format(
            idx,
            file,
            names,
            listens
        )
    )

    for loc_idx, location in enumerate(
        server["locations"],
        1
    ):

        header = (
            location[0]
            .replace("|", "/")
        )

        proxy = (
            location[1]
            .replace("|", "/")
        )

        print(
            "LOCATION|{}|{}|{}|{}".format(
                idx,
                loc_idx,
                header,
                proxy
            )
        )
PY
}

# ============================================================
# SELECT SERVER
# ============================================================

select_server() {

    header "АНАЛИЗ КОНФИГУРАЦИИ"

    info "Выполняется nginx -T..."
    echo

    NGINX_DUMP="$(
        get_nginx_dump
    )"

    if [[ -z "$NGINX_DUMP" ]]; then

        error "Не удалось получить конфигурацию Nginx."
        exit 1

    fi

    local parsed

    parsed="$(
        parse_targets "$NGINX_DUMP"
    )"

    if [[ -z "$parsed" ]]; then

        error "Server-блоки не найдены."
        exit 1

    fi

    declare -a SERVER_FILES
    declare -a SERVER_NAMES
    declare -a SERVER_LISTENS

    local count=0

    echo
    echo -e "${BOLD}Найденные server-блоки:${NC}"
    echo

    while IFS='|' read -r \
        type \
        number \
        file \
        names \
        listens
    do

        [[ "$type" == "SERVER" ]] || continue

        SERVER_FILES[$count]="$file"
        SERVER_NAMES[$count]="$names"
        SERVER_LISTENS[$count]="$listens"

        echo -e \
            "  ${WHITE}$((count + 1))${NC})"

        echo -e \
            "     server_name: ${CYAN}${names:-_}${NC}"

        echo -e \
            "     listen:      ${CYAN}${listens:-_}${NC}"

        echo -e \
            "     config:      ${GRAY}${file}${NC}"

        echo

        count=$((count + 1))

    done <<< "$parsed"

    if (( count == 0 )); then

        error "Подходящих server-блоков не найдено."
        exit 1

    fi

    local choice=""

    # --------------------------------------------------------
    # Automatic selection when only one server exists.
    # --------------------------------------------------------

    if (( count == 1 )); then

        echo -e \
            "${GREEN}Найден только один server — он будет выбран.${NC}"

        choice=1

        echo

    else

        while true; do

            read -r -p \
                "  Выберите server [1-${count}]: " choice

            if [[ "$choice" =~ ^[0-9]+$ ]] &&
                (( choice >= 1 && choice <= count )); then

                break

            fi

            error "Неверный выбор."

        done

    fi

    local selected=$((choice - 1))

    TARGET_SERVER="${SERVER_NAMES[$selected]}"
    NGINX_CONFIG="${SERVER_FILES[$selected]}"

    echo

    ok "Server: ${TARGET_SERVER:-_}"
    ok "Config: ${NGINX_CONFIG}"

    echo

    # Save server number for location selection.
    SELECTED_SERVER_NUMBER="$choice"
}

# ============================================================
# SELECT LOCATION
# ============================================================

select_location() {

    header "ВЫБОР LOCATION"

    local parsed

    parsed="$(
        parse_targets "$NGINX_DUMP"
    )"

    declare -a LOC_NAMES
    declare -a LOC_PROXIES

    local count=0

    echo

    while IFS='|' read -r \
        type \
        server_number \
        location_number \
        location \
        proxy
    do

        [[ "$type" == "LOCATION" ]] || continue

        [[ "$server_number" == "$SELECTED_SERVER_NUMBER" ]] || continue

        LOC_NAMES[$count]="$location"
        LOC_PROXIES[$count]="$proxy"

        echo -e \
            "  ${WHITE}$((count + 1))${NC})"

        echo -e \
            "     location: ${CYAN}${location}${NC}"

        echo -e \
            "     proxy:    ${CYAN}${proxy}${NC}"

        echo

        count=$((count + 1))

    done <<< "$parsed"

    if (( count == 0 )); then

        warn "В выбранном server не найден location с proxy_pass."

        echo
        echo "Фильтр предназначен для проксируемого трафика."
        echo "Автоматическое внедрение отменено."
        echo

        exit 1

    fi

    local choice=""

    if (( count == 1 )); then

        echo -e \
            "${GREEN}Найден только один proxy location — он будет выбран.${NC}"

        choice=1

        echo

    else

        while true; do

            read -r -p \
                "  Выберите location [1-${count}]: " choice

            if [[ "$choice" =~ ^[0-9]+$ ]] &&
                (( choice >= 1 && choice <= count )); then

                break

            fi

            error "Неверный выбор."

        done

    fi

    TARGET_LOCATION="${LOC_NAMES[$((choice - 1))]}"

    echo

    ok "Location: ${TARGET_LOCATION}"
    ok "Proxy:    ${LOC_PROXIES[$((choice - 1))]}"

    echo
}

# ============================================================
# IP SOURCE
# ============================================================

select_ip_source() {

    header "ИСТОЧНИК IP КЛИЕНТА"

    echo
    echo "Фильтру необходимо знать реальный IPv4 клиента."
    echo
    echo -e \
        "  ${WHITE}1${NC}) X-Real-IP"

    echo -e \
        "  ${WHITE}2${NC}) Первый IP из X-Forwarded-For"

    echo -e \
        "  ${WHITE}3${NC}) $remote_addr"

    echo -e \
        "  ${WHITE}4${NC}) Автоматически"

    echo

    local choice

    while true; do

        read -r -p \
            "  Выберите [1-4, по умолчанию 4]: " choice

        choice="${choice:-4}"

        case "$choice" in

            1)

                IP_SOURCE="x_real_ip"
                break
                ;;

            2)

                IP_SOURCE="x_forwarded_for"
                break
                ;;

            3)

                IP_SOURCE="remote_addr"
                break
                ;;

            4)

                IP_SOURCE="auto"
                break
                ;;

            *)

                error "Введите 1, 2, 3 или 4."
                ;;

        esac

    done

    echo

    case "$IP_SOURCE" in

        x_real_ip)
            ok "IP source: X-Real-IP"
            ;;

        x_forwarded_for)
            ok "IP source: первый IP X-Forwarded-For"
            ;;

        remote_addr)
            ok "IP source: remote_addr"
            ;;

        auto)
            ok "IP source: automatic"
            ;;

    esac

    echo
}

# ============================================================
# CUSTOM USER DATA
# ============================================================

valid_ipv4_or_cidr() {

    local value="$1"

    python3 - "$value" <<'PY'
import sys
import ipaddress

value = sys.argv[1]

try:
    network = ipaddress.ip_network(
        value,
        strict=False
    )

    if network.version != 4:
        raise ValueError

except Exception:
    sys.exit(1)

sys.exit(0)
PY
}

add_initial_custom_data() {

    header "ВАШИ IP И ASN"

    echo
    echo "Если хотите разрешить собственный IP"
    echo "или добавить собственный мобильный ASN,"
    echo "можно сделать это сейчас."
    echo

    read -r -p \
        "  Добавить свои IP/CIDR сейчас? [y/N]: " answer

    if [[ "$answer" =~ ^[Yy]$ ]]; then

        echo
        read -r -p \
            "  IP/CIDR через пробел: " values

        for value in $values; do

            if valid_ipv4_or_cidr "$value"; then

                echo "$value" >> "$CUSTOM_IPS"

                ok "Добавлен: $value"

            else

                warn "Некорректный IPv4/CIDR: $value"

            fi

        done

    fi

    echo

    read -r -p \
        "  Добавить свои ASN сейчас? [y/N]: " answer

    if [[ "$answer" =~ ^[Yy]$ ]]; then

        echo
        read -r -p \
            "  ASN через пробел: " values

        for ASN in $values; do

            ASN="${ASN#AS}"
            ASN="${ASN#as}"

            if [[ "$ASN" =~ ^[0-9]+$ ]]; then

                echo "$ASN" >> "$CUSTOM_ASNS"

                ok "Добавлен AS${ASN}"

            else

                warn "Некорректный ASN: $ASN"

            fi

        done

    fi

    sort -u "$CUSTOM_IPS" \
        -o "$CUSTOM_IPS"

    sort -nu "$CUSTOM_ASNS" \
        -o "$CUSTOM_ASNS"

    echo
}

# ============================================================
# ADD BUILT-IN STATIC IP NETWORKS
# ============================================================

install_static_networks() {

    header "STATIC NETWORKS"

    for IP in "${ROSTELECOM_IPS[@]}"; do

        echo "$IP" >> "$CUSTOM_IPS"

    done

    for IP in "${EXTRA_OPERATOR_IPS[@]}"; do

        echo "$IP" >> "$CUSTOM_IPS"

    done

    sort -u "$CUSTOM_IPS" \
        -o "$CUSTOM_IPS"

    ok \
        "Добавлены Rostelecom CIDR: ${#ROSTELECOM_IPS[@]}"

    ok \
        "Добавлены дополнительные CIDR: ${#EXTRA_OPERATOR_IPS[@]}"

    echo
}

# ============================================================
# BUILD ASN LIST
# ============================================================

build_asn_list() {

    local output="$1"

    : > "$output"

    for ASN in "${BASE_MOBILE_ASN[@]}"; do

        echo "$ASN" >> "$output"

    done

    if [[ -f "$CUSTOM_ASNS" ]]; then

        while IFS= read -r ASN; do

            ASN="$(echo "$ASN" |
                tr -d '[:space:]')"

            [[ -z "$ASN" ]] && continue

            [[ "$ASN" =~ ^# ]] && continue

            ASN="${ASN#AS}"
            ASN="${ASN#as}"

            if [[ "$ASN" =~ ^[0-9]+$ ]]; then

                echo "$ASN" >> "$output"

            fi

        done < "$CUSTOM_ASNS"

    fi

    sort -nu "$output" \
        -o "$output"
}

# ============================================================
# GENERATE PREFIX DATABASE
# ============================================================

generate_ranges() {

    header "ПОЛУЧЕНИЕ IP-ДИАПАЗОНОВ"

    local output

    output="$(mktemp)"

    local asn_file

    asn_file="$(mktemp)"

    local count_file

    count_file="$(mktemp)"

    trap \
        'rm -f "$output" "$asn_file" "$count_file"' \
        RETURN

    build_asn_list "$asn_file"

    echo
    echo "ASN в пуле: $(wc -l < "$asn_file")"
    echo
    echo "Запрос announced IPv4 prefixes через RIPE..."
    echo

    while IFS= read -r ASN; do

        [[ -z "$ASN" ]] && continue

        echo -n \
            "  AS${ASN} ... "

        : > "$count_file"

        curl -fsS \
            --max-time 30 \
            "https://stat.ripe.net/data/announced-prefixes/data.json?resource=AS${ASN}" |
        python3 -c '
import sys
import json

try:

    data = json.load(sys.stdin)

    prefixes = data.get(
        "data",
        {}
    ).get(
        "prefixes",
        []
    )

    count = 0

    for item in prefixes:

        prefix = item.get(
            "prefix",
            ""
        ).strip()

        if prefix and ":" not in prefix:

            print(
                prefix + " 1;"
            )

            count += 1

    print(
        count,
        file=sys.stderr
    )

except Exception:

    print(
        0,
        file=sys.stderr
    )
' 2>"$count_file" \
        >> "$output" || true

        local count

        count="$(
            cat "$count_file" 2>/dev/null ||
            echo 0
        )"

        echo \
            "${count} IPv4 prefixes"

        sleep 0.15

    done < "$asn_file"

    echo
    echo "Добавление статических IP/CIDR..."

    while IFS= read -r IP; do

        IP="$(echo "$IP" | xargs 2>/dev/null || true)"

        [[ -z "$IP" ]] && continue
        [[ "$IP" =~ ^# ]] && continue

        echo \
            "${IP} 1;" \
            >> "$output"

    done < "$CUSTOM_IPS"

    sort -u "$output" \
        -o "$output"

    echo
    echo "Всего IPv4 prefixes: $(wc -l < "$output")"
    echo

    install_ranges "$output"

    rm -f \
        "$output" \
        "$asn_file" \
        "$count_file"

    trap - RETURN
}

# ============================================================
# INSTALL RANGES
# ============================================================

install_ranges() {

    local source="$1"

    if [[ "$MODE" == "docker" ]]; then

        docker exec "$DOCKER_CONTAINER" \
            mkdir -p /etc/nginx

        docker exec -i "$DOCKER_CONTAINER" \
            sh -c \
            'cat > /etc/nginx/mobile-ranges.conf' \
            < "$source"

        ok \
            "mobile-ranges.conf загружен в Docker"

    else

        mkdir -p \
            "$(dirname "$MOBILE_RANGES")"

        install -m 0644 \
            "$source" \
            "$MOBILE_RANGES"

        ok \
            "mobile-ranges.conf установлен"

    fi
}

# ============================================================
# CREATE FILTER INCLUDE
# ============================================================

create_filter_config() {

    header "СОЗДАНИЕ ФИЛЬТРА"

    local temp

    temp="$(mktemp)"

    case "$IP_SOURCE" in

        x_real_ip)

            cat > "$temp" <<EOF
# ============================================================
# Mobile CDN Filter
# Generated by mobile-filter ${VERSION}
# ============================================================

geo \$http_x_real_ip \$mobile_filter_allowed {
    default 0;
    include /etc/nginx/mobile-ranges.conf;
}
EOF

            ;;

        x_forwarded_for)

            cat > "$temp" <<EOF
# ============================================================
# Mobile CDN Filter
# Generated by mobile-filter ${VERSION}
# ============================================================

map \$http_x_forwarded_for \$mobile_filter_client_ip {
    default \$remote_addr;
    "~^(?<mobile_filter_first_ip>[^, ]+)" \$mobile_filter_first_ip;
}

geo \$mobile_filter_client_ip \$mobile_filter_allowed {
    default 0;
    include /etc/nginx/mobile-ranges.conf;
}
EOF

            ;;

        remote_addr)

            cat > "$temp" <<EOF
# ============================================================
# Mobile CDN Filter
# Generated by mobile-filter ${VERSION}
# ============================================================

geo \$remote_addr \$mobile_filter_allowed {
    default 0;
    include /etc/nginx/mobile-ranges.conf;
}
EOF

            ;;

        auto)

            cat > "$temp" <<EOF
# ============================================================
# Mobile CDN Filter
# Generated by mobile-filter ${VERSION}
# ============================================================

map \$http_x_forwarded_for \$mobile_filter_client_ip {
    default \$remote_addr;
    "~^(?<mobile_filter_first_ip>[^, ]+)" \$mobile_filter_first_ip;
}

geo \$mobile_filter_client_ip \$mobile_filter_allowed {
    default 0;
    include /etc/nginx/mobile-ranges.conf;
}
EOF

            ;;

    esac

    if [[ "$MODE" == "docker" ]]; then

        docker exec "$DOCKER_CONTAINER" \
            mkdir -p /etc/nginx/conf.d

        docker cp \
            "$temp" \
            "${DOCKER_CONTAINER}:${FILTER_CONF}"

        ok \
            "Фильтр загружен в Docker"

    else

        mkdir -p \
            /etc/nginx/conf.d

        if [[ -f "$FILTER_CONF" ]]; then

            cp -a \
                "$FILTER_CONF" \
                "${FILTER_CONF}.backup.$(
                    date +%Y%m%d-%H%M%S
                )"

        fi

        install -m 0644 \
            "$temp" \
            "$FILTER_CONF"

        ok \
            "Фильтр установлен в ${FILTER_CONF}"

    fi

    rm -f "$temp"

    echo
}

# ============================================================
# CHECK CONF.D INCLUDE
# ============================================================

check_filter_include() {

    header "ПРОВЕРКА INCLUDE"

    if [[ "$MODE" == "docker" ]]; then

        local dump

        dump="$(
            docker exec \
                "$DOCKER_CONTAINER" \
                nginx -T 2>&1
        )"

        if echo "$dump" |
            grep -qE \
            'include[[:space:]]+/etc/nginx/conf\.d/\*\.conf;'
        then

            ok \
                "Docker Nginx подключает /etc/nginx/conf.d/*.conf"

            return

        fi

        if echo "$dump" |
            grep -q \
            "mobile-filter.conf"
        then

            ok \
                "mobile-filter.conf уже загружен"

            return

        fi

        error \
            "Не найден include для /etc/nginx/conf.d/*.conf."

        echo
        echo "Автоматическая модификация main nginx.conf"
        echo "отменена для безопасности."
        echo

        exit 1

    fi

    local main_conf

    main_conf="/etc/nginx/nginx.conf"

    if grep -qE \
        'include[[:space:]]+/etc/nginx/conf\.d/\*\.conf;' \
        "$main_conf"
    then

        ok \
            "Основной Nginx подключает conf.d/*.conf"

        return

    fi

    if grep -qE \
        'include[[:space:]]+conf\.d/\*\.conf;' \
        "$main_conf"
    then

        ok \
            "Основной Nginx подключает conf.d/*.conf"

        return

    fi

    warn \
        "Стандартный include conf.d не найден."

    echo
    echo "Найденные include:"
    echo

    grep -n \
        "include" \
        "$main_conf" \
        || true

    echo

    error \
        "Автоматическая установка остановлена."

    echo
    echo "Существующий nginx.conf не изменён."
    echo

    exit 1
}

# ============================================================
# PATCH NATIVE CONFIG
#
# Only the selected location is modified.
# ============================================================

patch_config_file() {

    local file="$1"
    local server_name="$2"
    local location_name="$3"

    python3 \
        - "$file" "$server_name" "$location_name" <<'PY'

import sys
import re
import shutil
from datetime import datetime

path = sys.argv[1]
server_name = sys.argv[2]
location_name = sys.argv[3]

# ------------------------------------------------------------
# Read
# ------------------------------------------------------------

with open(
    path,
    "r",
    encoding="utf-8"
) as f:

    text = f.read()

# ------------------------------------------------------------
# Already installed
# ------------------------------------------------------------

if "mobile_filter_allowed" in text:

    print("ALREADY_INSTALLED")
    sys.exit(0)

# ------------------------------------------------------------
# Find server blocks
# ------------------------------------------------------------

def find_blocks(
    text,
    keyword
):

    result = []

    pattern = re.compile(
        r'(?m)^[ \t]*' +
        re.escape(keyword) +
        r'\b[^{]*\{'
    )

    for match in pattern.finditer(text):

        start = match.start()

        open_pos = text.find(
            "{",
            match.start()
        )

        depth = 0
        end = None

        for pos in range(
            open_pos,
            len(text)
        ):

            if text[pos] == "{":

                depth += 1

            elif text[pos] == "}":

                depth -= 1

                if depth == 0:

                    end = pos + 1
                    break

        if end is not None:

            result.append(
                (
                    start,
                    end,
                    text[start:end]
                )
            )

    return result

servers = find_blocks(
    text,
    "server"
)

selected_server = None

# ------------------------------------------------------------
# Select server
# ------------------------------------------------------------

for (
    start,
    end,
    block
) in servers:

    names = re.findall(
        r'(?m)^[ \t]*server_name[ \t]+([^;]+);',
        block
    )

    joined = " ".join(
        names
    )

    if server_name in joined:

        selected_server = (
            start,
            end,
            block
        )

        break

if selected_server is None:

    print(
        "SERVER_NOT_FOUND"
    )

    sys.exit(2)

server_start, server_end, server_block = (
    selected_server
)

# ------------------------------------------------------------
# Find locations
# ------------------------------------------------------------

locations = []

pattern = re.compile(
    r'(?m)^[ \t]*location[ \t]+([^{]+)\{'
)

for match in pattern.finditer(
    server_block
):

    header = match.group(1).strip()

    open_pos = server_block.find(
        "{",
        match.start()
    )

    depth = 0
    end = None

    for pos in range(
        open_pos,
        len(server_block)
    ):

        if server_block[pos] == "{":

            depth += 1

        elif server_block[pos] == "}":

            depth -= 1

            if depth == 0:

                end = pos + 1
                break

    if end is None:
        continue

    block = server_block[
        match.start():
        end
    ]

    locations.append(
        (
            match.start(),
            end,
            header,
            block
        )
    )

# ------------------------------------------------------------
# Select location
# ------------------------------------------------------------

selected_location = None

for item in locations:

    if item[2].strip() == location_name.strip():

        selected_location = item
        break

if selected_location is None:

    for item in locations:

        if location_name.strip() in item[2]:

            selected_location = item
            break

if selected_location is None:

    print(
        "LOCATION_NOT_FOUND"
    )

    sys.exit(3)

loc_start, loc_end, loc_header, loc_block = (
    selected_location
)

# ------------------------------------------------------------
# Backup
# ------------------------------------------------------------

backup = (
    path +
    ".mobile-filter-backup." +
    datetime.now().strftime(
        "%Y%m%d-%H%M%S"
    )
)

shutil.copy2(
    path,
    backup
)

# ------------------------------------------------------------
# Determine indentation
# ------------------------------------------------------------

proxy_match = re.search(
    r'(?m)^([ \t]*)proxy_pass\b',
    loc_block
)

if proxy_match:

    indent = proxy_match.group(1)

else:

    indent = "    "

# ------------------------------------------------------------
# Filter block
# ------------------------------------------------------------

injection = (
    indent +
    "if ($mobile_filter_allowed = 0) {\n" +
    indent +
    "    return 403;\n" +
    indent +
    "}\n\n"
)

# ------------------------------------------------------------
# Inject before proxy_pass
# ------------------------------------------------------------

if proxy_match:

    new_location = (
        loc_block[
            :proxy_match.start()
        ] +
        injection +
        loc_block[
            proxy_match.start():
        ]
    )

else:

    open_pos = loc_block.find(
        "{"
    )

    new_location = (
        loc_block[
            :open_pos + 1
        ] +
        "\n" +
        injection +
        loc_block[
            open_pos + 1:
        ]
    )

# ------------------------------------------------------------
# Rebuild
# ------------------------------------------------------------

new_server = (
    server_block[
        :loc_start
    ] +
    new_location +
    server_block[
        loc_end:
    ]
)

new_text = (
    text[
        :server_start
    ] +
    new_server +
    text[
        server_end:
    ]
)

# ------------------------------------------------------------
# Write
# ------------------------------------------------------------

with open(
    path,
    "w",
    encoding="utf-8"
) as f:

    f.write(
        new_text
    )

print(
    "PATCHED"
)

print(
    "BACKUP=" + backup
)
PY
}

# ============================================================
# PATCH NATIVE
# ============================================================

patch_native() {

    header "ВНЕДРЕНИЕ В NGINX"

    local result

    result="$(
        patch_config_file \
            "$NGINX_CONFIG" \
            "$TARGET_SERVER" \
            "$TARGET_LOCATION"
    )"

    echo "$result"

    if echo "$result" |
        grep -q "^ALREADY_INSTALLED"
    then

        warn \
            "Фильтр уже установлен."

        return

    fi

    if ! echo "$result" |
        grep -q "^PATCHED"
    then

        error \
            "Не удалось изменить Nginx config."

        exit 1

    fi

    BACKUP_FILE="$(
        echo "$result" |
        sed -n 's/^BACKUP=//p'
    )"

    ok \
        "Изменён только выбранный location"

    echo

    info \
        "Backup: ${BACKUP_FILE}"

    echo
}

# ============================================================
# PATCH DOCKER
# ============================================================

patch_docker() {

    header "ВНЕДРЕНИЕ В DOCKER NGINX"

    local temp

    temp="$(mktemp)"

    docker exec \
        "$DOCKER_CONTAINER" \
        cat "$NGINX_CONFIG" \
        > "$temp"

    local result

    result="$(
        patch_config_file \
            "$temp" \
            "$TARGET_SERVER" \
            "$TARGET_LOCATION"
    )"

    echo "$result"

    if echo "$result" |
        grep -q "^ALREADY_INSTALLED"
    then

        rm -f "$temp"

        warn \
            "Фильтр уже установлен."

        return

    fi

    if ! echo "$result" |
        grep -q "^PATCHED"
    then

        rm -f "$temp"

        error \
            "Не удалось изменить Docker config."

        exit 1

    fi

    # --------------------------------------------------------
    # Create backup inside container
    # --------------------------------------------------------

    local timestamp

    timestamp="$(
        date +%Y%m%d-%H%M%S
    )"

    docker exec \
        "$DOCKER_CONTAINER" \
        cp \
        "$NGINX_CONFIG" \
        "${NGINX_CONFIG}.mobile-filter-backup.${timestamp}"

    # --------------------------------------------------------
    # Upload modified file
    # --------------------------------------------------------

    docker cp \
        "$temp" \
        "${DOCKER_CONTAINER}:${NGINX_CONFIG}"

    rm -f "$temp"

    BACKUP_FILE="${NGINX_CONFIG}.mobile-filter-backup.${timestamp}"

    ok \
        "Изменён только выбранный location"

    ok \
        "Backup внутри контейнера создан"

    echo
}

# ============================================================
# VALIDATE
# ============================================================

validate_config() {

    header "ПРОВЕРКА КОНФИГУРАЦИИ"

    echo

    if nginx_test; then

        echo
        ok "nginx -t: OK"

    else

        echo

        error \
            "nginx -t: ERROR"

        echo

        warn \
            "Reload НЕ выполняется."

        exit 1

    fi

    echo
}

# ============================================================
# RELOAD
# ============================================================

reload_nginx() {

    header "RELOAD"

    nginx_reload

    ok "Nginx успешно перезагружен"

    echo
}

# ============================================================
# CREATE UPDATE SCRIPT
# ============================================================

create_update_script() {

    header "СОЗДАНИЕ ОБНОВЛЯТОРА"

    cat > "$UPDATE_SCRIPT" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

BASE_DIR="/etc/mobile-filter"

CUSTOM_ASNS="${BASE_DIR}/custom-asns.conf"
CUSTOM_IPS="${BASE_DIR}/custom-ips.conf"

MOBILE_RANGES="/etc/nginx/mobile-ranges.conf"

INSTALLATION_CONF="${BASE_DIR}/installation.conf"

TMP="$(mktemp)"
ASN_FILE="$(mktemp)"
COUNT_FILE="$(mktemp)"

cleanup() {

    rm -f \
        "$TMP" \
        "$ASN_FILE" \
        "$COUNT_FILE"

}

trap cleanup EXIT

mkdir -p "$BASE_DIR"

touch "$CUSTOM_ASNS"
touch "$CUSTOM_IPS"

# ============================================================
# BASE ASN
# ============================================================

MOBILE_ASN=(
    8359

    3216
    16345
    42842

    31133
    47395
    35298
    31224
    31213
    31208
    31205
    31195
    31163
    25159

    12958
    15378
    42437
    48092
    48190
    41330
    39374

    201776
    206673

    35816

    205638
    214257
    202498

    203451
    203561

    47204

    31499

    214721
    204108

    59833
    47203
)

# ============================================================
# CUSTOM ASN
# ============================================================

while IFS= read -r ASN; do

    ASN="$(echo "$ASN" |
        tr -d '[:space:]')"

    [[ -z "$ASN" ]] && continue
    [[ "$ASN" =~ ^# ]] && continue

    ASN="${ASN#AS}"
    ASN="${ASN#as}"

    if [[ "$ASN" =~ ^[0-9]+$ ]]; then

        MOBILE_ASN+=("$ASN")

    fi

done < "$CUSTOM_ASNS"

printf '%s\n' \
    "${MOBILE_ASN[@]}" |
    sort -nu \
    > "$ASN_FILE"

# ============================================================
# FETCH
# ============================================================

echo
echo "============================================================"
echo " MOBILE CDN FILTER"
echo " RANGE UPDATE"
echo " $(date)"
echo "============================================================"
echo

echo "ASN count: $(wc -l < "$ASN_FILE")"
echo

while IFS= read -r ASN; do

    [[ -z "$ASN" ]] && continue

    echo -n "AS${ASN} ... "

    : > "$COUNT_FILE"

    curl -fsS \
        --max-time 30 \
        "https://stat.ripe.net/data/announced-prefixes/data.json?resource=AS${ASN}" |
    python3 -c '
import sys
import json

try:

    data = json.load(sys.stdin)

    prefixes = data.get(
        "data",
        {}
    ).get(
        "prefixes",
        []
    )

    count = 0

    for item in prefixes:

        prefix = item.get(
            "prefix",
            ""
        ).strip()

        if prefix and ":" not in prefix:

            print(
                prefix + " 1;"
            )

            count += 1

    print(
        count,
        file=sys.stderr
    )

except Exception:

    print(
        0,
        file=sys.stderr
    )
' 2>"$COUNT_FILE" \
        >> "$TMP" || true

    echo \
        "$(cat "$COUNT_FILE" 2>/dev/null || echo 0) prefixes"

    sleep 0.15

done < "$ASN_FILE"

# ============================================================
# STATIC IP
# ============================================================

echo
echo "Adding custom/static IP ranges..."

while IFS= read -r IP; do

    IP="$(echo "$IP" |
        xargs 2>/dev/null || true)"

    [[ -z "$IP" ]] && continue
    [[ "$IP" =~ ^# ]] && continue

    echo \
        "${IP} 1;" \
        >> "$TMP"

done < "$CUSTOM_IPS"

sort -u "$TMP" \
    -o "$TMP"

echo
echo "Final IPv4 prefixes:"
echo "  $(wc -l < "$TMP")"
echo

# ============================================================
# READ INSTALLATION
# ============================================================

MODE="native"
DOCKER_CONTAINER=""

if [[ -f "$INSTALLATION_CONF" ]]; then

    # shellcheck disable=SC1090
    source "$INSTALLATION_CONF"

fi

# ============================================================
# DOCKER
# ============================================================

if [[ "${MODE:-native}" == "docker" ]]; then

    if ! command -v docker >/dev/null 2>&1; then

        echo "ERROR: docker not found."
        exit 1

    fi

    if ! docker ps \
        --format '{{.Names}}' |
        grep -Fxq "${DOCKER_CONTAINER}"
    then

        echo \
            "ERROR: Docker container ${DOCKER_CONTAINER} is not running."

        exit 1

    fi

    docker exec \
        "$DOCKER_CONTAINER" \
        mkdir -p /etc/nginx

    docker exec -i \
        "$DOCKER_CONTAINER" \
        sh -c \
        'cat > /etc/nginx/mobile-ranges.conf' \
        < "$TMP"

    docker exec \
        "$DOCKER_CONTAINER" \
        nginx -t

    docker exec \
        "$DOCKER_CONTAINER" \
        nginx -s reload

    echo
    echo "Docker Nginx reloaded."

    exit 0
fi

# ============================================================
# NATIVE
# ============================================================

install -m 0644 \
    "$TMP" \
    "$MOBILE_RANGES"

nginx -t

nginx -s reload

echo
echo "Nginx reloaded."
EOF

    chmod +x "$UPDATE_SCRIPT"

    ok \
        "Создан ${UPDATE_SCRIPT}"

    echo
}

# ============================================================
# CREATE MANAGER
# ============================================================

create_manager() {

    header "СОЗДАНИЕ MANAGER"

    cat > "$MANAGER_SCRIPT" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

BASE_DIR="/etc/mobile-filter"

CUSTOM_ASNS="${BASE_DIR}/custom-asns.conf"
CUSTOM_IPS="${BASE_DIR}/custom-ips.conf"

UPDATE_SCRIPT="/usr/local/bin/update-mobile-ranges.sh"

GREEN='\033[0;32m'
RED='\033[0;31m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
NC='\033[0m'

mkdir -p "$BASE_DIR"

touch "$CUSTOM_ASNS"
touch "$CUSTOM_IPS"

pause() {

    echo
    read -r -p "Нажмите Enter..." _

}

valid_ipv4_or_cidr() {

    python3 - "$1" <<'PY'
import sys
import ipaddress

try:

    net = ipaddress.ip_network(
        sys.argv[1],
        strict=False
    )

    if net.version != 4:
        raise ValueError

except Exception:

    sys.exit(1)

sys.exit(0)
PY
}

add_asn() {

    echo
    echo "============================================================"
    echo " ДОБАВИТЬ ASN"
    echo "============================================================"
    echo

    read -r -p \
        "ASN через пробел: " values

    for ASN in $values; do

        ASN="${ASN#AS}"
        ASN="${ASN#as}"

        if [[ "$ASN" =~ ^[0-9]+$ ]]; then

            if grep -qx \
                "$ASN" \
                "$CUSTOM_ASNS"
            then

                echo \
                    "AS${ASN} уже существует."

            else

                echo \
                    "$ASN" \
                    >> "$CUSTOM_ASNS"

                echo -e \
                    "${GREEN}Добавлен AS${ASN}${NC}"

            fi

        else

            echo -e \
                "${RED}Некорректный ASN: ${ASN}${NC}"

        fi

    done

    sort -nu \
        "$CUSTOM_ASNS" \
        -o "$CUSTOM_ASNS"

    echo
    echo "После этого выберите:"
    echo "  6) Обновить диапазоны"

    pause
}

add_ip() {

    echo
    echo "============================================================"
    echo " ДОБАВИТЬ IP / CIDR"
    echo "============================================================"
    echo

    read -r -p \
        "IP/CIDR через пробел: " values

    for IP in $values; do

        if valid_ipv4_or_cidr "$IP"; then

            if grep -qxF \
                "$IP" \
                "$CUSTOM_IPS"
            then

                echo \
                    "$IP уже существует."

            else

                echo \
                    "$IP" \
                    >> "$CUSTOM_IPS"

                echo -e \
                    "${GREEN}Добавлен $IP${NC}"

            fi

        else

            echo -e \
                "${RED}Некорректный IPv4/CIDR: ${IP}${NC}"

        fi

    done

    sort -u \
        "$CUSTOM_IPS" \
        -o "$CUSTOM_IPS"

    echo
    echo "После этого выберите:"
    echo "  6) Обновить диапазоны"

    pause
}

remove_asn() {

    echo

    read -r -p \
        "ASN для удаления: " ASN

    ASN="${ASN#AS}"
    ASN="${ASN#as}"

    if [[ ! "$ASN" =~ ^[0-9]+$ ]]; then

        echo -e \
            "${RED}Некорректный ASN.${NC}"

        pause
        return

    fi

    grep -vxF \
        "$ASN" \
        "$CUSTOM_ASNS" \
        > "${CUSTOM_ASNS}.tmp" \
        || true

    mv \
        "${CUSTOM_ASNS}.tmp" \
        "$CUSTOM_ASNS"

    echo \
        "AS${ASN} удалён из custom ASN."

    pause
}

remove_ip() {

    echo

    read -r -p \
        "IP/CIDR для удаления: " IP

    grep -vxF \
        "$IP" \
        "$CUSTOM_IPS" \
        > "${CUSTOM_IPS}.tmp" \
        || true

    mv \
        "${CUSTOM_IPS}.tmp" \
        "$CUSTOM_IPS"

    echo \
        "$IP удалён из custom IP."

    pause
}

show_data() {

    clear

    echo -e "${CYAN}"
    echo "============================================================"
    echo " CUSTOM MOBILE FILTER DATA"
    echo "============================================================"
    echo -e "${NC}"

    echo
    echo "ASN:"
    echo "------------------------------------------------------------"

    if grep -qve \
        '^[[:space:]]*$' \
        "$CUSTOM_ASNS"
    then

        cat "$CUSTOM_ASNS"

    else

        echo "(пусто)"

    fi

    echo
    echo "IP/CIDR:"
    echo "------------------------------------------------------------"

    if grep -qve \
        '^[[:space:]]*$' \
        "$CUSTOM_IPS"
    then

        cat "$CUSTOM_IPS"

    else

        echo "(пусто)"

    fi

    pause
}

update_ranges() {

    echo
    echo "============================================================"
    echo " ОБНОВЛЕНИЕ ДИАПАЗОНОВ"
    echo "============================================================"
    echo

    "$UPDATE_SCRIPT"

    pause
}

while true; do

    clear

    echo -e "${CYAN}"
    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║                                                            ║"
    echo "║              MOBILE FILTER MANAGER                        ║"
    echo "║                                                            ║"
    echo "╚════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"

    echo
    echo "  1) Добавить ASN"
    echo "  2) Добавить IP/CIDR"
    echo "  3) Удалить ASN"
    echo "  4) Удалить IP/CIDR"
    echo "  5) Показать custom список"
    echo "  6) Обновить диапазоны"
    echo "  0) Выход"
    echo

    read -r -p \
        "Выбор: " choice

    case "$choice" in

        1)
            add_asn
            ;;

        2)
            add_ip
            ;;

        3)
            remove_asn
            ;;

        4)
            remove_ip
            ;;

        5)
            show_data
            ;;

        6)
            update_ranges
            ;;

        0)
            exit 0
            ;;

        *)

            echo -e \
                "${YELLOW}Неверный выбор.${NC}"

            sleep 1
            ;;

    esac

done
EOF

    chmod +x "$MANAGER_SCRIPT"

    ok \
        "Создан ${MANAGER_SCRIPT}"

    echo
}

# ============================================================
# CRON
# ============================================================

setup_cron() {

    header "АВТООБНОВЛЕНИЕ"

    if [[ "$MODE" == "docker" ]]; then

        cat > "$CRON_FILE" <<EOF
0 2 * * * root ${UPDATE_SCRIPT} >> ${LOG_FILE} 2>&1
EOF

    else

        cat > "$CRON_FILE" <<EOF
0 2 * * * root ${UPDATE_SCRIPT} >> ${LOG_FILE} 2>&1
EOF

    fi

    chmod 644 "$CRON_FILE"

    ok \
        "Автообновление: каждый день в 02:00"

    ok \
        "Лог: ${LOG_FILE}"

    echo
}

# ============================================================
# SAVE INSTALLATION
# ============================================================

save_installation() {

    cat > "$INSTALLATION_CONF" <<EOF
MODE="${MODE}"
DOCKER_CONTAINER="${DOCKER_CONTAINER}"
NGINX_CONFIG="${NGINX_CONFIG}"
TARGET_SERVER="${TARGET_SERVER}"
TARGET_LOCATION="${TARGET_LOCATION}"
IP_SOURCE="${IP_SOURCE}"
VERSION="${VERSION}"
INSTALLED_AT="$(date '+%Y-%m-%d %H:%M:%S')"
EOF

    chmod 600 \
        "$INSTALLATION_CONF"
}

# ============================================================
# FINAL STATUS
# ============================================================

finish() {

    echo
    echo -e "${GREEN}"
    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║                                                            ║"
    echo "║                  УСТАНОВКА ЗАВЕРШЕНА                      ║"
    echo "║                                                            ║"
    echo "╚════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"

    echo
    echo -e "${BOLD}Режим:${NC}"

    if [[ "$MODE" == "docker" ]]; then

        echo \
            "  Docker Nginx: ${DOCKER_CONTAINER}"

    else

        echo \
            "  Native Nginx"

    fi

    echo

    echo -e "${BOLD}Выбранный server:${NC}"
    echo "  ${TARGET_SERVER:-_}"

    echo

    echo -e "${BOLD}Выбранный location:${NC}"
    echo "  ${TARGET_LOCATION}"

    echo

    echo -e "${BOLD}Конфигурация:${NC}"
    echo "  ${NGINX_CONFIG}"

    echo

    if [[ -n "$BACKUP_FILE" ]]; then

        echo -e "${BOLD}Backup:${NC}"
        echo "  ${BACKUP_FILE}"

        echo

    fi

    line

    echo

    echo -e "${BOLD}Управление:${NC}"
    echo

    echo "  mobile-filter"

    echo

    echo "  Можно позже:"
    echo "    • добавить IP"
    echo "    • добавить CIDR"
    echo "    • добавить ASN"
    echo "    • удалить IP"
    echo "    • удалить ASN"
    echo "    • обновить диапазоны"

    echo

    line

    echo

    echo -e "${BOLD}Файлы:${NC}"
    echo

    echo "  Custom ASN:"
    echo "    ${CUSTOM_ASNS}"

    echo
    echo "  Custom IP:"
    echo "    ${CUSTOM_IPS}"

    echo
    echo "  Installation:"
    echo "    ${INSTALLATION_CONF}"

    echo
    echo "  Range updater:"
    echo "    ${UPDATE_SCRIPT}"

    echo
    echo "  Manager:"
    echo "    ${MANAGER_SCRIPT}"

    echo
    echo "  Cron:"
    echo "    ${CRON_FILE}"

    echo

    line

    echo

    echo -e "${BOLD}Проверка:${NC}"
    echo

    if [[ "$MODE" == "docker" ]]; then

        echo "  Полный конфиг:"
        echo "    docker exec -it ${DOCKER_CONTAINER} nginx -T"

        echo
        echo "  Текущий config:"
        echo "    docker exec -it ${DOCKER_CONTAINER} cat ${NGINX_CONFIG}"

        echo
        echo "  Проверка:"
        echo "    docker exec ${DOCKER_CONTAINER} nginx -t"

    else

        echo "  Полный конфиг:"
        echo "    nginx -T"

        echo
        echo "  Текущий config:"
        echo "    cat ${NGINX_CONFIG}"

        echo
        echo "  Проверка:"
        echo "    nginx -t"

    fi

    echo

    line

    echo

    echo -e "${BOLD}Принцип работы:${NC}"
    echo

    echo "  1. IP клиента определяется из выбранного источника."
    echo
    echo "  2. Nginx проверяет IP через geo."
    echo
    echo "  3. Разрешённые мобильные сети получают 1."
    echo
    echo "  4. Остальные получают 0."
    echo
    echo "  5. В выбранном location:"
    echo
    echo "       if (\$mobile_filter_allowed = 0) {"
    echo "           return 403;"
    echo "       }"
    echo
    echo "  6. Существующий proxy_pass остаётся без изменений."

    echo

    line

    echo
    echo -e "${GREEN}Готово.${NC}"
    echo
}

# ============================================================
# MAIN
# ============================================================

main() {

    banner

    check_root

    prepare_directories

    select_mode

    install_dependencies

    check_docker_container

    show_nginx_info

    # --------------------------------------------------------
    # Existing installation
    # --------------------------------------------------------

    if [[ -f "$INSTALLATION_CONF" ]]; then

        warn \
            "На сервере уже найдена установка mobile-filter."

        echo

        echo "Файл:"
        echo "  ${INSTALLATION_CONF}"

        echo

        read -r -p \
            "Продолжить и проверить текущую конфигурацию? [Y/n]: " answer

        if [[ "$answer" =~ ^[Nn]$ ]]; then

            echo
            echo "Отмена."
            exit 0

        fi

        echo

    fi

    # --------------------------------------------------------
    # Analyse actual Nginx
    # --------------------------------------------------------

    select_server

    select_location

    select_ip_source

    # --------------------------------------------------------
    # User custom IP / ASN
    # --------------------------------------------------------

    add_initial_custom_data

    # --------------------------------------------------------
    # Built-in static networks
    # --------------------------------------------------------

    install_static_networks

    # --------------------------------------------------------
    # Helper scripts
    # --------------------------------------------------------

    create_update_script

    create_manager

    # --------------------------------------------------------
    # Initial database
    # --------------------------------------------------------

    generate_ranges

    # --------------------------------------------------------
    # Filter include
    # --------------------------------------------------------

    check_filter_include

    create_filter_config

    # --------------------------------------------------------
    # Patch target location
    # --------------------------------------------------------

    if [[ "$MODE" == "docker" ]]; then

        patch_docker

    else

        patch_native

    fi

    # --------------------------------------------------------
    # Validate before reload
    # --------------------------------------------------------

    validate_config

    # --------------------------------------------------------
    # Reload
    # --------------------------------------------------------

    reload_nginx

    # --------------------------------------------------------
    # Cron
    # --------------------------------------------------------

    setup_cron

    # --------------------------------------------------------
    # Save installation
    # --------------------------------------------------------

    save_installation

    # --------------------------------------------------------
    # Final screen
    # --------------------------------------------------------

    finish
}

main "$@"