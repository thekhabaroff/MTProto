#!/usr/bin/env bash
# ============================================================================
# MTProto Proxy (telemt backend) — automated installer v2
#
# Architecture (single public port, no SNI router needed):
#   telemt :${MTPROTO_PORT} (FakeTLS MTProto proxy; binds as root then drops to
#       the unprivileged 'nonroot' user via --run-as-user)
#     ├── MTProto clients  → proxied to Telegram
#     └── everything else  → masked/relayed to Caddy :18443 (cover-site)
#   Caddy :18443           cover-site (Let's Encrypt cert for the domain, HSTS)
#   Caddy :<panel port>    reverse-proxy → Telemt Panel (same LE cert)  [optional]
#   Caddy :80              ACME HTTP-01 challenge + redirect to HTTPS
#   Watchtower → nightly auto-update of Caddy (telemt pinned by tag)
#   Telemt Panel → web UI for proxy management (optional, behind Caddy TLS)
#
# Everything the user sees uses the DOMAIN, never the raw IP:
#   * telemt's [general.links] public_host puts the domain in the tg:// link
#   * telemt mirrors the cover-site's real LE cert for its FakeTLS handshake
#   * the panel is published at https://<domain>:<panel port> with the LE cert
#
# telemt is a Rust+Tokio MTProxy implementation focused on DPI evasion:
#   https://github.com/telemt/telemt
#
# Telemt Panel is a Go+React web panel for managing telemt:
#   https://github.com/amirotin/telemt_panel
#
# Usage:
#   sudo ./install.sh        — interactive (asks all parameters)
#   sudo NONINTERACTIVE=1 \
#        DOMAIN=... \
#        MTPROTO_PORT=443 ./install.sh   — non-interactive, generates new secret
#
#   sudo NONINTERACTIVE=1 \
#        DOMAIN=... MTPROTO_PORT=443 \
#        TELEMT_SECRET_MODE=import \
#        TELEMT_SECRET=<32 hex chars from previous install> \
#        ./install.sh                    — migrate proxy from another server
# ============================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()  { echo -e "${GREEN}[+]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
error() { echo -e "${RED}[x]${NC} $*" >&2; }
separator() { echo -e "\n${GREEN}─── $* ───${NC}\n"; }

# ── Pre-flight ─────────────────────────────────────────────────────────────

if [[ "$EUID" -ne 0 ]]; then
  error "Run as root: sudo ./install.sh"
  exit 1
fi

# Helper: prompt with default. $1 = prompt, $2 = default, $3 = varname
prompt_default() {
  local prompt="$1" default="$2" varname="$3" val
  if [[ -n "${!varname:-}" ]]; then return; fi
  if [[ "${NONINTERACTIVE:-0}" == "1" ]]; then
    eval "$varname=\"\$default\""
    return
  fi
  if [[ -n "$default" ]]; then
    read -r -p "$(echo -e "${BLUE}?${NC} ${prompt} [${default}]: ")" val
    val="${val:-$default}"
  else
    read -r -p "$(echo -e "${BLUE}?${NC} ${prompt}: ")" val
    while [[ -z "$val" ]]; do
      read -r -p "$(echo -e "${RED}!${NC} Required. ${prompt}: ")" val
    done
  fi
  eval "$varname=\"\$val\""
}

prompt_yn() {
  local prompt="$1" default="$2" varname="$3" val hint
  if [[ -n "${!varname:-}" ]]; then return; fi
  if [[ "${NONINTERACTIVE:-0}" == "1" ]]; then
    eval "$varname=\"\$default\""
    return
  fi
  if [[ "$default" == "y" ]]; then hint="[Y/n]"; else hint="[y/N]"; fi
  while true; do
    read -r -p "$(echo -e "${BLUE}?${NC} ${prompt} ${hint}: ")" val
    val="${val:-$default}"
    case "${val,,}" in
      y|yes) eval "$varname=yes"; return;;
      n|no)  eval "$varname=no";  return;;
    esac
  done
}

