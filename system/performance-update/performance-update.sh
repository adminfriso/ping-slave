#!/bin/bash
# ping-performance-update: system settings for a Ping beacon (Pi Zero W, Raspbian buster), idempotent.
# (was beacon-tuning v1-v2; renamed so "tuning" stays free for audio tuning.)
#
# What it sets (see README.md next to this file for the why):
#   powersave  wifi power saving off on every wifi radio, now and at every (re)connect (dhcpcd hook)
#   bluetooth  bluetooth off: dtoverlay=disable-bt in /boot/config.txt, hciuart + bluetooth disabled
#              (the radio is shared with 2.4 GHz wifi); the overlay needs a reboot
#   timers     apt-daily, apt-daily-upgrade and man-db timers masked (no apt/man-db runs during a show)
#   locale     /etc/default/locale rewritten with the quote install.sh missed (LC_CTYPE="en_US.utf8)
#   governor   cpu governor performance (always 1 GHz) instead of ondemand (700 MHz idle), now and at every boot
#              (ping-cpu-performance.service, runs after raspi-config's init script that sets ondemand)
#   wifiguard  (v4) wifi-guard v4 installed and running (the mode in /etc/default/ping-wifi-guard is kept:
#              single until it is switched to multihome on purpose); needs the repo deployed, it runs
#              system/wifi-guard/wifi-guard.sh from it
#
# Usage (as root; the master's exec already runs as root):
#   performance-update.sh status   read-only: first line PERFORMANCE-UPDATE OK | TODO <items> [REBOOT-NEEDED], then details
#   performance-update.sh apply    sets only what is not set yet (an up-to-date beacon is not touched), prints
#                                  ok v<N> | changed <items> | failed <reason>
#
# Stacking updates: a new step is one more item (<item>_ok, <item>_apply, <item>_revert, added to ITEMS) and a
# VERSION bump. Every beacon then reports TODO <item> and the next apply sets only that item.
#   performance-update.sh revert   undoes the first five (bluetooth comes back after a reboot); the wifi guard stays
#                                  (wifi-guard.sh uninstall puts both radios on the network)
#
# It never reboots. Log: /var/log/ping-performance-update.log.

VERSION=4

