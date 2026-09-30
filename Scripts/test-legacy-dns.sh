#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/legacy-dns.sh"
TEST_DIR="$(mktemp -d /private/tmp/web-time-dns-test.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT
mkdir -p "$TEST_DIR/support/dns-backup"
CALLS="$TEST_DIR/calls"
: > "$CALLS"
legacy_networksetup() {
    case "$1" in
        -listallnetworkservices) printf 'Services\nWi-Fi\nUSB Hotspot\n*Ethernet\n' ;;
        -getdnsservers)
            case "$2" in
                Wi-Fi|Ethernet) echo '127.0.0.1' ;;
                'USB Hotspot') echo '9.9.9.9' ;;
                *) return 1 ;;
            esac ;;
        -setdnsservers)
            printf '%s\n' "$*" >> "$CALLS"
            [[ "${FAIL_RESTORE:-0}" == 0 ]] ;;
        *) return 1 ;;
    esac
}
expect_calls() {
    [[ "$(cat "$CALLS")" == "$1" ]] || { echo "Unexpected DNS changes" >&2; cat "$CALLS"; exit 1; }
    : > "$CALLS"
}
printf 'Wi-Fi\n__EMPTY__\n' > "$TEST_DIR/support/dns-backup/0.txt"
printf 'USB Hotspot\n8.8.8.8\n' > "$TEST_DIR/support/dns-backup/1.txt"
printf 'Ethernet\n192.168.1.1\n2001:db8::53\n' > "$TEST_DIR/support/dns-backup/2.txt"
printf 'Deleted adapter\n__EMPTY__\n' > "$TEST_DIR/support/dns-backup/3.txt"
restore_legacy_dns "$TEST_DIR/support"
expect_calls $'-setdnsservers Wi-Fi Empty\n-setdnsservers Ethernet 192.168.1.1 2001:db8::53'
echo '✓ restores DHCP and manual IPv4/IPv6; preserves changed DNS and skips deleted adapters'
touch "$TEST_DIR/support/scoped-dns-v1"
restore_legacy_dns "$TEST_DIR/support"
expect_calls ''
echo '✓ subsequent upgrades/uninstalls do not restore stale backups'
rm "$TEST_DIR/support/scoped-dns-v1"
FAIL_RESTORE=1
if restore_legacy_dns "$TEST_DIR/support"; then echo 'Expected failure' >&2; exit 1; fi
expect_calls '-setdnsservers Wi-Fi Empty'
FAIL_RESTORE=0
echo '✓ a failed restoration stops migration'
printf 'Wi-Fi\n127.0.0.1\n' > "$TEST_DIR/support/dns-backup/0.txt"
if restore_legacy_dns "$TEST_DIR/support"; then echo 'Expected invalid backup rejection' >&2; exit 1; fi
expect_calls ''
echo '✓ loopback backups cannot leave a dead DNS override behind'
touch "$TEST_DIR/support/upstream.txt"
if restore_legacy_dns "$TEST_DIR/support"; then echo 'Expected incomplete backup rejection' >&2; exit 1; fi
expect_calls ''
echo '✓ incomplete legacy backups remain recoverable'
restore_legacy_dns "$TEST_DIR/fresh-install"
expect_calls ''
echo '✓ fresh installs never change network-service DNS'
