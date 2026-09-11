#!/usr/bin/env bash
# =============================================================================
#  Downloads an official Moodle release and installs it to /var/www/moodle.
#
#  MOODLE_DISTRIBUTION=moodle  - standard Moodle:
#    1. $MOODLE_DOWNLOAD_URL / $1   (explicit override, if given)
#    2. download.moodle.org         (official package, SHA-256 verified)
#    3. github.com/moodle/moodle    (official mirror, release tag tarball)
#    4. git clone --depth 1         (official mirror, release tag)
#
#  MOODLE_DISTRIBUTION=mutms   - MuTMS distribution (Moodle + multi-tenancy
#  patch and the MuTMS plugin suite, tagged MuTMS-<moodle version>-NN):
#    1. $MOODLE_DOWNLOAD_URL / $1   (explicit override, if given)
#    2. github.com/mutms/mutms      (release tag tarball)
#    3. git clone --depth 1         (release tag, then the branch)
#
#  Every failure is printed, so `docker build --progress=plain` shows exactly
#  which source failed and why.
# =============================================================================
set -Eeuo pipefail

version="${MOODLE_VERSION:?MOODLE_VERSION is not set}"
branch="${MOODLE_BRANCH:?MOODLE_BRANCH is not set}"
override="${1:-${MOODLE_DOWNLOAD_URL:-}}"
distribution="$(echo "${MOODLE_DISTRIBUTION:-moodle}" | tr '[:upper:]' '[:lower:]')"

case "$distribution" in
    moodle|mutms) ;;
    *) echo "MOODLE_DISTRIBUTION must be 'moodle' or 'mutms', got '$distribution'" >&2; exit 1 ;;
esac

dest=/var/www/moodle
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

say()  { printf '==> %s\n' "$*"; }
fail() { printf '!!! %s\n' "$*" >&2; }

# -----------------------------------------------------------------------------
# Download helpers
# -----------------------------------------------------------------------------
# The package link on download.moodle.org has NO /direct/ in the path; only the
# checksum files do. Getting that wrong returns an error page rather than a
# tarball, so the downloaded file is validated instead of trusting HTTP status.
fetch_file() {
    local url="$1" out="$2"
    curl -fSL --retry 3 --retry-delay 3 --connect-timeout 20 \
         -A "moodle-aio-docker-build" -o "$out" "$url"
}

is_valid_tarball() {
    local f="$1"
    [[ -s "$f" ]] || { fail "downloaded file is empty"; return 1; }
    if ! gzip -t "$f" 2>/dev/null; then
        fail "downloaded file is not a gzip archive ($(stat -c%s "$f") bytes). First bytes:"
        head -c 200 "$f" | tr -d '\0' >&2; echo >&2
        return 1
    fi
    return 0
}

verify_checksum() {
    local tarball="$1" sumurl="$2" expected
    if ! curl -fsSL --retry 3 --retry-delay 3 --connect-timeout 20 -o "$tmp/sum" "$sumurl"; then
        fail "no checksum available at ${sumurl} - skipping verification"
        return 0
    fi
    expected="$(awk 'NR==1 {print $1}' "$tmp/sum")"
    if [[ ! "$expected" =~ ^[0-9a-f]{64}$ ]]; then
        fail "checksum file did not contain a SHA-256 hash - skipping verification"
        return 0
    fi
    echo "${expected}  ${tarball}" | sha256sum -c - >/dev/null \
        || { fail "SHA-256 mismatch - the download is corrupt or has been tampered with"; return 1; }
    say "SHA-256 verified"
}

try_url() {
    local url="$1" sumurl="${2:-}"
    say "Trying ${url}"
    if ! fetch_file "$url" "$tmp/moodle.tgz"; then
        fail "download failed: ${url}"
        return 1
    fi
    is_valid_tarball "$tmp/moodle.tgz" || return 1
    if [[ -n "$sumurl" ]]; then
        verify_checksum "$tmp/moodle.tgz" "$sumurl" || return 1
    fi
    return 0
}

try_git() {
    local repo="$1" ref="$2"
    command -v git >/dev/null 2>&1 || { fail "git is not installed - cannot use the git fallback"; return 1; }
    say "Trying git clone of ${ref} from ${repo}"
    rm -rf "$tmp/moodle"
    git clone --depth 1 --branch "$ref" --quiet "$repo" "$tmp/moodle" \
        || { fail "git clone of ${ref} failed"; return 1; }
    rm -rf "$tmp/moodle/.git"
    return 0
}

# -----------------------------------------------------------------------------
# Fetch
# -----------------------------------------------------------------------------
got=""
[[ -n "$override" ]] && try_url "$override" && got="tarball"

