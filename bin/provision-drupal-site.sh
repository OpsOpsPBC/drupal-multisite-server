#!/usr/bin/env bash
set -euo pipefail

# Provision a new Drupal website environment on the server.
#
# Usage:
#   sudo ./provision-drupal-site.sh <repo_name> <environment: live|staging> <domain> [certbot_email]
#
# Examples:
#   sudo ./provision-drupal-site.sh example.com live example.com admin@example.com
#   sudo ./provision-drupal-site.sh example.com staging staging.example.com admin@example.com

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
PHP_VERSION="8.4"

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
SHARED_DIR="${SITE_DIR}/shared"
BACKUPS_DIR="${SITE_DIR}/backups"
RELEASES_DIR="${SITE_DIR}/releases"
WEB_ROOT="${SITE_DIR}/current/web"

echo "==> [1/7] Setting up directory skeleton under ${SITE_DIR}..."
mkdir -p "${SHARED_DIR}/files" "${SHARED_DIR}/private" "${BACKUPS_DIR}" "${RELEASES_DIR}"

# Pre-create bootstrap placeholder release so Nginx test and Certbot validation succeed before first code deploy
if [ ! -L "${SITE_DIR}/current" ] && [ ! -d "${SITE_DIR}/current" ]; then
  BOOTSTRAP_RELEASE="${RELEASES_DIR}/bootstrap"
  mkdir -p "${BOOTSTRAP_RELEASE}/web"
  cat > "${BOOTSTRAP_RELEASE}/web/index.html" <<HTML
<!DOCTYPE html>
<html>
<head><title>Provisioned - ${REPO_NAME} (${ENV})</title></head>
<body style="font-family:sans-serif; text-align:center; padding: 50px;">
  <h1>Environment Ready</h1>
  <p>${REPO_NAME} (<em>${ENV}</em>) has been provisioned. Awaiting initial deployment via GitHub Actions.</p>
</body>
</html>
HTML
  ln -sfn "${BOOTSTRAP_RELEASE}" "${SITE_DIR}/current"
fi

echo "==> [2/7] Configuring MySQL database and user..."
CLEAN_REPO="${REPO_NAME//[.-]/_}"
DB_NAME="${CLEAN_REPO}_${ENV}"
DB_NAME="${DB_NAME:0:64}"

# MySQL allows usernames up to 32 characters.
# If DB_NAME exceeds 32 chars, use a deterministic hash suffix to avoid collisions.
if [ "${#DB_NAME}" -le 32 ]; then
  DB_USER="${DB_NAME}"
else
  DB_HASH="$(echo -n "${DB_NAME}" | md5sum | cut -c1-8)"
  DB_USER="${DB_NAME:0:23}_${DB_HASH}"
fi
DB_PASS="$(openssl rand -base64 18 | tr -dc 'a-zA-Z0-9' | head -c 20)"

mysql <<EOF
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
EOF

echo "==> [3/7] Generating persistent settings.php..."
SETTINGS_FILE="${SHARED_DIR}/settings.php"
if [ -f "$SETTINGS_FILE" ]; then
  echo "  $SETTINGS_FILE already exists, keeping current database credentials."
else
  HASH_SALT="$(openssl rand -hex 32)"
  cat > "$SETTINGS_FILE" <<EOF
<?php
// Auto-generated persistent settings for ${REPO_NAME} (${ENV})

\$databases['default']['default'] = [
  'database' => '${DB_NAME}',
  'username' => '${DB_USER}',
  'password' => '${DB_PASS}',
  'prefix' => '',
  'host' => 'localhost',
  'port' => '3306',
  'namespace' => 'Drupal\\\\mysql\\\\Driver\\\\Database\\\\mysql',
  'driver' => 'mysql',
  'autoload' => 'core/modules/mysql/src/Driver/Database/mysql/',
];

\$settings['hash_salt'] = '${HASH_SALT}';
\$settings['update_free_access'] = FALSE;
\$settings['file_public_path'] = 'sites/default/files';
\$settings['file_private_path'] = '${SHARED_DIR}/private';
\$settings['config_sync_directory'] = '../config/sync';

\$settings['trusted_host_patterns'] = [
  '^${DOMAIN//./\\.}$',
  '^www\\.${DOMAIN//./\\.}$',
];

if (file_exists(__DIR__ . '/settings.local.php')) {
  include __DIR__ . '/settings.local.php';
}
EOF
  chown "${DEPLOY_USER}:${WEB_GROUP}" "$SETTINGS_FILE"
  chmod 440 "$SETTINGS_FILE"
fi

echo "==> [4/7] Applying permissions..."
chown -R "${DEPLOY_USER}:${WEB_GROUP}" "${SITE_DIR}"
chmod 755 "${SITE_DIR}" "${SHARED_DIR}" "${RELEASES_DIR}"
chmod 775 "${SHARED_DIR}/files" "${SHARED_DIR}/private"
chmod g+s "${SHARED_DIR}/files" "${SHARED_DIR}/private"

# Restrict backups directory to deploy user only (web server does not need access)
chown "${DEPLOY_USER}:${DEPLOY_USER}" "${BACKUPS_DIR}"
chmod 700 "${BACKUPS_DIR}"

echo "==> [5/7] Ensuring Nginx Drupal snippet exists..."
if [ ! -f /etc/nginx/snippets/drupal.conf ]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  SNIPPET_SRC="${SCRIPT_DIR}/../nginx/snippets/drupal.conf"
  if [ -f "$SNIPPET_SRC" ]; then
    mkdir -p /etc/nginx/snippets
    cp "$SNIPPET_SRC" /etc/nginx/snippets/drupal.conf
  else
    echo "::warning::/etc/nginx/snippets/drupal.conf is missing. Please ensure it is installed."
  fi
fi

echo "==> [6/7] Generating and enabling Nginx virtual host..."
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
    include snippets/drupal.conf;

    access_log /var/log/nginx/${SITE_ID}_access.log;
    error_log  /var/log/nginx/${SITE_ID}_error.log error;
}
EOF

ln -sfn "$NGINX_AVAILABLE" "$NGINX_ENABLED"
nginx -t
systemctl reload nginx

echo "==> [7/7] Checking SSL (Certbot)..."
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
echo " Provisioning complete!"
echo "   Site ID:       ${SITE_ID}"
echo "   Domain:        http://${DOMAIN}"
echo "   Directory:     ${SITE_DIR}"
echo "   Document Root: ${WEB_ROOT}"
echo "   Database:      ${DB_NAME}"
echo "   DB User:       ${DB_USER}"
echo "   Nginx Conf:    ${NGINX_AVAILABLE}"
echo "=========================================================="
