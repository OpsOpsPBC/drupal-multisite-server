#!/usr/bin/env bash
set -euo pipefail

# Initial server bootstrap script for Ubuntu 24.04 LTS (DigitalOcean Droplet)
# Run once when provisioning a fresh server.

if [ "$EUID" -ne 0 ]; then
  echo "Error: this script must be run as root." >&2
  exit 1
fi

echo "==> [1/6] Updating apt packages..."
apt-get update && apt-get upgrade -y
apt-get install -y curl git ufw fail2ban unzip software-properties-common ca-certificates lsb-release

echo "==> [2/6] Adding Ondřej Surý PHP repository..."
add-apt-repository -y ppa:ondrej/php
apt-get update

echo "==> [3/6] Installing Nginx, MySQL, PHP 8.4, and Certbot..."
apt-get install -y \
  nginx \
  mysql-server \
  php8.4-fpm \
  php8.4-cli \
  php8.4-mbstring \
  php8.4-xml \
  php8.4-curl \
  php8.4-gd \
  php8.4-zip \
  php8.4-intl \
  php8.4-bcmath \
  php8.4-mysql \
  php8.4-opcache \
  certbot \
  python3-certbot-nginx

echo "==> [4/6] Setting up deploy user..."
if ! id -u deploy >/dev/null 2>&1; then
  useradd -m -s /bin/bash deploy
  usermod -aG www-data deploy
  echo "Deploy user created. Make sure to add authorized SSH keys to /home/deploy/.ssh/authorized_keys."
fi

# Ensure deploy user's SSH folder has correct permissions
mkdir -p /home/deploy/.ssh
chmod 700 /home/deploy/.ssh
touch /home/deploy/.ssh/authorized_keys
chmod 600 /home/deploy/.ssh/authorized_keys
chown -R deploy:deploy /home/deploy/.ssh

echo "==> [5/6] Installing sudoers rules..."
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "${SCRIPT_DIR}/sudoers-deploy" ]; then
  cp "${SCRIPT_DIR}/sudoers-deploy" /etc/sudoers.d/deploy
  chmod 440 /etc/sudoers.d/deploy
fi

echo "==> [6/6] Configuring firewall (UFW) and Fail2ban..."
ufw allow OpenSSH
ufw allow 'Nginx Full'
ufw --force enable

# Ubuntu 24.04 uses systemd-journald without rsyslog by default.
# Configure Fail2ban to use the systemd backend for SSH monitoring.
mkdir -p /etc/fail2ban
cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
backend = systemd

[sshd]
enabled = true
port = ssh
maxretry = 5
findtime = 600
bantime = 3600
EOF
systemctl enable fail2ban
systemctl restart fail2ban || true

echo "==> Installing global Drupal Nginx snippet..."
mkdir -p /etc/nginx/snippets
if [ -f "${SCRIPT_DIR}/../nginx/snippets/drupal.conf" ]; then
  cp "${SCRIPT_DIR}/../nginx/snippets/drupal.conf" /etc/nginx/snippets/drupal.conf
fi

echo "==> Installing logrotate rule for Drupal sites..."
if [ -f "${SCRIPT_DIR}/logrotate-drupal-sites" ]; then
  cp "${SCRIPT_DIR}/logrotate-drupal-sites" /etc/logrotate.d/drupal-sites
fi

echo "=========================================================="
echo " Server initialization complete!"
echo " Next steps:"
echo " 1. Add your SSH keys to /home/deploy/.ssh/authorized_keys"
echo " 2. Disable root SSH & password authentication in /etc/ssh/sshd_config"
echo " 3. Symlink provision-drupal-site.sh into /usr/local/bin/"
echo "=========================================================="
