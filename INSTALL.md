# Установка связки Hermes + Prometheus + Mnemosyne + gonka-router (+ веб-панель, Grok-vision, прямая публикация)

Подробная пошаговая инструкция, как развернуть весь стек с нуля на чистом сервере.

> Если нужно просто быстро — запусти `install.sh` (см. README): он делает шаги 4–10
> автоматически. Этот документ — подробный ручной разбор каждого шага: чтобы
> понимать, что происходит, и при желании кастомизировать.

---

## 1. Что это и как связано

```
                            ┌─────────────────────────── приватный контур (docker-сеть) ───────────────────────────┐
Internet ── Caddy(:443,TLS) ──► hermes-web (nginx) ──► hermes:9119 (веб-панель)                                     │
   │                                                                                                                │
   │            ┌────────────────────────────────────────────────────────────────────────────────────────────┐   │
   └─(нет прямого входа на :8642, только через панель/туннель)                                                  │   │
                                                                                                                │   │
   Hermes(:8642) ──base_url──► mnemosyne-gateway:8781 ──► prometheus-proxy:8780 ──► proxy.gonka.gg (Gonka)       │   │
                                      └──► mnemosyne-store:8782 ──► mnemosyne-qdrant:6333                         │   │
   gonka-router:8783  (отдельный реестро-зависимый роутер, не в боевом пути)                                     │   │
   Vision (картинки): Hermes ──► Grok (xAI) напрямую, через auxiliary.vision                                     │   │
                                                                                                                └───┘
```

Роли слоёв:
- **Hermes** — сам агент (OpenAI-совместимый API на :8642 + веб-панель :9119). Держит выбор модели и ключи.
- **Prometheus** — прозрачный continuation-прокси: пробивает лимит вывода Gonka (сшивает обрезанные ответы), динамически запрашивает большой `max_tokens`. Не хранит конфиги моделей.
- **Mnemosyne** — слой контекста/памяти: `gateway` (ужатие окна + резюме) → `store` (долгая память: fastembed + qdrant).
- **gonka-router** — реестро-зависимый роутер по сети Gonka (демо, отдельно).
- **Caddy + hermes-web** — публикация панели наружу с TLS.

Боевая цепочка модели: **Hermes → mnemosyne-gateway → prometheus-proxy → Gonka**. Картинки идут в обход — в Grok.

---

## 2. Требования

- Сервер Linux (проверено на Ubuntu 24.04/26.04), x86_64, ≥ 4 ГБ RAM (рекомендуется 8–16 ГБ: qdrant + fastembed), ≥ 20 ГБ диска.
- Доступ root по SSH.
- **Gonka API-ключ** (Bearer к `proxy.gonka.gg`).
- Для веб-панели снаружи: **домен** (А-запись на IP сервера) + аккаунт **Nous Portal** (вход в панель).
- Для распознавания картинок: аккаунт **xAI/Grok** (OAuth).

Ключи/логины вводит владелец сервера сам — это аутентификация.

---

## 3. Подготовка сервера

```bash
ssh root@<SERVER_IP>
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y docker.io docker-compose-v2 git
systemctl enable --now docker
docker --version && docker compose version
```

---

## 4. Каталог и исходники слоёв

Исходники Prometheus / Mnemosyne / gonka-router — в публичных репозиториях. Hermes — официальный образ.

```bash
mkdir -p /opt/hermes-stack && cd /opt/hermes-stack
git clone https://github.com/alexkolumbo/prometheus.git   prometheus
git clone https://github.com/alexkolumbo/mnemosyne.git     mnemosyne     # содержит gateway/ и store/
git clone https://github.com/alexkolumbo/gonka-router.git  gonka-router
mkdir -p hermes-web prometheus/log mnemosyne/gateway/log
```

Структура должна получиться:
```
/opt/hermes-stack/
├── docker-compose.yml          (создаём в шаге 6)
├── .env                        (создаём в шаге 5)
├── Caddyfile                   (шаг 9)
├── hermes-web/nginx.conf       (шаг 8)
├── prometheus/   (Dockerfile, app.py, engine.py, requirements.txt, log/)
├── mnemosyne/gateway/ , mnemosyne/store/
└── gonka-router/
```

---

## 5. Секреты — `.env`

```bash
cat > /opt/hermes-stack/.env <<EOF
# Ключ доступа к Gonka (тот, которым ходишь на proxy.gonka.gg)
GONKA_API_KEY=ВСТАВЬ_СВОЙ_КЛЮЧ

# Ключ авторизации к API-серверу Hermes (придумываем случайный)
HERMES_API_KEY=$(head -c24 /dev/urandom | od -An -tx1 | tr -d ' \n')

# Заполнится позже, после регистрации панели (шаг 11)
HERMES_DASHBOARD_OAUTH_CLIENT_ID=
EOF
chmod 600 /opt/hermes-stack/.env
```