if [[ "$distribution" == "mutms" ]]; then
    # MuTMS tags are MuTMS-<moodle version>-NN, e.g. MuTMS-5.2.2-01, and the
    # branches are MuTMS_52, MuTMS_51, ... Releases carry no published checksum.
    mutms_repo="https://github.com/mutms/mutms.git"
    mutms_tag="${MUTMS_TAG:-MuTMS-${version}-01}"
    mutms_branch="MuTMS_$(echo "${version%.*}" | tr -d '.')"
    mutms_url="https://github.com/mutms/mutms/archive/refs/tags/${mutms_tag}.tar.gz"

    say "Building the MuTMS distribution (${mutms_tag}, based on Moodle ${version})"
    if [[ -z "$got" ]] && try_url "$mutms_url"; then got="tarball"; fi
    if [[ -z "$got" ]] && try_git "$mutms_repo" "$mutms_tag"; then got="git"; fi
    if [[ -z "$got" ]] && try_git "$mutms_repo" "$mutms_branch"; then
        got="git"
        fail "NOTE: tag ${mutms_tag} was unavailable, so branch ${mutms_branch} was used."
        fail "That is the moving branch head, not a tagged release."
    fi

    if [[ -z "$got" ]]; then
        fail "Could not obtain the MuTMS distribution for Moodle ${version}."
        fail "Tags are listed at https://github.com/mutms/mutms/releases - they follow"
        fail "MuTMS-<moodle version>-NN, so check that MOODLE_VERSION matches a MuTMS"
        fail "release, or set MUTMS_TAG to the exact tag (e.g. MuTMS-5.2.2-02)."
        exit 1
    fi
else
    moodle_url="https://download.moodle.org/download.php/stable${branch}/moodle-${version}.tgz"
    moodle_sum="https://download.moodle.org/download.php/direct/stable${branch}/moodle-${version}.tgz.sha256"
    github_url="https://github.com/moodle/moodle/archive/refs/tags/v${version}.tar.gz"

    if [[ -z "$got" ]] && try_url "$moodle_url" "$moodle_sum"; then got="tarball"; fi
    if [[ -z "$got" ]] && try_url "$github_url"; then got="tarball"; fi
    if [[ -z "$got" ]] && try_git "https://github.com/moodle/moodle.git" "v${version}"; then got="git"; fi

    if [[ -z "$got" ]]; then
        fail "Could not obtain Moodle ${version}."
        fail "Check that MOODLE_VERSION and MOODLE_BRANCH match a real release listed on"
        fail "https://download.moodle.org/releases/ - for example 5.2.2 with branch 502,"
        fail "or 5.1.6 with branch 501. Also confirm the builder has internet access."
        exit 1
    fi
fi

# -----------------------------------------------------------------------------
# Install
# -----------------------------------------------------------------------------
if [[ "$got" == "tarball" ]]; then
    say "Extracting"
    mkdir -p "$tmp/x"
    tar -xzf "$tmp/moodle.tgz" -C "$tmp/x"
    # Official packages unpack to moodle/, GitHub tag tarballs to moodle-<version>/.
    src="$(find "$tmp/x" -mindepth 1 -maxdepth 1 -type d)"
    if [[ "$(printf '%s\n' "$src" | wc -l)" -ne 1 || -z "$src" ]]; then
        fail "Unexpected archive layout:"; printf '%s\n' "$src" >&2; exit 1
    fi
else
    src="$tmp/moodle"
fi

rm -rf "$dest"
mkdir -p "$(dirname "$dest")"
mv "$src" "$dest"

if [[ ! -f "$dest/public/version.php" ]]; then
    fail "public/version.php not found - this image requires Moodle 5.1 or newer."
    fail "Moodle 5.0 and earlier have no public/ directory and will not work here."
    if [[ "$distribution" == "mutms" ]]; then
        fail "MuTMS also publishes 4.5.x and 5.0.x releases; use a 5.1 or 5.2 one,"
        fail "for example MOODLE_VERSION=5.2.2."
    fi
    exit 1
fi

# Moodle 5.2 provides some third-party libraries via Composer. Release packages
# ship vendor/ already; git checkouts and some archives do not.
if [[ -f "$dest/composer.json" && ! -f "$dest/vendor/autoload.php" ]]; then
    if php -r '$j = json_decode(file_get_contents($argv[1]), true);
               foreach (array_keys($j["require"] ?? []) as $p) {
                   if ($p !== "php" && !preg_match("/^(ext|lib|composer)-/", $p)) { exit(0); }
               }
               exit(1);' "$dest/composer.json"; then
        say "Installing Composer dependencies (no-dev)"
        (cd "$dest" && COMPOSER_ALLOW_SUPERUSER=1 composer install \
            --no-dev --no-interaction --no-progress --optimize-autoloader)
    fi
fi

# Manifest of the plugin directories that ship with core. Anything with a
# version.php that is NOT in this list was added later (add-on plugin), which is
# how moodle-plugin-sync spots plugins installed through the web interface.
mkdir -p /usr/local/lib/moodle
say "Recording core plugin manifest"
( cd "$dest/public" && find . -mindepth 2 -name version.php -type f -printf '%P\n' ) \
    | sed 's|/version\.php$||' | sort -u > /usr/local/lib/moodle/core-plugins.txt
say "$(wc -l < /usr/local/lib/moodle/core-plugins.txt) core plugins recorded"

release="$(sed -n "s/^\\\$release *= *'\([^']*\)'.*/\1/p" "$dest/public/version.php" | head -n 1)"
release="${release:-$version}"
mkdir -p /usr/local/lib/moodle
echo "$release" > /usr/local/lib/moodle/RELEASE

# Code is owned by root and read-only to the web server.
chown -R root:root "$dest"
find "$dest" -type d -exec chmod 0755 {} +
find "$dest" -type f -exec chmod 0644 {} +

say "Installed Moodle ${release} [${distribution}] (source: ${got})"
