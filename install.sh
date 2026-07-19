#!/usr/bin/env bash
# Atlas self-host installer (Linux/macOS). The one-command way to stand up a fresh instance:
# checks Docker, CSPRNG-generates every secret into a fresh .env, brings up the self-host stack
# (containerized Caddy front door, GPU AI opt-in), waits for health, then points you at /Setup to
# create the owner account.
#
# SAFETY: refuses to run if a .env already exists - so it can never clobber a configured box. Never
# copy another instance's .env; a household's VAULT_MASTER_SECRET encrypts its OWN stored credentials.
#
# Usage:
#   ./install.sh                              # cloud-LLM (no GPU), data root /opt/atlas, host localhost
#   ./install.sh --data-root /srv/atlas       # custom data root
#   ./install.sh --domain atlas.example.com   # real host -> Caddy auto-HTTPS
#   ./install.sh --gpu                         # also start local GPU AI (ollama/kokoro/xtts/whisper)
set -euo pipefail

DATA_ROOT="/opt/atlas"
DOMAIN="localhost"
ACME_EMAIL="admin@localhost"
USE_GPU=0
AUTO_INSTALL_DOCKER=0

while [ $# -gt 0 ]; do
  case "$1" in
    --data-root) DATA_ROOT="$2"; shift 2 ;;
    --domain)    DOMAIN="$2"; shift 2 ;;
    --acme-email) ACME_EMAIL="$2"; shift 2 ;;
    --gpu)       USE_GPU=1; shift ;;
    --install-docker) AUTO_INSTALL_DOCKER=1; shift ;;   # install Docker without prompting if missing
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

step() { printf '\n\033[36m==> %s\033[0m\n' "$1"; }
ok()   { printf '    \033[32mOK\033[0m  %s\n' "$1"; }
warn() { printf '    \033[33m!\033[0m   %s\n' "$1"; }
fail() { printf '    \033[31mX\033[0m   %s\n' "$1" >&2; exit 1; }
# Ask a yes/no question; auto-yes when --install-docker was passed, no when not a TTY.
confirm() {
  [ "$AUTO_INSTALL_DOCKER" -eq 1 ] && return 0
  [ -t 0 ] || return 1
  printf '    %s [y/N] ' "$1"; read -r a; [ "$a" = "y" ] || [ "$a" = "Y" ]
}

# Ensure Docker + the compose v2 plugin exist; offer to install them per-OS if not.
ensure_docker() {
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    ok "Docker + compose plugin present"; return 0
  fi
  warn "Docker (with the 'docker compose' v2 plugin) was not found."
  local os; os="$(uname -s)"
  case "$os" in
    Linux)
      if confirm "Install Docker Engine now via the official get.docker.com script (uses sudo)?"; then
        curl -fsSL https://get.docker.com | sh || fail "Docker install failed - see https://docs.docker.com/engine/install/"
        sudo systemctl enable --now docker 2>/dev/null || true
        sudo usermod -aG docker "$USER" 2>/dev/null || true
        if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
          ok "Docker installed and running"
        else
          warn "Docker installed. Log out/in (or run 'newgrp docker') for group permissions, then re-run ./install.sh."
          exit 0
        fi
      else
        fail "Docker is required. Install it (https://docs.docker.com/engine/install/) then re-run - or pass --install-docker."
      fi
      ;;
    Darwin)
      if command -v brew >/dev/null 2>&1 && confirm "Install Docker Desktop via Homebrew?"; then
        brew install --cask docker || fail "brew install failed."
        warn "Docker Desktop installed. START it ('open -a Docker'), wait until it's running, then re-run ./install.sh."
        exit 0
      else
        fail "Install Docker Desktop for Mac (https://www.docker.com/products/docker-desktop), start it, then re-run."
      fi
      ;;
    *) fail "Unsupported OS '$os' for auto-install. Install Docker manually, then re-run." ;;
  esac
}

