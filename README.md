# MTProto Proxy Installer (telemt + Panel)

Автоматический установщик MTProto Proxy на базе [telemt](https://github.com/telemt/telemt) с опциональной веб-панелью [Telemt Panel](https://github.com/amirotin/telemt_panel).

Всё, что видит пользователь, использует **домен, а не IP**: ссылка прокси, cover-site и панель работают через один домен с настоящим сертификатом Let's Encrypt.

## Архитектура

Один публичный порт, без отдельного SNI-роутера (HAProxy больше не нужен):

```
telemt :443 (FakeTLS MTProto, биндит порт как root → сбрасывает права до nonroot)
  ├── MTProto-клиенты  → проксируются в Telegram
  └── всё остальное    → ретранслируется на Caddy :18443 (cover-site)

Caddy :18443  cover-site (сертификат Let's Encrypt на домен + HSTS)
Caddy :<порт панели>  reverse-proxy → Telemt Panel (тот же LE-сертификат) [опционально]
Caddy :80     ACME HTTP-01 (выпуск/автопродление сертификата) + редирект на HTTPS

Watchtower → ночное автообновление Caddy (telemt закреплён по тегу)
Telemt Panel → веб-панель управления (опционально, за Caddy TLS)
```

telemt получает домен в ссылке через `[general.links] public_host`, а для FakeTLS-хендшейка использует тот же реальный LE-сертификат, что и cover-site.

## Быстрый старт

### Скачать и запустить

```bash
# curl
curl -fsSL https://raw.githubusercontent.com/thekhabaroff/MTProto/master/install.sh -o install.sh
sudo bash install.sh

# либо wget
wget -qO install.sh https://raw.githubusercontent.com/thekhabaroff/MTProto/master/install.sh
sudo bash install.sh
```

> Перед запуском домен (например `proxy.example.com`) уже должен резолвиться на этот сервер, а порты **443** и **80** — быть доступны извне (порт 80 нужен для выпуска и автопродления сертификата Let's Encrypt).

### Интерактивная установка

```bash
sudo bash install.sh
```

Скрипт задаст все необходимые вопросы: домен, порт, секрет, панель и т.д.

### Неинтерактивная установка

```bash
sudo NONINTERACTIVE=1 \
     DOMAIN=proxy.example.com \
     MTPROTO_PORT=443 \
     INSTALL_PANEL=yes \
     PANEL_ADMIN_PASS=mysecretpass \
     bash install.sh
```

### Миграция с другого сервера

```bash
sudo NONINTERACTIVE=1 \
     DOMAIN=proxy.example.com \
     MTPROTO_PORT=443 \
     TELEMT_SECRET_MODE=import \
     TELEMT_SECRET=a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6 \
     bash install.sh
```

## Подключение к прокси

После установки скрипт печатает ссылку вида:

```
tg://proxy?server=<домен>&port=443&secret=ee<секрет><домен в hex>
```

Секрет в формате FakeTLS: `ee` + 32-hex секрет + домен в hex.

**Важно:** открывать ссылку нужно **внутри Telegram**, а не в браузере.

- Самый простой способ: скопировать `https://t.me/proxy?...`-ссылку, вставить её в чат «Избранное» (Saved Messages) и нажать → «Подключить прокси?» → Подключить.
- Либо вручную: Настройки → Данные и память → Прокси → Добавить прокси → MTProto, и ввести сервер, порт и секрет.

Если открыть `https://t.me/proxy?...` с FakeTLS-секретом в обычном браузере, страница t.me перенаправит на telegram.org — веб-страница t.me не умеет показывать превью FakeTLS-ссылок. Это **не** означает, что прокси сломан.

## Компоненты

| Компонент | Описание |
|-----------|----------|
| **telemt** | Rust+Tokio MTProxy, DPI evasion, FakeTLS; на :443, ретранслирует не-MTProto трафик на cover-site |
| **Caddy** | Сертификаты Let's Encrypt (HTTP-01), cover-site, reverse-proxy панели |
| **Watchtower** | Ночное автообновление Caddy (опционально) |
| **Telemt Panel** | Веб-панель управления (опционально) |

## Telemt Panel

Веб-панель управления для telemt MTProxy:

- **Dashboard** — здоровье сервера, uptime, соединения, трафик
- **Пользователи** — CRUD через API Telemt
- **Runtime** — соединения, пулы, upstream quality
- **Безопасность** — posture, лимиты, whitelist
- **Обновления** — обновление бинарника в один клик с откатом

Панель слушает только `127.0.0.1:8181` и публикуется наружу через Caddy на `https://<домен>:<порт панели>` с тем же сертификатом Let's Encrypt.

### Пути установки панели

| Компонент | Путь |
|-----------|------|
| Бинарник | `/usr/local/bin/telemt-panel` |
| Конфиг | `/etc/telemt-panel/config.toml` |
| Данные | `/var/lib/telemt-panel/` |
| Systemd-юнит | `/etc/systemd/system/telemt-panel.service` |
| Sudoers | `/etc/sudoers.d/telemt-panel` |

### Управление панелью

```bash
sudo systemctl status telemt-panel
sudo systemctl restart telemt-panel
sudo journalctl -u telemt-panel -f
```

## Переменные окружения

| Переменная | Описание | По умолчанию |
|-----------|----------|--------------|
| `NONINTERACTIVE` | Режим без вопросов | `0` |
| `DOMAIN` | Домен прокси | — (обязательный) |
| `MTPROTO_PORT` | Порт MTProto | `443` |
| `INSTALL_DIR` | Директория установки | `/opt/telemt` |
| `TELEMT_USER` | Имя пользователя telemt | `proxy` |
| `TELEMT_IMAGE_TAG` | Тег Docker-образа | `latest` |
| `TELEMT_SECRET_MODE` | `new` или `import` | `new` |
| `TELEMT_SECRET` | 32-hex секрет (для import) | — |
| `ENABLE_WATCHTOWER` | Watchtower | `yes` |
| `ENABLE_UNATTENDED` | Автообновления ОС | `yes` |
| `INSTALL_PANEL` | Установить панель | `yes` |
| `PANEL_PORT` | Внешний порт панели (HTTPS) | `8080` |
| `PANEL_ADMIN_USER` | Логин панели | `admin` |
| `PANEL_ADMIN_PASS` | Пароль панели | — |

## Firewall

По умолчанию скрипт настраивает UFW:
- SSH — открыт
- `MTPROTO_PORT` (443) — открыт
- Порт 80 — открыт (нужен для выпуска и автопродления сертификата Let's Encrypt по HTTP-01)
- `PANEL_PORT` — открыт (если панель установлена)

## Сертификат

Caddy сам выпускает и автоматически продлевает сертификат Let's Encrypt через ACME HTTP-01 (порт 80). Отдельный systemd-таймер не нужен — продление происходит автоматически, пока порт 80 доступен.

## Управление

```bash
cd /opt/telemt && docker compose logs -f      # логи
cd /opt/telemt && docker compose restart       # перезапуск
cd /opt/telemt && docker compose ps             # статус контейнеров
```

## Удаление

```bash
# Остановить контейнеры
cd /opt/telemt && docker compose down

# Удалить панель
sudo systemctl stop telemt-panel
sudo systemctl disable telemt-panel
sudo rm -f /etc/systemd/system/telemt-panel.service
sudo rm -f /etc/sudoers.d/telemt-panel
sudo rm -f /usr/local/bin/telemt-panel
sudo rm -rf /etc/telemt-panel /var/lib/telemt-panel
sudo userdel telemt-panel 2>/dev/null

# Удалить всё остальное
sudo rm -rf /opt/telemt
```

## Лицензия

MIT
