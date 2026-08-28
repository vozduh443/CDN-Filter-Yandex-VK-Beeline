#!/usr/bin/env bash
set -Eeuo pipefail

VERSION="7.1.0"

# ============================================================
# MOBILE CDN FILTER
# Universal installer for Nginx
#
# Modes:
#   1) Native Nginx
#   2) Nginx in Docker
#
# Designed for CDN/proxy setups such as:
# VK Cloud, Yandex Cloud, Beeline Cloud, CDN Video,
# Turboflare, Beget, Timeweb, Selectel, etc.
#
# Caddy is not supported.
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
WHITE='\033[1;37m'
GRAY='\033[0;90m'
BOLD='\033[1m'
NC='\033[0m'

BASE_DIR="/etc/mobile-filter"
CUSTOM_ASNS="${BASE_DIR}/custom-asns.conf"
CUSTOM_IPS="${BASE_DIR}/custom-ips.conf"
STATE_FILE="${BASE_DIR}/installation.conf"

MOBILE_RANGES="/etc/nginx/mobile-ranges.conf"
FILTER_FILE="/etc/nginx/conf.d/mobile-filter.generated.conf"

UPDATE_SCRIPT="/usr/local/bin/update-mobile-ranges.sh"
MANAGER_SCRIPT="/usr/local/bin/mobile-filter"
CRON_FILE="/etc/cron.d/mobile-filter"
UPDATE_LOG="/var/log/mobile-filter-update.log"

FILTER_VAR="mobile_cdn_filter_allowed"
FILTER_MARKER="# MOBILE-CDN-FILTER"

MODE=""
DOCKER_CONTAINER=""
NGINX_CONFIG=""
TARGET_SERVER=""
TARGET_SERVER_DISPLAY=""
TARGET_LOCATION=""
TARGET_SERVER_NO=""
IP_SOURCE=""

NGINX_DUMP_FILE=""
BACKUP_TARGET=""
BACKUP_MAIN=""
BACKUP_RANGES=""
FILTER_CREATED=0

ok()    { echo -e "  ${GREEN}✓${NC} $1"; }
warn()  { echo -e "  ${YELLOW}⚠${NC} $1"; }
error() { echo -e "  ${RED}✘${NC} $1"; }
info()  { echo -e "  ${CYAN}➜${NC} $1"; }
die()   { error "$1"; exit 1; }

header() {
    echo
    echo -e "${BOLD}${CYAN}$1${NC}"
    echo -e "${GRAY}────────────────────────────────────────────────────────────${NC}"
}

cleanup() {
    [[ -n "${NGINX_DUMP_FILE:-}" ]] &&
        rm -f "$NGINX_DUMP_FILE" 2>/dev/null || true
}

trap cleanup EXIT

# ============================================================
# Built-in mobile ASN pool
# AS12389 is intentionally excluded.
# ============================================================

BASE_MOBILE_ASN=(
    8359
    3216 16345 42842
    31133 47395 35298 31224 31213 31208 31205 31195 31163 25159
    12958 15378 42437 48092 48190 41330 39374
    201776
    206673
    35816
    205638 214257 202498
    203451 203561
    47204
    31499
    214721 204108
    59833 47203
)

# ============================================================
# Static IPv4 ranges
# ============================================================

STATIC_IPS=(
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
    "5.101.18.0/24"
    "91.107.97.0/24"
    "84.18.108.0/24"
)

banner() {
    clear 2>/dev/null || true
    echo -e "${CYAN}"
    echo "╔════════════════════════════════════════════════════════════╗"
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
}

check_root() {
    [[ "$EUID" -eq 0 ]] || die "Запустите установщик от root."
}

init_files() {
    mkdir -p "$BASE_DIR"
    touch "$CUSTOM_ASNS" "$CUSTOM_IPS"
    chmod 600 "$CUSTOM_ASNS" "$CUSTOM_IPS"
}

select_mode() {
    header "РЕЖИМ NGINX"

    echo
    echo "  1) Обычный Nginx"
    echo "  2) Nginx в Docker"
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
                read -r -p \
                    "  Имя контейнера [cdn-nginx]: " DOCKER_CONTAINER
                DOCKER_CONTAINER="${DOCKER_CONTAINER:-cdn-nginx}"
                break
                ;;
            *)
                error "Введите 1 или 2."
                ;;
        esac
    done

    echo

    if [[ "$MODE" == "native" ]]; then
        ok "Обычный Nginx"
    else
        ok "Docker: ${DOCKER_CONTAINER}"
    fi
}

