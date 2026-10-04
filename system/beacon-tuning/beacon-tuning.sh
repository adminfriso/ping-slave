#!/bin/bash
# ping-beacon-tuning: system settings for a Ping beacon (Pi Zero W, Raspbian buster), idempotent.
#
# What it sets (see README.md next to this file for the why):
#   powersave  wifi power saving off on every wifi radio, now and at every (re)connect (dhcpcd hook)
#   bluetooth  bluetooth off: dtoverlay=disable-bt in /boot/config.txt, hciuart + bluetooth disabled
#              (the radio is shared with 2.4 GHz wifi); the overlay needs a reboot
#   timers     apt-daily, apt-daily-upgrade and man-db timers masked (no apt/man-db runs during a show)
#   locale     /etc/default/locale rewritten with the quote install.sh missed (LC_CTYPE="en_US.utf8)
#
# Usage (as root; the master's exec already runs as root):
#   beacon-tuning.sh status   read-only: first line BEACON-TUNING OK | TODO <items> [REBOOT-NEEDED], then details
#   beacon-tuning.sh apply    sets what is not set yet, prints ok v<N> | changed <items> | failed <reason>
#   beacon-tuning.sh revert   undoes all four (bluetooth comes back after a reboot)
#
# It never reboots. Log: /var/log/ping-beacon-tuning.log.

VERSION=1

LOG=/var/log/ping-beacon-tuning.log
CONFIG_TXT=/boot/config.txt
DHCPCD_HOOK=/lib/dhcpcd/dhcpcd-hooks/05-ping-wifi-powersave
LOCALE_FILE=/etc/default/locale
BACKUP_DIR=/var/lib/ping-beacon-tuning
TIMERS="apt-daily.timer apt-daily-upgrade.timer man-db.timer"
BT_UNITS="hciuart.service bluetooth.service"

log() { echo "$(date '+%F %T') $*" >> "$LOG"; }

