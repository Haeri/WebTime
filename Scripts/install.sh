#!/bin/bash
set -euo pipefail
PATH="/usr/bin:/bin:/usr/sbin:/sbin"

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_SOURCE="$PROJECT_DIR/.build/Web Time.app"
HELPER_SOURCE="$PROJECT_DIR/.build/installer/webtimed"

if [[ ! -d "$APP_SOURCE" || ! -x "$HELPER_SOURCE" ]]; then
    echo "Build first: ./Scripts/build-app.sh" >&2
    exit 1
fi
if [[ "$(id -u)" -ne 0 ]]; then
    PAYLOAD_DIR="$(mktemp -d /private/tmp/web-time-install.XXXXXX)"
    PAYLOAD_ARCHIVE="$(mktemp /private/tmp/web-time-install-archive.XXXXXX)"
    cleanup_payload() { rm -rf "$PAYLOAD_DIR" "$PAYLOAD_ARCHIVE"; }
    trap cleanup_payload EXIT
    mkdir -p "$PAYLOAD_DIR/Scripts" "$PAYLOAD_DIR/Resources" "$PAYLOAD_DIR/.build/installer"
    ditto "$APP_SOURCE" "$PAYLOAD_DIR/.build/Web Time.app"
    cp "$HELPER_SOURCE" "$PAYLOAD_DIR/.build/installer/webtimed"
    cp "$PROJECT_DIR/Resources/local.web-time.daemon.plist" "$PAYLOAD_DIR/Resources/"
    cp "$PROJECT_DIR/Resources/local.web-time.agent.plist" "$PAYLOAD_DIR/Resources/"
    cp "$0" "$PAYLOAD_DIR/Scripts/install.sh"
    ditto -c -k --sequesterRsrc "$PAYLOAD_DIR" "$PAYLOAD_ARCHIVE"
    PAYLOAD_HASH="$(shasum -a 256 "$PAYLOAD_ARCHIVE" | awk '{print $1}')"
    sudo /bin/bash -c '
        set -euo pipefail
        PATH="/usr/bin:/bin:/usr/sbin:/sbin"
        ARCHIVE="$1"
        EXPECTED_HASH="$2"
        ROOT_STAGE="$(mktemp -d /var/tmp/web-time-install.XXXXXX)"
        chmod 700 "$ROOT_STAGE"
        trap "rm -rf \"$ROOT_STAGE\"" EXIT
        cp "$ARCHIVE" "$ROOT_STAGE/payload.zip"
        ACTUAL_HASH="$(shasum -a 256 "$ROOT_STAGE/payload.zip")"
        ACTUAL_HASH="${ACTUAL_HASH%% *}"
        if [[ "$ACTUAL_HASH" != "$EXPECTED_HASH" ]]; then
            echo "Install payload changed after authorization; refusing to continue." >&2
            exit 1
        fi
        mkdir "$ROOT_STAGE/payload"
        ditto -x -k "$ROOT_STAGE/payload.zip" "$ROOT_STAGE/payload"
        chown -R root:wheel "$ROOT_STAGE/payload"
        chmod -R go-w "$ROOT_STAGE/payload"
        "$ROOT_STAGE/payload/Scripts/install.sh" --verified-stage
        STATUS=$?
        exit "$STATUS"
    ' web-time-installer "$PAYLOAD_ARCHIVE" "$PAYLOAD_HASH"
    exit $?
fi
if [[ "${1:-}" != "--verified-stage" || "$(stat -f '%u' "$PROJECT_DIR")" -ne 0 ]]; then
    echo "Refusing a privileged install from an unverified, user-writable checkout." >&2
    exit 1
fi

CONSOLE_USER="$(stat -f '%Su' /dev/console)"
CONSOLE_UID="$(id -u "$CONSOLE_USER")"
SUPPORT_DIR="/Library/Application Support/Web Time"
BACKUP_DIR="$SUPPORT_DIR/dns-backup"
BACKUP_COMPLETE="$BACKUP_DIR/.complete"
UPSTREAM_FILE="$SUPPORT_DIR/upstream.txt"
mkdir -p "/Library/PrivilegedHelperTools" "/Library/LaunchDaemons" "/Library/LaunchAgents"

install -d -o root -g wheel -m 700 "$SUPPORT_DIR"
install -d -o root -g wheel -m 700 "$BACKUP_DIR"

backup_is_valid() {
    local FILE="$1"
    local VALUES
    [[ -s "$FILE" && -n "$(sed -n '1p' "$FILE")" ]] || return 1
    VALUES="$(tail -n +2 "$FILE")"
    [[ "$VALUES" == "__EMPTY__" ]] && return 0
    [[ -n "$VALUES" ]] || return 1
    awk 'NF == 0 || $0 !~ /^[0-9A-Fa-f:.]+$/ { exit 1 }' <<< "$VALUES"
}