# Validate port number 1..65535, excluding 80 (ACME)
validate_port() {
  local p="$1"
  [[ "$p" =~ ^[0-9]+$ ]] || return 1
  (( p >= 1 && p <= 65535 )) || return 1
  (( p != 80 )) || return 1
}

# ── Interactive configuration ──────────────────────────────────────────────

separator "Configuration"

prompt_default "MTProto domain (must already resolve to this server)" "" DOMAIN

# Port: default 443 but configurable
while true; do
  prompt_default "MTProto port (default 443; any 1..65535 except 80)" "443" MTPROTO_PORT
  if validate_port "$MTPROTO_PORT"; then break; fi
  warn "Invalid port '${MTPROTO_PORT}'. Must be 1..65535 and not 80."
  unset MTPROTO_PORT
done

prompt_default "Install directory"                                "/opt/telemt" INSTALL_DIR
prompt_default "Cover-site title (shown to non-Telegram visitors)" "Crypto Networks" SITE_TITLE
prompt_default "Cover-site description"                            "Boutique IT consulting and infrastructure services." SITE_DESCRIPTION

prompt_default "telemt username (used inside config + API, single user only)" "proxy" TELEMT_USER
prompt_default "telemt image tag (latest = follow upstream master, or pin e.g. 3.4.12)" "latest" TELEMT_IMAGE_TAG

# Secret handling
prompt_default "telemt secret source (new = generate / import = enter existing 32-hex)" "new" TELEMT_SECRET_MODE
TELEMT_SECRET_MODE="${TELEMT_SECRET_MODE,,}"
if [[ "$TELEMT_SECRET_MODE" != "new" && "$TELEMT_SECRET_MODE" != "import" ]]; then
  error "Invalid secret source '${TELEMT_SECRET_MODE}'. Must be 'new' or 'import'."
  exit 1
fi

if [[ "$TELEMT_SECRET_MODE" == "import" ]]; then
  if [[ "${NONINTERACTIVE:-0}" == "1" ]]; then
    if [[ -z "${TELEMT_SECRET:-}" ]] || ! [[ "$TELEMT_SECRET" =~ ^[0-9a-fA-F]{32}$ ]]; then
      error "NONINTERACTIVE import requires TELEMT_SECRET=<32 hex chars> in env."
      exit 1
    fi
    TELEMT_SECRET="${TELEMT_SECRET,,}"
  else
    while true; do
      read -r -p "$(echo -e "${BLUE}?${NC} Enter existing 32-hex secret: ")" TELEMT_SECRET_INPUT
      if [[ "$TELEMT_SECRET_INPUT" =~ ^[0-9a-fA-F]{32}$ ]]; then
        TELEMT_SECRET="${TELEMT_SECRET_INPUT,,}"
        break
      fi
      warn "Invalid format. Need exactly 32 hex characters (0-9, a-f)."
    done
  fi
fi

prompt_yn "Enable Watchtower (auto-update Caddy nightly)?" "y" ENABLE_WATCHTOWER
if [[ "$ENABLE_WATCHTOWER" == "yes" ]]; then
  prompt_default "Watchtower cron schedule" "0 0 4 * * *" WATCHTOWER_SCHEDULE
else
  WATCHTOWER_SCHEDULE=""
fi

prompt_yn "Enable Ubuntu unattended security upgrades?" "y" ENABLE_UNATTENDED
if [[ "$ENABLE_UNATTENDED" == "yes" ]]; then
  prompt_default "Reboot time if kernel update requires" "04:00" REBOOT_TIME
else
  REBOOT_TIME=""
fi

# ── Telemt Panel (optional) ────────────────────────────────────────────────

prompt_yn "Install Telemt Panel (web UI for proxy management)?" "y" INSTALL_PANEL
if [[ "$INSTALL_PANEL" == "yes" ]]; then
  prompt_default "Panel listen port" "8080" PANEL_PORT
  # The panel binds a localhost-only internal port; Caddy publishes it on
  # PANEL_PORT with TLS. Keep this off the public ports above.
  PANEL_INTERNAL_PORT="${PANEL_INTERNAL_PORT:-8181}"
  prompt_default "Panel admin username" "admin" PANEL_ADMIN_USER
  if [[ "${NONINTERACTIVE:-0}" == "1" ]]; then
    PANEL_ADMIN_PASS="${PANEL_ADMIN_PASS:-admin}"
  else
    while true; do
      read -r -s -p "$(echo -e "${BLUE}?${NC} Panel admin password: ")" PANEL_ADMIN_PASS
      echo
      if [[ -n "$PANEL_ADMIN_PASS" ]]; then break; fi
      warn "Password cannot be empty."
    done
  fi