> ⚠️ Подводный камень: не пиши комментарий в одной строке со значением (`KEY=val # коммент`) и сохраняй файл в LF/UTF-8 без BOM. Иначе хвост попадёт в значение.

---

## 6. Единый `docker-compose.yml`

```yaml
name: hermes-stack

volumes:
  hermes_data: {}
  hermes_projects: {}
  mnemosyne_store: {}
  mnemosyne_qdrant: {}
  caddy_data: {}
  caddy_config: {}

services:
  hermes:
    image: nousresearch/hermes-agent:latest
    container_name: hermes
    restart: unless-stopped
    environment:
      GONKA_API_KEY: "${GONKA_API_KEY}"
      API_SERVER_ENABLED: "true"
      API_SERVER_HOST: "0.0.0.0"
      API_SERVER_KEY: "${HERMES_API_KEY}"
      HERMES_API_KEY: "${HERMES_API_KEY}"
      HERMES_STREAM_READ_TIMEOUT: "1800"
      # веб-панель как s6-сервис ВНУТРИ этого же контейнера (отдельный контейнер
      # с тем же томом /opt/data ловит lock и поднимает второй gateway — нельзя)
      HERMES_DASHBOARD: "true"
      HERMES_DASHBOARD_HOST: "0.0.0.0"
      HERMES_DASHBOARD_PORT: "9119"
      HERMES_DASHBOARD_INSECURE: "true"
      HERMES_DASHBOARD_OAUTH_CLIENT_ID: "${HERMES_DASHBOARD_OAUTH_CLIENT_ID:-}"
    volumes:
      - hermes_data:/opt/data
      - hermes_projects:/projects
    command: gateway run
    healthcheck:
      test: ["CMD", "curl", "-sf", "http://localhost:8642/health"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 20s

  prometheus-proxy:
    build: ./prometheus
    image: prometheus-proxy:latest
    container_name: prometheus-proxy
    restart: unless-stopped
    environment:
      UPSTREAM_BASE_URL: "https://proxy.gonka.gg"
      LOGDIR: "/log"
      PROM_MAX_TOKENS: "32000"     # сколько токенов просим у Gonka за вызов (динамич. output)
      PROM_READ_TIMEOUT: "300"     # макс. тишина между чанками до fail-fast
    volumes:
      - ./prometheus/log:/log

  mnemosyne-store:
    build: ./mnemosyne/store
    image: mnemosyne-store:latest
    container_name: mnemosyne-store
    restart: unless-stopped
    environment:
      DATADIR: "/data"
      QDRANT_URL: "http://mnemosyne-qdrant:6333"
    volumes:
      - mnemosyne_store:/data

  mnemosyne-qdrant:
    image: qdrant/qdrant:latest
    container_name: mnemosyne-qdrant
    restart: unless-stopped
    volumes:
      - mnemosyne_qdrant:/qdrant/storage

  mnemosyne-gateway:
    build: ./mnemosyne/gateway
    image: mnemosyne-gateway:latest
    container_name: mnemosyne-gateway
    restart: unless-stopped
    environment:
      UPSTREAM_BASE_URL: "http://prometheus-proxy:8780"
      STORE_URL: "http://mnemosyne-store:8782"
      LOGDIR: "/log"
    volumes:
      - ./mnemosyne/gateway/log:/log
    depends_on: [prometheus-proxy, mnemosyne-store]

  gonka-router:
    build: ./gonka-router
    image: gonka-router:latest
    container_name: gonka-router
    restart: unless-stopped

  hermes-web:
    image: nginx:1.27-alpine
    container_name: hermes-web
    restart: unless-stopped
    volumes:
      - ./hermes-web/nginx.conf:/etc/nginx/conf.d/default.conf:ro
    depends_on: [hermes]

  caddy:
    image: caddy:2-alpine
    container_name: caddy
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy_data:/data
      - caddy_config:/config
    depends_on: [hermes-web]
```

Все сервисы в одной сети `hermes-stack` (compose создаёт её сам), резолвятся по имени контейнера.

---

## 7. nginx для панели — `hermes-web/nginx.conf`

```nginx
map $http_upgrade $connection_upgrade { default upgrade; '' close; }

server {
    listen 80;
    server_name _;
    client_max_body_size 50m;
    location / {
        proxy_pass http://hermes:9119;
        proxy_http_version 1.1;
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header Upgrade           $http_upgrade;
        proxy_set_header Connection        $connection_upgrade;
        proxy_read_timeout 600s;
    }
}
```

