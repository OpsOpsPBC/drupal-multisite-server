# Multi-Site Drupal Deployment & Infrastructure Documentation

**GitHub Organization:** `your-org`
**Infrastructure Repository:** `https://github.com/your-org/drupal-multisite-server`

**Server:** `web-server-01`
**Stack:** Ubuntu 24.04 LTS · Nginx · PHP-FPM 8.4 · MySQL/MariaDB · Drupal
**Last updated:** 2026-10-03

---

## 1. Multi-Site Architecture Overview

The server hosts multiple independent websites, each with dedicated **live** and **staging** environments following a standardized zero-downtime atomic deployment structure:

```text
/var/www/
├── {repo_name}/
│   ├── live/
│   │   ├── current -> releases/<timestamp>
│   │   ├── releases/
│   │   │   ├── <timestamp_1>/
│   │   │   └── <timestamp_2>/
│   │   ├── shared/
│   │   │   ├── files/          # Persistent user uploads (linked to current/web/sites/default/files)
│   │   │   ├── private/        # Persistent private uploads
│   │   │   └── settings.php    # Persistent live DB credentials and settings
│   │   └── backups/
│   │       └── db_<timestamp>.sql.gz
│   └── staging/
│       ├── current -> releases/<timestamp>
│       ├── releases/
│       ├── shared/
│       │   ├── files/
│       │   ├── private/
│       │   └── settings.php    # Persistent staging DB credentials and settings
│       └── backups/
```

### Environments & Branch Mapping

| Environment | Branch | Server Path | Document Root | Database |
|---|---|---|---|---|
| **Live** | `main` | `/var/www/{repo_name}/live` | `/var/www/{repo_name}/live/current/web` | `{repo_name}_live` |
| **Staging** | `staging` | `/var/www/{repo_name}/staging` | `/var/www/{repo_name}/staging/current/web` | `{repo_name}_staging` |

---

## 2. CI/CD Pipeline (GitHub Actions)

Deployments are automated via `.github/workflows/deploy.yml`. A ready-to-use starter workflow template is provided in this repository at [`templates/deploy.yml`](../templates/deploy.yml).

- Push to `main` → deploys to **live** (`/var/www/{repo_name}/live`)
- Push to `staging` → deploys to **staging** (`/var/www/{repo_name}/staging`)
- Manual trigger via `workflow_dispatch` (select branch `main` or `staging`)

### Pipeline Execution Steps

1. **Build Artifact (`build` job)**:
   - Sets up PHP 8.4 and Composer v2.
   - Caches composer dependencies.
   - Runs `composer install --no-dev --optimize-autoloader`.
   - Packages codebase into an archive, excluding `.git`, `.github`, `tests`, local settings, and uploads.
   - Uploads artifact to GitHub Actions storage.

2. **Deploy on Server (`deploy` job)**:
   - Target environment and path are computed automatically from `${{ github.ref_name }}`:
     - `TARGET_ENV`: `live` (if `main`) or `staging` (if `staging`).
     - `DEPLOY_PATH`: `/var/www/${{ github.event.repository.name }}/${{ env.TARGET_ENV }}`.
     - `REMOTE_TARBALL`: `/tmp/deploy-${{ github.event.repository.name }}-${{ env.TARGET_ENV }}-${{ github.run_id }}.tar.gz` (collision-free).
   - Establishes SSH connection using ControlMaster multiplexing.
   - Transfers archive to the remote server via SCP.
   - Executes deployment script over SSH:
     1. Creates timestamped release: `${DEPLOY_PATH}/releases/${TIMESTAMP}`.
     2. Extracts release archive.
     3. Symlinks `${DEPLOY_PATH}/shared/files` to `web/sites/default/files`.
     4. Symlinks `${DEPLOY_PATH}/shared/settings.php` to `web/sites/default/settings.php`.
     5. Sets permissions for `config/sync/` (775).
     6. Atomically flips `${DEPLOY_PATH}/current` symlink to the new release.
     7. Creates pre-deploy DB backup using Drush from the previous release.
     8. Runs `drush deploy -y -v` (database updates, config import, cache rebuild).
     9. **Rolls back symlink** automatically if `drush deploy` fails.
     10. Reloads PHP-FPM (`sudo systemctl reload php8.4-fpm`).
     11. Prunes old releases and DB backups (retaining the last 5).
     12. Deletes temporary upload tarball.
   - Runs optional HTTP health check against `HEALTH_URL`.

