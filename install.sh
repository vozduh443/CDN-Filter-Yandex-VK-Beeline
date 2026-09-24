#!/usr/bin/env bash
set -Eeuo pipefail

VERSION="7.3.0"

# ============================================================
# MOBILE CDN FILTER
# Universal installer for Nginx
#
# Modes:
#   1) Native Nginx
#   2) Nginx in Docker
#
# Usage:
#   bash install.sh              - установка
#   bash install.sh --uninstall  - удаление
#
# Caddy is not supported.
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
GRAY='\033[0;90m'
BOLD='\033[1m'
NC='\033[0m'

BASE_DIR="/etc/mobile-filter"
CUSTOM_ASNS="${BASE_DIR}/custom-asns.conf"
CUSTOM_IPS="${BASE_DIR}/custom-ips.conf"
BASE_ASNS="${BASE_DIR}/base-asns.conf"
STATE_FILE="${BASE_DIR}/installation.conf"
INSTALLER_COPY="${BASE_DIR}/installer.sh"

BACKUP_DIR="/var/backups/mobile-filter"

NGINX_MAIN="/etc/nginx/nginx.conf"
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
SCOPE=""
TARGETS=()
TARGET_SERVER_DISPLAY=""
TARGET_LOCATION=""
IP_SOURCE=""
REPLY_NUM=""

NGINX_DUMP_FILE=""
declare -A FILE_BACKUPS=()
BACKUP_MAIN=""
BACKUP_RANGES=""
BACKUP_FILTER=""
FILTER_CREATED=0
RANGES_CREATED=0
ROLLBACK_ARMED=0

ok()    { echo -e "  ${GREEN}✓${NC} $1"; }
warn()  { echo -e "  ${YELLOW}⚠${NC} $1"; }
error() { echo -e "  ${RED}✘${NC} $1"; }
info()  { echo -e "  ${CYAN}➜${NC} $1"; }

header() {
    echo
    echo -e "${BOLD}${CYAN}$1${NC}"
    echo -e "${GRAY}────────────────────────────────────────────────────────────${NC}"
}

die() {
    error "$1"
    rollback
    exit 1
}

cleanup() {
    if [[ -n "${NGINX_DUMP_FILE:-}" ]]; then
        rm -f "$NGINX_DUMP_FILE" 2>/dev/null || true
    fi
}

on_err() {
    error "Ошибка в строке $1: $2"
    if [[ "$BASH_SUBSHELL" -eq 0 ]]; then
        rollback
    fi
}

trap cleanup EXIT
trap 'on_err "$LINENO" "$BASH_COMMAND"' ERR

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

# ============================================================
# Python helpers (shared by parser and patcher, so that
# server/location numbering is always identical)
# ============================================================

read -r -d '' PY_COMMON <<'PY' || true
import re
import sys

def clean(s):
    return re.sub(r"#.*$", "", s)

def block_end(lines, start):
    depth = 0
    for j in range(start, len(lines)):
        c = clean(lines[j])
        depth += c.count("{") - c.count("}")
        if j > start and depth == 0:
            return j
    return None

def find_servers(lines):
    res = []
    i = 0
    while i < len(lines):
        c = clean(lines[i]).strip()
        if re.match(r"^server\s*\{", c):
            e = block_end(lines, i)
            if e is not None:
                res.append((i, e))
                i = e
        i += 1
    return res

def count_locations(block):
    return len(re.findall(r"(?m)^[ \t]*location[ \t]+[^{]+\{", block))

def proxy_locations(block):
    res = []
    for lm in re.finditer(r"(?m)^[ \t]*location[ \t]+([^{]+)\{", block):
        op = block.find("{", lm.start())
        depth = 0
        close = None
        for p in range(op, len(block)):
            ch = block[p]
            if ch == "{":
                depth += 1
            elif ch == "}":
                depth -= 1
                if depth == 0:
                    close = p + 1
                    break
        if close is None:
            continue
        loc = block[lm.start():close]
        m = re.search(r"(?m)^[ \t]*proxy_pass[ \t]+([^;]+);", loc)
        if m:
            res.append((lm.group(1).strip(), m.group(1).strip(), lm.start(), close))
    return res
PY

read -r -d '' PY_PARSE <<'PY' || true
path = sys.argv[1]

with open(path, encoding="utf-8", errors="replace") as f:
    lines = f.read().splitlines()

file_of = []
cur = ""
for l in lines:
    m = re.match(r"^# configuration file (.+):$", l)
    if m:
        cur = m.group(1).strip()
    file_of.append(cur)

def s(x):
    return x.replace("|", "/")

per_file = {}
snum = 0

for (a, b) in find_servers(lines):
    fname = file_of[a]
    per_file[fname] = per_file.get(fname, 0) + 1
    fidx = per_file[fname]

    block = "\n".join(lines[a:b + 1])

    # only http servers (stream servers have no location blocks)
    if count_locations(block) == 0:
        continue

    names = []
    listens = []
    for m in re.finditer(r"(?m)^[ \t]*server_name[ \t]+([^;]+);", block):
        names.extend(m.group(1).split())
    for m in re.finditer(r"(?m)^[ \t]*listen[ \t]+([^;]+);", block):
        listens.append(" ".join(m.group(1).split()))

    locs = proxy_locations(block)

    snum += 1
    print("SERVER|{}|{}|{}|{}|{}|{}".format(
        snum, s(fname), fidx, s(" ".join(names)), s(", ".join(listens)), len(locs)))

    for i, (h, p, _a, _b) in enumerate(locs, 1):
        print("LOCATION|{}|{}|{}|{}".format(snum, i, s(h), s(p)))
PY

read -r -d '' PY_PATCH <<'PY' || true
path = sys.argv[1]
mode = sys.argv[2]
sidx = int(sys.argv[3])
lidx = int(sys.argv[4]) if len(sys.argv) > 4 else 0