# --- 0. Guardrails -----------------------------------------------------------
[ -f "$ROOT/.env" ] && fail ".env already exists - this box is already configured. Refusing to overwrite. Delete it by hand only if you are CERTAIN this is a fresh install."
[ -f "$ROOT/.env.example" ] || fail ".env.example not found - run from the repo root."

# --- 1. Prerequisites --------------------------------------------------------
step "Checking prerequisites"
command -v openssl >/dev/null 2>&1 || fail "openssl not found (needed to generate secrets)."
ensure_docker

# --- 2. Generate secrets + write .env ---------------------------------------
step "Generating secrets and writing .env"
secret()      { openssl rand -base64 32 | tr -d '/+=\n'; }
sql_password() { echo "$(openssl rand -base64 24 | tr -d '/+=\n')Aa1!"; }   # SQL Server complexity rules

cp "$ROOT/.env.example" "$ROOT/.env"
set_env() {
  local key="$1" val="$2"
  # Remove any existing line for this key, then append the generated value.
  sed -i.bak "/^${key}=/d" "$ROOT/.env" && rm -f "$ROOT/.env.bak"
  printf '%s=%s\n' "$key" "$val" >> "$ROOT/.env"
}

set_env MSSQL_SA_PASSWORD               "$(sql_password)"
set_env JWT_SECRET                      "$(secret)"
set_env API_KEY                         "$(secret)"
set_env VAULT_MASTER_SECRET             "$(secret)"
set_env GMESSAGES_INGEST_SECRET         "$(secret)"
set_env ATLAS_MUSIC_STREAM_TOKEN_SECRET "$(secret)"
set_env TURN_SECRET                     "$(secret)"
set_env ATLAS_DATA_ROOT                 "$DATA_ROOT"
set_env ATLAS_DOMAIN                    "$DOMAIN"
set_env ATLAS_ACME_EMAIL                "$ACME_EMAIL"
chmod 600 "$ROOT/.env"
ok ".env written with fresh secrets"
warn "BACK UP .env NOW (especially VAULT_MASTER_SECRET) - losing it makes all stored credentials unrecoverable."

# --- 3. Data root + bring the stack up --------------------------------------
step "Creating data root at $DATA_ROOT"
mkdir -p "$DATA_ROOT" && ok "$DATA_ROOT ready"

step "Bringing up the stack (this can take a few minutes on first build)"
COMPOSE=(docker compose -f docker-compose.yml -f docker-compose.selfhost.yml)
[ "$USE_GPU" -eq 1 ] && COMPOSE+=(--profile gpu)
# Default: PULL public images from GHCR (a household has no source tree). --build is for source (dev).
if [ "${BUILD:-0}" -eq 1 ]; then "${COMPOSE[@]}" up -d --build || fail "docker compose up --build failed."
else "${COMPOSE[@]}" up -d || fail "docker compose up failed - if you have no source, images must be PUBLIC on GHCR; else re-run with BUILD=1."; fi
ok "Containers started"

# --- 4. Health gate ----------------------------------------------------------
step "Waiting for the API to become healthy"
healthy=0
for _ in $(seq 1 40); do
  if docker exec atlas-atlas-api-1 sh -lc "curl -fsS -m 4 http://localhost:8080/Atlas/api/ping" >/dev/null 2>&1; then
    healthy=1; break
  fi
  sleep 6
done
if [ "$healthy" -eq 1 ]; then ok "API is healthy"; else warn "API not healthy yet. Check: ${COMPOSE[*]} logs atlas-api"; fi

# --- 5. Done -----------------------------------------------------------------
step "Done"
base="http://localhost/Atlas"
[ "$DOMAIN" != "localhost" ] && base="https://$DOMAIN/Atlas"
cat <<EOF

  Atlas is up. Open it in your browser and register the FIRST account - it becomes the
  owner (superadmin):

    ${base}/           (register the owner account, then add your Anthropic key in Settings)

  Remote access (optional): add a Tailscale or Cloudflare Tunnel sidecar - see deploy/selfhost/README.md.
  GPU AI (optional): re-run with --gpu, or 'docker compose -f docker-compose.yml -f docker-compose.selfhost.yml --profile gpu up -d'.
EOF
