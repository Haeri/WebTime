#!/bin/bash
# Live end-to-end check of the built daemon against the real macOS resolver.
# Runs .build/installer/webtimed in the foreground (sudo is needed to publish DNS routes),
# then drives it over its control socket. Nothing persists: the daemon's routes are
# session-owned and disappear when it exits. Requires Web Time to be uninstalled.
set -uo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DAEMON="$PROJECT_DIR/.build/installer/webtimed"
SOCKET=/var/run/web-time.sock
TEST_DOMAIN="${1:-example.com}"
OTHER_DOMAIN="${2:-apple.com}"
FAILURES=0

[[ -x "$DAEMON" ]] || { echo "Build first: make build" >&2; exit 1; }
if [[ -e /Library/LaunchDaemons/local.web-time.daemon.plist ]]; then
    echo "Web Time is installed; uninstall it before running this check." >&2
    exit 1
fi

resolves() { dscacheutil -q host -a name "$1" | grep -q '_address:'; }
policy() {
    printf '{"action":"updatePolicies","policies":[{"id":"t","domains":["%s"],"blocked":%s}]}' \
        "$TEST_DOMAIN" "$1" | nc -U -w 3 "$SOCKET"
    echo
}
check() {
    if eval "$2"; then echo "✓ $1"; else echo "✗ $1"; FAILURES=$((FAILURES + 1)); fi
}

sudo -v || exit 1
sudo "$DAEMON" &
SUDO_PID=$!
cleanup() {
    sudo pkill -x webtimed 2>/dev/null
    wait "$SUDO_PID" 2>/dev/null
}
trap cleanup EXIT
for _ in {1..50}; do [[ -S "$SOCKET" ]] && break; sleep 0.1; done
[[ -S "$SOCKET" ]] || { echo "✗ daemon did not start"; exit 1; }

policy false
sleep 1
check "supplemental route for $TEST_DOMAIN is registered on port 5354" \
    "scutil --dns | grep -E -A4 'domain +: $TEST_DOMAIN$' | grep -Eq 'port +: 5354'"
check "allowed $TEST_DOMAIN resolves through the daemon" "resolves $TEST_DOMAIN"
check "unrelated $OTHER_DOMAIN resolves normally" "resolves $OTHER_DOMAIN"

policy true
sleep 1
check "exhausted $TEST_DOMAIN is blocked" "! resolves $TEST_DOMAIN"
check "subdomain www.$TEST_DOMAIN is blocked" "! resolves www.$TEST_DOMAIN"
check "unrelated $OTHER_DOMAIN still resolves while $TEST_DOMAIN is blocked" "resolves $OTHER_DOMAIN"

policy false
sleep 1
check "snoozed $TEST_DOMAIN resolves again immediately" "resolves $TEST_DOMAIN"

policy true
sleep 1
cleanup
trap - EXIT
sleep 1
check "route disappears when the daemon exits" "! scutil --dns | grep -Eq 'domain +: $TEST_DOMAIN$'"
sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder
check "$TEST_DOMAIN resolves normally with the daemon gone" "resolves $TEST_DOMAIN"

echo
if [[ "$FAILURES" -eq 0 ]]; then echo "All live DNS checks passed."; else echo "$FAILURES live DNS check(s) failed."; exit 1; fi
