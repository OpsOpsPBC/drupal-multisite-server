# Static Site Hosting Guide

This guide describes how to host, provision, configure, and deploy static websites alongside Drupal sites on the server.

---

## 1. Overview & Architecture

While the server is configured to run dynamic Drupal applications (PHP 8.4, MySQL), it is also optimized to serve static sites directly through Nginx with minimal overhead, high performance, and zero-downtime atomic deployments.

### Suitable Site Types
- Plain HTML, CSS, and client-side JavaScript sites
- Static Site Generators (SSGs) such as **Astro**, **Vite**, **Hugo**, **11ty**, **Gatsby**, **Nuxt Content**, or **Next.js (Static HTML Export)**
- Single Page Applications (SPAs) built with **React**, **Vue**, **Svelte**, or **Angular**

### Key Differences from Drupal Sites

| Feature | Drupal Sites | Static Sites |
|---|---|---|
| **Database** | MySQL database per environment | None required |
| **PHP / FastCGI** | PHP-FPM 8.4 socket | None (served directly by Nginx) |
| **Document Root** | `/var/www/{repo_name}/{env}/current/web` | `/var/www/{repo_name}/{env}/current` |
| **Shared Resources** | `shared/files`, `shared/settings.php` | None (pure immutable releases) |
| **Deployment Mechanism** | Composer + tarball + DB updates via Drush | Build step + tarball + atomic symlink flip |
| **Rollback** | Code symlink flip + DB restore | Instant code symlink flip |

---

## 2. Server Layout

Every static site follows an atomic deployment release structure under `/var/www`:

```text
/var/www/
└── {repo_name}/
    ├── live/
    │   ├── current -> releases/<timestamp>   # Document root pointing to active release
    │   └── releases/
    │       ├── <timestamp_1>/                # Extracted build files (e.g. index.html)
    │       └── <timestamp_2>/
    └── staging/
        ├── current -> releases/<timestamp>
        └── releases/
            └── <timestamp>/
```

---

## 3. Provisioning a Static Site

### Option A: Automated Provisioning (Recommended)

Use the included `provision-static-site` script to automatically create the folder skeleton, permissions, Nginx virtual host, and SSL certificates:

```bash
sudo provision-static-site <repo_name> <environment: live|staging> <domain> [certbot_email]
```

**Examples:**
```bash
# Provision live environment
sudo provision-static-site docs.example.com live docs.example.com admin@example.com

# Provision staging environment
sudo provision-static-site docs.example.com staging staging-docs.example.com admin@example.com
```

#### What `provision-static-site` does:
1. Creates directory layout (`/var/www/{repo_name}/{env}/releases`).
2. Generates a placeholder release (`releases/bootstrap`) with an initial `index.html` and symlinks `current` to it, ensuring Nginx configuration tests and Certbot domain validation pass before the first deployment.
3. Sets permissions (`deploy:www-data`, `755`).
4. Ensures the shared `/etc/nginx/snippets/static.conf` snippet exists.
5. Generates `/etc/nginx/sites-available/{repo_name}_{env}`, links it to `sites-enabled`, tests Nginx, and reloads the service.
6. Automatically injects `X-Robots-Tag: noindex, nofollow, noarchive, nosnippet` on staging environments.
7. Requests an SSL certificate from Let's Encrypt using Certbot (if an email is provided).

---

### Option B: Manual Provisioning

If you prefer to configure the site manually:

1. **Create directories and bootstrap release:**
   ```bash
   REPO_NAME="my-static-site"
   ENV="live"
   DOMAIN="static.example.com"

   sudo mkdir -p /var/www/${REPO_NAME}/${ENV}/releases/bootstrap
   echo "<h1>Site Ready</h1>" | sudo tee /var/www/${REPO_NAME}/${ENV}/releases/bootstrap/index.html
   sudo ln -sfn /var/www/${REPO_NAME}/${ENV}/releases/bootstrap /var/www/${REPO_NAME}/${ENV}/current
   sudo chown -R deploy:www-data /var/www/${REPO_NAME}/${ENV}
   sudo chmod 755 /var/www/${REPO_NAME}/${ENV} /var/www/${REPO_NAME}/${ENV}/releases
   ```

2. **Configure Nginx virtual host:**
   Copy [`nginx/templates/vhost-static.conf.template`](../nginx/templates/vhost-static.conf.template) to `/etc/nginx/sites-available/${REPO_NAME}_${ENV}`:
   ```nginx
   server {
       listen 80;
       listen [::]:80;
       server_name static.example.com;
       server_tokens off;

       root /var/www/my-static-site/live/current;

       include snippets/static.conf;

       access_log /var/log/nginx/my-static-site_live_access.log;
       error_log  /var/log/nginx/my-static-site_live_error.log error;
   }
   ```

3. **Enable site and reload Nginx:**
   ```bash
   sudo ln -sf /etc/nginx/sites-available/${REPO_NAME}_${ENV} /etc/nginx/sites-enabled/${REPO_NAME}_${ENV}
   sudo nginx -t
   sudo systemctl reload nginx
   ```

4. **Obtain SSL certificate:**
   ```bash
   sudo certbot --nginx -d static.example.com
   ```

---

## 4. Nginx Configuration & Snippet Details

Static site virtual hosts rely on [`nginx/snippets/static.conf`](../nginx/snippets/static.conf), which implements web server best practices:

### 1. Multi-Page vs. Single Page Application (SPA) Routing

- **Default Multi-Page Routing:**
  ```nginx
  location / {
      try_files $uri $uri/ $uri.html =404;
  }
  ```
  Matches the requested URI directly, checks for a directory with `index.html`, attempts appending `.html` (clean URLs for SSGs), or returns a 404.

