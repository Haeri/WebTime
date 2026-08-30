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
BACKUP_DIR="$SUPPORT_DIR/dns-backup"
BACKUP_COMPLETE="$BACKUP_DIR/.complete"

if [[ ! -f "$BACKUP_COMPLETE" ]]; then
    echo "DNS backup is incomplete; refusing to remove Web Time automatically." >&2
    exit 1
fi

launchctl bootout "gui/$CONSOLE_UID/local.web-time.agent" 2>/dev/null || true
/sbin/pfctl -a local.web-time -F all 2>/dev/null || true

RESTORE_FAILED=0
for BACKUP_FILE in "$BACKUP_DIR"/*.txt; do
    [[ -f "$BACKUP_FILE" ]] || continue
    SERVICE="$(sed -n '1p' "$BACKUP_FILE")"
    DNS_VALUES="$(tail -n +2 "$BACKUP_FILE")"
    if [[ "$DNS_VALUES" == "__EMPTY__" ]]; then
        /usr/sbin/networksetup -setdnsservers "$SERVICE" Empty || RESTORE_FAILED=1
    else
        # Values were emitted by networksetup and are IP addresses, one per line.
        /usr/sbin/networksetup -setdnsservers "$SERVICE" $DNS_VALUES || RESTORE_FAILED=1
    fi
done

if [[ "$RESTORE_FAILED" -ne 0 ]]; then
    echo "One or more DNS settings could not be restored. Web Time was left installed so the backup remains recoverable." >&2
    exit 1
fi

/usr/bin/dscacheutil -flushcache
/usr/bin/killall -HUP mDNSResponder 2>/dev/null || true
launchctl bootout system/local.web-time.daemon 2>/dev/null || true
rm -f "/Library/LaunchAgents/local.web-time.agent.plist"
rm -f "/Library/LaunchDaemons/local.web-time.daemon.plist"
rm -f "/Library/PrivilegedHelperTools/webtimed"
rm -f "/var/run/web-time.sock"
rm -f "/var/log/web-time.log"
rm -rf "/Applications/Web Time.app"
rm -rf "$SUPPORT_DIR"

echo "Web Time was removed and the previous DNS settings were restored."
