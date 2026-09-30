#!/bin/bash
set -euo pipefail
PATH="/usr/bin:/bin:/usr/sbin:/sbin"

if [[ "$(id -u)" -ne 0 ]]; then
    PAYLOAD_DIR="$(mktemp -d /private/tmp/web-time-uninstall.XXXXXX)"
    PAYLOAD_ARCHIVE="$(mktemp /private/tmp/web-time-uninstall-archive.XXXXXX)"
    cleanup_payload() { rm -rf "$PAYLOAD_DIR" "$PAYLOAD_ARCHIVE"; }
    trap cleanup_payload EXIT
    mkdir -p "$PAYLOAD_DIR/Scripts"
    cp "$0" "$PAYLOAD_DIR/Scripts/uninstall.sh"
    cp "$(dirname "$0")/legacy-dns.sh" "$PAYLOAD_DIR/Scripts/legacy-dns.sh"
    ditto -c -k --sequesterRsrc "$PAYLOAD_DIR" "$PAYLOAD_ARCHIVE"
    PAYLOAD_HASH="$(shasum -a 256 "$PAYLOAD_ARCHIVE" | awk '{print $1}')"
    sudo /bin/bash -c '
        set -euo pipefail
        PATH="/usr/bin:/bin:/usr/sbin:/sbin"
        ARCHIVE="$1"
        EXPECTED_HASH="$2"
        ROOT_STAGE="$(mktemp -d /var/tmp/web-time-uninstall.XXXXXX)"
        chmod 700 "$ROOT_STAGE"
        trap "rm -rf \"$ROOT_STAGE\"" EXIT
        cp "$ARCHIVE" "$ROOT_STAGE/payload.zip"
        ACTUAL_HASH="$(shasum -a 256 "$ROOT_STAGE/payload.zip")"
        ACTUAL_HASH="${ACTUAL_HASH%% *}"
        [[ "$ACTUAL_HASH" == "$EXPECTED_HASH" ]] || exit 1
        mkdir "$ROOT_STAGE/payload"
        ditto -x -k "$ROOT_STAGE/payload.zip" "$ROOT_STAGE/payload"
        chown -R root:wheel "$ROOT_STAGE/payload"
        chmod -R go-w "$ROOT_STAGE/payload"
        "$ROOT_STAGE/payload/Scripts/uninstall.sh" --verified-stage
    ' web-time-uninstaller "$PAYLOAD_ARCHIVE" "$PAYLOAD_HASH"
    exit $?
fi
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
if [[ "${1:-}" != "--verified-stage" || "$(stat -f '%u' "$PROJECT_DIR")" -ne 0 ]]; then
    echo "Refusing a privileged uninstall from an unverified, user-writable checkout." >&2
    exit 1
fi

CONSOLE_USER="$(stat -f '%Su' /dev/console)"
CONSOLE_UID="$(id -u "$CONSOLE_USER")"
SUPPORT_DIR="/Library/Application Support/Web Time"
# Modern installs leave network service settings alone. For older installs, restore
# only the loopback overrides we still own, before taking the old proxy down.
source "$PROJECT_DIR/Scripts/legacy-dns.sh"
restore_legacy_dns "$SUPPORT_DIR"
launchctl bootout "gui/$CONSOLE_UID/local.web-time.agent" 2>/dev/null || true
launchctl bootout system/local.web-time.daemon 2>/dev/null || true
/sbin/pfctl -a local.web-time -F all 2>/dev/null || true

/usr/bin/dscacheutil -flushcache
/usr/bin/killall -HUP mDNSResponder 2>/dev/null || true
rm -f "/Library/LaunchAgents/local.web-time.agent.plist"
rm -f "/Library/LaunchDaemons/local.web-time.daemon.plist"
rm -f "/Library/PrivilegedHelperTools/webtimed"
rm -f "/var/run/web-time.sock"
rm -f "/var/log/web-time.log"
rm -rf "/Applications/Web Time.app"
rm -rf "$SUPPORT_DIR"

echo "Web Time was removed and its DNS routes were cleared."
