#!/usr/bin/env bash
# Shared helpers for the Moodle container scripts.

MOODLE_ROOT="${MOODLE_ROOT:-/var/www/moodle}"
MOODLE_DATA="${MOODLE_DATA:-/var/www/moodledata}"
CONFIG_DIR="${CONFIG_DIR:-/config}"

log()  { printf '%s [moodle] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; }
warn() { log "WARNING: $*"; }
die()  { log "ERROR: $*"; exit 1; }

is_true() {
    case "${1,,}" in
        1|true|yes|on) return 0 ;;
        *) return 1 ;;
    esac
}

is_local_host() {
    case "${1,,}" in
        ""|localhost|127.0.0.1|::1) return 0 ;;
        *) return 1 ;;
    esac
}

# Web root served by nginx (Moodle 5.1+ uses public/).
moodle_webroot() {
    if [[ -d "$MOODLE_ROOT/public" ]]; then echo "$MOODLE_ROOT/public"; else echo "$MOODLE_ROOT"; fi
}

# Location of admin/cli (checked rather than assumed, to survive layout changes).
moodle_cli_dir() {
    local d
    for d in "$MOODLE_ROOT/public/admin/cli" "$MOODLE_ROOT/admin/cli"; do
        if [[ -f "$d/cron.php" ]]; then echo "$d"; return 0; fi
    done
    return 1
}

moodle_release() { cat /usr/local/lib/moodle/RELEASE 2>/dev/null || echo "unknown"; }

run_as_www() { setpriv --reuid=www-data --regid=www-data --init-groups -- "$@"; }

# Quote a string as a MariaDB string literal.
sql_quote() {
    local s="${1//\\/\\\\}"
    s="${s//\'/\'\'}"
    printf "'%s'" "$s"
}
