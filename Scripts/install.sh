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
    cp "$PROJECT_DIR/Scripts/legacy-dns.sh" "$PAYLOAD_DIR/Scripts/legacy-dns.sh"
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
mkdir -p "/Library/PrivilegedHelperTools" "/Library/LaunchDaemons" "/Library/LaunchAgents"
install -d -o root -g wheel -m 700 "$SUPPORT_DIR"

# Restore the old global override before replacing its running DNS service.
source "$PROJECT_DIR/Scripts/legacy-dns.sh"
restore_legacy_dns "$SUPPORT_DIR"
touch "$SUPPORT_DIR/scoped-dns-v1"
chmod 600 "$SUPPORT_DIR/scoped-dns-v1"

launchctl bootout "gui/$CONSOLE_UID/local.web-time.agent" 2>/dev/null || true
rm -rf "/Applications/Web Time.app"
ditto "$APP_SOURCE" "/Applications/Web Time.app"
install -o root -g wheel -m 755 "$HELPER_SOURCE" "/Library/PrivilegedHelperTools/webtimed"
install -o root -g wheel -m 644 "$PROJECT_DIR/Resources/local.web-time.daemon.plist" "/Library/LaunchDaemons/local.web-time.daemon.plist"
install -o root -g wheel -m 644 "$PROJECT_DIR/Resources/local.web-time.agent.plist" "/Library/LaunchAgents/local.web-time.agent.plist"

# The daemon publishes temporary routes only for configured domains. Normal DNS stays
# under macOS/DHCP/VPN control, and no installation-time upstream is captured.
launchctl bootout system/local.web-time.daemon 2>/dev/null || true
/sbin/pfctl -a local.web-time -F all 2>/dev/null || true
launchctl bootstrap system "/Library/LaunchDaemons/local.web-time.daemon.plist"

/usr/bin/dscacheutil -flushcache
/usr/bin/killall -HUP mDNSResponder 2>/dev/null || true
launchctl bootstrap "gui/$CONSOLE_UID" "/Library/LaunchAgents/local.web-time.agent.plist"

echo "Web Time is installed and running for $CONSOLE_USER."
