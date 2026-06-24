# MTProto Proxy Installer (telemt + Panel)

Автоматический установщик MTProto Proxy на базе [telemt](https://github.com/telemt/telemt) с опциональной веб-панелью [Telemt Panel](https://github.com/amirotin/telemt_panel).

## Архитектура

```
HAProxy :443 (SNI router, inspect-delay 30s для VPN-совместимости)
  ├── MTProto SNI → telemt :13128 (FakeTLS + TLS-emulation, PROXY v2)
  └── остальное  → Caddy :18443 (LE cert + HSTS + cover-site)

HAProxy :80 → Caddy :18080 (ACME challenge; порт 80 закрыт кроме окна обновления)

Watchtower → ночное автообновление Caddy + HAProxy (telemt pinned by tag)

Telemt Panel :8080 → веб-панель управления (опционально)
```

## Быстрый старт

### Интерактивная установка

```bash
sudo ./install.sh
```

Скрипт задаст все необходимые вопросы: домен, порт, секрет, панель и т.д.

### Неинтерактивная установка

```bash
sudo NONINTERACTIVE=1 \
     DOMAIN=proxy.example.com \
     MTPROTO_PORT=443 \
     INSTALL_PANEL=yes \
     PANEL_ADMIN_PASS=mysecretpass \
     ./install.sh
```

### Миграция с другого сервера

```bash
sudo NONINTERACTIVE=1 \
     DOMAIN=proxy.example.com \
     MTPROTO_PORT=443 \
     TELEMT_SECRET_MODE=import \
     TELEMT_SECRET=a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6 \
     ./install.sh
```

## Компоненты

| Компонент | Описание |
|-----------|----------|
| **telemt** | Rust+Tokio MTProxy, DPI evasion, FakeTLS |
| **HAProxy** | SNI-роутер, разделяет MTProto и обычный HTTPS |
| **Caddy** | Let's Encrypt сертификаты, cover-site |
| **Watchtower** | Автообновление контейнеров (опционально) |
| **Telemt Panel** | Веб-панель управления (опционально) |

## Telemt Panel

Веб-панель управления для telemt MTProxy:

- **Dashboard** — здоровье сервера, uptime, соединения, трафик
- **Пользователи** — CRUD через API Telemt
- **Runtime** — соединения, пулы, upstream quality
- **Безопасность** — posture, лимиты, whitelist
- **Обновления** — обновление бинарника в один клик с откатом

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
| `PANEL_PORT` | Порт панели | `8080` |
| `PANEL_ADMIN_USER` | Логин панели | `admin` |
| `PANEL_ADMIN_PASS` | Пароль панели | — |

## Firewall

По умолчанию скрипт настраивает UFW:
- SSH — открыт
- `MTPROTO_PORT` — открыт
- `PANEL_PORT` — открыт (если панель установлена)
- Порт 80 — закрыт (открывается только во время обновления сертификата)

## Обновление сертификата

Системный таймер открывает порт 80 раз в неделю для ACME-проверки Let's Encrypt, затем закрывает обратно.

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
sudo systemctl disable cert-renewal.timer
sudo rm -f /etc/systemd/system/cert-renewal.*
sudo systemctl daemon-reload
```

## Лицензия

MIT
