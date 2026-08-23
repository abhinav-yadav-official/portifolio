#!/usr/bin/env bash
set -euo pipefail

HOST="${1:-${HOST:-kronos}}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

DOMAIN="${DOMAIN:-abhiyadav.in}"
DOMAIN_ALIASES="${DOMAIN_ALIASES:-www.$DOMAIN}"
WEB_ROOT="${WEB_ROOT:-/var/www/html}"
LEETDRILL_BASE_PATH="${LEETDRILL_BASE_PATH:-/leetdrill}"
LEETDRILL_ADDR="${LEETDRILL_ADDR:-127.0.0.1:8082}"
ENABLE_TLS="${ENABLE_TLS:-auto}"
SETUP_SYSTEM="${SETUP_SYSTEM:-true}"
SETUP_NGINX="${SETUP_NGINX:-true}"
FORCE_NGINX_SITE="${FORCE_NGINX_SITE:-false}"

require_local() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing local command: $1" >&2
    exit 1
  fi
}

quote() {
  printf "%q" "$1"
}

bool() {
  case "$1" in
    true|false) printf "%s" "$1" ;;
    *) echo "expected true/false, got: $1" >&2; exit 1 ;;
  esac
}

require_local ssh
require_local rsync
require_local python3

SETUP_SYSTEM="$(bool "$SETUP_SYSTEM")"
SETUP_NGINX="$(bool "$SETUP_NGINX")"
FORCE_NGINX_SITE="$(bool "$FORCE_NGINX_SITE")"

python3 "$ROOT/scripts/check_homepage.py"

REMOTE_USER="$(ssh "$HOST" 'id -un')"
REMOTE_GROUP="$(ssh "$HOST" 'id -gn')"

echo "deploying portifolio homepage to $HOST:$WEB_ROOT"

ssh "$HOST" \
  "SETUP_SYSTEM=$SETUP_SYSTEM REMOTE_USER=$(quote "$REMOTE_USER") REMOTE_GROUP=$(quote "$REMOTE_GROUP") WEB_ROOT=$(quote "$WEB_ROOT") bash -s" <<'REMOTE_BOOTSTRAP'
set -euo pipefail

if [ "$SETUP_SYSTEM" = true ]; then
  if ! sudo -n true >/dev/null 2>&1; then
    echo "passwordless sudo is required for first-run setup" >&2
    exit 1
  fi

  if command -v apt-get >/dev/null 2>&1; then
    packages=(ca-certificates curl rsync nginx certbot python3-certbot-nginx)
    missing=()
    for package in "${packages[@]}"; do
      if ! dpkg -s "$package" >/dev/null 2>&1; then
        missing+=("$package")
      fi
    done
    if [ "${#missing[@]}" -gt 0 ]; then
      sudo apt-get update
      sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}"
    fi
  fi
fi

sudo mkdir -p "$WEB_ROOT" /var/www/letsencrypt
sudo chown -R "$REMOTE_USER:$REMOTE_GROUP" "$WEB_ROOT"
REMOTE_BOOTSTRAP

tmp_home="/tmp/portifolio-homepage"
tmp_extra="/tmp/portifolio-extra"
ssh "$HOST" "rm -rf $(quote "$tmp_home") $(quote "$tmp_extra") && mkdir -p $(quote "$tmp_home") $(quote "$tmp_extra")"
rsync -az --delete \
  --exclude='.git/' \
  --exclude='scripts/' \
  --exclude='Taskfile.yml' \
  --exclude='README.md' \
  --exclude='.local-html/' \
  "$ROOT"/ "$HOST:$tmp_home"/

# Extra HTML hosted at the web root but kept out of the repo lives in the gitignored
# .local-html/ dir. Push it from the local working tree only; CI checkouts lack the dir,
# so a server-side manifest tells those deploys to preserve what is already live.
if [ -d "$ROOT/.local-html" ] && [ -n "$(ls -A "$ROOT/.local-html" 2>/dev/null)" ]; then
  rsync -az "$ROOT/.local-html"/ "$HOST:$tmp_extra"/
fi

ssh "$HOST" \
  "WEB_ROOT=$(quote "$WEB_ROOT") TMP_HOME=$(quote "$tmp_home") TMP_EXTRA=$(quote "$tmp_extra") bash -s" <<'REMOTE_SYNC'
set -euo pipefail
manifest="$WEB_ROOT/.local-html.manifest"

# Names to keep across deploys: union of the server manifest (written by past local
# deploys) and whatever this run is pushing from .local-html/.
declare -A protect=()
if sudo test -f "$manifest"; then
  while IFS= read -r name; do
    [ -n "$name" ] && protect["$name"]=1
  done < <(sudo cat "$manifest")