fi

# Normalize
DOMAIN="${DOMAIN,,}"

# Sanity: warn if non-standard port
if [[ "$MTPROTO_PORT" != "443" ]]; then
  warn "MTProto port = ${MTPROTO_PORT} (not 443)."
  warn "Cover-site at https://${DOMAIN}/ will NOT work; only https://${DOMAIN}:${MTPROTO_PORT}/"
  warn "Telegram clients still work (they support custom ports via tg:// URL)."
fi

# ── Review ─────────────────────────────────────────────────────────────────

separator "Review configuration"
cat <<EOF
  Domain:           ${DOMAIN}
  MTProto port:     ${MTPROTO_PORT}
  Install dir:      ${INSTALL_DIR}
  Cover-site:       ${SITE_TITLE}
  Telemt user:      ${TELEMT_USER}
  Image tag:        ${TELEMT_IMAGE_TAG}
  Secret mode:      ${TELEMT_SECRET_MODE}
  Watchtower:       ${ENABLE_WATCHTOWER}
  Unattended:       ${ENABLE_UNATTENDED}
  Panel:            ${INSTALL_PANEL:-no}
EOF

if [[ "${NONINTERACTIVE:-0}" != "1" ]]; then
  echo
  read -r -p "$(echo -e "${BLUE}?${NC} Proceed with installation? [Y/n]: ")" CONFIRM
  CONFIRM="${CONFIRM:-y}"
  if [[ "${CONFIRM,,}" != "y" && "${CONFIRM,,}" != "yes" ]]; then
    info "Aborted."
    exit 0
  fi
fi

# ══════════════════════════════════════════════════════════════════════════════
# INSTALLATION
# ══════════════════════════════════════════════════════════════════════════════

separator "Installing dependencies"

apt-get update -qq
apt-get install -y -qq curl jq openssl ufw xxd >/dev/null 2>&1

# ── Docker (idempotent, repo-aware) ────────────────────────────────────────
# Don't mix Ubuntu's docker.io with Docker's official docker-compose-plugin:
# docker.io pulls Ubuntu's `containerd`, the official plugin pulls `containerd.io`,
# and the two conflict ("pkgProblemResolver::Resolve ... broken packages").
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  info "Docker (with compose plugin) already installed — skipping"
elif command -v docker >/dev/null 2>&1; then
  info "Docker present but compose plugin missing — installing matching plugin"
  if dpkg -s docker-ce >/dev/null 2>&1; then
    apt-get install -y -qq docker-compose-plugin >/dev/null 2>&1
  else
    apt-get install -y -qq docker-compose-v2 >/dev/null 2>&1 \
      || apt-get install -y -qq docker-compose-plugin >/dev/null 2>&1
  fi
else
  info "Installing Docker from the official repository"
  install -m 0755 -d /etc/apt/keyrings
  if [[ ! -f /etc/apt/keyrings/docker.asc ]]; then
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
  fi
  . /etc/os-release
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -qq
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >/dev/null 2>&1
fi

systemctl enable --now docker

# ── Generate or use imported secret ────────────────────────────────────────

if [[ "$TELEMT_SECRET_MODE" == "new" ]]; then
  TELEMT_SECRET=$(openssl rand -hex 16)
  info "Generated new secret: ${TELEMT_SECRET}"
else
  info "Using imported secret: ${TELEMT_SECRET}"
fi

# ── Create directory structure ─────────────────────────────────────────────

separator "Setting up directories"

mkdir -p "${INSTALL_DIR}"/{caddy/{site,data,config},telemt}
info "Created ${INSTALL_DIR}"

# ── Telemt config ──────────────────────────────────────────────────────────