with open(path, encoding="utf-8", errors="surrogateescape", newline="") as f:
    text = f.read()

lines = text.split("\n")
offs = []
pos = 0
for l in lines:
    offs.append(pos)
    pos += len(l) + 1

servers = find_servers(lines)
if sidx < 1 or sidx > len(servers):
    print("NO_SERVER")
    sys.exit(0)

a, b = servers[sidx - 1]
ss = offs[a]
se = offs[b] + len(lines[b])
block = text[ss:se]

if mode == "server":
    if "# MOBILE-CDN-FILTER:server" in block:
        print("ALREADY")
        sys.exit(0)

    first_nl = block.find("\n")
    if first_nl == -1:
        print("BAD_SERVER")
        sys.exit(0)

    indent = "    "
    for l in block.split("\n")[1:]:
        if l.strip() and l.strip() != "}":
            ind = re.match(r"^([ \t]*)", l).group(1)
            if ind:
                indent = ind
            break

    inj = (
        indent + "# MOBILE-CDN-FILTER:server\n" +
        indent + "if ($mobile_cdn_filter_block) {\n" +
        indent + "    return 403;\n" +
        indent + "}\n\n"
    )

    new_block = block[:first_nl + 1] + inj + block[first_nl + 1:]

else:
    locs = proxy_locations(block)
    if lidx < 1 or lidx > len(locs):
        print("NO_LOCATION")
        sys.exit(0)

    _h, _p, ls, le = locs[lidx - 1]
    loc = block[ls:le]

    if "$mobile_cdn_filter_" in loc:
        print("ALREADY")
        sys.exit(0)

    m = re.search(r"(?m)^([ \t]*)proxy_pass\b", loc)
    indent = m.group(1) or "    "

    inj = (
        indent + "# MOBILE-CDN-FILTER:location\n" +
        indent + "if ($mobile_cdn_filter_block) {\n" +
        indent + "    return 403;\n" +
        indent + "}\n\n"
    )

    new_loc = loc[:m.start()] + inj + loc[m.start():]
    new_block = block[:ls] + new_loc + block[le:]

new_text = text[:ss] + new_block + text[se:]

with open(path, "w", encoding="utf-8", errors="surrogateescape", newline="") as f:
    f.write(new_text)

print("PATCHED")
PY

read -r -d '' PY_STRIP <<'PY' || true
import re
import sys

p = sys.argv[1]
with open(p, encoding="utf-8", errors="surrogateescape", newline="") as f:
    t = f.read()

n = re.sub(
    r"(?:[ \t]*# MOBILE-CDN-FILTER:(?:server|location)[ \t]*\r?\n)?"
    r"[ \t]*if[ \t]*\(\$mobile_cdn_filter_(?:allowed[ \t]*=[ \t]*0|block)\)[ \t]*\{[ \t]*\r?\n"
    r"[ \t]*return[ \t]+403;[ \t]*\r?\n"
    r"[ \t]*\}[ \t]*\r?\n(?:[ \t]*\r?\n)?",
    "",
    t,
)

if n != t:
    with open(p, "w", encoding="utf-8", errors="surrogateescape", newline="") as f:
        f.write(n)
    print("STRIPPED")
PY

# ============================================================
# Host / container abstraction
# ============================================================

c_exec() {
    if [[ "$MODE" == "docker" ]]; then
        docker exec "$DOCKER_CONTAINER" "$@"
    else
        "$@"
    fi
}

c_exec_i() {
    if [[ "$MODE" == "docker" ]]; then
        docker exec -i "$DOCKER_CONTAINER" "$@"
    else
        "$@"
    fi
}

# c_write <host_src> <target>  (writes through symlinks)
c_write() {
    c_exec_i sh -c 'cat > "$1"' sh "$2" < "$1"
}

# c_restore <backup> <target>  (both inside host/container)
c_restore() {
    c_exec sh -c 'cat "$1" > "$2"' sh "$1" "$2"
}

nginx_test() {
    c_exec nginx -t
}

nginx_reload() {
    if [[ "$MODE" == "native" ]] &&
       command -v systemctl >/dev/null 2>&1 &&
       systemctl is-active --quiet nginx 2>/dev/null
    then
        systemctl reload nginx
    elif ! c_exec nginx -s reload; then
        if [[ "$MODE" == "native" ]] && command -v systemctl >/dev/null 2>&1; then
            warn "nginx -s reload не сработал, пробуем systemctl restart nginx"
            systemctl restart nginx
        else
            return 1
        fi
    fi
}

ask_number() {
    local max="$1" prompt="$2" v

    if (( max == 1 )); then
        REPLY_NUM=1
        echo
        ok "Единственный вариант выбран автоматически."
        return 0
    fi

    while true; do
        read -r -p "  ${prompt} [1-${max}]: " v
        if [[ "$v" =~ ^[0-9]+$ ]] && (( v >= 1 && v <= max )); then
            REPLY_NUM="$v"
            return 0
        fi
        error "Неверный выбор."
    done
}

banner() {
    clear 2>/dev/null || true
    echo -e "${CYAN}"
    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║                    MOBILE CDN FILTER                       ║"
    echo "║                                                            ║"
    echo "║          Universal NGINX Mobile Network Filter             ║"
    echo "║                                                            ║"
    echo "║          VK • Yandex • Beeline • CDN Video                 ║"
    echo "║          Turboflare • Beget • Timeweb • Selectel           ║"
    echo "╚════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    echo -e "${GRAY}Version ${VERSION}${NC}"
}

check_root() {
    [[ "$EUID" -eq 0 ]] || die "Запустите установщик от root."
}