- **SPA Routing (React, Vue, Svelte):**
  If your application uses client-side routing (HTML5 History API), uncomment the SPA block in `/etc/nginx/snippets/static.conf` (or override in the site's vhost):
  ```nginx
  location / {
      try_files $uri $uri/ /index.html;
  }
  ```

### 2. Cache Control & Invalidation
- **Hashed Assets (JS, CSS, images, fonts):**
  ```nginx
  location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|webp|avif|woff|woff2|ttf|eot|otf|mp4|webm|wasm)$ {
      expires 1y;
      add_header Cache-Control "public, max-age=31536000, immutable";
      log_not_found off;
      access_log off;
  }
  ```
  Cached aggressively for 1 year because modern bundlers (Vite, Webpack, Astro) hash asset filenames upon content changes.

- **HTML Documents:**
  ```nginx
  location ~* \.html?$ {
      expires -1;
      add_header Cache-Control "no-cache, no-store, must-revalidate";
  }
  ```
  Never cached by the browser, ensuring newly deployed releases are rendered immediately when visitors reload.

### 3. Gzip Compression
Pre-configured with gzip level 6 compression across all standard static MIME types (`text/plain`, `text/css`, `application/javascript`, `application/json`, `image/svg+xml`, `application/wasm`, etc.).

### 4. Security & Hardening
- Hidden files and version control directories (e.g. `.git`) return `403 Forbidden`.
- Sensitive file extensions (`.env`, `.yml`, `.lock`, `.md`, `.log`) return `404 Not Found`.
- Baseline security headers injected:
  - `X-Content-Type-Options "nosniff"`
  - `X-Frame-Options "SAMEORIGIN"`
  - `Referrer-Policy "strict-origin-when-cross-origin"`

### 5. Staging Environment Protection
Staging environments automatically receive the `X-Robots-Tag` header:
```nginx
add_header X-Robots-Tag "noindex, nofollow, noarchive, nosnippet" always;
```

If you also wish to require password access for staging, add HTTP Basic Authentication:
```bash
sudo apt-get install -y apache2-utils
sudo htpasswd -c /etc/nginx/.htpasswd staging_user
```
And add to the server block in `/etc/nginx/sites-available/{repo_name}_staging`:
```nginx
auth_basic "Restricted Staging";
auth_basic_user_file /etc/nginx/.htpasswd;
```

---

## 5. CI/CD Deployment with GitHub Actions

A ready-to-use GitHub Actions workflow is provided at [`templates/deploy-static.yml`](../templates/deploy-static.yml).

### Step 1: Add Workflow to Site Repository
Copy `templates/deploy-static.yml` into your site's repository at `.github/workflows/deploy.yml`.

### Step 2: Configure Build Directory
In `.github/workflows/deploy.yml`, adjust the `BUILD_DIR` environment variable to match your project's build output directory:

```yaml
env:
  KEEP_RELEASES: 5
  TARGET_ENV: ${{ github.ref_name == 'main' && 'live' || 'staging' }}
  DEPLOY_PATH: /var/www/${{ github.event.repository.name }}/${{ github.ref_name == 'main' && 'live' || 'staging' }}
  BUILD_DIR: 'dist'  # Change to match your tool: '.', 'dist', 'build', 'public', or 'out'
```

Common defaults:
- **Plain HTML/CSS/JS**: `BUILD_DIR: '.'`
- **Astro, Vite, Nuxt, SvelteKit (adapter-static)**: `BUILD_DIR: 'dist'`
- **Create React App**: `BUILD_DIR: 'build'`
- **Hugo**: `BUILD_DIR: 'public'`
- **Next.js (Static Export `output: 'export'`)**: `BUILD_DIR: 'out'`

### Step 3: Configure GitHub Secrets
In your GitHub repository under **Settings** → **Secrets and variables** → **Actions**, add:

| Secret | Value |
|---|---|
| `SSH_HOST` | Droplet IP address or hostname |
| `SSH_USER` | `deploy` |
| `SSH_PRIVATE_KEY` | Deploy user's private SSH key |
| `SSH_KNOWN_HOSTS` | Output of `ssh-keyscan -H <SSH_HOST>` |
| `HEALTH_URL` | *(Optional)* URL to verify after deploy (e.g. `https://static.example.com`) |

### Step 4: Push to Deploy
- Push to `main` → deploys to `/var/www/{repo_name}/live`
- Push to `staging` → deploys to `/var/www/{repo_name}/staging`
- Trigger manually via **Actions** → **Run workflow**

---

## 6. Zero-Downtime Rollback

Because each deployment creates an isolated release folder before updating the `current` symlink, rollbacks are instantaneous and risk-free:

```bash
# 1. Connect to the server
ssh deploy@<server_ip>

# 2. Check available releases
ls -l /var/www/<repo_name>/<env>/releases

# 3. Flip the symlink to the previous release timestamp
ln -sfn /var/www/<repo_name>/<env>/releases/<previous_timestamp> /var/www/<repo_name>/<env>/current
```

No service reload or database restore is needed. Nginx immediately resolves requests to the newly symlinked directory.

---

## 7. Deprovisioning a Static Site

To safely retire a static site:

```bash
sudo deprovision-drupal-site <repo_name> <env>
```

> **Note:** The `deprovision-drupal-site` script cleans up the Nginx configuration, removes the symlink from `sites-enabled`, and deletes `/var/www/{repo_name}/{env}`. Since static sites do not use a database, omit the `--drop-db` flag.