separator "Configuring telemt"

# telemt reads /app/config.toml inside the image and runs as the unprivileged
# 'nonroot' user (uid 65532) after binding the port. This is the upstream
# 'telemt --init' schema with three deliberate additions:
#   * [general.links] public_host → forces the DOMAIN (not the IP) into tg:// link
#   * [censorship] mask_host/port → relays non-MTProto traffic to the local Caddy
#                                   cover-site so browsers get a real LE cert
#   * [server.api]                → local HTTP API consumed by Telemt Panel
cat > "${INSTALL_DIR}/telemt/config.toml" <<EOF
show_link = ["${TELEMT_USER}"]

[general]
use_middle_proxy = false
fast_mode = true
log_level = "normal"

[general.modes]
classic = false
secure = false
tls = true

[general.links]
show = "*"
public_host = "${DOMAIN}"
public_port = ${MTPROTO_PORT}

[[server.listeners]]
ip = "0.0.0.0"
port = ${MTPROTO_PORT}

[[server.listeners]]
ip = "::"
port = ${MTPROTO_PORT}

[server.api]
listen = "127.0.0.1:9091"
whitelist = ["127.0.0.1/32", "::1/128"]

[censorship]
tls_domain = "${DOMAIN}"
mask = true
mask_host = "127.0.0.1"
mask_port = 18443

[access.users]
${TELEMT_USER} = "${TELEMT_SECRET}"
EOF

# telemt drops to uid 65532 (nonroot) after binding the port; give it ownership
# of its data dir so it can persist the proxy-secret / TLS-front / quota caches.
chown -R 65532:65532 "${INSTALL_DIR}/telemt"

info "telemt config written"

# ── Caddy config ───────────────────────────────────────────────────────────

separator "Configuring Caddy"

# Caddy obtains a real Let's Encrypt cert for ${DOMAIN} via the HTTP-01 challenge
# on port 80. TLS-ALPN is disabled because telemt — not Caddy — owns
# :${MTPROTO_PORT}. The cover-site is served on :18443; telemt relays non-MTProto
# visitors there, so browsers complete a real TLS handshake with Caddy and see a
# valid certificate. Caddy auto-renews while port 80 stays open at the firewall.
cat > "${INSTALL_DIR}/caddy/Caddyfile" <<EOF
{
    http_port 80
}

https://${DOMAIN}:18443 {
    tls {
        issuer acme {
            disable_tlsalpn_challenge
        }
    }
    header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload"
    encode gzip
    root * /srv
    file_server
}
EOF

if [[ "${INSTALL_PANEL:-no}" == "yes" ]]; then
  cat >> "${INSTALL_DIR}/caddy/Caddyfile" <<EOF

https://${DOMAIN}:${PANEL_PORT} {
    tls {
        issuer acme {
            disable_tlsalpn_challenge
        }
    }
    reverse_proxy 127.0.0.1:${PANEL_INTERNAL_PORT}
}
EOF
fi