wifi_ifaces() {
    local d
    for d in /sys/class/net/*; do
        [ -d "$d/wireless" ] || [ -e "$d/phy80211" ] && basename "$d"
    done
}

# ---------- powersave ----------
hook_content() {
    cat <<EOF
# ping beacon-tuning v$VERSION: wifi power saving off (it adds delay and jitter to every command).
# Power saving comes back when a radio goes down and up (e.g. a wifi-guard switch), so set it on every connect.
if [ "\$ifwireless" = "1" ]; then
    case "\$reason" in
        PREINIT|CARRIER|BOUND|RENEW|REBIND|REBOOT|STATIC) $(command -v iw) dev "\$interface" set power_save off 2>/dev/null ;;
    esac
fi
EOF
}
powersave_on_ifaces() {  # prints the wifi radios that are up and still have power saving on
    local i
    for i in $(wifi_ifaces); do
        [ "$(cat "/sys/class/net/$i/operstate" 2>/dev/null)" = "up" ] || continue
        iw dev "$i" get power_save 2>/dev/null | grep -q 'Power save: on' && echo "$i"
    done
}
powersave_ok() { [ -f "$DHCPCD_HOOK" ] && hook_content | cmp -s - "$DHCPCD_HOOK" && [ -z "$(powersave_on_ifaces)" ]; }
powersave_apply() {
    local i
    if ! { [ -f "$DHCPCD_HOOK" ] && hook_content | cmp -s - "$DHCPCD_HOOK"; }; then
        hook_content > "$DHCPCD_HOOK.tmp" && chmod 644 "$DHCPCD_HOOK.tmp" && mv "$DHCPCD_HOOK.tmp" "$DHCPCD_HOOK"
    fi
    for i in $(powersave_on_ifaces); do iw dev "$i" set power_save off; done
}
powersave_revert() {
    local i
    rm -f "$DHCPCD_HOOK"
    for i in $(wifi_ifaces); do iw dev "$i" set power_save on 2>/dev/null; done
}

# ---------- bluetooth ----------
bt_overlay_set() { grep -qE '^\s*dtoverlay=disable-bt\s*$' "$CONFIG_TXT"; }
bt_units_off() {
    local u
    for u in $BT_UNITS; do
        systemctl is-enabled -q "$u" 2>/dev/null && return 1
        systemctl is-active -q "$u" 2>/dev/null && return 1
    done
    return 0
}
bt_reboot_needed() { bt_overlay_set && [ -e /sys/class/bluetooth/hci0 ]; }
bluetooth_ok() { bt_overlay_set && bt_units_off; }
bluetooth_apply() {
    if ! bt_overlay_set; then
        mkdir -p "$BACKUP_DIR"
        [ -f "$BACKUP_DIR/config.txt" ] || cp "$CONFIG_TXT" "$BACKUP_DIR/config.txt"
        # append in an [all] section: the last section header may be a model filter like [pi4]
        {
            [ -n "$(tail -c1 "$CONFIG_TXT")" ] && echo
            [ "$(grep -E '^\s*\[' "$CONFIG_TXT" | tail -n1 | tr -d ' \r')" = "[all]" ] || echo "[all]"
            echo "# ping beacon-tuning: bluetooth off, the radio is shared with wifi"
            echo "dtoverlay=disable-bt"
        } >> "$CONFIG_TXT"
        sync
    fi
    systemctl disable --now -q $BT_UNITS 2>/dev/null
}
bluetooth_revert() {
    if bt_overlay_set; then
        sed -i -e '/^# ping beacon-tuning: bluetooth off/d' -e '/^\s*dtoverlay=disable-bt\s*$/d' "$CONFIG_TXT"
        sync
    fi
    systemctl enable -q $BT_UNITS 2>/dev/null
}

# ---------- timers ----------
timers_left() {  # prints the timers that are not masked yet
    local t
    for t in $TIMERS; do
        [ -e "/lib/systemd/system/$t" ] || [ -e "/etc/systemd/system/$t" ] || continue
        [ "$(systemctl is-enabled "$t" 2>/dev/null)" = "masked" ] || echo "$t"
    done
}
timers_ok() { [ -z "$(timers_left)" ]; }
timers_apply() { local t; for t in $(timers_left); do systemctl mask --now -q "$t" 2>/dev/null; done; }
timers_revert() {
    local t
    for t in $TIMERS; do
        [ "$(systemctl is-enabled "$t" 2>/dev/null)" = "masked" ] || continue
        systemctl unmask -q "$t"; systemctl enable --now -q "$t" 2>/dev/null
    done
}

# ---------- locale ----------
locale_content() {
    echo "LANG=en_US.utf8"
    echo "LANGUAGE=en_US.utf8"
    local v
    for v in CTYPE NUMERIC TIME COLLATE MONETARY MESSAGES PAPER NAME ADDRESS TELEPHONE MEASUREMENT IDENTIFICATION; do
        echo "LC_$v=\"en_US.utf8\""
    done
}
locale_ok() { locale_content | cmp -s - "$LOCALE_FILE"; }
locale_apply() {
    mkdir -p "$BACKUP_DIR"
    [ -f "$BACKUP_DIR/locale" ] || cp "$LOCALE_FILE" "$BACKUP_DIR/locale" 2>/dev/null
    locale_content > "$LOCALE_FILE.tmp" && chmod 644 "$LOCALE_FILE.tmp" && mv "$LOCALE_FILE.tmp" "$LOCALE_FILE"
}
locale_revert() { [ -f "$BACKUP_DIR/locale" ] && cp "$BACKUP_DIR/locale" "$LOCALE_FILE"; }

ITEMS="powersave bluetooth timers locale"

# ---------- commands ----------
cmd_status() {
    local todo="" i
    for i in $ITEMS; do ${i}_ok || todo="$todo $i"; done
    local line="BEACON-TUNING"
    if [ -z "$todo" ]; then line="$line OK"; else line="$line TODO$todo"; fi
    bt_reboot_needed && line="$line REBOOT-NEEDED"
    echo "$line v$VERSION"
    local ps=""
    for i in $(wifi_ifaces); do ps="$ps $i=$(iw dev "$i" get power_save 2>/dev/null | awk '{print $3}')"; done
    echo "  powersave:${ps:- no wifi radio} hook=$([ -f "$DHCPCD_HOOK" ] && echo yes || echo no)"
    echo "  bluetooth: overlay=$(bt_overlay_set && echo yes || echo no) hci0=$([ -e /sys/class/bluetooth/hci0 ] && echo present || echo gone)$(for u in $BT_UNITS; do echo -n " ${u%.service}=$(systemctl is-enabled "$u" 2>/dev/null)/$(systemctl is-active "$u" 2>/dev/null)"; done)"
    echo "  timers:$(for t in $TIMERS; do echo -n " ${t%.timer}=$(systemctl is-enabled "$t" 2>/dev/null)"; done)"
    echo "  locale: $(locale_ok && echo fixed || echo "not fixed")"
    return 0
}

cmd_apply() {
    [ "$(id -u)" = "0" ] || { echo "failed not root"; exit 1; }
    local t i changed="" failed=""
    for t in iw systemctl; do command -v $t >/dev/null || { echo "failed missing $t"; exit 1; }; done
    [ -w "$CONFIG_TXT" ] || { echo "failed $CONFIG_TXT not writable"; exit 1; }
    for i in $ITEMS; do
        ${i}_ok && continue
        ${i}_apply
        if ${i}_ok; then changed="$changed $i"; else failed="$failed $i"; fi
    done
    if [ -n "$failed" ]; then echo "failed$failed"; log "apply v$VERSION: failed$failed changed$changed"; cmd_status; exit 1; fi
    if [ -n "$changed" ]; then echo "changed$changed"; log "apply v$VERSION: changed$changed"; else echo "ok v$VERSION"; fi
    bt_reboot_needed && echo "reboot needed: bluetooth overlay takes effect at the next boot"
    cmd_status
}

cmd_revert() {
    [ "$(id -u)" = "0" ] || { echo "failed not root"; exit 1; }
    local i
    for i in $ITEMS; do ${i}_revert; done
    log "reverted v$VERSION"
    echo "reverted (bluetooth comes back after a reboot)"
    cmd_status
}

case "$1" in
    status) cmd_status ;;
    apply) cmd_apply ;;
    revert) cmd_revert ;;
    *) sed -n '2,17p' "$0"; exit 2 ;;
esac