LOG=/var/log/ping-performance-update.log
CONFIG_TXT=/boot/config.txt
DHCPCD_HOOK=/lib/dhcpcd/dhcpcd-hooks/05-ping-wifi-powersave
LOCALE_FILE=/etc/default/locale
BACKUP_DIR=/var/lib/ping-performance-update
OLD_BACKUP_DIR=/var/lib/ping-beacon-tuning   # v1-v2 (beacon-tuning): moved to BACKUP_DIR on apply/revert
TIMERS="apt-daily.timer apt-daily-upgrade.timer man-db.timer"
BT_UNITS="hciuart.service bluetooth.service"
GOV_UNIT=/etc/systemd/system/ping-cpu-performance.service
GUARD_BIN=/usr/local/sbin/ping-wifi-guard
GUARD_VERSION=4

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
# ping performance-update: wifi power saving off (it adds delay and jitter to every command).
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
boot_id() { cat /proc/sys/kernel/random/boot_id 2>/dev/null; }
# the overlay works from the next boot. hci0 is not a marker for that: stopping hciuart already removes it. So apply
# records the boot it added the overlay in; still the same boot = reboot needed. (hci0 back with the overlay set also.)
bt_reboot_needed() {
    bt_overlay_set || return 1
    [ -f "$BACKUP_DIR/bt-overlay-boot" ] && [ "$(cat "$BACKUP_DIR/bt-overlay-boot")" = "$(boot_id)" ] && return 0
    [ -e /sys/class/bluetooth/hci0 ]
}
BT_COMMENT_RE='^# ping (beacon-tuning|performance-update): bluetooth off'   # marks the overlay line this script added
bluetooth_ok() { bt_overlay_set && bt_units_off; }
bluetooth_apply() {
    if ! bt_overlay_set; then
        mkdir -p "$BACKUP_DIR"
        [ -f "$BACKUP_DIR/config.txt" ] || cp "$CONFIG_TXT" "$BACKUP_DIR/config.txt"
        # append in an [all] section: the last section header may be a model filter like [pi4]
        {
            [ -n "$(tail -c1 "$CONFIG_TXT")" ] && echo
            [ "$(grep -E '^\s*\[' "$CONFIG_TXT" | tail -n1 | tr -d ' \r')" = "[all]" ] || echo "[all]"
            echo "# ping performance-update: bluetooth off, the radio is shared with wifi"
            echo "dtoverlay=disable-bt"
        } >> "$CONFIG_TXT"
        sync
        boot_id > "$BACKUP_DIR/bt-overlay-boot"
    fi
    # remember which units were enabled, so revert only enables those again
    mkdir -p "$BACKUP_DIR"
    if [ ! -f "$BACKUP_DIR/bt-units-enabled" ]; then
        local u; for u in $BT_UNITS; do systemctl is-enabled -q "$u" 2>/dev/null && echo "$u"; done > "$BACKUP_DIR/bt-units-enabled"
    fi
    systemctl disable --now -q $BT_UNITS 2>/dev/null
}
bluetooth_revert() {
    # remove only what this script added: our comment line and the dtoverlay line right after it. A disable-bt line
    # that was there before stays (bluetooth then stays off, as it was).
    if grep -qE "$BT_COMMENT_RE" "$CONFIG_TXT"; then
        awk -v re="$BT_COMMENT_RE" '
            skip && /^[ \t]*dtoverlay=disable-bt[ \t\r]*$/ { skip = 0; next }
            { skip = 0 }
            $0 ~ re { skip = 1; next }
            { print }' "$CONFIG_TXT" > "$CONFIG_TXT.tmp" && cat "$CONFIG_TXT.tmp" > "$CONFIG_TXT" && rm -f "$CONFIG_TXT.tmp"
        sync
    fi
    rm -f "$BACKUP_DIR/bt-overlay-boot"
    # enable only the units that were enabled before apply (v1-v2 did not record it: both, the Raspbian default)
    if [ -f "$BACKUP_DIR/bt-units-enabled" ]; then
        local u; for u in $(cat "$BACKUP_DIR/bt-units-enabled"); do systemctl enable -q "$u" 2>/dev/null; done
        rm -f "$BACKUP_DIR/bt-units-enabled"
    else
        systemctl enable -q $BT_UNITS 2>/dev/null
    fi
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

# ---------- governor ----------
gov_unit_content() {
    cat <<'EOF'
[Unit]
Description=Ping performance-update: cpu governor performance (raspi-config sets ondemand at boot)
After=raspi-config.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo performance > $g; done'

[Install]
WantedBy=multi-user.target
EOF
}
gov_current() { cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null; }
governor_ok() {
    [ -f "$GOV_UNIT" ] && gov_unit_content | cmp -s - "$GOV_UNIT" &&
        systemctl is-enabled -q ping-cpu-performance.service 2>/dev/null && [ "$(gov_current)" = "performance" ]
}
governor_apply() {
    if ! { [ -f "$GOV_UNIT" ] && gov_unit_content | cmp -s - "$GOV_UNIT"; }; then
        gov_unit_content > "$GOV_UNIT.tmp" && chmod 644 "$GOV_UNIT.tmp" && mv "$GOV_UNIT.tmp" "$GOV_UNIT"
        systemctl daemon-reload
        systemctl restart ping-cpu-performance.service 2>/dev/null
    fi
    systemctl enable -q ping-cpu-performance.service 2>/dev/null
    [ "$(gov_current)" = "performance" ] || systemctl restart ping-cpu-performance.service 2>/dev/null
}
governor_revert() {
    local g
    systemctl disable -q ping-cpu-performance.service 2>/dev/null
    rm -f "$GOV_UNIT"; systemctl daemon-reload
    for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo ondemand > "$g"; done
}

# ---------- wifiguard (v4) ----------
guard_src() {  # the wifi-guard script of this repo (next to this script, or the deployed clone)
    local f
    for f in "$(dirname "$(readlink -f "$0")")/../wifi-guard/wifi-guard.sh" /root/ping-slave/system/wifi-guard/wifi-guard.sh; do
        [ -f "$f" ] && [ "$(sed -n 's/^VERSION=//p' "$f")" -ge "$GUARD_VERSION" ] 2>/dev/null && { readlink -f "$f"; return 0; }
    done
    return 1
}
guard_installed() { sed -n 's/^VERSION=//p' "$GUARD_BIN" 2>/dev/null; }
wifiguard_ok() {
    [ "$(guard_installed)" -ge "$GUARD_VERSION" ] 2>/dev/null && systemctl is-active -q ping-wifi-guard.service 2>/dev/null
}
wifiguard_apply() {
    local src out
    src=$(guard_src) || { FAIL_REASON="wifiguard: no wifi-guard v$GUARD_VERSION in the repo, deploy first"; return 1; }
    out=$(bash "$src" install 2>&1)   # no mode arguments: dry/live and single/multihome stay as they are
    case "$out" in failed*) FAIL_REASON="wifiguard: $(echo "$out" | head -n1)"; return 1 ;; esac
}
wifiguard_revert() { :; }   # never here: uninstalling the guard puts both radios on the network

