# syntax=docker/dockerfile:1
# =============================================================================
#  Moodle all-in-one image
#  nginx + PHP-FPM + MariaDB + Redis + Moodle cron, managed by supervisord
# =============================================================================
#  Build:  docker build -t moodle-aio:5.2.2 .
#  Weekly "+" build of the stable branch:
#          docker build --build-arg MOODLE_VERSION=latest-502 -t moodle-aio:5.2-latest .
# =============================================================================

# Moodle 5.2 requires PHP 8.3+ (8.4 is also supported).
ARG PHP_VERSION=8.3

FROM composer:2 AS composer

FROM php:${PHP_VERSION}-fpm-trixie

# Latest stable release at the time of writing: Moodle 5.2.2 (10 Aug 2026).
ARG MOODLE_VERSION=5.2.2
ARG MOODLE_BRANCH=502
ARG MOODLE_DOWNLOAD_URL=https://download.moodle.org/download.php/direct/stable${MOODLE_BRANCH}/moodle-${MOODLE_VERSION}.tgz

LABEL org.opencontainers.image.title="Moodle AIO" \
      org.opencontainers.image.description="Self-contained Moodle LMS: nginx, PHP-FPM, MariaDB, Redis and cron in one container" \
      org.opencontainers.image.version="${MOODLE_VERSION}" \
      org.opencontainers.image.licenses="GPL-3.0-or-later"

ENV DEBIAN_FRONTEND=noninteractive \
    MOODLE_ROOT=/var/www/moodle \
    MOODLE_DATA=/var/www/moodledata \
    CONFIG_DIR=/config

COPY --from=mlocati/php-extension-installer /usr/bin/install-php-extensions /usr/local/bin/
COPY --from=composer /usr/bin/composer /usr/local/bin/composer

# --- OS packages + PHP extensions -------------------------------------------
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        nginx supervisor \
        mariadb-server mariadb-client \
        redis-server \
        ca-certificates curl git rsync unzip locales tzdata \
        ghostscript poppler-utils graphviz aspell aspell-en; \
    sed -i -e 's/^# *\(en_US.UTF-8 UTF-8\)/\1/' -e 's/^# *\(en_AU.UTF-8 UTF-8\)/\1/' /etc/locale.gen; \
    locale-gen; \
    install-php-extensions gd intl zip soap exif opcache mysqli pgsql redis xsl ldap bcmath; \
    rm -rf /var/lib/apt/lists/* /tmp/*; \
    command -v setpriv; \
    php -r '$need = ["curl","ctype","dom","exif","fileinfo","gd","iconv","intl","json","mbstring","mysqli","openssl","pgsql","redis","simplexml","soap","sodium","tokenizer","xml","xmlreader","zip","Zend OPcache"]; \
            $missing = array_values(array_filter($need, fn($e) => !extension_loaded($e))); \
            if ($missing) { fwrite(STDERR, "Missing PHP extensions: " . implode(", ", $missing) . "\n"); exit(1); } \
            echo "All required PHP extensions present\n";'

# --- Moodle code --------------------------------------------------------------
# The build args are passed as environment variables so the script fails with a
# clear message if one is empty, instead of silently building a broken URL.
COPY build/fetch-moodle.sh /usr/local/lib/moodle/build/fetch-moodle.sh
RUN bash /usr/local/lib/moodle/build/fetch-moodle.sh "${MOODLE_DOWNLOAD_URL}"

# --- Base system tweaks -------------------------------------------------------
# * www-data's home is moved away from /var/www, otherwise `usermod -u` (PUID)
#   would recursively chown moodledata on every container start.
# * The MariaDB datadir starts empty so bind mounts and named volumes behave
#   the same way (initialised by the entrypoint on first run).
RUN set -eux; \
    cp "$PHP_INI_DIR/php.ini-production" "$PHP_INI_DIR/php.ini"; \
    usermod -d /nonexistent www-data; \
    rm -rf /var/lib/mysql/* /etc/nginx/sites-enabled/default /etc/supervisor/conf.d/*; \
    mkdir -p "$CONFIG_DIR" "$MOODLE_DATA" /run/mysqld /var/lib/redis; \
    chown www-data:www-data "$MOODLE_DATA"; \
    chown redis:redis /var/lib/redis

COPY rootfs/ /

RUN set -eux; \
    chmod 0755 /usr/local/bin/docker-entrypoint /usr/local/bin/moodle-cli \
               /usr/local/bin/moodle-cron /usr/local/bin/healthcheck; \
    for f in /usr/local/bin/docker-entrypoint /usr/local/bin/moodle-cli /usr/local/bin/moodle-cron \
             /usr/local/bin/healthcheck /usr/local/lib/moodle/common.sh; do bash -n "$f"; done; \
    php -l /usr/local/lib/moodle/write-config.php; \
    php -l /usr/local/lib/moodle/db-check.php

EXPOSE 80
VOLUME ["/config", "/var/www/moodledata", "/var/lib/mysql"]

HEALTHCHECK --interval=30s --timeout=10s --start-period=15m --retries=5 \
    CMD ["/usr/local/bin/healthcheck"]

STOPSIGNAL SIGTERM
ENTRYPOINT ["/usr/local/bin/docker-entrypoint"]
