# XenForo development container — Apache + PHP
#
# Apache rather than nginx + php-fpm: one fewer service to go wrong, and
# XenForo ships .htaccess rules that Apache honours directly. If you prefer
# nginx, see docs/architecture.md — the trade-off is documented there.
#
# PHP 8.4 by default. XenForo 2.3 itself accepts PHP 7.2 and up (the installer
# refuses anything older), but the official php images only carry maintained
# PHP branches, so 8.2 is the oldest you can build here. Override at build time:
#   docker compose build --build-arg PHP_VERSION=8.5
# or set PHP_VERSION in stack/.env.
ARG PHP_VERSION=8.4

# The Debian release is pinned with the -trixie suffix. Without it the base OS
# changes underneath you the next time the php image moves to a new Debian
# release, and package names in the apt-get line below can stop existing.
FROM php:${PHP_VERSION}-apache-trixie

# PECL extension versions are pinned so a rebuild gives the same image.
# Xdebug 3.5 is the first line that supports PHP 8.5. Bump these deliberately;
# Dependabot does not track PECL.
ARG XDEBUG_VERSION=3.5.3
ARG APCU_VERSION=5.1.28

# ---- PHP extensions XenForo 2.3 needs --------------------------------------
# mbstring, json, ctype, filter, hash, session, openssl, SimpleXML, dom, pcre
# and zlib are already compiled into the official image. The helper script's
# `doctor` command verifies the full list at runtime rather than assuming.
#
# OPcache is compiled into PHP itself from 8.5 onwards, and
# `docker-php-ext-install opcache` fails there ("cp: cannot stat 'modules/*'").
# So it is only built as a separate extension on older versions.
#
# Run every RUN under bash with pipefail, so a failing command on the left of
# a pipe fails the build instead of being masked by the command on the right.
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# DL3008: apt packages are deliberately not version-pinned. Debian removes
#   superseded package versions from its mirrors, so exact pins break the build
#   within weeks; the -trixie base tag already pins the release.
# SC2086: $exts is unquoted on purpose - it must split into separate names.
# hadolint ignore=DL3008,SC2086
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        libpng-dev libjpeg62-turbo-dev libwebp-dev libfreetype6-dev \
        libzip-dev libicu-dev \
        unzip less default-mysql-client; \
    docker-php-ext-configure gd --with-jpeg --with-webp --with-freetype; \
    exts="gd mysqli pdo_mysql zip intl exif bcmath"; \
    if php -r 'exit(PHP_VERSION_ID < 80500 ? 0 : 1);'; then exts="$exts opcache"; fi; \
    docker-php-ext-install -j"$(nproc)" $exts; \
    pecl install "apcu-${APCU_VERSION}"; \
    docker-php-ext-enable apcu; \
    pecl install "xdebug-${XDEBUG_VERSION}"; \
    a2enmod rewrite headers expires; \
    rm -rf /var/lib/apt/lists/* /tmp/pear

# ---- PHP configuration ------------------------------------------------------
# display_errors=On and error_reporting=E_ALL are DEVELOPMENT settings. They
# leak paths and stack traces to the browser. Never carry this image to a
# public host — see docs/SECURITY.md.
ARG PHP_TIMEZONE=UTC
RUN { \
        echo 'memory_limit = 512M'; \
        echo 'upload_max_filesize = 64M'; \
        echo 'post_max_size = 64M'; \
        echo 'max_execution_time = 300'; \
        echo "date.timezone = ${PHP_TIMEZONE}"; \
        echo 'display_errors = On'; \
        echo 'display_startup_errors = On'; \
        echo 'error_reporting = E_ALL'; \
        echo 'log_errors = On'; \
        echo 'opcache.enable = 1'; \
        echo 'opcache.revalidate_freq = 0'; \
        echo 'opcache.validate_timestamps = 1'; \
    } > /usr/local/etc/php/conf.d/zz-xenforo.ini

# Xdebug is INSTALLED BUT NOT ENABLED — it roughly halves request throughput.
# The helper scripts toggle it by copying this file into place:
#   xf xdebug on | xf xdebug off
RUN { \
        echo 'zend_extension=xdebug'; \
        echo 'xdebug.mode=debug'; \
        echo 'xdebug.start_with_request=yes'; \
        echo 'xdebug.client_host=host.docker.internal'; \
        echo 'xdebug.client_port=9003'; \
        echo 'xdebug.idekey=VSCODE'; \
    } > /usr/local/etc/php/conf.d/zz-xdebug.ini.disabled

# ---- Apache: let XenForo's shipped .htaccess work ---------------------------
# AllowOverride All is required for XenForo's friendly URLs. `Options -Indexes`
# because directory listings on a webroot are a needless disclosure even
# locally.
RUN { \
        echo '<Directory /var/www/html>'; \
        echo '    Options -Indexes +FollowSymLinks'; \
        echo '    AllowOverride All'; \
        echo '    Require all granted'; \
        echo '</Directory>'; \
        echo 'ServerTokens Prod'; \
        echo 'ServerSignature Off'; \
    } > /etc/apache2/conf-available/xenforo.conf \
    && a2enconf xenforo

# ---- host UID/GID alignment (matters on Linux only) -------------------------
# On Linux, a bind-mounted webroot keeps the HOST's ownership. Apache runs as
# www-data (uid 33), so unless the two agree you get either "permission denied"
# writing data/ and internal_data/, or files you can no longer edit from the
# host after chowning them to 33.
#
# Docker Desktop on Windows and macOS translates ownership for you, so the
# defaults below are correct there and nothing needs to change.
#
# The Linux helper script passes the invoking user's ids automatically:
#   docker compose build --build-arg PUID=$(id -u) --build-arg PGID=$(id -g)
ARG PUID=33
ARG PGID=33
RUN set -eux; \
    if [ "$PGID" != "33" ]; then \
        existing="$(getent group "$PGID" | cut -d: -f1 || true)"; \
        if [ -n "$existing" ] && [ "$existing" != "www-data" ]; then \
            groupmod -g 60033 "$existing"; \
        fi; \
        groupmod -g "$PGID" www-data; \
    fi; \
    if [ "$PUID" != "33" ]; then \
        existing="$(getent passwd "$PUID" | cut -d: -f1 || true)"; \
        if [ -n "$existing" ] && [ "$existing" != "www-data" ]; then \
            usermod -u 60033 "$existing"; \
        fi; \
        usermod -u "$PUID" -g "$PGID" www-data; \
    fi; \
    # Files the image itself owns must follow the remap.
    chown -R www-data:www-data /var/www

WORKDIR /var/www/html