ITEMS="powersave bluetooth timers locale governor wifiguard"

# ---------- commands ----------
cmd_status() {
    local todo="" i
    for i in $ITEMS; do ${i}_ok || todo="$todo $i"; done
    local line="PERFORMANCE-UPDATE"
    if [ -z "$todo" ]; then line="$line OK"; else line="$line TODO$todo"; fi
    bt_reboot_needed && line="$line REBOOT-NEEDED"
    echo "$line v$VERSION"
    local ps=""
    for i in $(wifi_ifaces); do ps="$ps $i=$(iw dev "$i" get power_save 2>/dev/null | awk '{print $3}')"; done
    echo "  powersave:${ps:- no wifi radio} hook=$([ -f "$DHCPCD_HOOK" ] && echo yes || echo no)"
    echo "  bluetooth: overlay=$(bt_overlay_set && echo yes || echo no) hci0=$([ -e /sys/class/bluetooth/hci0 ] && echo present || echo gone)$(for u in $BT_UNITS; do echo -n " ${u%.service}=$(systemctl is-enabled "$u" 2>/dev/null)/$(systemctl is-active "$u" 2>/dev/null)"; done)"
    echo "  timers:$(for t in $TIMERS; do echo -n " ${t%.timer}=$(systemctl is-enabled "$t" 2>/dev/null)"; done)"
    echo "  locale: $(locale_ok && echo fixed || echo "not fixed")"
    echo "  wifiguard: installed=v$(guard_installed || true) service=$(systemctl is-active ping-wifi-guard.service 2>/dev/null) $(grep -E '^(MODE|ENABLED)=' /etc/default/ping-wifi-guard 2>/dev/null | paste -sd' ')"
    echo "  governor: $(gov_current) $(($(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq 2>/dev/null || echo 0) / 1000)) MHz unit=$(systemctl is-enabled ping-cpu-performance.service 2>/dev/null || echo none) $(vcgencmd measure_temp 2>/dev/null) $(vcgencmd get_throttled 2>/dev/null)"
    return 0
}

migrate_backups() {  # v1-v2 kept the backups (original config.txt, locale) under the old name
    [ -d "$OLD_BACKUP_DIR" ] && [ ! -d "$BACKUP_DIR" ] && mv "$OLD_BACKUP_DIR" "$BACKUP_DIR"
    return 0
}

cmd_apply() {
    [ "$(id -u)" = "0" ] || { echo "failed not root"; exit 1; }
    migrate_backups
    local t i changed="" failed=""
    for t in iw systemctl; do command -v $t >/dev/null || { echo "failed missing $t"; exit 1; }; done
    [ -w "$CONFIG_TXT" ] || { echo "failed $CONFIG_TXT not writable"; exit 1; }
    for i in $ITEMS; do
        ${i}_ok && continue
        ${i}_apply
        if ${i}_ok; then changed="$changed $i"; else failed="$failed $i"; fi
    done
    if [ -n "$failed" ]; then echo "failed$failed${FAIL_REASON:+ ($FAIL_REASON)}"; log "apply v$VERSION: failed$failed changed$changed"; cmd_status; exit 1; fi
    if [ -n "$changed" ]; then echo "changed$changed"; log "apply v$VERSION: changed$changed"; else echo "ok v$VERSION"; fi
    bt_reboot_needed && echo "reboot needed: bluetooth overlay takes effect at the next boot"
    cmd_status
}

cmd_revert() {
    [ "$(id -u)" = "0" ] || { echo "failed not root"; exit 1; }
    migrate_backups
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
    *) sed -n '2,30p' "$0"; exit 2 ;;
esac