init_files() {
    mkdir -p "$BASE_DIR" "$BACKUP_DIR"
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
                read -r -p "  Имя контейнера [cdn-nginx]: " DOCKER_CONTAINER
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

    if [[ "$MODE" == "native" ]] && ! command -v nginx >/dev/null 2>&1; then
        missing+=(nginx)
    fi

    if [[ "$MODE" == "docker" ]] && ! command -v docker >/dev/null 2>&1; then
        missing+=(docker.io)
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

    docker info >/dev/null 2>&1 || die "Docker недоступен."

    docker ps --format '{{.Names}}' | grep -Fxq "$DOCKER_CONTAINER" ||
        die "Контейнер '${DOCKER_CONTAINER}' не запущен."

    ok "Контейнер найден: ${DOCKER_CONTAINER}"
}

# ============================================================
# Cleanup of leftovers from previous (failed) runs
# ============================================================

migrate_old_backups() {
    local moved

    moved="$(c_exec sh -c '
        mkdir -p "$1"
        for f in /etc/nginx/sites-enabled/*.mobile-filter-backup.* \
                 /etc/nginx/conf.d/*.mobile-filter-backup.*
        do
            [ -e "$f" ] || [ -L "$f" ] || continue
            mv "$f" "$1"/ && echo "$f"
        done
    ' sh "$BACKUP_DIR" 2>/dev/null || true)"

    if [[ -n "$moved" ]]; then
        warn "Старые бэкапы убраны из папок nginx в ${BACKUP_DIR}:"
        while IFS= read -r f; do
            echo "     $f"
        done <<< "$moved"
    fi
}

strip_all_injections() {
    local files f real tmp res seen=" "

    files="$( {
        c_exec grep -RlF 'mobile_cdn_filter_' /etc/nginx 2>/dev/null ||
        c_exec grep -rlF 'mobile_cdn_filter_' /etc/nginx 2>/dev/null ||
        true
    } )"

    while IFS= read -r f; do
        if [[ -z "$f" ]]; then
            continue
        fi

        real="$(c_exec readlink -f "$f" 2>/dev/null || echo "$f")"

        case "$real" in
            "$FILTER_FILE"|"$MOBILE_RANGES"|*.mobile-filter-backup.*|*/mobile-filter-debug.conf)
                continue
                ;;
        esac

        if [[ "$seen" == *" $real "* ]]; then
            continue
        fi
        seen+="$real "

        tmp="$(mktemp)"
        c_exec cat "$real" > "$tmp"

        res="$(python3 -c "$PY_STRIP" "$tmp")"

        if [[ "$res" == "STRIPPED" ]]; then
            c_exec mkdir -p "$BACKUP_DIR"
            c_exec cp -L "$real" \
                "${BACKUP_DIR}/$(basename "$real").before-clean.$(date +%Y%m%d-%H%M%S)"
            c_write "$tmp" "$real"
            ok "Удалена старая вставка фильтра: ${real}"
        fi

        rm -f "$tmp"
    done <<< "$files"
}

preflight_nginx() {
    header "ПРЕДВАРИТЕЛЬНАЯ ПРОВЕРКА NGINX"

    migrate_old_backups

    local out attempt

    for attempt in 1 2 3; do
        if out="$(c_exec nginx -t 2>&1)"; then
            ok "nginx -t: OK"
            return 0
        fi

        if grep -qF "mobile-filter.generated.conf" <<< "$out"; then
            warn "Удаляется битый filter от прошлой установки"
            c_exec rm -f "$FILTER_FILE"
            continue
        fi

        if grep -qE 'unknown "mobile_cdn_[a-z_]+" variable' <<< "$out"; then
            warn "Найдены остатки фильтра без объявления переменной"
            strip_all_injections
            continue
        fi

        if grep -qF "mobile-filter-backup" <<< "$out"; then
            continue
        fi

        break
    done

    echo "$out"
    die "Текущая конфигурация nginx не проходит nginx -t. Исправьте её и запустите установщик снова."
}

# ============================================================
# Server + location selection
# ============================================================

save_nginx_dump() {
    NGINX_DUMP_FILE="$(mktemp)"

    if ! c_exec nginx -T >"$NGINX_DUMP_FILE" 2>&1; then
        cat "$NGINX_DUMP_FILE"
        die "nginx -T завершился ошибкой."
    fi
}


select_scope() {
    header "ОБЛАСТЬ ФИЛЬТРАЦИИ"

    echo
    echo "  1) Весь server: все location (рекомендуется)"
    echo "  2) Только один location"
    echo

    local c

    while true; do
        read -r -p "  Выберите [1-2, по умолчанию 1]: " c
        c="${c:-1}"
        case "$c" in
            1) SCOPE="server"; break ;;
            2) SCOPE="location"; break ;;
            *) error "Введите 1 или 2." ;;
        esac
    done

    echo
    if [[ "$SCOPE" == "server" ]]; then
        ok "Весь server (все location)"
    else
        ok "Один location"
    fi
}