---

## 8. Публикация наружу — `Caddyfile`

Вариант с автоматическим TLS по HTTP-01 (нужны открытые 80/443 и А-запись домена на IP сервера):

```
hermes.example.com {
    reverse_proxy hermes-web:80
}
```

DNS: заведи A-запись `hermes.example.com → <SERVER_IP>` (если домен за Cloudflare — «серое облако»/DNS-only). Открой в фаерволе сервера **80 и 443**.

> Если домен проксируется Cloudflare (оранжевое облако) — используй вместо HTTP-01 challenge DNS-01 (нужен образ Caddy с плагином cloudflare и `tls { dns cloudflare {env.CF_API_TOKEN} }`).

---

## 9. Первый запуск стека

```bash
cd /opt/hermes-stack
docker compose build           # соберёт prometheus/mnemosyne/gonka-router
docker compose up -d
docker compose ps
```

Дождись `hermes` → healthy. На первом старте Hermes создаёт дефолтный `/opt/data/config.yaml` — его донастроим в шаге 10.

---

## 10. Критичные настройки Hermes (`config.yaml`)

Конфиг лежит в томе: `docker exec -it hermes hermes config edit` (или `docker exec hermes cat /opt/data/config.yaml`). Нужно выставить блоки ниже.

**Скалярные ключи** — через CLI:
```bash
docker exec hermes hermes config set model.provider custom
docker exec hermes hermes config set model.base_url http://mnemosyne-gateway:8781/v1
docker exec hermes hermes config set model.default moonshotai/Kimi-K2.6
docker exec hermes hermes config set model.api_key '<GONKA_API_KEY>'
docker exec hermes hermes config set terminal.backend local
```

**Списочные ключи** — редактируем `config.yaml` (`hermes config edit`):

```yaml
# чтобы write_file / terminal / skills работали и через API-сервер, и в чате —
# у профиля api_server должен быть ПОЛНЫЙ набор тулсетов:
platform_toolsets:
  cli: &full
    - browser
    - clarify
    - delegation
    - file
    - image_gen
    - memory
    - messaging
    - session_search
    - skills
    - terminal
    - todo
    - vision
    - web
  telegram: *full
  api_server: *full

# кастомный OpenAI-совместимый провайдер, указывающий на наш gateway:
custom_providers:
  - name: GonkaAI
    base_url: http://mnemosyne-gateway:8781/v1
    api_key: <GONKA_API_KEY>
    model: Qwen/Qwen3-235B-A22B-Instruct-2507-FP8

api_server:
  enabled: true
  host: 0.0.0.0
  port: 8642
```

Применить:
```bash
docker restart hermes
```

Проверка цепочки (pong через весь стек):
```bash
HK=$(docker exec hermes printenv HERMES_API_KEY)
curl -s -H "Authorization: Bearer $HK" -H "Content-Type: application/json" \
  -X POST http://localhost:8642/v1/chat/completions \
  -d '{"model":"hermes-agent","messages":[{"role":"user","content":"reply one word: pong"}],"stream":false}'
```

---

## 11. Веб-панель (доступ с любого устройства, вход через Nous Portal)

1. **Логин в Nous Portal** (аутентификация — делаешь сам):
   ```bash
   docker exec -it hermes hermes auth add nous --type oauth --no-browser --manual-paste
   ```
   Откроется ссылка/код — подтверди в браузере. (Не используй `hermes portal` без подкоманды — он меняет основную модель.)

2. **Регистрация панели** под твой домен:
   ```bash
   docker exec hermes hermes dashboard register \
     --name "hermes-dashboard" \
     --redirect-uri "https://hermes.example.com/auth/callback"
   ```
   Команда выведет `HERMES_DASHBOARD_OAUTH_CLIENT_ID=...`. Впиши его в `.env` и пересоздай Hermes:
   ```bash
   sed -i 's|^HERMES_DASHBOARD_OAUTH_CLIENT_ID=.*|HERMES_DASHBOARD_OAUTH_CLIENT_ID=agent:XXXX|' .env
   docker compose up -d hermes
   ```

3. Открой `https://hermes.example.com` → вход через Nous Portal → панель.

> Панель управляет ключами/конфигом, поэтому наружу — только за её логином (Nous OAuth включается при non-loopback bind + заданном client id; оба условия выполнены) и по HTTPS. Без домена доступ только через SSH-туннель: `ssh -L 9119:127.0.0.1:9119 root@<IP>` → но тогда сначала опубликуй порт панели (`docker exec` не публикует) или прокинь через hermes-web.