# Cover-site HTML
cat > "${INSTALL_DIR}/caddy/site/index.html" <<EOF
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>${SITE_TITLE}</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
            background: linear-gradient(135deg, #0f0c29 0%, #302b63 50%, #24243e 100%);
            color: #e0e0e0;
            min-height: 100vh;
            display: flex;
            align-items: center;
            justify-content: center;
        }
        .container {
            text-align: center;
            padding: 2rem;
        }
        h1 { font-size: 2.5rem; margin-bottom: 1rem; color: #fff; }
        p { font-size: 1.2rem; opacity: 0.8; max-width: 600px; }
    </style>
</head>
<body>
    <div class="container">
        <h1>${SITE_TITLE}</h1>
        <p>${SITE_DESCRIPTION}</p>
    </div>
</body>
</html>
EOF

info "Caddy config and cover-site written"

# ── Docker Compose ─────────────────────────────────────────────────────────

separator "Creating Docker Compose"

COMPOSE_FILE="${INSTALL_DIR}/docker-compose.yml"

cat > "$COMPOSE_FILE" <<EOF
services:
  caddy:
    image: caddy:2-alpine
    container_name: caddy
    restart: unless-stopped
    network_mode: host
    volumes:
      - ${INSTALL_DIR}/caddy/Caddyfile:/etc/caddy/Caddyfile:ro
      - ${INSTALL_DIR}/caddy/site:/srv:ro
      - ${INSTALL_DIR}/caddy/data:/data
      - ${INSTALL_DIR}/caddy/config:/config

  telemt:
    image: ghcr.io/telemt/telemt:${TELEMT_IMAGE_TAG}
    container_name: telemt
    restart: unless-stopped
    network_mode: host
    # Start as root so telemt can bind the privileged port, then immediately drop
    # to the unprivileged 'nonroot' user (uid 65532) via --run-as-user.
    user: "0:0"
    command: ["--data-path", "/data", "--run-as-user", "nonroot", "--run-as-group", "nonroot", "/app/config.toml"]
    volumes:
      - ${INSTALL_DIR}/telemt/config.toml:/app/config.toml:ro
      - ${INSTALL_DIR}/telemt:/data
    depends_on:
      - caddy
    labels:
      - "com.centurylinklabs.watchtower.enable=false"
EOF

if [[ "$ENABLE_WATCHTOWER" == "yes" ]]; then
  cat >> "$COMPOSE_FILE" <<EOF

  watchtower:
    image: containrrr/watchtower
    container_name: watchtower
    restart: unless-stopped
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
    environment:
      - WATCHTOWER_CLEANUP=true
      - WATCHTOWER_SCHEDULE=${WATCHTOWER_SCHEDULE}
      - WATCHTOWER_LABEL_ENABLE=false
    command: --label-enable=false caddy
EOF
fi

info "Docker Compose written"

# ── Firewall ───────────────────────────────────────────────────────────────

separator "Configuring firewall"

ufw --force reset >/dev/null 2>&1
ufw default deny incoming
ufw default allow outgoing
ufw allow ssh
ufw allow "${MTPROTO_PORT}/tcp"
# Port 80 stays open so Caddy can complete and auto-renew the Let's Encrypt
# HTTP-01 challenge for ${DOMAIN} (and redirect plain-HTTP visitors to HTTPS).
ufw allow 80/tcp
ufw --force enable
info "UFW configured (open: ssh, ${MTPROTO_PORT}/tcp, 80/tcp)"
if [[ "${INSTALL_PANEL:-no}" == "yes" ]]; then
  ufw allow "${PANEL_PORT}/tcp" >/dev/null 2>&1
  info "Firewall: panel port ${PANEL_PORT} opened"
fi

# ── Unattended upgrades ────────────────────────────────────────────────────

if [[ "$ENABLE_UNATTENDED" == "yes" ]]; then
  separator "Configuring unattended upgrades"
  apt-get install -y -qq unattended-upgrades >/dev/null 2>&1

  cat > /etc/apt/apt.conf.d/50unattended-upgrades <<EOF
Unattended-Upgrade::Allowed-Origins {
    "\${distro_id}:\${distro_codename}-security";
};
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "${REBOOT_TIME}";
EOF

  cat > /etc/apt/apt.conf.d/20auto-upgrades <<EOF
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

  info "Unattended upgrades enabled (reboot at ${REBOOT_TIME} if needed)"
fi

# ── Start services ─────────────────────────────────────────────────────────

separator "Starting services"

cd "${INSTALL_DIR}"
docker compose pull
# --force-recreate is required: on a reinstall the compose service definition is
# unchanged, so plain `up -d` would leave the old container running with its old
# in-memory config (e.g. a previously-entered secret). telemt loads config.toml
# once at start and a single-file bind mount pins the old inode when the file is
# replaced, so the running container never sees the new secret/domain. Recreating
# guarantees the freshly written config.toml is loaded.
docker compose up -d --force-recreate --remove-orphans

info "All containers started"

# ══════════════════════════════════════════════════════════════════════════════
# TELEMT PANEL INSTALLATION (optional)
# ══════════════════════════════════════════════════════════════════════════════

if [[ "${INSTALL_PANEL:-no}" == "yes" ]]; then
  separator "Installing Telemt Panel"

  PANEL_REPO="amirotin/telemt_panel"
  PANEL_BINARY_NAME="telemt-panel"
  PANEL_SYSTEM_USER="telemt-panel"
  PANEL_BIN_DIR="/usr/local/bin"
  PANEL_BINARY_PATH="${PANEL_BIN_DIR}/${PANEL_BINARY_NAME}"
  PANEL_CONFIG_DIR="/etc/telemt-panel"
  PANEL_CONFIG_FILE="${PANEL_CONFIG_DIR}/config.toml"
  PANEL_DATA_DIR="/var/lib/telemt-panel"
  PANEL_SERVICE_FILE="/etc/systemd/system/${PANEL_BINARY_NAME}.service"
  PANEL_SUDOERS_FILE="/etc/sudoers.d/${PANEL_BINARY_NAME}"

  # Detect architecture
  ARCH=$(uname -m)
  case "$ARCH" in
    x86_64)  PANEL_ARCH="x86_64" ;;
    aarch64) PANEL_ARCH="aarch64" ;;
    *) error "Unsupported architecture for panel: $ARCH"; exit 1 ;;
  esac
  info "Architecture: ${PANEL_ARCH}"

  # Download latest release
  info "Fetching latest panel release..."
  PANEL_TAG=$(curl -fsSL "https://api.github.com/repos/${PANEL_REPO}/releases/latest" \
    | jq -r '.tag_name') || { error "Could not fetch panel release"; exit 1; }
  [[ -n "$PANEL_TAG" && "$PANEL_TAG" != "null" ]] || { error "Could not determine panel version"; exit 1; }
  info "Panel version: ${PANEL_TAG}"

  PANEL_TARBALL="telemt-panel-${PANEL_ARCH}-linux-gnu.tar.gz"
  PANEL_URL="https://github.com/${PANEL_REPO}/releases/download/${PANEL_TAG}/${PANEL_TARBALL}"

  PANEL_TMP=$(mktemp -d)
  trap "rm -rf '$PANEL_TMP'" EXIT

  info "Downloading ${PANEL_TARBALL}..."
  curl -fSL "$PANEL_URL" -o "${PANEL_TMP}/${PANEL_TARBALL}" \
    || { error "Panel download failed"; exit 1; }

  # Verify checksum if available
  PANEL_CHECKSUM_URL="https://github.com/${PANEL_REPO}/releases/download/${PANEL_TAG}/checksums.txt"
  if curl -fsSL "$PANEL_CHECKSUM_URL" -o "${PANEL_TMP}/checksums.txt" 2>/dev/null; then
    EXPECTED=$(grep "$PANEL_TARBALL" "${PANEL_TMP}/checksums.txt" | awk '{print $1}')
    if [[ -n "$EXPECTED" ]]; then
      ACTUAL=$(sha256sum "${PANEL_TMP}/${PANEL_TARBALL}" | awk '{print $1}')
      if [[ "$EXPECTED" != "$ACTUAL" ]]; then
        error "Panel checksum mismatch! Expected: $EXPECTED, Got: $ACTUAL"
        exit 1
      fi
      info "Checksum verified"
    fi
  fi

  # Extract and install binary
  tar -xzf "${PANEL_TMP}/${PANEL_TARBALL}" -C "${PANEL_TMP}"
  install -m 0755 "${PANEL_TMP}/telemt-panel-${PANEL_ARCH}-linux" "$PANEL_BINARY_PATH"
  info "Installed ${PANEL_BINARY_PATH}"

  # Create system user
  if id "$PANEL_SYSTEM_USER" >/dev/null 2>&1; then
    info "System user '${PANEL_SYSTEM_USER}' already exists"
  else
    useradd --system --shell /usr/sbin/nologin --home /nonexistent "$PANEL_SYSTEM_USER"
    info "Created system user '${PANEL_SYSTEM_USER}'"
  fi

  # Join telemt group if exists
  if getent group telemt >/dev/null 2>&1; then
    usermod -aG telemt "$PANEL_SYSTEM_USER" 2>/dev/null || true
    info "Added ${PANEL_SYSTEM_USER} to telemt group"
  fi

  # Setup directories
  mkdir -p "$PANEL_CONFIG_DIR" "$PANEL_DATA_DIR/staging"
  chown "$PANEL_SYSTEM_USER:$PANEL_SYSTEM_USER" "$PANEL_CONFIG_DIR"
  chown "$PANEL_SYSTEM_USER:$PANEL_SYSTEM_USER" "$PANEL_DATA_DIR"
  chown "$PANEL_SYSTEM_USER:$PANEL_SYSTEM_USER" "$PANEL_DATA_DIR/staging"

  # Generate password hash and JWT secret
  info "Generating credentials..."
  PANEL_PASS_HASH=$(printf '%s\n' "$PANEL_ADMIN_PASS" | "$PANEL_BINARY_PATH" hash-password) \
    || { error "Failed to generate password hash"; exit 1; }
  PANEL_JWT_SECRET=$(openssl rand -hex 32)

  # Determine telemt API URL (running in Docker on host network)
  TELEMT_API_URL="http://127.0.0.1:9091"

  # Write config
  # Note: telemt runs in Docker (host network mode), managed via docker compose.
  # The panel communicates with telemt's HTTP API directly on localhost.
  # binary_path and service_name are used by the panel's update feature;
  # for Docker-based telemt they are informational only.
  cat > "$PANEL_CONFIG_FILE" <<EOF