select_targets() {
    header "АНАЛИЗ ТЕКУЩЕЙ КОНФИГУРАЦИИ"

    save_nginx_dump

    local parsed
    parsed="$(python3 -c "${PY_COMMON}
${PY_PARSE}" "$NGINX_DUMP_FILE")" ||
        die "Не удалось разобрать вывод nginx -T."

    local -a S_NO=() S_FILE=() S_FIDX=() S_NAMES=() S_NPROXY=()
    local count=0 type a b c d e f

    while IFS='|' read -r type a b c d e f; do
        [[ "$type" == "SERVER" ]] || continue

        S_NO[count]="$a"
        S_FILE[count]="$b"
        S_FIDX[count]="$c"
        S_NAMES[count]="$d"
        S_NPROXY[count]="${f:-0}"

        echo
        echo -e "  ${WHITE}$((count + 1)))${NC} server_name: ${d:-_}"
        echo "     listen:      ${e:-_}"
        echo "     proxy_pass location: ${f:-0}"
        echo -e "     config:      ${GRAY}${b}${NC}"

        count=$((count + 1))
    done <<< "$parsed"

    (( count > 0 )) || die "Не найдено ни одного http server-блока с location."

    local -a sel=()
    local v i

    echo

    if [[ "$SCOPE" == "server" ]]; then
        if (( count == 1 )); then
            sel=(0)
            ok "Единственный server выбран автоматически."
        else
            while true; do
                read -r -p "  Выберите server [1-${count}, a = все]: " v
                if [[ "$v" =~ ^[Aa]$ ]]; then
                    for (( i = 0; i < count; i++ )); do
                        sel+=("$i")
                    done
                    break
                fi
                if [[ "$v" =~ ^[0-9]+$ ]] && (( v >= 1 && v <= count )); then
                    sel=("$((v - 1))")
                    break
                fi
                error "Неверный выбор."
            done
        fi
    else
        ask_number "$count" "Выберите server"
        sel=("$((REPLY_NUM - 1))")
    fi

    TARGETS=()
    TARGET_SERVER_DISPLAY=""

    local real
    echo

    for i in "${sel[@]}"; do
        [[ -n "${S_FILE[$i]}" ]] || die "Не удалось определить файл конфигурации."

        real="$(c_exec readlink -f "${S_FILE[$i]}")" ||
            die "Не удалось определить путь: ${S_FILE[$i]}"

        TARGETS+=("${real}|${S_FIDX[$i]}|0")
        TARGET_SERVER_DISPLAY+="${S_NAMES[$i]:-_} "

        ok "Server: ${S_NAMES[$i]:-_}  (${real})"
    done

    TARGET_SERVER_DISPLAY="${TARGET_SERVER_DISPLAY% }"

    [[ "$SCOPE" == "location" ]] || return 0

    i="${sel[0]}"
    local snum="${S_NO[$i]}"

    (( S_NPROXY[i] > 0 )) || die "В выбранном server нет location с proxy_pass."

    local -a L_NAMES=() L_PROXIES=()
    local lcount=0

    while IFS='|' read -r type a b c d e f; do
        [[ "$type" == "LOCATION" ]] || continue
        [[ "$a" == "$snum" ]] || continue

        L_NAMES[lcount]="$c"
        L_PROXIES[lcount]="$d"

        echo
        echo -e "  ${WHITE}$((lcount + 1)))${NC} location ${c}"
        echo "     proxy_pass: ${d}"

        lcount=$((lcount + 1))
    done <<< "$parsed"

    echo
    ask_number "$lcount" "Выберите location"

    TARGETS=("${real}|${S_FIDX[$i]}|${REPLY_NUM}")
    TARGET_LOCATION="${L_NAMES[$((REPLY_NUM - 1))]}"

    echo
    ok "Location: ${TARGET_LOCATION}"
    ok "Proxy:    ${L_PROXIES[$((REPLY_NUM - 1))]}"
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
    echo "  4) Автоматически (X-Forwarded-For → remote_addr)"
    echo

    local choice

    while true; do
        read -r -p "  Выберите [1-4, по умолчанию 4]: " choice
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
        x_real_ip) ok "X-Real-IP" ;;
        xff)       ok "Первый IP X-Forwarded-For" ;;
        remote)    ok "remote_addr" ;;
        auto)      ok "X-Forwarded-For → remote_addr" ;;
    esac

    if [[ "$IP_SOURCE" != "remote" ]]; then
        warn "Заголовки клиент может подделать. Закройте прямой доступ"
        warn "к серверу фаерволом и разрешите только адреса CDN."
    fi
}

# ============================================================
# User custom IP / ASN
# ============================================================

valid_ipv4_or_cidr() {
    python3 - "$1" <<'PY'
import ipaddress
import sys

try:
    net = ipaddress.ip_network(sys.argv[1], strict=False)
    raise SystemExit(0 if net.version == 4 else 1)
except ValueError:
    raise SystemExit(1)
PY
}

ask_custom() {
    header "СОБСТВЕННЫЕ IP И ASN"

    echo
    echo "  Можно добавить свои IP/CIDR и ASN."
    echo "  Они сохранятся и не удалятся при автообновлении."
    echo

    local answer values value asn

    read -r -p "  Добавить свои IP/CIDR? [y/N]: " answer

    if [[ "$answer" =~ ^[Yy]$ ]]; then
        read -r -p "  IP/CIDR через пробел: " values
        for value in $values; do
            if valid_ipv4_or_cidr "$value"; then
                echo "$value" >> "$CUSTOM_IPS"
                ok "Добавлен IP: $value"
            else
                warn "Некорректный IPv4/CIDR: $value"
            fi
        done
    fi

    echo
    read -r -p "  Добавить свои ASN? [y/N]: " answer

    if [[ "$answer" =~ ^[Yy]$ ]]; then
        read -r -p "  ASN через пробел: " values
        for asn in $values; do
            asn="${asn#AS}"
            asn="${asn#as}"
            if [[ "$asn" =~ ^[0-9]+$ ]]; then
                echo "$asn" >> "$CUSTOM_ASNS"
                ok "Добавлен AS${asn}"
            else
                warn "Некорректный ASN: $asn"
            fi
        done
    fi

    printf '%s\n' "${STATIC_IPS[@]}" >> "$CUSTOM_IPS"

    sort -u "$CUSTOM_IPS" -o "$CUSTOM_IPS"
    sort -nu "$CUSTOM_ASNS" -o "$CUSTOM_ASNS"
}

# ============================================================
# Backup (outside nginx include dirs!)
# ============================================================

