# 🛡️ Mobile-Only VPN Access

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Shell Script](https://img.shields.io/badge/Shell-Bash-89E051?logo=gnu-bash&logoColor=white)](#)
[![Platform](https://img.shields.io/badge/Platform-Ubuntu%20%7C%20Debian-orange?logo=ubuntu&logoColor=white)](#)

**Универсальный интерактивный установщик для Nginx, который ограничивает доступ к VPN / proxy-ноду только IP-адресами мобильных операторов.**

Скрипт автоматически получает актуальные IPv4-префиксы мобильных ASN, создаёт whitelist, анализирует существующую конфигурацию Nginx и внедряет фильтр непосредственно в подходящий `server` / `location`.

Работает как с **обычным Nginx на сервере**, так и с **Nginx внутри Docker-контейнера**.

> **Caddy больше не поддерживается.** Проект ориентирован исключительно на Nginx.

---

## ✨ Что нового

### 🚀 Универсальный Nginx-инсталлер

Теперь не требуется заранее знать, где именно находится конфигурация Nginx.

Скрипт не предполагает наличие конкретного файла вроде:

```text
/etc/nginx/sites-enabled/default
```

или:

```text
/etc/nginx/conf.d/default.conf
```

Вместо этого он анализирует фактически загруженную конфигурацию через:

```bash
nginx -T
```

и самостоятельно находит:

- `server { ... }`
- `server_name`
- `listen`
- `location`
- `proxy_pass`

После этого интерактивный мастер предлагает выбрать нужный `server` и `location`.

---

### 🐳 Поддержка Nginx в Docker

При установке можно выбрать:

```text
1) Обычный Nginx
2) Nginx в Docker
```

Для Docker можно указать имя контейнера, например:

```text
cdn-nginx
```

Скрипт работает непосредственно с Nginx внутри контейнера:

```bash
docker exec cdn-nginx nginx -T
```

Конфигурация анализируется и изменяется внутри контейнера, а после изменения выполняется:

```bash
docker exec cdn-nginx nginx -t
```

и только после успешной проверки:

```bash
docker exec cdn-nginx nginx -s reload
```

---

## 🌐 Поддерживаемые CDN

Фильтр **не привязан к конкретному CDN**.

Он подходит для любой инфраструктуры, где входящий HTTP/HTTPS-трафик в конечном итоге обрабатывается Nginx.

В частности:

- **VK Cloud**
- **Yandex Cloud**
- **Beeline Cloud**
- **CDN Video**
- **Turboflare**
- **Beget**
- **Timeweb**
- **Selectel**
- собственные CDN / reverse proxy
- VPS с Nginx
- Nginx внутри Docker

То есть проект не пытается определить, какой именно CDN используется.

Ему достаточно существующего Nginx-конфига.

---

# ⚡ Быстрая установка

Установщик интерактивный, поэтому сначала скачайте файл:

```bash
curl -sSL https://raw.githubusercontent.com/pwdrs/Yandex-CDN-only-on-Mobile-Whitelist-Bypass/main/install.sh -o install.sh
```

Затем запустите:

```bash
sudo bash install.sh
```

или от `root`:

```bash
bash install.sh
```

### ⚠️ Почему не стоит использовать `curl | bash`

Не рекомендуется:

```bash
curl -sSL https://.../install.sh | sudo bash
```

Установщик задаёт интерактивные вопросы через `read`, поэтому ему необходим нормальный `stdin` терминала.

Используйте схему:

```bash
curl -sSL https://.../install.sh -o install.sh
sudo bash install.sh
```

---

# 🧙 Интерактивный мастер

При запуске установщик последовательно определяет конфигурацию.

## 1. Выбор режима Nginx

```text
╔════════════════════════════════════════════════════════════╗
║                 MOBILE CDN FILTER                         ║
╚════════════════════════════════════════════════════════════╝

РЕЖИМ NGINX

  1) Обычный Nginx
     Nginx установлен непосредственно на сервере

  2) Nginx в Docker
     Nginx работает внутри Docker-контейнера

Выберите [1-2]:
```

---

## 2. Docker-контейнер

Если выбран Docker:

```text
Имя контейнера [cdn-nginx]:
```

Например:

```text
cdn-nginx
```

Установщик проверит, что контейнер существует и запущен.

---

# 🔎 Автоматический анализ Nginx

После выбора режима скрипт анализирует текущую конфигурацию.

Он не требует заранее известной структуры файлов.

Например, если Nginx содержит:

```nginx
server {
    listen 443 ssl;
    server_name cdn.example.com;

    location / {
        proxy_pass http://127.0.0.1:8003;
    }
}
```

скрипт обнаружит этот блок автоматически.

Если конфигурация содержит несколько сайтов:

```text
Найденные server-блоки:

  1)
     server_name: site.example.com
     listen:      443 ssl
     config:      /etc/nginx/sites-enabled/site.example.com

  2)
     server_name: cdn.example.com
     listen:      443 ssl
     config:      /etc/nginx/conf.d/cdn.conf
```

можно выбрать необходимый `server`.

---

# 📍 Выбор proxy location

После выбора `server` скрипт ищет `location`, в которых присутствует:

```nginx
proxy_pass
```

Например:

```text
ВЫБОР LOCATION

  1)
     location: /
     proxy:    http://127.0.0.1:8003

  2)
     location: /api/
     proxy:    http://127.0.0.1:9000
```

Фильтр устанавливается только в выбранный `location`.

---

# 🧩 Что именно изменяется

Допустим, исходный конфиг:

```nginx
location / {
    proxy_pass http://127.0.0.1:8003;
}
```

После установки фильтра он получает проверку перед существующим `proxy_pass`:

```nginx
location / {

    if ($mobile_filter_allowed = 0) {
        return 403;
    }

    proxy_pass http://127.0.0.1:8003;
}
```

Существующий `proxy_pass` и остальные параметры location не переписываются.

---

# 📱 Как работает whitelist

Фильтр использует Nginx `geo`.

Принцип:

```text
IP клиента
    │
    ▼
определение IP
    │
    ▼
mobile-ranges.conf
    │
    ├── мобильная сеть → ALLOW
    │
    └── неизвестная сеть → DENY
```

Для разрешённых сетей переменная:

```text
$mobile_filter_allowed = 1
```

Для остальных:

```text
$mobile_filter_allowed = 0
```

После чего Nginx возвращает:

```http
403 Forbidden
```

---

# 📡 Источник IP клиента

Установщик позволяет выбрать, откуда брать IP.

Доступны:

```text
1) X-Real-IP
2) Первый IP из X-Forwarded-For
3) remote_addr
4) Автоматически
```

Это позволяет использовать фильтр с разными CDN и reverse proxy-схемами.

Например, если CDN передаёт:

```http
X-Real-IP: 178.156.181.172
```

фильтр проверяет именно этот адрес.

---

# 🏢 Поддерживаемые мобильные ASN

В базовый whitelist включены сети мобильных операторов, в том числе:

### MTS

```text
AS8359
```

### Beeline / VimpelCom

```text
AS3216
AS16345
AS42842
```

### MegaFon

```text
AS31133
AS47395
AS35298
AS31224
AS31213
AS31208
AS31205
AS31195
AS31163
AS25159
```

### T2

```text
AS12958
AS15378
AS42437
AS48092
AS48190
AS41330
AS39374
```

Также включены:

- Miranda
- Sberbank-Telecom
- Sevastar
- T-Mobile / Alfa-Mobile
- Volna-Mobile
- MCS
- MOTIV
- Phoenix
- Sevtelecom

Полный список находится непосредственно в `install.sh`.

---

# 🏠 Ростелеком

`AS12389` специально не используется как полный whitelist ASN.

Причина — ASN Ростелекома содержит слишком широкий набор сетей, включая проводной broadband.

Вместо этого используются точечные IPv4/CIDR-сети Ростелекома.

Это позволяет добавить необходимые диапазоны, не разрешая весь ASN целиком.

---

# ➕ Свои IP и ASN

Во время установки скрипт спрашивает:

```text
Добавить свои IP/CIDR сейчас? [y/N]:
```

Например:

```text
178.176.128.128
```

или:

```text
178.176.128.0/24
```

Также можно добавить собственный ASN:

```text
Добавить свои ASN сейчас? [y/N]:
```

Например:

```text
12345
```

или:

```text
AS12345
```

---

# 🛠️ Управление после установки

После установки появляется отдельная команда:

```bash
mobile-filter
```

Запуск:

```bash
mobile-filter
```

Откроется меню:

```text
╔════════════════════════════════════════════════════════════╗
║              MOBILE FILTER MANAGER                        ║
╚════════════════════════════════════════════════════════════╝

  1) Добавить ASN
  2) Добавить IP/CIDR
  3) Удалить ASN
  4) Удалить IP/CIDR
  5) Показать custom список
  6) Обновить диапазоны
  0) Выход

Выбор:
```

---

## 1️⃣ Добавить ASN

```bash
mobile-filter
```

→ `1`

Можно добавить:

```text
12345
```

или несколько сразу:

```text
12345 67890 11111
```

---

## 2️⃣ Добавить IP / CIDR

```bash
mobile-filter
```

→ `2`

Например:

```text
46.32.86.71
```

или:

```text
46.32.86.0/24
```

Можно добавить несколько:

```text
46.32.86.71 178.176.128.128 10.10.10.0/24
```

---

## 3️⃣ Удалить ASN

```bash
mobile-filter
```

→ `3`

Например:

```text
12345
```

Удаляется только пользовательский ASN.

---

## 4️⃣ Удалить IP

```bash
mobile-filter
```

→ `4`

Например:

```text
46.32.86.71
```

---

## 5️⃣ Посмотреть пользовательский whitelist

```bash
mobile-filter
```

→ `5`

Будут показаны:

```text
ASN:
------------------------------------------------------------
12345
67890

IP/CIDR:
------------------------------------------------------------
46.32.86.71
178.176.128.128
```

---

# 🔄 Обновление мобильных диапазонов

После добавления ASN:

```bash
mobile-filter
```

→ `6`

Скрипт заново получает актуальные IPv4-префиксы ASN и создаёт:

```text
/etc/nginx/mobile-ranges.conf
```

Для Docker этот файл загружается непосредственно внутрь контейнера.

После обновления выполняются:

```bash
nginx -t
```

и при успешной проверке:

```bash
nginx reload
```

---

# 🤖 Автоматическое обновление

После установки создаётся:

```text
/etc/cron.d/mobile-filter
```

По умолчанию диапазоны обновляются:

```text
каждый день в 02:00
```

Лог обновления:

```text
/var/log/mobile-filter-update.log
```

Таким образом, не требуется вручную следить за изменениями мобильных сетей.

---

# 📁 Файлы проекта после установки

Основная директория:

```text
/etc/mobile-filter/
```

В ней находятся:

```text
/etc/mobile-filter/
├── custom-asns.conf
├── custom-ips.conf
└── installation.conf
```

### `custom-asns.conf`

Пользовательские ASN:

```text
12345
67890
```

### `custom-ips.conf`

Пользовательские IP/CIDR:

```text
46.32.86.71
178.176.128.128
```

### `installation.conf`

Параметры текущей установки:

- режим Nginx
- Docker container
- выбранный config
- server
- location
- источник IP

---

# 🌐 Файлы Nginx

Основная база диапазонов:

```text
/etc/nginx/mobile-ranges.conf
```

Конфигурация переменной фильтра:

```text
/etc/nginx/conf.d/mobile-filter.conf
```

Для Docker эти файлы находятся внутри контейнера:

```text
/etc/nginx/mobile-ranges.conf
/etc/nginx/conf.d/mobile-filter.conf
```

---

# 💾 Backup

Перед изменением существующего Nginx-конфига создаётся резервная копия.

Например:

```text
/etc/nginx/sites-enabled/default.mobile-filter-backup.20260828-173000
```

Для Docker backup создаётся внутри контейнера рядом с исходным конфигом.

Это позволяет вернуть конфигурацию вручную, если потребуется.

---

# 🔍 Полезные команды

## Посмотреть полный загруженный конфиг

Обычный Nginx:

```bash
nginx -T
```

Docker:

```bash
docker exec -it cdn-nginx nginx -T
```

---

## Посмотреть конкретный конфиг

Обычный Nginx:

```bash
cat /etc/nginx/sites-enabled/default
```

Docker:

```bash
docker exec -it cdn-nginx cat /etc/nginx/conf.d/default.conf
```

---

## Проверить конфигурацию

Обычный Nginx:

```bash
nginx -t
```

Docker:

```bash
docker exec cdn-nginx nginx -t
```

---

## Перезагрузить Nginx

Обычный:

```bash
nginx -s reload
```

Docker:

```bash
docker exec cdn-nginx nginx -s reload
```

---

## Посмотреть whitelist

Обычный Nginx:

```bash
cat /etc/nginx/mobile-ranges.conf
```

Docker:

```bash
docker exec -it cdn-nginx cat /etc/nginx/mobile-ranges.conf
```

---

## Посмотреть свои IP

```bash
cat /etc/mobile-filter/custom-ips.conf
```

---

## Посмотреть свои ASN

```bash
cat /etc/mobile-filter/custom-asns.conf
```

---

## Открыть менеджер

```bash
mobile-filter
```

---

# 🧪 Проверка работы

После установки рекомендуется проверить запрос с разрешённого мобильного IP и с IP, который не входит в whitelist.

Ожидаемое поведение:

### Мобильная сеть

```text
HTTP 200 / нормальный ответ upstream
```

### Проводной интернет / неизвестная сеть

```text
HTTP 403 Forbidden
```

---

# ⚠️ Важный момент про CDN

Фильтр проверяет **тот IP, который Nginx получает от выбранного источника**.

Например:

```text
Клиент
   │
   │ 178.156.181.172
   ▼
CDN
   │
   │ X-Real-IP: 178.156.181.172
   ▼
Nginx
   │
   ▼
Mobile Filter
```

Поэтому необходимо правильно выбрать источник:

```text
X-Real-IP
```

или:

```text
X-Forwarded-For
```

Если CDN не передаёт реальный IP клиента, фильтр не сможет корректно определить мобильную сеть.

---

# 🔒 Прямой доступ к origin

Если origin доступен напрямую из интернета, пользователь потенциально может обойти CDN.

Поэтому наиболее правильная схема:

```text
                 ┌──────────────┐
                 │    Client    │
                 └──────┬───────┘
                        │
                        ▼
                 ┌──────────────┐
                 │     CDN      │
                 └──────┬───────┘
                        │
                  X-Real-IP
                        │
                        ▼
              ┌──────────────────┐
              │      Nginx       │
              │                  │
              │ Mobile Filter    │
              └────────┬─────────┘
                       │
                  allowed
                       │
                       ▼
              ┌──────────────────┐
              │ VPN / Xray /     │
              │ Proxy / Backend  │
              └──────────────────┘
```

Для дополнительной защиты рекомендуется ограничивать прямой доступ к origin firewall-правилами, если используемая инфраструктура это позволяет.

---

# ❌ Caddy

**Caddy больше не поддерживается.**

Проект рассчитан на:

```text
NGINX
```

в двух вариантах:

```text
Native Nginx
```

или:

```text
Nginx in Docker
```

---

# 🐳 Docker

Для Docker не требуется менять архитектуру контейнера.

Если контейнер называется:

```text
cdn-nginx
```

установщик работает с ним напрямую:

```bash
docker exec cdn-nginx nginx -T
```

```bash
docker exec cdn-nginx nginx -t
```

```bash
docker exec cdn-nginx nginx -s reload
```

---

# 🆘 Если что-то пошло не так

Первым делом проверить конфигурацию:

```bash
nginx -t
```

или:

```bash
docker exec cdn-nginx nginx -t
```

Затем посмотреть полный конфиг:

```bash
nginx -T
```

или:

```bash
docker exec -it cdn-nginx nginx -T
```

Проверить установленные диапазоны:

```bash
cat /etc/nginx/mobile-ranges.conf
```

или для Docker:

```bash
docker exec -it cdn-nginx cat /etc/nginx/mobile-ranges.conf
```

Посмотреть лог автоматического обновления:

```bash
tail -f /var/log/mobile-filter-update.log
```

---

# 🔙 Восстановление backup

Установщик сохраняет оригинальный конфиг перед изменением.

Backup имеет формат:

```text
<original-config>.mobile-filter-backup.<date>
```

При необходимости можно восстановить исходный файл вручную, затем проверить:

```bash
nginx -t
```

и выполнить reload:

```bash
nginx -s reload
```

---

# 📋 Требования

### ОС

Поддерживаются:

- Ubuntu 20.04+
- Debian 11+

### Для Native Nginx

Необходимо:

- Nginx
- Python 3
- curl
- root-доступ

Недостающие зависимости установщик устанавливает автоматически, если доступен `apt`.

### Для Docker

Необходимо:

- Docker
- работающий контейнер с Nginx
- Python 3
- curl
- root-доступ

---

# 🧠 Принцип проекта

Проект специально не привязан к конкретному CDN.

Вместо:

```text
если Yandex → использовать этот конфиг
если Beeline → использовать другой конфиг
если VK → использовать третий конфиг
```

используется универсальный подход:

```text
                  NGINX
                    │
                    ▼
              nginx -T
                    │
                    ▼
          анализ server/location
                    │
                    ▼
          выбор proxy location
                    │
                    ▼
             Mobile Filter
                    │
             ┌──────┴──────┐
             │             │
          MOBILE        OTHER
             │             │
             ▼             ▼
          ALLOW           403
```

Поэтому структура конкретного `sites-enabled`, `sites-available` или `conf.d` не имеет принципиального значения.

---

# 📌 Поддерживаемая архитектура

Проект подходит для:

```text
Client
  ↓
CDN
  ↓
Nginx
  ↓
Xray / V2Ray / VPN / Proxy / Backend
```

а также:

```text
Client
  ↓
CDN
  ↓
Docker
  ↓
Nginx
  ↓
Xray / V2Ray / VPN / Proxy / Backend
```

---

# 📜 License

MIT License

См. файл:

```text
LICENSE
```

---

# ⭐ Возможности

| Возможность | Поддержка |
|---|---:|
| Nginx | ✅ |
| Nginx Docker | ✅ |
| Caddy | ❌ |
| Автоопределение конфигурации | ✅ |
| `nginx -T` анализ | ✅ |
| Автоматический поиск `server` | ✅ |
| Автоматический поиск `location` | ✅ |
| Поиск `proxy_pass` | ✅ |
| Выбор IP source | ✅ |
| Mobile ASN whitelist | ✅ |
| Статические CIDR | ✅ |
| Свои IP | ✅ |
| Свои ASN | ✅ |
| Удаление своих IP | ✅ |
| Удаление своих ASN | ✅ |
| Автообновление ASN | ✅ |
| Cron | ✅ |
| Backup конфигурации | ✅ |
| Проверка `nginx -t` | ✅ |
| Автоматический reload | ✅ |
| VK Cloud | ✅ |
| Yandex Cloud | ✅ |
| Beeline Cloud | ✅ |
| CDN Video | ✅ |
| Turboflare | ✅ |
| Beget | ✅ |
| Timeweb | ✅ |
| Selectel | ✅ |

---

## 🚀 TL;DR

Установка:

```bash
curl -sSL https://raw.githubusercontent.com/pwdrs/Yandex-CDN-only-on-Mobile-Whitelist-Bypass/main/install.sh -o install.sh
sudo bash install.sh
```

После установки:

```bash
mobile-filter
```

Добавить IP:

```text
mobile-filter → 2
```

Добавить ASN:

```text
mobile-filter → 1
```

Обновить диапазоны:

```text
mobile-filter → 6
```

Проверить Nginx:

```bash
nginx -t
```

Для Docker:

```bash
docker exec cdn-nginx nginx -t
```

Посмотреть полный конфиг:

```bash
nginx -T
```

Для Docker:

```bash
docker exec -it cdn-nginx nginx -T
```

**Один установщик → любой подходящий Nginx → любой CDN → мобильный whitelist.**