install_dependencies() {
    header "ПРОВЕРКА ЗАВИСИМОСТЕЙ"

    local missing=()

    command -v curl >/dev/null 2>&1 || missing+=(curl)
    command -v python3 >/dev/null 2>&1 || missing+=(python3)

    if [[ "$MODE" == "native" ]] &&
       ! command -v nginx >/dev/null 2>&1
    then
        missing+=(nginx)
    fi

    if [[ "$MODE" == "docker" ]] &&
       ! command -v docker >/dev/null 2>&1
    then
        missing+=(docker)
    fi

    if (( ${#missing[@]} == 0 )); then
        ok "Все зависимости установлены"
        return 0
    fi

    command -v apt-get >/dev/null 2>&1 ||
        die "Не найдены: ${missing[*]} и apt-get недоступен."

    info "Устанавливаем: ${missing[*]}"
    apt-get update -qq
    apt-get install -y -qq "${missing[@]}"
    ok "Зависимости установлены"
}

check_docker() {
    [[ "$MODE" == "docker" ]] || return 0

    header "ПРОВЕРКА DOCKER"

    docker info >/dev/null 2>&1 ||
        die "Docker недоступен."

    docker ps --format '{{.Names}}' |
        grep -Fxq "$DOCKER_CONTAINER" ||
        die "Контейнер '${DOCKER_CONTAINER}' не запущен."

    ok "Контейнер найден: ${DOCKER_CONTAINER}"
}

nginx_test() {
    if [[ "$MODE" == "docker" ]]; then
        docker exec "$DOCKER_CONTAINER" nginx -t
    else
        nginx -t
    fi
}

nginx_reload() {
    if [[ "$MODE" == "docker" ]]; then
        docker exec "$DOCKER_CONTAINER" nginx -s reload
    else
        nginx -s reload
    fi
}

save_nginx_dump() {
    NGINX_DUMP_FILE="$(mktemp)"

    if [[ "$MODE" == "docker" ]]; then
        docker exec "$DOCKER_CONTAINER" nginx -T \
            >"$NGINX_DUMP_FILE" 2>&1
    else
        nginx -T >"$NGINX_DUMP_FILE" 2>&1
    fi
}

# ============================================================
# nginx -T parser
#
# Output:
# SERVER|number|file|names|listen
# LOCATION|server_number|location_number|location|proxy_pass
# ============================================================

parse_targets() {
    python3 - "$1" <<'PY'
import re
import sys

path = sys.argv[1]

with open(path, "r", encoding="utf-8", errors="replace") as f:
    text = f.read()

lines = text.splitlines()
current_file = ""

def block_from(lines, start, keyword):
    clean = lines[start].split("#", 1)[0].rstrip()

    if not re.match(
        rf'^[ \t]*{re.escape(keyword)}[ \t]*\{{',
        clean
    ):
        return None

    depth = 0
    result = []

    for idx in range(start, len(lines)):
        clean = re.sub(r'#.*$', '', lines[idx])
        depth += clean.count("{")
        depth -= clean.count("}")
        result.append(lines[idx])

        if idx > start and depth == 0:
            return "\n".join(result)

    return None

servers = []
i = 0

while i < len(lines):

    marker = re.match(
        r'^# configuration file (.+):$',
        lines[i]
    )

    if marker:
        current_file = marker.group(1).strip()

    clean = re.sub(r'#.*$', '', lines[i]).strip()

    if re.match(r'^server\s*\{', clean):

        block = block_from(lines, i, "server")

        if block:

            names = []
            listens = []

            for m in re.finditer(
                r'(?m)^[ \t]*server_name[ \t]+([^;]+);',
                block
            ):
                names.extend(m.group(1).split())

            for m in re.finditer(
                r'(?m)^[ \t]*listen[ \t]+([^;]+);',
                block
            ):
                listens.append(m.group(1).strip())

            locations = []

            for lm in re.finditer(
                r'(?m)^[ \t]*location[ \t]+([^{]+)\{',
                block
            ):

                loc_header = lm.group(1).strip()

                open_pos = block.find("{", lm.start())
                depth = 0
                close_pos = None

                for p in range(
                    open_pos,
                    len(block)
                ):

                    if block[p] == "{":
                        depth += 1

                    elif block[p] == "}":
                        depth -= 1

                        if depth == 0:
                            close_pos = p + 1
                            break

                if close_pos is None:
                    continue

                loc_block = block[
                    lm.start():close_pos
                ]

                proxy = re.findall(
                    r'(?m)^[ \t]*proxy_pass[ \t]+([^;]+);',
                    loc_block
                )

                if proxy:
                    locations.append(
                        (
                            loc_header,
                            proxy[0].strip()
                        )
                    )

            servers.append(
                (
                    current_file,
                    names,
                    listens,
                    locations
                )
            )

            depth = 0

            for j in range(i, len(lines)):

                clean2 = re.sub(r'#.*$', '', lines[j])
                depth += clean2.count("{")
                depth -= clean2.count("}")

                if j > i and depth == 0:
                    i = j
                    break

    i += 1

for snum, server in enumerate(servers, 1):

    filename, names, listens, locations = server

    print(
        "SERVER|{}|{}|{}|{}".format(
            snum,
            filename.replace("|", "/"),
            " ".join(names).replace("|", "/"),
            " ".join(listens).replace("|", "/")
        )
    )

    for lnum, location in enumerate(
        locations,
        1
    ):

        print(
            "LOCATION|{}|{}|{}|{}".format(
                snum,
                lnum,
                location[0].replace("|", "/"),
                location[1].replace("|", "/")
            )
        )
PY
}

# ============================================================
# Server + location selection
# ============================================================

select_target() {
    header "АНАЛИЗ ТЕКУЩЕЙ КОНФИГУРАЦИИ"

    save_nginx_dump

    local parsed
    parsed="$(parse_targets "$NGINX_DUMP_FILE")"

    [[ -n "$parsed" ]] ||
        die "Не найдено ни одного server-блока."

    declare -a SERVER_FILES
    declare -a SERVER_NAMES
    declare -a SERVER_LISTENS

    local count=0

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

        echo
        echo -e "  ${WHITE}$((count + 1))${NC}"
        echo "     server_name: ${names:-_}"
        echo "     listen:      ${listens:-_}"
        echo -e "     config:      ${GRAY}${file}${NC}"

        count=$((count + 1))

    done <<< "$parsed"

    (( count > 0 )) ||
        die "Server-блоки не найдены."

    local choice

    if (( count == 1 )); then

        choice=1

        echo
        ok "Единственный server выбран автоматически."

    else

        while true; do

            read -r -p \
                "  Выберите server [1-${count}]: " choice

            if [[ "$choice" =~ ^[0-9]+$ ]] &&
               (( choice >= 1 && choice <= count ))
            then
                break
            fi

            error "Неверный выбор."
        done

    fi

    local idx=$((choice - 1))

    TARGET_SERVER_DISPLAY="${SERVER_NAMES[$idx]}"
    TARGET_SERVER="${SERVER_NAMES[$idx]%% *}"
    TARGET_FILE="${SERVER_FILES[$idx]}"
    TARGET_SERVER_NO="$choice"
    NGINX_CONFIG="$TARGET_FILE"

    echo
    ok "Server: ${TARGET_SERVER_DISPLAY:-_}"
    ok "Config: ${TARGET_FILE}"

    declare -a LOC_NAMES
    declare -a LOC_PROXIES

    local location_count=0

    while IFS='|' read -r \
        type \
        server_number \
        location_number \
        location \
        proxy
    do

        [[ "$type" == "LOCATION" ]] || continue
        [[ "$server_number" == "$TARGET_SERVER_NO" ]] || continue

        LOC_NAMES[$location_count]="$location"
        LOC_PROXIES[$location_count]="$proxy"

        echo
        echo -e \
            "  ${WHITE}$((location_count + 1))${NC}) ${location}"

        echo -e \
            "     proxy_pass: ${proxy}"

        location_count=$((location_count + 1))

    done <<< "$parsed"

    (( location_count > 0 )) ||
        die "В выбранном server нет location с proxy_pass."

    if (( location_count == 1 )); then

        choice=1

        echo
        ok "Единственный proxy location выбран автоматически."

    else

        while true; do

            read -r -p \
                "  Выберите location [1-${location_count}]: " choice

            if [[ "$choice" =~ ^[0-9]+$ ]] &&
               (( choice >= 1 && choice <= location_count ))
            then
                break
            fi

            error "Неверный выбор."
        done

    fi

    TARGET_LOCATION="${LOC_NAMES[$((choice - 1))]}"

    echo
    ok "Location: ${TARGET_LOCATION}"
    ok "Proxy:    ${LOC_PROXIES[$((choice - 1))]}"
}

# ============================================================
# IP source
# ============================================================

select_ip_source() {
    header "ИСТОЧНИК IP КЛИЕНТА"

    echo
    echo "  1) X-Real-IP"
    echo "  2) Первый IP X-Forwarded-For"
    echo "  3) remote_addr"
    echo "  4) Автоматически"
    echo

    local choice

    while true; do

        read -r -p \
            "  Выберите [1-4, по умолчанию 4]: " choice

        choice="${choice:-4}"

        case "$choice" in
            1) IP_SOURCE="x_real_ip"; break ;;
            2) IP_SOURCE="xff"; break ;;
            3) IP_SOURCE="remote"; break ;;
            4) IP_SOURCE="auto"; break ;;
            *) error "Введите 1-4." ;;
        esac

    done

    echo

    case "$IP_SOURCE" in
        x_real_ip)
            ok "X-Real-IP"
            ;;
        xff)
            ok "Первый IP X-Forwarded-For"
            ;;
        remote)
            ok "remote_addr"
            ;;
        auto)
            ok "X-Forwarded-For → remote_addr"
            ;;
    esac
}