### GitHub Secrets & Environments

Secrets should be configured per repository under **Settings** → **Secrets and variables** → **Actions** (or scoped per environment) to isolate access across different sites:

| Secret | Purpose | Recommended Scope |
|---|---|---|
| `SSH_HOST` | Server IP or hostname | Repository secret |
| `SSH_USER` | Deploy user (`deploy`) | Repository secret |
| `SSH_PRIVATE_KEY` | Deploy SSH private key | Repository secret |
| `SSH_KNOWN_HOSTS` | Server host key entry (`ssh-keyscan -H <IP>`) | Repository secret |
| `HEALTH_URL` | Site health check URL (optional) | Environment secret (`live` vs `staging`) |

> **Security Note:** Scoping SSH credentials per repository avoids cross-tenant lateral movement in the event that an individual repository or developer account is compromised.

### Rollback Procedures

If an issue occurs after a deploy, roll back by re-pointing the symlink:

```bash
# Example: Roll back example.com live
ssh deploy@<server_ip>
ln -sfn /var/www/example.com/live/releases/<previous_timestamp> /var/www/example.com/live/current
sudo systemctl reload php8.4-fpm
cd /var/www/example.com/live/current && ./vendor/bin/drush cr
```

---

## 3. Site Provisioning Automation

To onboard a new website or environment on the droplet, use the automated provisioning script from the `server-infrastructure` repository.

### One-Command Provisioning

```bash
# Provision a new site environment
# Note: <repo_name> must be the bare repository name (e.g. example.com), NOT org/repo_name.
sudo provision-drupal-site <repo_name> <live|staging> <domain> [certbot_email]

# Examples:
sudo provision-drupal-site example.com live example.com admin@example.com
sudo provision-drupal-site example.com staging staging.example.com admin@example.com
```

### Initial Deployment & Database Onboarding

`provision-drupal-site` creates an empty MySQL database. When the first GitHub Actions deployment runs, `drush deploy` requires an initialized Drupal site matching your codebase and `config/sync`.

1. **Trigger first deployment** via GitHub Actions (or let it extract code).
2. **Import your initial database** (e.g. from local DDEV):
   ```bash
   # On local machine:
   ddev export-db --file=./init.sql.gz
   scp ./init.sql.gz deploy@<server_ip>:~/init.sql.gz
   rm -f ./init.sql.gz

   # On the server:
   cd /var/www/<repo_name>/<env>/current
   gunzip -c ~/init.sql.gz | ./vendor/bin/drush sql:cli
   ./vendor/bin/drush deploy -v
   sudo systemctl reload php8.4-fpm
   rm -f ~/init.sql.gz
   ```
3. **Sync initial media / public files** (from local machine):
   ```bash
   rsync -avz --progress web/sites/default/files/ deploy@<server_ip>:/var/www/<repo_name>/<env>/shared/files/ \
     --exclude='php/' \
     --exclude='css/' \
     --exclude='js/' \
     --exclude='styles/'
   ```
4. All future pushes to `main` (for live) or `staging` (for staging) will deploy automatically via CI/CD!

### What Provisioning Does Automatically:
1. Creates directory structure: `shared/files`, `shared/private`, `backups`, `releases`.
2. Creates bootstrap release so Nginx testing and Let's Encrypt validation succeed immediately.
3. Provisions isolated MySQL database and user (`{repo_name}_{env}`).
4. Generates persistent `shared/settings.php` with database credentials, `hash_salt`, and trusted host patterns.
5. Sets Linux ownership (`deploy:www-data`) and permissions (`setgid` on upload directories).
6. Configures `/etc/nginx/sites-available/{repo_name}_{env}` including shared `/etc/nginx/snippets/drupal.conf` (automatically injecting `X-Robots-Tag: noindex, nofollow, noarchive, nosnippet` for staging environments).
7. Tests Nginx syntax and reloads Nginx.
8. Provisions free SSL certificates via Certbot.

---

## 4. Configuration Management

- Config lives in the repository at `config/sync/`.
- In `shared/settings.php`:
  ```php
  $settings['config_sync_directory'] = '../config/sync';
  ```
- **Workflow**:
  1. Make changes in local environment (DDEV).
  2. Export config: `ddev drush cex -y`.
  3. Commit and push: `git commit -am "Update config" && git push`.
  4. GitHub Actions runs `drush deploy -y` which imports changes cleanly.