fi
if [ -d "$TMP_EXTRA" ]; then
  for f in "$TMP_EXTRA"/*; do
    [ -e "$f" ] && protect["$(basename "$f")"]=1
  done
fi

# tutorials/ now lives on the web root via the separate almostturingcomplete/tutorials
# deploy, not this repo — --delete must not remove it just because it's gone from git.
excludes=(--exclude=shared/ --exclude=github-profile/ --exclude=tutorials/)
for name in "${!protect[@]}"; do
  excludes+=("--exclude=/$name" "--exclude=/$name.gz")
done

sudo rsync -a --delete "${excludes[@]}" "$TMP_HOME"/ "$WEB_ROOT"/

# Local deploys ship fresh copies of the extra files and refresh the manifest.
if [ -d "$TMP_EXTRA" ] && [ -n "$(ls -A "$TMP_EXTRA" 2>/dev/null)" ]; then
  sudo rsync -a "$TMP_EXTRA"/ "$WEB_ROOT"/
fi
if [ "${#protect[@]}" -gt 0 ]; then
  printf '%s\n' "${!protect[@]}" | sort -u | sudo tee "$manifest" >/dev/null
fi

sudo find "$WEB_ROOT" -maxdepth 1 -type f \( -name '*.html' -o -name '*.txt' -o -name '*.xml' -o -name '*.svg' \) -exec gzip -9 -kf {} \;
rm -rf "$TMP_HOME" "$TMP_EXTRA"
REMOTE_SYNC

if [ "$SETUP_NGINX" = true ]; then
  ssh "$HOST" \
    "DOMAIN=$(quote "$DOMAIN") DOMAIN_ALIASES=$(quote "$DOMAIN_ALIASES") WEB_ROOT=$(quote "$WEB_ROOT") LEETDRILL_BASE_PATH=$(quote "$LEETDRILL_BASE_PATH") LEETDRILL_ADDR=$(quote "$LEETDRILL_ADDR") ENABLE_TLS=$(quote "$ENABLE_TLS") FORCE_NGINX_SITE=$FORCE_NGINX_SITE LETSENCRYPT_EMAIL=$(quote "${LETSENCRYPT_EMAIL:-}") bash -s" <<'REMOTE_NGINX'
set -euo pipefail

if ! command -v nginx >/dev/null 2>&1; then
  echo "nginx is not installed on remote host" >&2
  exit 1
fi

sudo tee /etc/nginx/conf.d/static-perf.conf >/dev/null <<'NGINX_PERF'
# Static-site latency tuning for abhiyadav.in.
keepalive_timeout 65;
keepalive_requests 1000;
tcp_nodelay on;

open_file_cache max=1000 inactive=60s;
open_file_cache_valid 120s;
open_file_cache_min_uses 2;
open_file_cache_errors on;

gzip_static on;
gzip_min_length 1024;
NGINX_PERF

site="/etc/nginx/sites-available/$DOMAIN"
if [ -e "$site" ] && [ "$FORCE_NGINX_SITE" != true ]; then
  echo "$site exists; leaving existing site config in place"
else
  server_names="$DOMAIN $DOMAIN_ALIASES"
  sudo tee "$site" >/dev/null <<NGINX
server {
    listen 80;
    listen [::]:80;
    server_name $server_names;

    location /.well-known/acme-challenge/ {
        root /var/www/letsencrypt;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name $server_names;
    root $WEB_ROOT;
    error_page 403 /403.html;
    error_page 404 /404.html;
    error_page 500 502 503 504 /50x.html;

    location = /403.html {
        internal;
    }

    location = /404.html {
        internal;
    }

    location = /50x.html {
        internal;
    }

    location = / {
        add_header Cache-Control "public, max-age=300, stale-while-revalidate=86400" always;
        try_files /index.html =404;
    }

    location = /index.html {
        add_header Cache-Control "public, max-age=300, stale-while-revalidate=86400" always;
        try_files /index.html =404;
    }

    location = /resume {
        default_type application/pdf;
        add_header Cache-Control "no-store, no-cache, must-revalidate, max-age=0" always;
        add_header Pragma "no-cache" always;
        add_header Expires "0" always;
        try_files /resume.pdf =404;
    }

    location = /resume.pdf {
        default_type application/pdf;
        add_header Cache-Control "no-store, no-cache, must-revalidate, max-age=0" always;
        add_header Pragma "no-cache" always;
        add_header Expires "0" always;
        try_files /resume.pdf =404;
    }

    location = /linkedin {
        return 302 https://linkedin.com/in/abhiyd;
    }

    location = /github {
        return 302 https://github.com/almostturingcomplete;
    }

    location = $LEETDRILL_BASE_PATH {
        return 301 $LEETDRILL_BASE_PATH/;
    }

    location $LEETDRILL_BASE_PATH/ {
        proxy_pass http://$LEETDRILL_ADDR/;
        proxy_intercept_errors on;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Prefix $LEETDRILL_BASE_PATH;
    }

    location / {
        try_files \$uri \$uri/ =404;
    }
}
NGINX
  sudo ln -sfn "$site" "/etc/nginx/sites-enabled/$DOMAIN"
fi

cert_path="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
cert_exists=false
if sudo test -f "$cert_path"; then
  cert_exists=true
fi
certbot_domains=(-d "$DOMAIN")
for alias in $DOMAIN_ALIASES; do
  certbot_domains+=(-d "$alias")
done

sudo nginx -t
sudo systemctl reload nginx

if [ "$ENABLE_TLS" != false ]; then
  if [ "$cert_exists" = true ]; then
    sudo certbot --nginx --non-interactive --redirect --cert-name "$DOMAIN" "${certbot_domains[@]}"
    sudo nginx -t
    sudo systemctl reload nginx
  elif [ "$ENABLE_TLS" = true ] || [ "$ENABLE_TLS" = auto ]; then
    if [ -z "${LETSENCRYPT_EMAIL:-}" ]; then
      echo "TLS certificate missing; set LETSENCRYPT_EMAIL to let deploy run certbot" >&2
      exit 1
    fi
    sudo certbot --nginx --non-interactive --agree-tos --redirect -m "$LETSENCRYPT_EMAIL" --cert-name "$DOMAIN" "${certbot_domains[@]}"
    sudo nginx -t
    sudo systemctl reload nginx
  fi
fi
REMOTE_NGINX
fi

scheme="https"
if [ "$ENABLE_TLS" = false ]; then
  scheme="http"
fi

curl -fsS "$scheme://$DOMAIN/" >/dev/null
curl -fsS "$scheme://$DOMAIN/robots.txt" >/dev/null
echo "homepage: $scheme://$DOMAIN/"