# ============================================================
# User custom IP / ASN
# ============================================================

valid_ipv4_or_cidr() {
    python3 - "$1" <<'PY'
import ipaddress
import sys

try:
    net = ipaddress.ip_network(
        sys.argv[1],
        strict=False
    )

    if net.version != 4:
        raise ValueError

except Exception:
    raise SystemExit(1)

raise SystemExit(0)
PY
}

ask_custom() {
    header "СОБСТВЕННЫЕ IP И ASN"

    echo
    echo "Можно добавить свои IP/CIDR и ASN."
    echo "Они сохранятся и не удалятся при автообновлении."
    echo

    read -r -p \
        "  Добавить свои IP/CIDR? [y/N]: " answer

    if [[ "$answer" =~ ^[Yy]$ ]]; then

        read -r -p \
            "  IP/CIDR через пробел: " values

        for value in $values; do

            if valid_ipv4_or_cidr "$value"; then

                echo "$value" >> "$CUSTOM_IPS"

                ok "Добавлен IP: $value"

            else

                warn \
                    "Некорректный IPv4/CIDR: $value"

            fi

        done

    fi

    echo

    read -r -p \
        "  Добавить свои ASN? [y/N]: " answer

    if [[ "$answer" =~ ^[Yy]$ ]]; then

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

    for IP in "${STATIC_IPS[@]}"; do
        echo "$IP" >> "$CUSTOM_IPS"
    done

    sort -u "$CUSTOM_IPS" -o "$CUSTOM_IPS"
    sort -nu "$CUSTOM_ASNS" -o "$CUSTOM_ASNS"
}

# ============================================================
# Backup
# ============================================================