# Telemt Panel Configuration
# Generated by MTProto installer on $(date -Iseconds)

listen = "127.0.0.1:${PANEL_INTERNAL_PORT}"

[telemt]
url = "${TELEMT_API_URL}"
# auth_header = ""
# Note: telemt runs in Docker; binary_path is for native installs only
# binary_path = "/bin/telemt"
# service_name = "telemt"
config_edit_mode = "api"

[panel]
binary_path = "${PANEL_BINARY_PATH}"
service_name = "${PANEL_BINARY_NAME}"

[auth]
username = "${PANEL_ADMIN_USER}"
password_hash = "${PANEL_PASS_HASH}"
jwt_secret = "${PANEL_JWT_SECRET}"
session_ttl = "24h"
EOF

  chown "$PANEL_SYSTEM_USER:$PANEL_SYSTEM_USER" "$PANEL_CONFIG_FILE"
  chmod 600 "$PANEL_CONFIG_FILE"
  info "Panel config written to ${PANEL_CONFIG_FILE}"

  # Install sudoers drop-in
  CP_PATH=$(command -v cp)
  MV_PATH=$(command -v mv)
  CHMOD_PATH=$(command -v chmod)
  RM_PATH=$(command -v rm)
  SYSTEMCTL_PATH=$(command -v systemctl)

  PANEL_TMP_BIN="${PANEL_BIN_DIR}/.${PANEL_BINARY_NAME}.tmp"
  PANEL_BACKUP="${PANEL_DATA_DIR}/staging/${PANEL_BINARY_NAME}.bak"

  cat > "$PANEL_SUDOERS_FILE" <<EOF
