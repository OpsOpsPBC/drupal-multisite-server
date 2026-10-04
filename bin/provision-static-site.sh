#!/usr/bin/env bash
set -euo pipefail

# Provision a new static website environment on the server.
#
# Usage:
#   sudo ./provision-static-site.sh <repo_name> <environment: live|staging> <domain> [certbot_email]
#
# Examples:
#   sudo ./provision-static-site.sh docs.example.com live docs.example.com admin@example.com
#   sudo ./provision-static-site.sh docs.example.com staging staging-docs.example.com admin@example.com

if [ "$EUID" -ne 0 ]; then
  echo "Error: this script must be run as root (or with sudo)." >&2
  exit 1
fi

REPO_NAME="${1:-}"
ENV="${2:-}"
DOMAIN="${3:-}"
SSL_EMAIL="${4:-}"

DEPLOY_USER="deploy"
WEB_GROUP="www-data"

if [[ -z "$REPO_NAME" || -z "$ENV" || -z "$DOMAIN" ]]; then
  echo "Usage: sudo $0 <repo_name> <environment: live|staging> <domain> [certbot_email]" >&2
  exit 1
fi

# Input validation
if [[ ! "$REPO_NAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]]; then
  echo "Error: Invalid repo_name '$REPO_NAME'. Must only contain alphanumeric characters, dots, hyphens, and underscores." >&2
  exit 1
fi

if [[ "$ENV" != "live" && "$ENV" != "staging" ]]; then
  echo "Error: environment must be 'live' or 'staging'" >&2
  exit 1
fi

if [[ ! "$DOMAIN" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)+$ ]]; then
  echo "Error: Invalid domain format '$DOMAIN'." >&2
  exit 1
fi

if [[ -n "$SSL_EMAIL" && ! "$SSL_EMAIL" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
  echo "Error: Invalid email format '$SSL_EMAIL'." >&2
  exit 1
fi

SITE_ID="${REPO_NAME}_${ENV}"
SITE_DIR="/var/www/${REPO_NAME}/${ENV}"
RELEASES_DIR="${SITE_DIR}/releases"
WEB_ROOT="${SITE_DIR}/current"

echo "==> [1/5] Setting up directory skeleton under ${SITE_DIR}..."
mkdir -p "${RELEASES_DIR}"

# Pre-create bootstrap placeholder release so Nginx test and Certbot validation succeed before first code deploy
if [ ! -L "${SITE_DIR}/current" ] && [ ! -d "${SITE_DIR}/current" ]; then
  BOOTSTRAP_RELEASE="${RELEASES_DIR}/bootstrap"
  mkdir -p "${BOOTSTRAP_RELEASE}"
  cat > "${BOOTSTRAP_RELEASE}/index.html" <<HTML
<!DOCTYPE html>
<html>
<head><title>Provisioned - ${REPO_NAME} (${ENV})</title></head>
<body style="font-family:sans-serif; text-align:center; padding: 50px;">
  <h1>Static Site Ready</h1>
  <p>${REPO_NAME} (<em>${ENV}</em>) has been provisioned. Awaiting initial deployment via GitHub Actions.</p>
</body>
</html>
HTML
  ln -sfn "${BOOTSTRAP_RELEASE}" "${SITE_DIR}/current"
fi

echo "==> [2/5] Applying permissions..."
chown -R "${DEPLOY_USER}:${WEB_GROUP}" "${SITE_DIR}"
chmod 755 "${SITE_DIR}" "${RELEASES_DIR}"

echo "==> [3/5] Ensuring Nginx static snippet exists..."
if [ ! -f /etc/nginx/snippets/static.conf ]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  SNIPPET_SRC="${SCRIPT_DIR}/../nginx/snippets/static.conf"
  if [ -f "$SNIPPET_SRC" ]; then
    mkdir -p /etc/nginx/snippets
    cp "$SNIPPET_SRC" /etc/nginx/snippets/static.conf
  else
    echo "::warning::/etc/nginx/snippets/static.conf is missing. Please ensure it is installed."
  fi
fi

echo "==> [4/5] Generating and enabling Nginx virtual host..."
NGINX_AVAILABLE="/etc/nginx/sites-available/${SITE_ID}"
NGINX_ENABLED="/etc/nginx/sites-enabled/${SITE_ID}"

STAGING_HEADER=""
if [[ "$ENV" == "staging" ]]; then
  STAGING_HEADER="$(cat <<'EOF'

    # Prevent search engines from indexing staging environments
    add_header X-Robots-Tag "noindex, nofollow, noarchive, nosnippet" always;
EOF
)"
fi

cat > "$NGINX_AVAILABLE" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};
    server_tokens off;

    root ${WEB_ROOT};
${STAGING_HEADER}
    include snippets/static.conf;

    access_log /var/log/nginx/${SITE_ID}_access.log;
    error_log  /var/log/nginx/${SITE_ID}_error.log error;
}
EOF

ln -sfn "$NGINX_AVAILABLE" "$NGINX_ENABLED"
nginx -t
systemctl reload nginx

echo "==> [5/5] Checking SSL (Certbot)..."
if [[ -n "$SSL_EMAIL" ]]; then
  if command -v certbot >/dev/null 2>&1; then
    echo "  Requesting Let's Encrypt certificate for ${DOMAIN}..."
    certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos -m "$SSL_EMAIL" --redirect || {
      echo "::warning::Certbot failed to obtain SSL certificate. Check DNS records and run certbot manually."
    }
  else
    echo "::warning::Certbot not found. Install certbot to enable SSL automation."
  fi
else
  echo "  No SSL email provided; skipping Certbot. Run 'sudo certbot --nginx -d ${DOMAIN}' when ready."
fi

echo ""
echo "=========================================================="
echo " Static Site Provisioning complete!"
echo "   Site ID:       ${SITE_ID}"
echo "   Domain:        http://${DOMAIN}"
echo "   Directory:     ${SITE_DIR}"
echo "   Document Root: ${WEB_ROOT}"
echo "   Nginx Conf:    ${NGINX_AVAILABLE}"
echo "=========================================================="