backup_current() {
    header "BACKUP"

    local ts
    ts="$(date +%Y%m%d-%H%M%S)"

    c_exec mkdir -p "$BACKUP_DIR"

    local t f bk n=0

    for t in "${TARGETS[@]}"; do
        f="${t%%|*}"

        if [[ -n "${FILE_BACKUPS[$f]:-}" ]]; then
            continue
        fi

        n=$((n + 1))
        bk="${BACKUP_DIR}/$(basename "$f").${ts}.${n}"
        c_exec cp -L "$f" "$bk"
        FILE_BACKUPS[$f]="$bk"
    done

    if c_exec test -f "$MOBILE_RANGES"; then
        BACKUP_RANGES="${BACKUP_DIR}/mobile-ranges.conf.${ts}"
        c_exec cp -L "$MOBILE_RANGES" "$BACKUP_RANGES"
    else
        RANGES_CREATED=1
    fi

    if c_exec test -e "$FILTER_FILE"; then
        if ! c_exec grep -qF "$FILTER_MARKER" "$FILTER_FILE"; then
            die "Файл ${FILTER_FILE} уже существует и создан не этим скриптом."
        fi
        BACKUP_FILTER="${BACKUP_DIR}/mobile-filter.generated.conf.${ts}"
        c_exec cp -L "$FILTER_FILE" "$BACKUP_FILTER"
    else
        FILTER_CREATED=1
    fi

    ROLLBACK_ARMED=1

    ok "Backup: ${BACKUP_DIR}"
}

# ============================================================
# Updater script (also used by installer to build ranges)
# ============================================================

write_updater() {
    printf '%s\n' "${BASE_MOBILE_ASN[@]}" > "$BASE_ASNS"
    chmod 644 "$BASE_ASNS"

    cat > "$UPDATE_SCRIPT" <<'UPDATER'
#!/usr/bin/env bash
set -Eeuo pipefail

# Usage:
#   update-mobile-ranges.sh            - обновить диапазоны и перезагрузить nginx
#   update-mobile-ranges.sh --force    - то же, без защиты от резкого уменьшения списка
#   update-mobile-ranges.sh --build F  - только собрать список в файл F

BASE="/etc/mobile-filter"
BASE_ASNS="${BASE}/base-asns.conf"
ASN_FILE="${BASE}/custom-asns.conf"
IP_FILE="${BASE}/custom-ips.conf"
STATE="${BASE}/installation.conf"
RANGES="/etc/nginx/mobile-ranges.conf"
BACKUP_DIR="/var/backups/mobile-filter"
MIN_PERCENT=50

FORCE=0
FAILED=0

build() {
    local out="$1"
    local asns count A

    asns="$(mktemp)"
    count="$(mktemp)"

    : > "$out"

    { cat "$BASE_ASNS" "$ASN_FILE" 2>/dev/null || true; } |
        tr -d ' \t\r' |
        sed -e 's/^[Aa][Ss]//' |
        { grep -E '^[0-9]+$' || true; } |
        sort -nu > "$asns"

    echo "ASN в пуле: $(wc -l < "$asns")"
    echo

    while IFS= read -r A; do
        printf '  AS%s ... ' "$A"
        : > "$count"

        if curl -fsS --retry 3 --retry-delay 2 --max-time 30 \
            "https://stat.ripe.net/data/announced-prefixes/data.json?resource=AS${A}" |
           python3 -c '
import json
import sys

data = json.load(sys.stdin)
n = 0
for item in data.get("data", {}).get("prefixes", []):
    p = item.get("prefix", "").strip()
    if p and ":" not in p:
        print(p + " 1;")
        n += 1
print(n, file=sys.stderr)
' 2>"$count" >> "$out"
        then
            echo "$(cat "$count") prefixes"
        else
            echo "ERROR"
            FAILED=$((FAILED + 1))
        fi

        sleep 0.12
    done < "$asns"

    echo
    echo "Добавление static/custom IP..."

    if [[ -f "$IP_FILE" ]]; then
        { grep -Ev '^[[:space:]]*(#|$)' "$IP_FILE" || true; } |
            tr -d ' \t\r' |
            sed 's/$/ 1;/' >> "$out"
    fi

    sort -u "$out" -o "$out"
    rm -f "$asns" "$count"

    echo "Итого IPv4 prefixes: $(wc -l < "$out")"

    if (( FAILED > 0 )); then
        echo "ВНИМАНИЕ: не удалось получить ${FAILED} ASN."
    fi
}

case "${1:-}" in
    --build)
        [[ -n "${2:-}" ]] || { echo "Usage: $0 --build FILE"; exit 1; }
        build "$2"
        exit 0
        ;;
    --force)
        FORCE=1
        ;;
    "")
        ;;
    *)
        echo "Usage: $0 [--force | --build FILE]"
        exit 1
        ;;
esac

[[ -f "$STATE" ]] || { echo "ERROR: ${STATE} не найден."; exit 1; }

# shellcheck disable=SC1090
source "$STATE"

MODE="${MODE:-native}"
DOCKER_CONTAINER="${DOCKER_CONTAINER:-}"

c_exec() {
    if [[ "$MODE" == "docker" ]]; then
        docker exec "$DOCKER_CONTAINER" "$@"
    else
        "$@"
    fi
}

c_exec_i() {
    if [[ "$MODE" == "docker" ]]; then
        docker exec -i "$DOCKER_CONTAINER" "$@"
    else
        "$@"
    fi
}

nginx_reload() {
    if [[ "$MODE" == "native" ]] &&
       command -v systemctl >/dev/null 2>&1 &&
       systemctl is-active --quiet nginx 2>/dev/null
    then
        systemctl reload nginx
    else
        c_exec nginx -s reload
    fi
}

echo "=== $(date '+%Y-%m-%d %H:%M:%S') ==="

if [[ "$MODE" == "docker" ]]; then
    if ! docker ps --format '{{.Names}}' | grep -Fxq "$DOCKER_CONTAINER"; then
        echo "ERROR: Docker container ${DOCKER_CONTAINER} is not running."
        exit 1
    fi
fi

TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

build "$TMP"

NEW="$(wc -l < "$TMP")"
OLD="$( { c_exec cat "$RANGES" 2>/dev/null || true; } | wc -l )"

if (( NEW == 0 )); then
    echo "ERROR: whitelist is empty. Старый список оставлен."
    exit 1
fi