# Telemt Panel updater permissions
${PANEL_SYSTEM_USER} ALL=(root) NOPASSWD: ${CP_PATH} -f ${PANEL_BINARY_PATH} ${PANEL_BACKUP}
${PANEL_SYSTEM_USER} ALL=(root) NOPASSWD: ${CP_PATH} -f ${PANEL_DATA_DIR}/staging/${PANEL_BINARY_NAME} ${PANEL_TMP_BIN}
${PANEL_SYSTEM_USER} ALL=(root) NOPASSWD: ${CHMOD_PATH} 0755 ${PANEL_TMP_BIN}
${PANEL_SYSTEM_USER} ALL=(root) NOPASSWD: ${MV_PATH} -f ${PANEL_TMP_BIN} ${PANEL_BINARY_PATH}
${PANEL_SYSTEM_USER} ALL=(root) NOPASSWD: ${RM_PATH} -f ${PANEL_TMP_BIN}
${PANEL_SYSTEM_USER} ALL=(root) NOPASSWD: ${SYSTEMCTL_PATH} restart ${PANEL_BINARY_NAME}
${PANEL_SYSTEM_USER} ALL=(root) NOPASSWD: ${SYSTEMCTL_PATH} start ${PANEL_BINARY_NAME}
EOF

  chmod 0440 "$PANEL_SUDOERS_FILE"
  # Validate sudoers syntax
  if command -v visudo >/dev/null 2>&1; then
    visudo -cf "$PANEL_SUDOERS_FILE" >/dev/null || { error "Invalid sudoers file"; rm -f "$PANEL_SUDOERS_FILE"; exit 1; }
  fi
  info "Sudoers drop-in installed"

  # Create systemd service
  cat > "$PANEL_SERVICE_FILE" <<EOF