launchctl bootout "gui/$CONSOLE_UID/local.web-time.agent" 2>/dev/null || true
rm -rf "/Applications/Web Time.app"
ditto "$APP_SOURCE" "/Applications/Web Time.app"
install -o root -g wheel -m 755 "$HELPER_SOURCE" "/Library/PrivilegedHelperTools/webtimed"
install -o root -g wheel -m 644 "$PROJECT_DIR/Resources/local.web-time.daemon.plist" "/Library/LaunchDaemons/local.web-time.daemon.plist"
install -o root -g wheel -m 644 "$PROJECT_DIR/Resources/local.web-time.agent.plist" "/Library/LaunchAgents/local.web-time.agent.plist"

# Capture the active resolver before redirecting DNS to the local proxy. Existing backups take
# precedence on subsequent installs; scutil supplies the resolver on a fresh installation.
UPSTREAM=""
for BACKUP_FILE in "$BACKUP_DIR"/*.txt; do
    [[ -f "$BACKUP_FILE" ]] || continue
    UPSTREAM="$(tail -n +2 "$BACKUP_FILE" | awk '/^[0-9]+(\.[0-9]+){3}$/ && $0 != "127.0.0.1" { print; exit }')"
    [[ -n "$UPSTREAM" ]] && break
done
if [[ -z "$UPSTREAM" ]]; then
    UPSTREAM="$(/usr/sbin/scutil --dns 2>/dev/null | awk '/nameserver\[[0-9]+\]/ { if ($3 ~ /^[0-9]+(\.[0-9]+){3}$/ && $3 != "127.0.0.1") { print $3; exit } }')"
fi
[[ -n "$UPSTREAM" ]] || UPSTREAM="1.1.1.1"
printf '%s\n' "$UPSTREAM" > "$UPSTREAM_FILE"
chown root:wheel "$UPSTREAM_FILE"
chmod 600 "$UPSTREAM_FILE"

# Backups are written atomically and completed before DNS is changed. Never replace an existing
# pre-limiter value with the temporary 127.0.0.1 setting.
SERVICES=()
NEXT_INDEX=0
while IFS= read -r SERVICE; do
    [[ "$SERVICE" == \** ]] && SERVICE="${SERVICE#\*}"
    [[ -z "$SERVICE" ]] && continue
    SERVICES+=("$SERVICE")
    BACKUP_FILE=""
    for CANDIDATE in "$BACKUP_DIR"/*.txt; do
        [[ -f "$CANDIDATE" ]] || continue
        if [[ "$(sed -n '1p' "$CANDIDATE")" == "$SERVICE" ]]; then
            if ! backup_is_valid "$CANDIDATE"; then
                echo "Existing DNS backup for $SERVICE is incomplete; refusing to change DNS." >&2
                exit 1
            fi
            BACKUP_FILE="$CANDIDATE"
            break
        fi
    done
    if [[ -z "$BACKUP_FILE" ]]; then
        while [[ -e "$BACKUP_DIR/$NEXT_INDEX.txt" ]]; do
            NEXT_INDEX=$((NEXT_INDEX + 1))
        done
        BACKUP_FILE="$BACKUP_DIR/$NEXT_INDEX.txt"
        TEMP_BACKUP="$(mktemp "$BACKUP_DIR/.backup.XXXXXX")"
        printf '%s\n' "$SERVICE" > "$TEMP_BACKUP"
        if ! DNS_OUTPUT="$(/usr/sbin/networksetup -getdnsservers "$SERVICE" 2>/dev/null)"; then
            rm -f "$TEMP_BACKUP"
            echo "Could not capture DNS settings for $SERVICE; refusing to continue." >&2
            exit 1
        fi
        if [[ "$DNS_OUTPUT" == "There aren't any DNS Servers set on"* ]]; then
            printf '%s\n' "__EMPTY__" >> "$TEMP_BACKUP"
        else
            if [[ -z "$DNS_OUTPUT" ]] || ! awk 'NF == 0 || $0 !~ /^[0-9A-Fa-f:.]+$/ { exit 1 }' <<< "$DNS_OUTPUT"; then
                rm -f "$TEMP_BACKUP"
                echo "Captured invalid DNS settings for $SERVICE; refusing to continue." >&2
                exit 1
            fi
            printf '%s\n' "$DNS_OUTPUT" >> "$TEMP_BACKUP"
        fi
        chown root:wheel "$TEMP_BACKUP"
        chmod 600 "$TEMP_BACKUP"
        mv "$TEMP_BACKUP" "$BACKUP_FILE"
    fi
done < <(/usr/sbin/networksetup -listallnetworkservices | tail -n +2)
touch "$BACKUP_COMPLETE"
chown root:wheel "$BACKUP_COMPLETE"
chmod 600 "$BACKUP_COMPLETE"

# Bring up the proxy before redirecting any network service, so a launch failure leaves the
# machine's DNS untouched.
launchctl bootout system/local.web-time.daemon 2>/dev/null || true
launchctl bootstrap system "/Library/LaunchDaemons/local.web-time.daemon.plist"
for SERVICE in "${SERVICES[@]}"; do
    /usr/sbin/networksetup -setdnsservers "$SERVICE" 127.0.0.1
done

/usr/bin/dscacheutil -flushcache
/usr/bin/killall -HUP mDNSResponder 2>/dev/null || true
launchctl bootstrap "gui/$CONSOLE_UID" "/Library/LaunchAgents/local.web-time.agent.plist"

echo "Web Time is installed and running for $CONSOLE_USER."
