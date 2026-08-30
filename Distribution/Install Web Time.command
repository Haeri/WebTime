#!/bin/bash
set -euo pipefail

VOLUME_DIR="$(cd "$(dirname "$0")" && pwd)"
"$VOLUME_DIR/.web-time/Scripts/install.sh"

echo
echo "Web Time is ready. You can close this window."
read -r -n 1 -s -p "Press any key to close…"
echo