backup_current() {
    header "BACKUP"

    local ts
    ts="$(date +%Y%m%d-%H%M%S)"

    BACKUP_TARGET="${TARGET_FILE}.mobile-filter-backup.${ts}"

    if [[ "$MODE" == "docker" ]]; then

        docker exec "$DOCKER_CONTAINER" \
            cp "$TARGET_FILE" "$BACKUP_TARGET"

        if docker exec "$DOCKER_CONTAINER" \
            test -f "$MOBILE_RANGES"
        then

            BACKUP_RANGES="${MOBILE_RANGES}.mobile-filter-backup.${ts}"

            docker exec "$DOCKER_CONTAINER" \
                cp "$MOBILE_RANGES" "$BACKUP_RANGES"

        fi

    else

        [[ -f "$TARGET_FILE" ]] ||
            die "Целевой конфиг не найден: $TARGET_FILE"

        cp -a "$TARGET_FILE" "$BACKUP_TARGET"

        if [[ -f "$MOBILE_RANGES" ]]; then

            BACKUP_RANGES="${MOBILE_RANGES}.mobile-filter-backup.${ts}"

            cp -a "$MOBILE_RANGES" "$BACKUP_RANGES"

        fi

    fi

    ok "Backup создан"
}

# ============================================================
# Filter config
# ============================================================

create_filter_file() {
    header "СОЗДАНИЕ FILTER"

    local tmp
    tmp="$(mktemp)"

    case "$IP_SOURCE" in

        x_real_ip)

            cat > "$tmp" <<EOF
${FILTER_MARKER}
geo \$http_x_real_ip ${FILTER_VAR} {
    default 0;
    include /etc/nginx/mobile-ranges.conf;
}
EOF
            ;;

        xff)

            cat > "$tmp" <<EOF
${FILTER_MARKER}
map \$http_x_forwarded_for mobile_cdn_client_ip {
    default \$remote_addr;
    "~^(?<mobile_cdn_first_ip>[^, ]+)" \$mobile_cdn_first_ip;
}

geo \$mobile_cdn_client_ip ${FILTER_VAR} {
    default 0;
    include /etc/nginx/mobile-ranges.conf;
}
EOF
            ;;

        remote)

            cat > "$tmp" <<EOF
${FILTER_MARKER}
geo \$remote_addr ${FILTER_VAR} {
    default 0;
    include /etc/nginx/mobile-ranges.conf;
}
EOF
            ;;

        auto)

            cat > "$tmp" <<EOF
${FILTER_MARKER}
map \$http_x_forwarded_for mobile_cdn_client_ip {
    default \$remote_addr;
    "~^(?<mobile_cdn_first_ip>[^, ]+)" \$mobile_cdn_first_ip;
}

geo \$mobile_cdn_client_ip ${FILTER_VAR} {
    default 0;
    include /etc/nginx/mobile-ranges.conf;
}
EOF
            ;;

    esac

    if [[ "$MODE" == "docker" ]]; then

        docker exec "$DOCKER_CONTAINER" \
            mkdir -p /etc/nginx/conf.d

        if docker exec "$DOCKER_CONTAINER" \
            test -e "$FILTER_FILE"
        then

            if ! docker exec "$DOCKER_CONTAINER" \
                grep -qF "$FILTER_MARKER" "$FILTER_FILE"
            then

                rm -f "$tmp"

                die \
                    "Файл ${FILTER_FILE} уже используется."

            fi

            FILTER_CREATED=0

        else

            docker cp "$tmp" \
                "${DOCKER_CONTAINER}:${FILTER_FILE}"

            FILTER_CREATED=1

        fi

    else

        mkdir -p /etc/nginx/conf.d

        if [[ -e "$FILTER_FILE" ]] &&
           ! grep -qF "$FILTER_MARKER" "$FILTER_FILE"
        then

            rm -f "$tmp"

            die \
                "Файл ${FILTER_FILE} уже используется."

        fi

        if [[ ! -e "$FILTER_FILE" ]]; then

            install -m 0644 \
                "$tmp" \
                "$FILTER_FILE"

            FILTER_CREATED=1

        fi

    fi

    rm -f "$tmp"

    ok "Filter: ${FILTER_FILE}"
}

# ============================================================
# Include filter into http {}
# ============================================================