if (( FORCE == 0 && OLD > 0 && NEW * 100 < OLD * MIN_PERCENT )); then
    echo "ERROR: новый список (${NEW}) меньше ${MIN_PERCENT}% старого (${OLD})."
    echo "Вероятно, RIPE недоступен. Старый список оставлен."
    echo "Принудительно: $0 --force"
    exit 1
fi

PREV="${BACKUP_DIR}/mobile-ranges.conf.prev"
c_exec mkdir -p "$BACKUP_DIR"
c_exec sh -c '[ -f "$1" ] && cp "$1" "$2" || true' sh "$RANGES" "$PREV"

c_exec_i sh -c 'cat > "$1" && chmod 644 "$1"' sh "$RANGES" < "$TMP"

if ! c_exec nginx -t; then
    echo "ERROR: nginx -t failed, восстанавливаю прежний список."
    c_exec sh -c '[ -f "$1" ] && cat "$1" > "$2" || true' sh "$PREV" "$RANGES"
    exit 1
fi

nginx_reload

echo
echo "Updated: ${NEW} IPv4 prefixes (было ${OLD})."
UPDATER

    chmod 755 "$UPDATE_SCRIPT"
}

generate_ranges() {
    header "ОБНОВЛЕНИЕ MOBILE RANGES"

    local out total
    out="$(mktemp)"

    "$UPDATE_SCRIPT" --build "$out"

    total="$(wc -l < "$out")"
    (( total > 0 )) || die "Whitelist пуст."

    c_write "$out" "$MOBILE_RANGES"
    c_exec chmod 644 "$MOBILE_RANGES"

    rm -f "$out"

    ok "Mobile ranges установлены (${total})"
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
geo \$http_x_real_ip \$${FILTER_VAR} {
    default 0;
    include ${MOBILE_RANGES};
}
EOF
            ;;
        remote)
            cat > "$tmp" <<EOF
${FILTER_MARKER}
geo \$remote_addr \$${FILTER_VAR} {
    default 0;
    include ${MOBILE_RANGES};
}
EOF
            ;;
        xff|auto)
            cat > "$tmp" <<EOF
${FILTER_MARKER}
map \$http_x_forwarded_for \$mobile_cdn_client_ip {
    default \$remote_addr;
    "~^(?<mobile_cdn_first_ip>[^, ]+)" \$mobile_cdn_first_ip;
}

geo \$mobile_cdn_client_ip \$${FILTER_VAR} {
    default 0;
    include ${MOBILE_RANGES};
}
EOF
            ;;
    esac

    # ACME (Let's Encrypt HTTP-01) is never blocked
    cat >> "$tmp" <<'EOF'

map $uri $mobile_cdn_acme {
    default 0;
    "~^/\.well-known/acme-challenge/" 1;
}

map "$mobile_cdn_filter_allowed:$mobile_cdn_acme" $mobile_cdn_filter_block {
    default 0;
    "0:0" 1;
}
EOF

    c_exec mkdir -p "$(dirname "$FILTER_FILE")"
    c_write "$tmp" "$FILTER_FILE"
    c_exec chmod 644 "$FILTER_FILE"

    rm -f "$tmp"

    ok "Filter: ${FILTER_FILE}"
}

# ============================================================
# Include filter into http {}
# ============================================================

ensure_filter_include() {
    header "ПОДКЛЮЧЕНИЕ FILTER"

    local dump tmp res ts
    dump="$(mktemp)"

    if ! c_exec nginx -T >"$dump" 2>&1; then
        cat "$dump"
        rm -f "$dump"
        die "nginx -T завершился ошибкой после создания filter."
    fi

    if grep -qF "# configuration file ${FILTER_FILE}:" "$dump"; then
        rm -f "$dump"
        ok "Filter подключён (через conf.d)"
        return 0
    fi

    rm -f "$dump"

    tmp="$(mktemp)"
    c_exec cat "$NGINX_MAIN" > "$tmp"

    res="$(python3 - "$tmp" "$FILTER_FILE" <<'PY'
import re
import sys

path, include = sys.argv[1], sys.argv[2]

with open(path, encoding="utf-8", errors="surrogateescape") as f:
    text = f.read()

m = re.search(r"(?m)^[ \t]*http[ \t]*\{", text)
if not m:
    print("NO_HTTP")
    sys.exit(0)

pos = text.find("{", m.start())
text = text[:pos + 1] + "\n    include " + include + ";\n" + text[pos + 1:]

with open(path, "w", encoding="utf-8", errors="surrogateescape") as f:
    f.write(text)

print("ADDED")
PY
)"

    if [[ "$res" != "ADDED" ]]; then
        rm -f "$tmp"
        die "Не найден блок http {} в ${NGINX_MAIN}."
    fi

    ts="$(date +%Y%m%d-%H%M%S)"
    BACKUP_MAIN="${BACKUP_DIR}/nginx.conf.${ts}"
    c_exec cp -L "$NGINX_MAIN" "$BACKUP_MAIN"

    c_write "$tmp" "$NGINX_MAIN"
    rm -f "$tmp"

    ok "Include добавлен в ${NGINX_MAIN}"
}

# ============================================================
# Patch selected location
# ============================================================


patch_targets() {
    header "ВНЕДРЕНИЕ ФИЛЬТРА"

    local t f sidx lidx tmp result

    for t in "${TARGETS[@]}"; do
        IFS='|' read -r f sidx lidx <<< "$t"

        tmp="$(mktemp)"
        c_exec cat "$f" > "$tmp"

        result="$(python3 -c "${PY_COMMON}
${PY_PATCH}" "$tmp" "$SCOPE" "$sidx" "$lidx")"

        case "$result" in
            PATCHED)
                c_write "$tmp" "$f"
                rm -f "$tmp"
                ok "Фильтр внедрён: ${f} (server #${sidx} в файле)"
                ;;
            ALREADY)
                rm -f "$tmp"
                ok "Уже установлен: ${f} (server #${sidx} в файле)"
                ;;
            *)
                rm -f "$tmp"
                die "Не удалось внедрить фильтр в ${f} (${result:-нет ответа})."
                ;;
        esac
    done
}

