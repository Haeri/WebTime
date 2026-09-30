#!/bin/bash
# Shared by install and uninstall. Restore only DNS settings still owned by the old proxy.
# A completed migration prevents later uninstalls from restoring obsolete network settings.
legacy_networksetup() { /usr/sbin/networksetup "$@"; }

restore_legacy_dns() {
    local SUPPORT_DIR="$1"
    local BACKUP_DIR="$SUPPORT_DIR/dns-backup"
    local BACKUP_FILE SERVICE DNS_OUTPUT DNS_VALUES SERVICES
    [[ -f "$SUPPORT_DIR/scoped-dns-v1" ]] && return 0
    if [[ -f "$SUPPORT_DIR/upstream.txt" && ! -f "$BACKUP_DIR/.complete" ]]; then
        echo "Legacy DNS backup is incomplete; keeping the existing service installed for recovery." >&2
        return 1
    fi
    [[ -d "$BACKUP_DIR" ]] || return 0
    SERVICES="$(legacy_networksetup -listallnetworkservices)" || return 1
    SERVICES="$(printf '%s\n' "$SERVICES" | tail -n +2 | sed 's/^\*//')"
    for BACKUP_FILE in "$BACKUP_DIR"/*.txt; do
        [[ -f "$BACKUP_FILE" ]] || continue
        SERVICE="$(sed -n '1p' "$BACKUP_FILE")"
        [[ -n "$SERVICE" ]] || return 1
        # Deleted services no longer have settings to restore.
        if ! printf '%s\n' "$SERVICES" | /usr/bin/grep -Fxq -- "$SERVICE"; then continue; fi
        DNS_OUTPUT="$(legacy_networksetup -getdnsservers "$SERVICE")" || return 1
        # Preserve settings the user or a VPN has changed since installation.
        [[ "$DNS_OUTPUT" == "127.0.0.1" ]] || continue
        DNS_VALUES="$(tail -n +2 "$BACKUP_FILE")"
        if [[ "$DNS_VALUES" == "__EMPTY__" ]]; then
            legacy_networksetup -setdnsservers "$SERVICE" Empty || return 1
        else
            if [[ -z "$DNS_VALUES" ]] || ! awk 'NF == 0 || $0 !~ /^[0-9A-Fa-f:.]+$/ || $0 == "127.0.0.1" || $0 == "::1" { exit 1 }' <<< "$DNS_VALUES"; then
                echo "Invalid legacy DNS backup for $SERVICE; keeping the backup for recovery." >&2
                return 1
            fi
            local ADDRESSES=()
            while IFS= read -r ADDRESS; do ADDRESSES+=("$ADDRESS"); done <<< "$DNS_VALUES"
            legacy_networksetup -setdnsservers "$SERVICE" "${ADDRESSES[@]}" || return 1
        fi
    done
}
