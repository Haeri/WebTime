#!/bin/bash
set -euo pipefail
PATH="/usr/bin:/bin:/usr/sbin:/sbin"

if [[ "$(id -u)" -ne 0 || "$#" -ne 3 ]]; then
    echo "This helper must be run by Web Time Setup with administrator privileges." >&2
    exit 1
fi

ACTION="$1"
ARCHIVE="$2"
EXPECTED_HASH="$3"
case "$ACTION" in
    install|uninstall) ;;
    *) echo "Unknown setup action." >&2; exit 1 ;;
esac
if [[ ! -f "$ARCHIVE" || ! "$EXPECTED_HASH" =~ ^[0-9a-f]{64}$ ]]; then
    echo "The setup payload is invalid." >&2
    exit 1
fi

ROOT_STAGE="$(mktemp -d /var/tmp/web-time-setup.XXXXXX)"
chmod 700 "$ROOT_STAGE"
cleanup_stage() { rm -rf "$ROOT_STAGE"; }
trap cleanup_stage EXIT

cp "$ARCHIVE" "$ROOT_STAGE/payload.zip"
ACTUAL_HASH="$(shasum -a 256 "$ROOT_STAGE/payload.zip")"
ACTUAL_HASH="${ACTUAL_HASH%% *}"
if [[ "$ACTUAL_HASH" != "$EXPECTED_HASH" ]]; then
    echo "The setup payload changed after authorization." >&2
    exit 1
fi

mkdir "$ROOT_STAGE/payload"
ditto -x -k "$ROOT_STAGE/payload.zip" "$ROOT_STAGE/payload"
chown -R root:wheel "$ROOT_STAGE/payload"
chmod -R go-w "$ROOT_STAGE/payload"

case "$ACTION" in
    install)
        "$ROOT_STAGE/payload/Scripts/install.sh" --verified-stage
        ;;
    uninstall)
        "$ROOT_STAGE/payload/Scripts/uninstall.sh" --verified-stage
        ;;
esac
