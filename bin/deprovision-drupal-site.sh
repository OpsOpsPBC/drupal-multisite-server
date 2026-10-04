#!/usr/bin/env bash
set -euo pipefail

# Safely deprovision and clean up an existing site environment.
#
# Usage:
#   sudo ./deprovision-drupal-site.sh <repo_name> <environment: live|staging> [--drop-db]
#
# Example:
#   sudo ./deprovision-drupal-site.sh old-site staging --drop-db

if [ "$EUID" -ne 0 ]; then
  echo "Error: this script must be run as root (or with sudo)." >&2
  exit 1
fi

REPO_NAME="${1:-}"
ENV="${2:-}"
FLAG="${3:-}"

if [[ -z "$REPO_NAME" || -z "$ENV" ]]; then
  echo "Usage: sudo $0 <repo_name> <environment: live|staging> [--drop-db]" >&2
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

if [[ -n "$FLAG" && "$FLAG" != "--drop-db" ]]; then
  echo "Error: Unknown flag '$FLAG'. Supported options: --drop-db" >&2
  exit 1
fi

SITE_ID="${REPO_NAME}_${ENV}"
SITE_DIR="/var/www/${REPO_NAME}/${ENV}"

# Ensure SITE_DIR is within /var/www and not root or empty
if [[ "$SITE_DIR" != /var/www/* || "$SITE_DIR" == "/var/www" || "$SITE_DIR" == "/var/www/" ]]; then
  echo "Error: Invalid target path: $SITE_DIR" >&2
  exit 1
fi

NGINX_AVAILABLE="/etc/nginx/sites-available/${SITE_ID}"
NGINX_ENABLED="/etc/nginx/sites-enabled/${SITE_ID}"

CLEAN_REPO="${REPO_NAME//[.-]/_}"
DB_NAME="${CLEAN_REPO}_${ENV}"
DB_NAME="${DB_NAME:0:64}"

# Attempt to extract exact database username from settings.php if it exists
EXTRACTED_USER=""
if [ -f "${SITE_DIR}/shared/settings.php" ]; then
  EXTRACTED_USER="$(grep -E "'username'\s*=>\s*'" "${SITE_DIR}/shared/settings.php" | head -n1 | sed -E "s/.*'username'\s*=>\s*'([^']+)'.*/\1/" || true)"
fi

if [[ -n "$EXTRACTED_USER" ]]; then
  DB_USER="$EXTRACTED_USER"
elif [ "${#DB_NAME}" -le 32 ]; then
  DB_USER="${DB_NAME}"
else
  DB_HASH="$(echo -n "${DB_NAME}" | md5sum | cut -c1-8)"
  DB_USER="${DB_NAME:0:23}_${DB_HASH}"
fi

echo "Preparing to deprovision site: ${SITE_ID}"
read -rp "Are you SURE you want to remove ${SITE_DIR}? [y/N]: " CONFIRM
if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
  echo "Aborted."
  exit 0
fi

# 1. Disable and remove Nginx configuration
if [ -L "$NGINX_ENABLED" ] || [ -f "$NGINX_ENABLED" ]; then
  echo "==> Disabling Nginx site..."
  rm -f "$NGINX_ENABLED"
fi

if [ -f "$NGINX_AVAILABLE" ]; then
  echo "==> Removing Nginx configuration..."
  rm -f "$NGINX_AVAILABLE"
  nginx -t && systemctl reload nginx
fi

# 2. Database cleanup (optional flag)
if [ "$FLAG" = "--drop-db" ]; then
  echo "==> Dropping database ${DB_NAME} and user ${DB_USER}..."
  mysql <<EOF
DROP DATABASE IF EXISTS \`${DB_NAME}\`;
DROP USER IF EXISTS '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
EOF
else
  echo "==> Preserving database ${DB_NAME} (use --drop-db to delete)."
fi

# 3. Remove filesystem directory
if [ -d "$SITE_DIR" ]; then
  echo "==> Removing directory ${SITE_DIR}..."
  rm -rf "$SITE_DIR"
fi

# Check if parent repo directory is empty and remove if so
PARENT_DIR="/var/www/${REPO_NAME}"
if [ -d "$PARENT_DIR" ] && [ -z "$(ls -A "$PARENT_DIR")" ]; then
  rmdir "$PARENT_DIR"
fi

echo "==> Deprovisioning complete for ${SITE_ID}."