ensure_filter_include() {
    header "ПОДКЛЮЧЕНИЕ FILTER"

    local main="/etc/nginx/nginx.conf"

    if [[ "$MODE" == "docker" ]]; then

        local dump
        local tmp

        dump="$(mktemp)"

        docker exec "$DOCKER_CONTAINER" \
            nginx -T >"$dump" 2>&1 || true

        if grep -qF "$FILTER_FILE" "$dump"; then

            rm -f "$dump"

            ok "Filter уже подключён"

            return 0

        fi

        if grep -qE \
            'include[[:space:]]+/etc/nginx/conf\.d/\*\.conf;' \
            "$dump"
        then

            rm -f "$dump"

            ok \
                "Docker Nginx подключает conf.d/*.conf"

            return 0

        fi

        rm -f "$dump"

        tmp="$(mktemp)"

        docker exec "$DOCKER_CONTAINER" \
            cat "$main" > "$tmp"

        python3 - "$tmp" "$FILTER_FILE" <<'PY'
import re
import sys

path = sys.argv[1]
include = sys.argv[2]

with open(path, encoding="utf-8") as f:
    text = f.read()

if include in text:
    raise SystemExit(0)

m = re.search(
    r"(?m)^[ \t]*http[ \t]*\{",
    text
)

if not m:
    raise SystemExit(2)

pos = text.find(
    "{",
    m.start()
)

text = (
    text[:pos + 1] +
    f"\n    include {include};\n" +
    text[pos + 1:]
)

with open(path, "w", encoding="utf-8") as f:
    f.write(text)
PY

        local ts
        ts="$(date +%Y%m%d-%H%M%S)"

        BACKUP_MAIN="${main}.mobile-filter-backup.${ts}"

        docker exec "$DOCKER_CONTAINER" \
            cp "$main" "$BACKUP_MAIN"

        docker cp "$tmp" \
            "${DOCKER_CONTAINER}:${main}"

        rm -f "$tmp"

        ok "Include добавлен в Docker nginx.conf"

    else

        if grep -qF "$FILTER_FILE" "$main"; then

            ok "Filter уже подключён"

            return 0

        fi

        if grep -qE \
            'include[[:space:]]+/etc/nginx/conf\.d/\*\.conf;' \
            "$main"
        then

            ok "Nginx подключает conf.d/*.conf"

            return 0

        fi

        local backup

        backup="${main}.mobile-filter-backup.$(
            date +%Y%m%d-%H%M%S
        )"

        cp -a "$main" "$backup"

        python3 - "$main" "$FILTER_FILE" <<'PY'
import re
import sys

path = sys.argv[1]
include = sys.argv[2]

with open(path, encoding="utf-8") as f:
    text = f.read()

if include in text:
    raise SystemExit(0)

m = re.search(
    r"(?m)^[ \t]*http[ \t]*\{",
    text
)

if not m:
    raise SystemExit(2)

pos = text.find(
    "{",
    m.start()
)

text = (
    text[:pos + 1] +
    f"\n    include {include};\n" +
    text[pos + 1:]
)

with open(path, "w", encoding="utf-8") as f:
    f.write(text)
PY

        BACKUP_MAIN="$backup"

        ok "Include добавлен в nginx.conf"
    fi
}

# ============================================================
# Generate whitelist
# ============================================================

