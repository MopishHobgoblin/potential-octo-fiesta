#!/usr/bin/env bash
# Downloads an official Moodle release package, verifies its SHA-256 checksum
# and installs it to /var/www/moodle (read-only for the web server).
set -Eeuo pipefail

url="${1:?usage: fetch-moodle.sh <download-url>}"
dest=/var/www/moodle
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "==> Downloading ${url}"
curl -fSL --retry 5 --retry-delay 5 -o "$tmp/moodle.tgz" "$url"

echo "==> Verifying SHA-256 checksum"
curl -fsSL --retry 5 --retry-delay 5 -o "$tmp/moodle.tgz.sha256" "${url}.sha256"
expected="$(awk 'NR==1 {print $1}' "$tmp/moodle.tgz.sha256")"
[[ "$expected" =~ ^[0-9a-f]{64}$ ]] || { echo "Checksum file did not contain a SHA-256 hash" >&2; exit 1; }
echo "${expected}  $tmp/moodle.tgz" | sha256sum -c -

echo "==> Extracting"
tar -xzf "$tmp/moodle.tgz" -C "$tmp"
[[ -d "$tmp/moodle" ]] || { echo "Unexpected archive layout (no top-level moodle/ directory)" >&2; exit 1; }
rm -rf "$dest"
mkdir -p "$(dirname "$dest")"
mv "$tmp/moodle" "$dest"

# Moodle 5.1+ serves only the public/ directory.
if [[ ! -f "$dest/public/version.php" ]]; then
    echo "public/version.php not found: this image requires Moodle 5.1 or newer" >&2
    exit 1
fi

# Moodle 5.2 started providing third-party libraries via Composer. Official
# release packages should already ship vendor/, but install it if they don't.
if [[ -f "$dest/composer.json" && ! -f "$dest/vendor/autoload.php" ]]; then
    if php -r '$j = json_decode(file_get_contents($argv[1]), true);
               foreach (array_keys($j["require"] ?? []) as $p) {
                   if ($p !== "php" && !preg_match("/^(ext|lib|composer)-/", $p)) { exit(0); }
               }
               exit(1);' "$dest/composer.json"; then
        echo "==> Installing Composer dependencies (no-dev)"
        (cd "$dest" && COMPOSER_ALLOW_SUPERUSER=1 composer install \
            --no-dev --no-interaction --no-progress --optimize-autoloader)
    fi
fi

release="$(sed -n "s/^\\\$release *= *'\([^']*\)'.*/\1/p" "$dest/public/version.php" | head -n 1)"
release="${release:-unknown}"
echo "$release" > /usr/local/lib/moodle/RELEASE
echo "==> Installed Moodle ${release}"

chown -R root:root "$dest"
find "$dest" -type d -exec chmod 0755 {} +
find "$dest" -type f -exec chmod 0644 {} +
