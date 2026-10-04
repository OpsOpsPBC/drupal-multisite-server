# Server Infrastructure for Multi-Site Drupal Hosting

Infrastructure scripts, Nginx configurations, and provisioning tools for hosting multiple Drupal websites on a single DigitalOcean Droplet (Ubuntu 24.04 LTS, PHP 8.4, Nginx, MySQL).

---

## Directory Structure

```text
drupal-multisite-server/
├── README.md
├── bin/
│   ├── provision-drupal-site.sh     # Automates new site/environment provisioning
│   └── deprovision-drupal-site.sh   # Safely tears down a site/environment
├── docs/
│   └── server-config.md             # Detailed server topology and admin guide
├── nginx/
│   ├── snippets/
│   │   └── drupal.conf              # Shared Drupal rewrites & fastcgi rules
│   └── templates/
│       └── vhost.conf.template      # Nginx server block template
├── system/
│   ├── droplet-init.sh              # One-time bootstrap for fresh servers
│   ├── sudoers-deploy               # Sudoers permissions for the deploy user
│   └── logrotate-drupal-sites       # Log rotation for Nginx site access/error logs
└── templates/
    └── deploy.yml                   # Starter GitHub Actions deployment workflow for site repos
```

---

## Server Layout

Every hosted website and environment follows an atomic deployment layout under `/var/www`:

```text
/var/www/
└── {repo_name}/
    ├── live/
    │   ├── current -> releases/<timestamp>
    │   ├── releases/
    │   │   └── <timestamp>/
    │   ├── shared/
    │   │   ├── files/          # User-uploaded files (public)
    │   │   ├── private/        # Private files
    │   │   └── settings.php    # DB credentials and environment settings
    │   └── backups/
    │       └── db_<timestamp>.sql.gz
    └── staging/
        ├── current -> releases/<timestamp>
        ├── releases/
        ├── shared/
        │   ├── files/
        │   ├── private/
        │   └── settings.php
        └── backups/
```

---

## Installation on the Server

### 1. Bootstrap a fresh Droplet
Run the initial bootstrap script once on a fresh Ubuntu 24.04 server (installs Nginx, MySQL, PHP 8.4, Certbot, UFW, fail2ban, creates `deploy` user and sudoers):

```bash
# Clone this repository (use sudo if cloning to /opt)
sudo git clone https://github.com/your-org/drupal-multisite-server.git /opt/drupal-multisite-server
cd /opt/drupal-multisite-server

# Run initial bootstrap
sudo bash system/droplet-init.sh
```

### 2. Link CLI scripts to system PATH
```bash
sudo chmod +x /opt/drupal-multisite-server/bin/*.sh
sudo chmod +x /opt/drupal-multisite-server/system/*.sh

# Symlink CLI commands into /usr/local/bin
sudo ln -sf /opt/drupal-multisite-server/bin/provision-drupal-site.sh /usr/local/bin/provision-drupal-site
sudo ln -sf /opt/drupal-multisite-server/bin/deprovision-drupal-site.sh /usr/local/bin/deprovision-drupal-site

# Symlink shared Drupal Nginx snippet
sudo mkdir -p /etc/nginx/snippets
sudo ln -sf /opt/drupal-multisite-server/nginx/snippets/drupal.conf /etc/nginx/snippets/drupal.conf
```

---

## Usage

### Provision a new website or environment

```bash
# Note: <repo_name> must be the bare repository name (e.g. example.com), NOT org/repo_name.
sudo provision-drupal-site <repo_name> <environment: live|staging> <domain> [certbot_email]
```

**Examples:**
```bash
# Provision live environment
sudo provision-drupal-site example.com live example.com admin@example.com

# Provision staging environment
sudo provision-drupal-site example.com staging staging.example.com admin@example.com
```

#### What `provision-drupal-site` does automatically:
1. Creates directory layout (`shared/files`, `shared/private`, `backups`, `releases`).
2. Creates a bootstrap release so Nginx syntax tests and Certbot domain validation pass before the first code deployment.
3. Creates a dedicated MySQL database (`{repo_name}_{env}`) and user with a secure generated password.
4. Generates a persistent `shared/settings.php` file containing database credentials, hash salt, and trusted host patterns.
5. Sets appropriate ownership (`deploy:www-data`), permissions (`setgid` on upload directories, `440` on `settings.php`), and restricts backups to `deploy:deploy` (`700`).
6. Creates `/etc/nginx/sites-available/{repo_name}_{env}`, symlinks to `sites-enabled`, tests configuration, and reloads Nginx (automatically injecting `X-Robots-Tag: noindex, nofollow, noarchive, nosnippet` on staging environments).
7. Requests an SSL certificate from Let's Encrypt using Certbot (if an email is provided).

### Deploying Code

A starter workflow template is provided at [`templates/deploy.yml`](templates/deploy.yml). Copy it to `.github/workflows/deploy.yml` in your site's repository.

Once provisioned and configured with secrets (`SSH_HOST`, `SSH_USER`, `SSH_PRIVATE_KEY`, `SSH_KNOWN_HOSTS`), trigger deployments via GitHub Actions:
- Push to `main` → deploys to `live` (`/var/www/{repo_name}/live`)
- Push to `staging` → deploys to `staging` (`/var/www/{repo_name}/staging`)

> **Note on Initial Deployment:**
> The first time you push to a newly provisioned site, GitHub Actions deploys the code, but `drush deploy` requires an initial database.
> 1. Export your local DB: `ddev export-db --file=/tmp/init.sql.gz && scp /tmp/init.sql.gz deploy@<IP>:~/init.sql.gz && rm -f /tmp/init.sql.gz`
> 2. Import on server: `cd /var/www/<repo_name>/<env>/current && gunzip -c ~/init.sql.gz | ./vendor/bin/drush sql:cli && ./vendor/bin/drush deploy -v && rm -f ~/init.sql.gz`
> 3. Sync media files: `rsync -avz --progress web/sites/default/files/ deploy@<IP>:/var/www/<repo_name>/<env>/shared/files/ --exclude='php/' --exclude='css/' --exclude='js/' --exclude='styles/'`
> 
> Future pushes will deploy and update automatically without manual intervention.

### Deprovisioning a site

```bash
# Keep database intact
sudo deprovision-drupal-site my-old-site staging

# Delete database as well
sudo deprovision-drupal-site my-old-site staging --drop-db
```
