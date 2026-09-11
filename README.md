# Moodle AIO — self-contained Moodle 5.2 container

One container, everything Moodle needs:

| Component | Version / notes |
|---|---|
| Moodle LMS | **5.2.2** (official release package, SHA-256 verified at build) |
| PHP-FPM | 8.3 (build arg `PHP_VERSION=8.4` also supported by Moodle 5.2) |
| Web server | nginx, web root `public/`, Moodle Router and X-Accel-Redirect configured |
| Database | MariaDB 11.8 (Debian trixie) — or point at an external MariaDB/MySQL/PostgreSQL |
| Sessions | Redis (bundled, localhost only) |
| Cron | Moodle `cron.php` every 60 s |
| Extras | Ghostscript + poppler (assignment PDF annotation), Graphviz, Aspell, en_AU/en_US locales |

Processes are run by supervisord. On start the entrypoint generates `config.php` from environment variables, installs Moodle on first run, and runs the database upgrade automatically after an image update.

```
.
├── Dockerfile
├── docker-compose.yml
├── .env.example
├── build/fetch-moodle.sh          # download + checksum + install Moodle code
├── rootfs/                        # config files and scripts copied into the image
├── unraid/moodle.xml              # Unraid Docker template
└── .github/workflows/build.yml    # optional: build & push to ghcr.io
```

---

## Quick start (Docker Compose)

```bash
cp .env.example .env
# edit .env: set MOODLE_URL to the address you'll browse to, e.g. http://192.168.1.50:8080
docker compose up -d --build
docker compose logs -f
```

The first start installs the database (2–10 minutes). When the log says `Starting services`, open `MOODLE_URL`.
If you didn't set `MOODLE_ADMIN_PASSWORD`, read the generated one:

```bash
docker exec moodle cat /config/secrets/admin_password
```

> **`MOODLE_URL` must be exact.** Moodle redirects every request to this address, so it must match what users type (scheme, host and port). Sub-paths such as `https://example.com/moodle` are not supported by this image.

---

## Unraid

Unraid pulls images from a registry, so publish the image first.

**Option A — GitHub Container Registry (recommended)**
1. Push this folder to a GitHub repository.
2. The included workflow builds and pushes `ghcr.io/<your-user>/moodle-aio:5.2.2` and `:latest` (run it from the *Actions* tab). Make the package public, or add registry credentials on Unraid.
3. In `unraid/moodle.xml`, replace `YOUR_GITHUB_USER` (lowercase).

**Option B — Docker Hub:** `docker build -t youruser/moodle-aio:5.2.2 . && docker push youruser/moodle-aio:5.2.2`, then set `<Repository>` to that name.

**Install the template**
1. Copy `unraid/moodle.xml` to `/boot/config/plugins/dockerMan/templates-user/my-Moodle.xml`.
2. *Docker → Add Container → Template:* choose **Moodle**.
3. Set **Moodle URL** (e.g. `http://192.168.1.50:8080`) and an admin password, then **Apply**.
4. Watch the container log until you see `Starting services`.

The template uses `/mnt/user/appdata/moodle/{config,moodledata,mysql}`, PUID 99 / PGID 100, and `--stop-timeout=120` so MariaDB can shut down cleanly. Keep the `mysql` path on a cache pool/SSD.

---

## Volumes

| Container path | Contents |
|---|---|
| `/config` | `plugins/` add-on plugins, `secrets/` generated passwords, optional `config.extra.php` |
| `/var/www/moodledata` | Uploaded files, caches, language packs (back this up) |
| `/var/lib/mysql` | Bundled MariaDB data (back this up) |

The Moodle code itself lives in the image and is replaced on every update, so there are no stale files after upgrades.

## Environment variables

| Variable | Default | Notes |
|---|---|---|
| `MOODLE_URL` | — | **Required.** e.g. `http://192.168.1.50:8080` or `https://moodle.example.com` |
| `MOODLE_SSLPROXY` | `auto` | `auto` = on when URL is https (reverse proxy terminates TLS) |
| `MOODLE_SITE_FULLNAME` / `MOODLE_SITE_SHORTNAME` | `Moodle LMS` / `Moodle` | First install only |
| `MOODLE_ADMIN_USER` / `MOODLE_ADMIN_PASSWORD` / `MOODLE_ADMIN_EMAIL` | `admin` / generated / `admin@example.com` | First install only |
| `MOODLE_SUPPORT_EMAIL` | admin email | First install only |
| `MOODLE_LANG` | `en` | Install language |
| `MOODLE_AUTO_UPGRADE` | `true` | Run `upgrade.php` on start when needed |
| `MOODLE_UPGRADE_KEY` | — | Optional web upgrade key |
| `MOODLE_DB_TYPE` | `mariadb` | `mariadb`, `mysqli`, `pgsql` |
| `MOODLE_DB_HOST` | `127.0.0.1` | `127.0.0.1`/`localhost` = bundled MariaDB |
| `MOODLE_DB_PORT` | 3306 / 5432 | |
| `MOODLE_DB_NAME` / `MOODLE_DB_USER` | `moodle` / `moodle` | |
| `MOODLE_DB_PASSWORD` | generated | Required for external DBs |
| `MOODLE_DB_PREFIX` | `mdl_` | Max 10 characters |
| `MARIADB_INNODB_BUFFER_POOL_SIZE` | `512M` | Bundled DB only |
| `MOODLE_REDIS_ENABLED` / `MOODLE_REDIS_HOST` / `MOODLE_REDIS_PORT` / `MOODLE_REDIS_PASSWORD` | `true` / `127.0.0.1` / `6379` / — | Redis session store |
| `REDIS_MAXMEMORY` | `256mb` | Bundled Redis only |
| `MOODLE_SMTP_HOST` / `_SECURE` / `_USER` / `_PASSWORD` | — | e.g. `smtp.example.com:587`, `tls` |
| `MOODLE_NOREPLY_ADDRESS` | — | |
| `PHP_MEMORY_LIMIT` | `512M` | |
| `PHP_UPLOAD_MAX_FILESIZE` | `256M` | Applied to PHP and nginx |
| `PHP_MAX_EXECUTION_TIME` | `300` | |
| `PHP_FPM_MAX_CHILDREN` | `20` | ~60 MB RAM each |
| `MOODLE_CRON_ENABLED` / `MOODLE_CRON_INTERVAL` / `MOODLE_CRON_VERBOSE` | `true` / `60` / `false` | Non-verbose logs only failures |
| `NGINX_ACCESS_LOG` | `false` | Log requests to stdout |
| `MOODLE_DEBUG` | `false` | Developer debugging on screen |
| `TZ`, `PUID`, `PGID` | `UTC`, —, — | |