[Unit]
Description=Telemt Panel
After=network.target

[Service]
Type=simple
User=${PANEL_SYSTEM_USER}
ExecStart=${PANEL_BINARY_PATH} --config ${PANEL_CONFIG_FILE}
Restart=on-failure
RestartSec=5
LimitNOFILE=65536

# Hardening
ProtectHome=true
PrivateTmp=true
ReadWritePaths=${PANEL_CONFIG_DIR} ${PANEL_DATA_DIR}

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable "$PANEL_BINARY_NAME"
  systemctl start "$PANEL_BINARY_NAME"
  info "Panel service started (listening on 127.0.0.1:${PANEL_INTERNAL_PORT}, published by Caddy on :${PANEL_PORT})"
fi

# ══════════════════════════════════════════════════════════════════════════════
# SUMMARY
# ══════════════════════════════════════════════════════════════════════════════

separator "Installation complete!"

SERVER_IP=$(curl -s4 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')

# Build the proxy links. telemt's public_host advertises the DOMAIN (not the raw
# IP); the FakeTLS secret is ee + 32-hex secret + hex(domain).
FAKE_TLS_SECRET="ee${TELEMT_SECRET}$(echo -n "$DOMAIN" | xxd -p | tr -d '\n')"
TG_LINK="tg://proxy?server=${DOMAIN}&port=${MTPROTO_PORT}&secret=${FAKE_TLS_SECRET}"
TME_LINK="https://t.me/proxy?server=${DOMAIN}&port=${MTPROTO_PORT}&secret=${FAKE_TLS_SECRET}"

if [[ "${MTPROTO_PORT}" == "443" ]]; then
  COVER_URL="https://${DOMAIN}/"
else
  COVER_URL="https://${DOMAIN}:${MTPROTO_PORT}/"
fi

cat <<EOF

  ────────────────────  MTProto Proxy — Ready!  ────────────
  Server IP:   ${SERVER_IP}
  Domain:      ${DOMAIN}
  Port:        ${MTPROTO_PORT}
  Secret:      ${TELEMT_SECRET}

  Telegram link (FakeTLS, uses the domain — NOT the IP):
  ${TG_LINK}

  Web form of the same link:
  ${TME_LINK}

  ! How to connect: open the link INSIDE Telegram — paste it into
    "Saved Messages" and tap it, then choose "Connect". Opening a
    t.me/proxy FakeTLS link in a plain web browser just bounces to
    telegram.org (the t.me web page can't preview FakeTLS links);
    that is normal and does NOT mean the proxy is broken.
    Manual alternative: Settings → Data and Storage → Proxy →
    Add proxy → MTProto, then server=${DOMAIN} port=${MTPROTO_PORT}
    secret=${FAKE_TLS_SECRET}

  Cover-site:  ${COVER_URL}
EOF

if [[ "${INSTALL_PANEL:-no}" == "yes" ]]; then
  cat <<EOF

  ── Panel ────────────────────────────────────────────────
  URL:         https://${DOMAIN}:${PANEL_PORT}/
  Username:    ${PANEL_ADMIN_USER}
  Password:    (as configured)
EOF
fi

cat <<EOF

  ── Management ───────────────────────────────────────────
  cd ${INSTALL_DIR} && docker compose logs -f
  cd ${INSTALL_DIR} && docker compose restart
  ──────────────────────────────────────────────────────────

EOF

info "Save your Telegram link and secret securely!"