- Never edit active configuration directly in production without exporting it, as it will be overwritten on next deploy.

---

## 5. Access & Security

### Users & Permissions

| User | Purpose | Access |
|---|---|---|
| `deploy` | SSH deploy & administration | Key-only authentication; sudo access |
| `www-data` | Web server runtime | No shell / system user |
| `root` | Emergency only | SSH disabled; DigitalOcean console only |

### SSH Hardening (`/etc/ssh/sshd_config`)

```bash
PermitRootLogin no
PasswordAuthentication no
```

### Sudoers Configuration (`/etc/sudoers.d/deploy`)

For security and least privilege, the automated deploy user is restricted to only reloading web services and validating Nginx configurations:

```bash
# Passwordless service reloads for CI/CD automation (Ubuntu 24.04 uses /usr/bin/systemctl)
deploy ALL=(ALL) NOPASSWD: /usr/bin/systemctl reload php8.4-fpm, /usr/bin/systemctl restart php8.4-fpm, /usr/bin/systemctl reload nginx, /usr/sbin/nginx -t, /bin/systemctl reload php8.4-fpm, /bin/systemctl restart php8.4-fpm, /bin/systemctl reload nginx
```

### Fail2ban

Protects SSH from brute-force attempts:
```bash
# Check status
sudo fail2ban-client status sshd

# Unban an IP
sudo fail2ban-client set sshd unbanip <your_ip>
```

---

## 6. Database Management

### Manual DB Dump & Restore

```bash
# Export from live directly into the protected backups directory
cd /var/www/example.com/live/current
./vendor/bin/drush sql:dump --gzip --structure-tables-key=common --result-file=/var/www/example.com/live/backups/manual_backup_$(date +%s).sql.gz

# Sync live DB to local DDEV via SSH pipe (avoids intermediate server files)
ssh deploy@<server_ip> "cd /var/www/example.com/live/current && ./vendor/bin/drush sql:dump --gzip --structure-tables-key=common" > ./dump.sql.gz
ddev import-db --src=./dump.sql.gz
rm -f ./dump.sql.gz
ddev drush cr && ddev drush uli
```

### Refresh Staging from Live

You can stream the live database directly into staging without temporary files:

```bash
# 1. Direct stream database from live to staging
cd /var/www/example.com/live/current
./vendor/bin/drush sql:dump | /var/www/example.com/staging/current/vendor/bin/drush sql:cli

# 2. Sync public upload files from live to staging
rsync -avz --progress /var/www/example.com/live/shared/files/ /var/www/example.com/staging/shared/files/ \
  --exclude='php/' \
  --exclude='css/' \
  --exclude='js/' \
  --exclude='styles/'

# 3. Apply updates & clear cache on staging
cd /var/www/example.com/staging/current
./vendor/bin/drush deploy -v
sudo systemctl reload php8.4-fpm
```

### Sync Files to/from Local Environment (DDEV)

Run from your local project root:

```bash
# Local -> Live
rsync -avz --progress web/sites/default/files/ deploy@<server_ip>:/var/www/example.com/live/shared/files/ \
  --exclude='php/' \
  --exclude='css/' \
  --exclude='js/' \
  --exclude='styles/'

# Live -> Local
rsync -avz --progress deploy@<server_ip>:/var/www/example.com/live/shared/files/ web/sites/default/files/ \
  --exclude='php/' \
  --exclude='css/' \
  --exclude='js/' \
  --exclude='styles/'
```

---

## 7. Maintenance Runbook

| Task | Command |
|---|---|
| Check current symlink | `readlink -f /var/www/{repo_name}/{env}/current` |
| List releases | `ls -1dt /var/www/{repo_name}/{env}/releases/*/` |
| Rollback symlink | `ln -sfn /var/www/{repo_name}/{env}/releases/<ts> /var/www/{repo_name}/{env}/current && sudo systemctl reload php8.4-fpm` |
| Clear OPcache | `sudo systemctl reload php8.4-fpm` |
| Clear Drupal cache | `cd /var/www/{repo_name}/{env}/current && ./vendor/bin/drush cr` |
| View Nginx error logs | `sudo tail -f /var/log/nginx/{repo_name}_{env}_error.log` |
| Test Nginx config | `sudo nginx -t` |
| Reload Nginx | `sudo systemctl reload nginx` |
| Check disk space | `df -h` |
| Provision new site | `sudo provision-drupal-site <repo_name> <live\|staging> <domain> [email]` |