# ============================================================
# Rollback
# ============================================================

rollback() {
    (( ROLLBACK_ARMED == 1 )) || return 0
    ROLLBACK_ARMED=0

    set +e

    warn "Выполняется rollback..."

    local f
    for f in "${!FILE_BACKUPS[@]}"; do
        c_restore "${FILE_BACKUPS[$f]}" "$f" >/dev/null 2>&1
    done

    if [[ -n "$BACKUP_MAIN" ]]; then
        c_restore "$BACKUP_MAIN" "$NGINX_MAIN" >/dev/null 2>&1
    fi

    if [[ -n "$BACKUP_RANGES" ]]; then
        c_restore "$BACKUP_RANGES" "$MOBILE_RANGES" >/dev/null 2>&1
    elif (( RANGES_CREATED == 1 )); then
        c_exec rm -f "$MOBILE_RANGES" >/dev/null 2>&1
    fi

    if [[ -n "$BACKUP_FILTER" ]]; then
        c_restore "$BACKUP_FILTER" "$FILTER_FILE" >/dev/null 2>&1
    elif (( FILTER_CREATED == 1 )); then
        c_exec rm -f "$FILTER_FILE" >/dev/null 2>&1
    fi

    if c_exec nginx -t >/dev/null 2>&1; then
        ok "Rollback завершён, nginx -t: OK"
    else
        error "После rollback nginx -t с ошибкой, проверьте конфиг вручную."
    fi

    set -e
}

# ============================================================
# Manager + cron
# ============================================================

create_manager_and_cron() {
    header "СОЗДАНИЕ УПРАВЛЕНИЯ"

    cat > "$MANAGER_SCRIPT" <<'MANAGER'
#!/usr/bin/env bash
set -Eeuo pipefail

BASE="/etc/mobile-filter"
A="${BASE}/custom-asns.conf"
I="${BASE}/custom-ips.conf"
U="/usr/local/bin/update-mobile-ranges.sh"
INSTALLER="${BASE}/installer.sh"

[[ "$EUID" -eq 0 ]] || { echo "Запустите от root."; exit 1; }

mkdir -p "$BASE"
touch "$A" "$I"

pause() {
    echo
    read -r -p "Нажмите Enter..." _
}

valid_ip() {
    python3 - "$1" <<'PY'
import ipaddress
import sys

try:
    n = ipaddress.ip_network(sys.argv[1], strict=False)
    raise SystemExit(0 if n.version == 4 else 1)
except ValueError:
    raise SystemExit(1)
PY
}

add_asn() {
    echo
    read -r -p "ASN через пробел: " values
    for x in $values; do
        x="${x#AS}"
        x="${x#as}"
        if [[ "$x" =~ ^[0-9]+$ ]]; then
            if grep -qx "$x" "$A"; then
                echo "AS${x} уже существует."
            else
                echo "$x" >> "$A"
                echo "Добавлен AS${x}"
            fi
        else
            echo "Некорректный ASN: $x"
        fi
    done
    sort -nu "$A" -o "$A"
    echo
    echo "После этого выберите «Обновить диапазоны»."
    pause
}

add_ip() {
    echo
    read -r -p "IP/CIDR через пробел: " values
    for x in $values; do
        if valid_ip "$x"; then
            if grep -qxF "$x" "$I"; then
                echo "$x уже существует."
            else
                echo "$x" >> "$I"
                echo "Добавлен $x"
            fi
        else
            echo "Некорректный IPv4/CIDR: $x"
        fi
    done
    sort -u "$I" -o "$I"
    echo
    echo "После этого выберите «Обновить диапазоны»."
    pause
}

remove_asn() {
    echo
    read -r -p "ASN для удаления: " x
    x="${x#AS}"
    x="${x#as}"
    if grep -qxF "$x" "$A"; then
        grep -vxF "$x" "$A" > "${A}.tmp" || true
        mv "${A}.tmp" "$A"
        echo "AS${x} удалён."
    else
        echo "AS${x} нет в custom-списке (встроенные ASN так не удаляются)."
    fi
    pause
}

remove_ip() {
    echo
    read -r -p "IP/CIDR для удаления: " x
    if grep -qxF "$x" "$I"; then
        grep -vxF "$x" "$I" > "${I}.tmp" || true
        mv "${I}.tmp" "$I"
        echo "$x удалён."
    else
        echo "$x не найден."
    fi
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
    "$U" || echo "Обновление завершилось с ошибкой."
    pause
}

uninstall() {
    if [[ -f "$INSTALLER" ]]; then
        bash "$INSTALLER" --uninstall
        exit 0
    fi
    echo "Копия установщика не найдена: $INSTALLER"
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
    echo "  7) Удалить фильтр полностью"
    echo "  0) Выход"
    echo

    read -r -p "Выбор: " c

    case "$c" in
        1) add_asn ;;
        2) add_ip ;;
        3) remove_asn ;;
        4) remove_ip ;;
        5) show_data ;;
        6) update_ranges ;;
        7) uninstall ;;
        0) exit 0 ;;
        *) echo "Неверный выбор."; sleep 1 ;;
    esac
done
MANAGER

    chmod 755 "$MANAGER_SCRIPT"

    cat > "$CRON_FILE" <<EOF
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
0 2 * * * root ${UPDATE_SCRIPT} >> ${UPDATE_LOG} 2>&1
EOF

    chmod 644 "$CRON_FILE"

    local self="${BASH_SOURCE[0]:-}"
    if [[ -f "$self" ]] &&
       [[ "$(readlink -f "$self")" != "$(readlink -f "$INSTALLER_COPY" 2>/dev/null || true)" ]]
    then
        cp "$self" "$INSTALLER_COPY"
        chmod 700 "$INSTALLER_COPY"
    fi

    ok "Updater: ${UPDATE_SCRIPT}"
    ok "Manager: ${MANAGER_SCRIPT}"
    ok "Cron: каждый день в 02:00 (лог: ${UPDATE_LOG})"
}