Anything else goes in `/config/config.extra.php` (plain `$CFG->…` lines, it is included before `setup.php`).

---

## Plugins and themes

Web-based plugin installation is disabled on purpose: the code tree comes from the image and is rebuilt on every update, so anything installed through the browser would disappear.

Instead, place plugins in `/config/plugins` using the same layout as Moodle's `public/` folder, then restart:

```
config/plugins/mod/customcert/
config/plugins/theme/moove/
config/plugins/local/staticpage/
config/plugins/admin/tool/uploadcoursecategory/
```

On start they are copied into the code tree and `upgrade.php` installs them. To remove a plugin, uninstall it in *Site administration → Plugins → Plugins overview* first, then delete its folder and **recreate** the container (a plain restart keeps the previously copied files).

---

## Upgrading Moodle

1. Change `MOODLE_VERSION` (and `MOODLE_BRANCH` for a new major, e.g. `503` for 5.3).
2. Update any add-on plugins in `/config/plugins` to versions compatible with the new release.
3. Back up (below), then rebuild: `docker compose up -d --build` — or push a new image and click *Update* on Unraid.

The container detects the new version and runs the upgrade before starting the web server. For the weekly "5.2.x+" build, use `MOODLE_VERSION=latest-502`.

## Backups

```bash
# Database (bundled MariaDB)
docker exec moodle sh -c 'mariadb-dump --single-transaction -uroot "${MOODLE_DB_NAME:-moodle}"' > moodle-db.sql

# Files: copy the moodledata and config volumes / appdata folders
```

Enable maintenance mode during file backups on busy sites: `docker exec moodle moodle-cli maintenance.php --enable`.

## Useful commands

```bash
docker exec -it moodle moodle-cli                   # list admin CLI scripts
docker exec -it moodle moodle-cli purge_caches.php
docker exec -it moodle moodle-cli reset_password.php
docker exec -it moodle moodle-cli maintenance.php --enable|--disable
docker exec -it moodle supervisorctl status
docker exec -it moodle mariadb -uroot moodle         # SQL shell (bundled DB)
```

## Reverse proxy (SWAG, Nginx Proxy Manager, Traefik)

Set `MOODLE_URL=https://moodle.example.com` and proxy to the container's port 80. `MOODLE_SSLPROXY=auto` enables `$CFG->sslproxy`. Raise the proxy's upload limit to match `PHP_UPLOAD_MAX_FILESIZE`.

Moodle 5.2's environment page checks that the Router works by requesting your own `MOODLE_URL` from inside the container; if the container can't reach that address (split-horizon DNS, hairpin NAT), that check may warn even though routing works for users.

## External database

Set `MOODLE_DB_HOST` to your server and provide `MOODLE_DB_TYPE`, `MOODLE_DB_NAME`, `MOODLE_DB_USER` and `MOODLE_DB_PASSWORD`. The bundled MariaDB is then not started. Moodle 5.2 needs MariaDB ≥ 10.11, MySQL ≥ 8.4 or PostgreSQL ≥ 16. Create the database with `utf8mb4_unicode_ci` (MySQL/MariaDB) or UTF8 encoding (PostgreSQL).

## Troubleshooting

- **Redirect loop / "incorrect access" warning:** `MOODLE_URL` doesn't match the browser address, or you're behind HTTPS without `MOODLE_SSLPROXY`.
- **"Partial Moodle install" on start:** a previous first install was interrupted. Empty the database (or delete the `mysql` folder for the bundled DB) and restart.
- **Cron errors:** set `MOODLE_CRON_VERBOSE=true`, or read `/tmp/moodle-cron-last.log` inside the container.
- **Big uploads fail:** raise `PHP_UPLOAD_MAX_FILESIZE`, and the limit in any reverse proxy in front.
# potential-octo-fiesta