---

## 12. Картинки — Grok (vision)

1. **OAuth-логин xAI** (делаешь сам):
   ```bash
   docker exec -it hermes hermes auth add xai-oauth --type oauth --no-browser --manual-paste
   ```
   После подтверждения **xAI показывает код прямо на странице** — вставь именно ЭТОТ код (а не адрес `127.0.0.1/callback`).
   Проверка: `docker exec hermes hermes auth list` → есть `xai-oauth`; `hermes status` → `xAI OAuth ✓`.

2. **Направить vision на Grok** (основная модель остаётся Gonka):
   ```bash
   docker exec hermes hermes config set auxiliary.vision.provider xai-oauth
   docker exec hermes hermes config set auxiliary.vision.model grok-4
   docker restart hermes
   ```

> ⚠️ Не делай Grok ОСНОВНОЙ моделью в `/model` — тогда основной поток пойдёт мимо `mnemosyne-gateway` и потеряет continuation+память. Grok — только для картинок.

---

## 13. Проверка слоёв

```bash
# здоровье
curl -s localhost:8780/healthz   # prometheus-proxy
curl -s localhost:8781/healthz   # mnemosyne-gateway (видны upstream+store)
curl -s localhost:8782/healthz   # mnemosyne-store (memory_backend: vector)
curl -s localhost:8783/healthz   # gonka-router
curl -s localhost:8642/health    # hermes

# Prometheus: пробитие лимита — попросить вывод > cap, finish=stop, completion_tokens большой
# Mnemosyne: remember -> recall (vector)
curl -s -XPOST localhost:8782/memory/remember -H 'Content-Type: application/json' \
  -d '{"namespace":"t","text":"The reactor codename is Prometheus-7 in Sector Gamma."}'
curl -s -XPOST localhost:8782/memory/recall -H 'Content-Type: application/json' \
  -d '{"namespace":"t","query":"what is the reactor called?","top_k":1}'

# gonka-router: живой реестр
curl -s localhost:8783/map

# Vision: послать картинку в hermes API (см. шаг 12 — модель должна прочитать содержимое)
```

---

## 14. Эксплуатация

- **Изменил `.env`** → `docker compose up -d hermes` (НЕ `restart` — он не перечитывает env).
- **Изменил `config.yaml`** → достаточно `docker restart hermes` (он в томе).
- **Обновил код слоя** → `docker compose up -d --build prometheus-proxy` (или нужный сервис).
- **Логи прокси**: `prometheus/log/proxy.log` (видно continuation и наблюдаемый cap).
- **Бэкап данных**: тома `hermes_data` (конфиг/сессии/память Hermes), `mnemosyne_store`, `mnemosyne_qdrant`.

### Подводные камни (собрано из реального деплоя)
- **Панель — только внутри контейнера hermes** (env `HERMES_DASHBOARD=*`). Отдельный контейнер на том же томе `/opt/data` ловит `s6-log lock: Resource busy` и поднимает второй gateway — риск порчи `state.db`.
- **`.env` из Windows**: CRLF и inline-комментарии ломают значения. LF, без BOM, комментарии на отдельной строке.
- **`hermes login` удалён** в свежих образах — используй `hermes auth add <provider> --type oauth`.
- **xAI отдаёт код на странице**, а не редиректом — вставляй код, а не `127.0.0.1/callback`.
- **Свежая DNS-запись**: резолверы кэшируют NXDOMAIN (negative-TTL, у Cloudflare ~30 мин). Сервер часто не может достучаться до своего же публичного IP (hairpin NAT) — проверяй через авторитетный NS или `curl --resolve ...:443:<IP>`, а не с самого сервера.
- **`docker compose ... down --remove-orphans`**: если рядом другие compose-проекты в том же каталоге — может снести чужие контейнеры. Держи стек в своём каталоге/проекте.
- **PowerShell** (если рулишь по SSH с Windows) коверкает inline-кавычки/`|`/`$(...)` — гоняй команды через залитые `.sh`-обёртки.
- **openssl** может отсутствовать — случайный ключ: `head -c24 /dev/urandom | od -An -tx1 | tr -d ' \n'`.

---

## 15. Кратко: порядок действий
1. Docker (шаг 3) → 2. clone (шаг 4) → 3. `.env` (шаг 5) → 4. compose+nginx+Caddyfile (6–8) →
5. `docker compose up -d --build` (9) → 6. config.yaml + pong (10) → 7. панель: Nous login + register + домен (11) →
8. Grok: xai login + vision (12) → 9. проверки (13).