# ============================================================
# Save installation state
# ============================================================

save_state() {
    {
        printf 'MODE=%q\n'                  "$MODE"
        printf 'DOCKER_CONTAINER=%q\n'      "$DOCKER_CONTAINER"
        printf 'SCOPE=%q\n'                 "$SCOPE"
        printf 'TARGETS=%q\n'               "$(IFS=';'; echo "${TARGETS[*]}")"
        printf 'FILTER_CONF=%q\n'           "$FILTER_FILE"
        printf 'TARGET_SERVER_DISPLAY=%q\n' "$TARGET_SERVER_DISPLAY"
        printf 'TARGET_LOCATION=%q\n'       "$TARGET_LOCATION"
        printf 'IP_SOURCE=%q\n'             "$IP_SOURCE"
        printf 'INSTALLED_VERSION=%q\n'     "$VERSION"
        printf 'INSTALLED_AT=%q\n'          "$(date '+%Y-%m-%d %H:%M:%S')"
    } > "$STATE_FILE"

    chmod 600 "$STATE_FILE"
}

# ============================================================
# Uninstall
# ============================================================

uninstall() {
    banner
    check_root

    [[ -f "$STATE_FILE" ]] || die "Установка не найдена (${STATE_FILE})."

    # shellcheck disable=SC1090
    source "$STATE_FILE"
    MODE="${MODE:-native}"

    check_docker

    header "УДАЛЕНИЕ MOBILE CDN FILTER"

    local answer tmp res
    read -r -p "  Удалить фильтр из nginx? [y/N]: " answer
    if [[ ! "$answer" =~ ^[Yy]$ ]]; then
        info "Отменено."
        exit 0
    fi

    strip_all_injections

    c_exec rm -f "$FILTER_FILE" "$MOBILE_RANGES"
    ok "Filter и mobile ranges удалены"

    tmp="$(mktemp)"
    c_exec cat "$NGINX_MAIN" > "$tmp"

    res="$(python3 - "$tmp" "$FILTER_FILE" <<'PY'
import re
import sys

path, include = sys.argv[1], sys.argv[2]

with open(path, encoding="utf-8", errors="surrogateescape") as f:
    t = f.read()

n = re.sub(r"(?m)^[ \t]*include[ \t]+" + re.escape(include) + r"[ \t]*;[ \t]*\n", "", t)

if n != t:
    with open(path, "w", encoding="utf-8", errors="surrogateescape") as f:
        f.write(n)
    print("REMOVED")
PY
)"

    if [[ "$res" == "REMOVED" ]]; then
        c_exec mkdir -p "$BACKUP_DIR"
        c_exec cp -L "$NGINX_MAIN" "${BACKUP_DIR}/nginx.conf.before-uninstall.$(date +%Y%m%d-%H%M%S)"
        c_write "$tmp" "$NGINX_MAIN"
        ok "Include удалён из ${NGINX_MAIN}"
    fi
    rm -f "$tmp"

    if nginx_test; then
        nginx_reload
        ok "Nginx перезагружен"
    else
        error "nginx -t с ошибкой после удаления, проверьте конфиг вручную."
    fi

    rm -f "$UPDATE_SCRIPT" "$MANAGER_SCRIPT" "$CRON_FILE" \
          "$STATE_FILE" "$BASE_ASNS" "$INSTALLER_COPY"

    echo
    ok "Удаление завершено."
    info "Свои списки сохранены в ${BASE_DIR}, бэкапы в ${BACKUP_DIR}."
    echo
}

# ============================================================
# MAIN
# ============================================================

main() {
    case "${1:-}" in
        --uninstall)
            uninstall
            exit 0
            ;;
        -h|--help)
            echo "Usage: $0 [--uninstall]"
            exit 0
            ;;
        "")
            ;;
        *)
            echo "Неизвестный параметр: $1"
            echo "Usage: $0 [--uninstall]"
            exit 1
            ;;
    esac

    banner

    check_root
    init_files

    select_mode
    install_dependencies
    check_docker

    preflight_nginx

    select_scope
    select_targets
    select_ip_source
    ask_custom

    backup_current

    write_updater
    generate_ranges
    create_filter_file
    ensure_filter_include
    patch_targets

    header "ПРОВЕРКА NGINX"

    if ! nginx_test; then
        die "nginx -t завершился ошибкой."
    fi

    ok "nginx -t: OK"

    nginx_reload || die "Не удалось перезагрузить nginx."

    ROLLBACK_ARMED=0

    ok "Nginx перезагружен"

    create_manager_and_cron
    save_state

    echo
    echo -e "${GREEN}"
    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║                   УСТАНОВКА ЗАВЕРШЕНА                      ║"
    echo "╚════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"

    echo "  Режим:     ${MODE}"
    if [[ "$MODE" == "docker" ]]; then
        echo "  Container: ${DOCKER_CONTAINER}"
    fi
    echo "  Server:    ${TARGET_SERVER_DISPLAY:-_}"
    if [[ "$SCOPE" == "server" ]]; then
        echo "  Область:   весь server (все location)"
    else
        echo "  Location:  ${TARGET_LOCATION}"
    fi
    echo "  Config:    $(printf '%s\n' "${TARGETS[@]}" | cut -d'|' -f1 | sort -u | tr '\n' ' ')"
    echo "  Backups:   ${BACKUP_DIR}"

    echo
    echo "  Управление:  mobile-filter"
    echo "  Обновление:  update-mobile-ranges.sh"
    echo "  Удаление:    mobile-filter → 7"

    echo
    echo -e "${GREEN}Готово.${NC}"
    echo
}

main "$@"