generate_ranges() {
    header "ОБНОВЛЕНИЕ MOBILE RANGES"

    local asn_file
    local output
    local count_file

    asn_file="$(mktemp)"
    output="$(mktemp)"
    count_file="$(mktemp)"

    printf '%s\n' \
        "${BASE_MOBILE_ASN[@]}" \
        > "$asn_file"

    while IFS= read -r ASN; do

        ASN="$(echo "$ASN" | tr -d '[:space:]')"

        [[ -z "$ASN" ]] && continue
        [[ "$ASN" =~ ^# ]] && continue

        ASN="${ASN#AS}"
        ASN="${ASN#as}"

        if [[ "$ASN" =~ ^[0-9]+$ ]]; then
            echo "$ASN" >> "$asn_file"
        fi

    done < "$CUSTOM_ASNS"

    sort -nu "$asn_file" -o "$asn_file"

    local total_asn
    total_asn="$(wc -l < "$asn_file")"

    echo
    echo "ASN в пуле: ${total_asn}"
    echo

    while IFS= read -r ASN; do

        echo -n "  AS${ASN} ... "

        : > "$count_file"

        if curl -fsS \
            --max-time 30 \
            "https://stat.ripe.net/data/announced-prefixes/data.json?resource=AS${ASN}" |
        python3 -c '
import json
import sys

try:
    data = json.load(sys.stdin)
    prefixes = data.get("data", {}).get("prefixes", [])
    count = 0

    for item in prefixes:
        p = item.get("prefix", "").strip()

        if p and ":" not in p:
            print(p + " 1;")
            count += 1

    print(count, file=sys.stderr)

except Exception:
    print(0, file=sys.stderr)
' 2>"$count_file" >> "$output"
        then
            echo \
                "$(cat "$count_file" 2>/dev/null || echo 0) prefixes"
        else
            echo "ERROR"
        fi

        sleep 0.12

    done < "$asn_file"

    echo
    echo "Добавление static/custom IP..."

    while IFS= read -r IP; do

        IP="$(echo "$IP" | xargs 2>/dev/null || true)"

        [[ -z "$IP" ]] && continue
        [[ "$IP" =~ ^# ]] && continue

        echo "${IP} 1;" >> "$output"

    done < "$CUSTOM_IPS"

    sort -u "$output" -o "$output"

    local total
    total="$(wc -l < "$output")"

    echo
    echo "Итого IPv4 prefixes: ${total}"

    (( total > 0 )) ||
        die "Whitelist пуст."

    if [[ "$MODE" == "docker" ]]; then

        docker exec -i "$DOCKER_CONTAINER" \
            sh -c \
            'cat > /etc/nginx/mobile-ranges.conf' \
            < "$output"

    else

        install -m 0644 \
            "$output" \
            "$MOBILE_RANGES"

    fi

    rm -f \
        "$asn_file" \
        "$output" \
        "$count_file"

    ok "Mobile ranges установлены"
}

# ============================================================
# Patch selected location
# ============================================================

patch_target() {
    header "ВНЕДРЕНИЕ ФИЛЬТРА"

    local tmp
    tmp="$(mktemp)"

    if [[ "$MODE" == "docker" ]]; then

        docker exec "$DOCKER_CONTAINER" \
            cat "$TARGET_FILE" > "$tmp"

    else

        cp "$TARGET_FILE" "$tmp"

    fi

    local result

    result="$(
        python3 \
            - "$tmp" "$TARGET_SERVER" "$TARGET_LOCATION" <<'PY'
import re
import sys

path = sys.argv[1]
wanted_server = sys.argv[2]
wanted_location = sys.argv[3]

with open(path, encoding="utf-8") as f:
    text = f.read()

servers = []

for sm in re.finditer(
    r"(?m)^[ \t]*server\b[^{]*\{",
    text
):

    ss = sm.start()
    op = text.find("{", sm.start())

    depth = 0
    se = None

    for i in range(op, len(text)):

        if text[i] == "{":
            depth += 1

        elif text[i] == "}":

            depth -= 1

            if depth == 0:
                se = i + 1
                break

    if se is None:
        continue

    block = text[ss:se]

    names = []

    for m in re.finditer(
        r"(?m)^[ \t]*server_name[ \t]+([^;]+);",
        block
    ):
        names.extend(m.group(1).split())

    if wanted_server in names:
        servers.append(
            (
                ss,
                se,
                block
            )
        )

if not servers:
    print("NO_SERVER")
    raise SystemExit(2)

ss, se, server_block = servers[0]

selected = None

for lm in re.finditer(
    r"(?m)^[ \t]*location[ \t]+([^{]+)\{",
    server_block
):

    location = lm.group(1).strip()

    if (
        location != wanted_location
        and wanted_location not in location
    ):
        continue

    op = server_block.find(
        "{",
        lm.start()
    )

    depth = 0
    le = None

    for i in range(
        op,
        len(server_block)
    ):

        if server_block[i] == "{":
            depth += 1

        elif server_block[i] == "}":

            depth -= 1

            if depth == 0:
                le = i + 1
                break

    if le is not None:

        selected = (
            lm.start(),
            le,
            server_block[
                lm.start():le
            ]
        )

        break

if selected is None:
    print("NO_LOCATION")
    raise SystemExit(3)

ls, le, location_block = selected

if re.search(
    r"(?m)^[ \t]*if[ \t]*\(\$mobile_cdn_filter_allowed[ \t]*=[ \t]*0\)",
    location_block
):
    print("ALREADY")
    raise SystemExit(0)

proxy = re.search(
    r"(?m)^([ \t]*)proxy_pass\b",
    location_block
)

indent = (
    proxy.group(1)
    if proxy
    else "    "
)

injection = (
    indent +
    "if ($mobile_cdn_filter_allowed = 0) {\n" +
    indent +
    "    return 403;\n" +
    indent +
    "}\n\n"
)

if proxy:

    new_location = (
        location_block[:proxy.start()] +
        injection +
        location_block[proxy.start():]
    )

else:

    p = location_block.find("{")

    new_location = (
        location_block[:p + 1] +
        "\n" +
        injection +
        location_block[p + 1:]
    )

new_server = (
    server_block[:ls] +
    new_location +
    server_block[le:]
)

new_text = (
    text[:ss] +
    new_server +
    text[se:]
)

with open(path, "w", encoding="utf-8") as f:
    f.write(new_text)

print("PATCHED")
PY
    )"

    if grep -q "^ALREADY$" <<< "$result"; then

        rm -f "$tmp"

        ok "Фильтр уже установлен"

        return 0
    fi

    if ! grep -q "^PATCHED$" <<< "$result"; then

        rm -f "$tmp"

        die "Не удалось внедрить фильтр."

    fi

    if [[ "$MODE" == "docker" ]]; then

        docker cp \
            "$tmp" \
            "${DOCKER_CONTAINER}:${TARGET_FILE}"

    else

        cp "$tmp" "$TARGET_FILE"

    fi

    rm -f "$tmp"

    ok "Фильтр внедрён"
}

# ============================================================
# Rollback
# ============================================================

rollback() {
    warn "Выполняется rollback..."

    if [[ "$MODE" == "docker" ]]; then

        if [[ -n "${BACKUP_TARGET:-}" ]]; then

            docker exec "$DOCKER_CONTAINER" \
                cp "$BACKUP_TARGET" "$TARGET_FILE" \
                >/dev/null 2>&1 || true

        fi

        if [[ -n "${BACKUP_MAIN:-}" ]]; then

            docker exec "$DOCKER_CONTAINER" \
                cp "$BACKUP_MAIN" /etc/nginx/nginx.conf \
                >/dev/null 2>&1 || true

        fi

        if [[ -n "${BACKUP_RANGES:-}" ]]; then

            docker exec "$DOCKER_CONTAINER" \
                cp "$BACKUP_RANGES" "$MOBILE_RANGES" \
                >/dev/null 2>&1 || true

        fi

    else

        if [[ -n "${BACKUP_TARGET:-}" &&
              -f "$BACKUP_TARGET" ]]
        then
            cp -a "$BACKUP_TARGET" "$TARGET_FILE"
        fi

        if [[ -n "${BACKUP_MAIN:-}" &&
              -f "$BACKUP_MAIN" ]]
        then
            cp -a "$BACKUP_MAIN" /etc/nginx/nginx.conf
        fi

        if [[ -n "${BACKUP_RANGES:-}" &&
              -f "$BACKUP_RANGES" ]]
        then
            cp -a "$BACKUP_RANGES" "$MOBILE_RANGES"
        fi

    fi

    if (( FILTER_CREATED == 1 )); then

        if [[ "$MODE" == "docker" ]]; then

            docker exec "$DOCKER_CONTAINER" \
                rm -f "$FILTER_FILE" \
                >/dev/null 2>&1 || true

        else

            rm -f "$FILTER_FILE" || true

        fi

    fi

    ok "Rollback завершён"
}

# ============================================================
# Helper scripts
# ============================================================

create_helpers() {

    header "СОЗДАНИЕ УПРАВЛЕНИЯ"

    cat > "$UPDATE_SCRIPT" <<'UPDATER'
#!/usr/bin/env bash
set -Eeuo pipefail

BASE="/etc/mobile-filter"

ASN_FILE="${BASE}/custom-asns.conf"
IP_FILE="${BASE}/custom-ips.conf"
STATE="${BASE}/installation.conf"

RANGES="/etc/nginx/mobile-ranges.conf"

ASN=(
    8359
    3216 16345 42842
    31133 47395 35298 31224 31213 31208 31205 31195 31163 25159
    12958 15378 42437 48092 48190 41330 39374
    201776 206673 35816
    205638 214257 202498
    203451 203561
    47204
    31499
    214721 204108
    59833 47203
)

TMP="$(mktemp)"
ASNS="$(mktemp)"
COUNT="$(mktemp)"

trap 'rm -f "$TMP" "$ASNS" "$COUNT"' EXIT

printf '%s\n' \
    "${ASN[@]}" \
    > "$ASNS"

while IFS= read -r A; do

    A="$(echo "$A" | tr -d '[:space:]')"

    [[ -z "$A" ]] && continue
    [[ "$A" =~ ^# ]] && continue

    A="${A#AS}"
    A="${A#as}"

    [[ "$A" =~ ^[0-9]+$ ]] &&
        echo "$A" >> "$ASNS"

done < "$ASN_FILE"

sort -nu "$ASNS" -o "$ASNS"

while IFS= read -r A; do

    echo -n "AS${A} ... "
    : > "$COUNT"

    if curl -fsS \
        --max-time 30 \
        "https://stat.ripe.net/data/announced-prefixes/data.json?resource=AS${A}" |
    python3 -c '
import json
import sys

try:
    data = json.load(sys.stdin)
    n = 0

    for item in data.get("data", {}).get("prefixes", []):

        p = item.get(
            "prefix",
            ""
        ).strip()

        if p and ":" not in p:

            print(
                p + " 1;"
            )

            n += 1

    print(
        n,
        file=sys.stderr
    )

except Exception:

    print(
        0,
        file=sys.stderr
    )
' 2>"$COUNT" >> "$TMP"
    then

        echo \
            "$(cat "$COUNT" 2>/dev/null || echo 0) prefixes"

    else

        echo "ERROR"

    fi

    sleep 0.12

done < "$ASNS"

while IFS= read -r IP; do

    IP="$(echo "$IP" | xargs 2>/dev/null || true)"

    [[ -z "$IP" ]] && continue
    [[ "$IP" =~ ^# ]] && continue

    echo \
        "${IP} 1;" \
        >> "$TMP"

done < "$IP_FILE"

sort -u "$TMP" -o "$TMP"

COUNT_FINAL="$(wc -l < "$TMP")"

if [[ "$COUNT_FINAL" -eq 0 ]]; then

    echo "ERROR: whitelist is empty."

    exit 1
fi

if [[ "${MODE:-native}" == "docker" ]]; then

    if ! docker ps \
        --format '{{.Names}}' |
        grep -Fxq "$DOCKER_CONTAINER"
    then

        echo \
            "ERROR: Docker container ${DOCKER_CONTAINER} is not running."

        exit 1
    fi

    docker exec -i "$DOCKER_CONTAINER" \
        sh -c \
        'cat > /etc/nginx/mobile-ranges.conf' \
        < "$TMP"

    docker exec "$DOCKER_CONTAINER" \
        nginx -t

    docker exec "$DOCKER_CONTAINER" \
        nginx -s reload

else

    install -m 0644 \
        "$TMP" \
        "$RANGES"

    nginx -t

    nginx -s reload

fi

echo
echo "Updated: ${COUNT_FINAL} IPv4 prefixes."
UPDATER

    chmod 755 "$UPDATE_SCRIPT"

    cat > "$MANAGER_SCRIPT" <<'MANAGER'
#!/usr/bin/env bash
set -Eeuo pipefail

BASE="/etc/mobile-filter"

A="${BASE}/custom-asns.conf"
I="${BASE}/custom-ips.conf"

U="/usr/local/bin/update-mobile-ranges.sh"

mkdir -p "$BASE"

touch "$A" "$I"

pause() {

    echo

    read -r -p \
        "Нажмите Enter..." _

}

valid_ip() {

    python3 - "$1" <<'PY'
import ipaddress
import sys

try:

    n = ipaddress.ip_network(
        sys.argv[1],
        strict=False
    )

    raise SystemExit(
        0 if n.version == 4 else 1
    )

except Exception:

    raise SystemExit(1)
PY

}

add_asn() {

    echo
    echo "Добавить ASN"
    echo

    read -r -p \
        "ASN через пробел: " values

    for x in $values; do

        x="${x#AS}"
        x="${x#as}"

        if [[ "$x" =~ ^[0-9]+$ ]]; then

            if grep -qx "$x" "$A"; then

                echo \
                    "AS${x} уже существует."

            else

                echo \
                    "$x" \
                    >> "$A"

                echo \
                    "Добавлен AS${x}"

            fi

        else

            echo \
                "Некорректный ASN: $x"

        fi

    done

    sort -nu \
        "$A" \
        -o "$A"

    echo
    echo \
        "После этого выберите «Обновить диапазоны»."

    pause
}

add_ip() {

    echo
    echo "Добавить IP/CIDR"
    echo

    read -r -p \
        "IP/CIDR через пробел: " values

    for x in $values; do

        if valid_ip "$x"; then

            if grep -qxF "$x" "$I"; then

                echo \
                    "$x уже существует."

            else

                echo \
                    "$x" \
                    >> "$I"

                echo \
                    "Добавлен $x"

            fi

        else

            echo \
                "Некорректный IPv4/CIDR: $x"

        fi

    done

    sort -u \
        "$I" \
        -o "$I"

    echo
    echo \
        "После этого выберите «Обновить диапазоны»."

    pause
}

remove_asn() {

    echo

    read -r -p \
        "ASN для удаления: " x

    x="${x#AS}"
    x="${x#as}"

    grep -vxF \
        "$x" \
        "$A" \
        > "${A}.tmp" \
        || true

    mv \
        "${A}.tmp" \
        "$A"

    echo \
        "AS${x} удалён."

    pause
}

remove_ip() {

    echo

    read -r -p \
        "IP/CIDR для удаления: " x

    grep -vxF \
        "$x" \
        "$I" \
        > "${I}.tmp" \
        || true

    mv \
        "${I}.tmp" \
        "$I"

    echo \
        "$x удалён."

    pause
}

show_data() {

    clear

    echo
    echo "============================================================"
    echo " CUSTOM ASN"
    echo "============================================================"

    cat "$A"

    echo
    echo "============================================================"
    echo " CUSTOM IP/CIDR"
    echo "============================================================"

    cat "$I"

    pause
}

update_ranges() {

    clear

    echo
    echo "Обновление диапазонов..."
    echo

    "$U"

    pause
}

while true; do

    clear

    echo
    echo "============================================================"
    echo " MOBILE FILTER MANAGER"
    echo "============================================================"
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
        "Выбор: " c

    case "$c" in

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
            echo \
                "Неверный выбор."

            sleep 1
            ;;

    esac

done
MANAGER

    chmod 755 "$MANAGER_SCRIPT"

    cat > "$CRON_FILE" <<EOF
0 2 * * * root ${UPDATE_SCRIPT} >> ${UPDATE_LOG} 2>&1
EOF

    chmod 644 "$CRON_FILE"

    ok "Updater: ${UPDATE_SCRIPT}"
    ok "Manager: ${MANAGER_SCRIPT}"
    ok "Cron: каждый день в 02:00"
}

# ============================================================
# Save installation state
# ============================================================

save_state() {

    cat > "$STATE_FILE" <<EOF
MODE="${MODE}"
DOCKER_CONTAINER="${DOCKER_CONTAINER}"
NGINX_CONFIG="${TARGET_FILE}"
FILTER_CONF="${FILTER_FILE}"
TARGET_SERVER="${TARGET_SERVER}"
TARGET_SERVER_DISPLAY="${TARGET_SERVER_DISPLAY}"
TARGET_LOCATION="${TARGET_LOCATION}"
IP_SOURCE="${IP_SOURCE}"
VERSION="${VERSION}"
INSTALLED_AT="$(date '+%Y-%m-%d %H:%M:%S')"
EOF

    chmod 600 "$STATE_FILE"
}

# ============================================================
# MAIN
# ============================================================

main() {

    banner

    check_root
    init_files

    select_mode
    install_dependencies
    check_docker

    select_target
    select_ip_source
    ask_custom

    backup_current

    create_filter_file
    ensure_filter_include
    generate_ranges
    patch_target

    header "ПРОВЕРКА NGINX"

    if ! nginx_test; then

        error \
            "nginx -t завершился ошибкой."

        rollback

        exit 1

    fi

    ok "nginx -t: OK"

    nginx_reload

    ok "Nginx перезагружен"

    create_helpers
    save_state

    echo
    echo -e "${GREEN}"
    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║                                                            ║"
    echo "║                  УСТАНОВКА ЗАВЕРШЕНА                      ║"
    echo "║                                                            ║"
    echo "╚════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"

    echo
    echo "  Режим:     ${MODE}"

    if [[ "$MODE" == "docker" ]]; then
        echo "  Container: ${DOCKER_CONTAINER}"
    fi

    echo "  Server:    ${TARGET_SERVER_DISPLAY:-_}"
    echo "  Location:  ${TARGET_LOCATION}"
    echo "  Config:    ${TARGET_FILE}"

    echo
    echo "  Управление:"
    echo "    mobile-filter"

    echo
    echo "  Проверка:"

    if [[ "$MODE" == "docker" ]]; then

        echo \
            "    docker exec -it ${DOCKER_CONTAINER} nginx -T"

        echo \
            "    docker exec ${DOCKER_CONTAINER} nginx -t"

    else

        echo \
            "    nginx -T"

        echo \
            "    nginx -t"

    fi

    echo
    echo -e "${GREEN}Готово.${NC}"
    echo
}

main "$@"
