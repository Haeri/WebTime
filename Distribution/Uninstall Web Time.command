#!/bin/bash
set -euo pipefail

VOLUME_DIR="$(cd "$(dirname "$0")" && pwd)"
"$VOLUME_DIR/.web-time/Scripts/uninstall.sh"

echo
echo "Web Time was removed. You can close this window."
read -r -n 1 -s -p "Press any key to close…"
echo
