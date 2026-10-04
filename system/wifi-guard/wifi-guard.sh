#!/bin/bash
# ping-wifi-guard: keep at most ONE wifi radio of a Ping beacon on the network.
#
# A beacon (Pi Zero W) has two radios: the internal one (driver brcmfmac) and an external USB one.
# With both on, 5 UniFi APs see ~500 clients instead of ~250. The guard:
#   - prefers the internal radio; the external one stays switched off (rfkill) while the internal works;
#   - switches to the external radio when the internal one has not reached the master for FAILOVER_AFTER s
#     (a swap: the internal is switched off first, then the external on; never both);
#   - on the external radio: tries the internal again when the external fails for FAILBACK_AFTER s, at the
#     next boot (every boot starts with the external off and the internal first), and (v3) every PROBE_EVERY s
#     while the external works if the internal worked earlier this boot: after a network outage (build-up,
#     partial power cut) a beacon returns to its internal radio by itself. A probe switches the internal on
#     NEXT TO the external (two radios for at most PROBE_WINDOW s, never offline); internal works: external off;
#     not: internal off again and the wait doubles (up to PROBE_MAX). The only time two radios are on;
#   - "works" = associated, an IPv4 address, and the master or the gateway answers (v2: a master restart
#     made every beacon swap radios in v1);
#   - owns the rfkill state: systemd-rfkill is masked on install (v3), it restored a radio state saved at
#     shutdown after the boot unit had run;
#   - finds the radios by driver, not by name (wlan0/wlan1 can swap between boots).
#
# Usage (as root):
#   wifi-guard.sh status      read-only, one line + details, works before install too
#   wifi-guard.sh install [dry|live]  idempotent: installs/updates the guard, prints ok | changed | failed <reason>
#                             dry = only log what it would switch (ENABLED=0), live = switch (ENABLED=1)
#   wifi-guard.sh uninstall   removes the guard and switches BOTH radios on again (2 clients per beacon!)
#   wifi-guard.sh run         the loop (started by systemd, ping-wifi-guard.service)
#   wifi-guard.sh boot        at boot: internal on, external off (ping-wifi-guard-boot.service)
#   wifi-guard.sh hotplug <if>  called by udev when a wlan interface appears
#
# Settings: /etc/default/ping-wifi-guard (made on install when missing, never overwritten).
# Log: /var/log/ping-wifi-guard.log. Docs: README.md next to this file.

VERSION=3

SELF=/usr/local/sbin/ping-wifi-guard
CONF=/etc/default/ping-wifi-guard
STATE_DIR=/var/lib/ping-wifi-guard
RUN_DIR=/run/ping-wifi-guard
LOG=/var/log/ping-wifi-guard.log
UNIT_LOOP=/etc/systemd/system/ping-wifi-guard.service
UNIT_BOOT=/etc/systemd/system/ping-wifi-guard-boot.service
UDEV_RULE=/etc/udev/rules.d/70-ping-wifi-guard.rules

# defaults (override in $CONF)
MASTER_IP=192.168.8.50
MASTER_PORT=4000
INTERNAL_DRIVER=brcmfmac
INTERVAL=15          # s between checks
BOOT_GRACE=60        # s after boot or a switch before a radio counts as failing
FAILOVER_AFTER=120   # s internal failing before switching to the external radio
QUICK_FAILOVER=30    # same, when the previous boot ended on the external radio (broken internal)
FAILBACK_AFTER=600   # s external failing before trying the internal radio again
PROBE_EVERY=300      # s on a working external before trying the internal again (only if it worked this boot); 0 = never
PROBE_WINDOW=90      # s a probed internal gets to work (both radios on meanwhile) before it is switched off again
PROBE_MAX=3600       # s, the wait doubles after every failed probe up to this
MIN_SIGNAL=0         # dBm, e.g. -85: internal weaker than this counts as failing; 0 = off
JITTER=30            # s, random extra wait before a switch so beacons do not all switch at once
ENABLED=1            # 0 = dry run: decide and log, never switch a radio

[ -r "$CONF" ] && . "$CONF"

log() { mkdir -p "$(dirname "$LOG")"; echo "$(date '+%F %T') $*" >> "$LOG"; }
trim_log() {
    [ -f "$LOG" ] && [ "$(stat -c %s "$LOG" 2>/dev/null || echo 0)" -gt 262144 ] &&
        tail -n 2000 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
}
uptime_s() { cut -d. -f1 /proc/uptime; }

# ---------- radios ----------
is_wireless() { [ -d "/sys/class/net/$1/wireless" ] || [ -e "/sys/class/net/$1/phy80211" ]; }
driver_of() { basename "$(readlink -f "/sys/class/net/$1/device/driver" 2>/dev/null)" 2>/dev/null; }
mac_of() { cat "/sys/class/net/$1/address" 2>/dev/null; }

find_radios() {
    INT=""; EXT=""
    for d in /sys/class/net/*; do
        i=$(basename "$d")
        is_wireless "$i" || continue
        if [ "$(driver_of "$i")" = "$INTERNAL_DRIVER" ]; then
            [ -z "$INT" ] && INT=$i
        else
            [ -z "$EXT" ] && EXT=$i
        fi
    done
}

rfkill_path() {  # /sys/class/rfkill/rfkillN of the radio's phy
    local p
    for p in /sys/class/net/$1/phy80211/rfkill*; do [ -e "$p" ] && { readlink -f "$p"; return 0; }; done
    return 1
}
is_blocked() {  # 0 = switched off (rfkill soft block, or link admin down when there is no rfkill)
    local r; r=$(rfkill_path "$1")
    if [ -n "$r" ]; then [ "$(cat "$r/soft")" = "1" ]; return; fi
    ! ip link show "$1" 2>/dev/null | grep -q '[<,]UP[,>]'
}
radio_off() {
    [ -n "$1" ] || return 0
    is_blocked "$1" && return 0
    if [ "$ENABLED" != "1" ]; then log "dry run: would switch off $1 ($(driver_of "$1"))"; return 0; fi
    local r; r=$(rfkill_path "$1")
    if [ -n "$r" ]; then echo 1 > "$r/soft"; else
        wpa_cli -i "$1" disconnect >/dev/null 2>&1; ip link set "$1" down; fi
    log "switched off $1 ($(driver_of "$1") $(mac_of "$1"))"
}
radio_on() {
    [ -n "$1" ] || return 0
    is_blocked "$1" || return 0
    if [ "$ENABLED" != "1" ]; then log "dry run: would switch on $1 ($(driver_of "$1"))"; return 0; fi
    local r; r=$(rfkill_path "$1")
    if [ -n "$r" ]; then echo 0 > "$r/soft"; else
        ip link set "$1" up; wpa_cli -i "$1" reconnect >/dev/null 2>&1; fi
    log "switched on $1 ($(driver_of "$1") $(mac_of "$1"))"
}

associated() { iw dev "$1" link 2>/dev/null | grep -q '^Connected'; }
signal_of() { iw dev "$1" link 2>/dev/null | awk '/signal:/ {print $2}'; }
ip4_of() { ip -4 -o addr show dev "$1" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1; }
reaches_master() {
    ping -I "$1" -c 1 -W 2 "$MASTER_IP" >/dev/null 2>&1 && return 0
    ping -I "$1" -c 1 -W 2 "$MASTER_IP" >/dev/null 2>&1 && return 0
    [ "$ICMP_ONLY" = 1 ] && return 1  # /dev/tcp is not bound to the radio: with two radios up it can pass via the other
    timeout 3 bash -c "</dev/tcp/$MASTER_IP/$MASTER_PORT" >/dev/null 2>&1
}
reaches_gateway() {  # the default gateway of this radio (the router), so a master restart is not a radio failure
    local gw; gw=$(ip route show default dev "$1" 2>/dev/null | awk '{print $3; exit}')
    [ -n "$gw" ] || return 1
    ping -I "$1" -c 1 -W 2 "$gw" >/dev/null 2>&1 || ping -I "$1" -c 1 -W 2 "$gw" >/dev/null 2>&1
}
healthy() {  # the radio is on, associated, has an address and reaches the master or, when the master is down, the gateway
    [ -n "$1" ] || return 1
    is_blocked "$1" && return 1
    associated "$1" || return 1
    [ -n "$(ip4_of "$1")" ] || return 1
    if [ "$MIN_SIGNAL" != "0" ]; then
        local s; s=$(signal_of "$1"); [ -n "$s" ] && [ "$s" -lt "$MIN_SIGNAL" ] && return 1
    fi
    reaches_master "$1" || reaches_gateway "$1"
}

describe() {  # one radio, for status
    [ -n "$1" ] || { echo "none"; return; }
    local st="on"; is_blocked "$1" && st="off"
    local a="not-associated"; associated "$1" && a="associated"
    local s; s=$(signal_of "$1")
    echo "$1 $(driver_of "$1") $(mac_of "$1") $st $a${s:+ ${s}dBm} ip=$(ip4_of "$1")"
}

active_get() { cat "$RUN_DIR/active" 2>/dev/null; }
active_set() {  # RUN_DIR is per boot (tmpfs); STATE_DIR/last-active survives a power cut (written on a switch only)
    mkdir -p "$RUN_DIR" "$STATE_DIR"; echo "$1" > "$RUN_DIR/active"
    [ "$(cat "$STATE_DIR/last-active" 2>/dev/null)" = "$1" ] || echo "$1" > "$STATE_DIR/last-active"
}

# ---------- switching (order matters: off first, then on, two radios on only during a probe) ----------
use_internal() { radio_off "$EXT"; radio_on "$INT"; active_set int; }
use_external() { radio_off "$INT"; radio_on "$EXT"; active_set ext; }

# ---------- commands ----------
cmd_status() {
    find_radios
    local inst="no" svc="-" n=0 verdict
    [ -x "$SELF" ] && inst="v$(sed -n 's/^VERSION=//p' "$SELF")"
    command -v systemctl >/dev/null && svc=$(systemctl is-active ping-wifi-guard.service 2>/dev/null)
    for i in $INT $EXT; do associated "$i" && n=$((n + 1)); done
    case $n in 1) verdict=OK ;; 0) verdict=NO-RADIO-ASSOCIATED ;; *) verdict=TWO-RADIOS-ON-NETWORK ;; esac
    [ -z "$EXT" ] && [ $n -eq 1 ] && verdict="OK (no external radio seen)"
    [ -f "$RUN_DIR/probing" ] && verdict="$verdict (probing internal)"
    echo "WIFI-GUARD $verdict installed=$inst service=$svc enabled=$ENABLED active=$(active_get || echo -) last=$(cat "$STATE_DIR/last-active" 2>/dev/null || echo -)"
    echo "  internal: $(describe "$INT")"
    echo "  external: $(describe "$EXT")"
    echo "  usb: $(lsusb 2>/dev/null | grep -viE 'root hub' | cut -d' ' -f6- | paste -sd';')"
    [ -f "$LOG" ] && tail -n 5 "$LOG" | sed 's/^/  log: /'
    return 0
}

cmd_boot() {  # early at boot: internal first, external off (the loop decides from here)
    mkdir -p "$RUN_DIR" "$STATE_DIR"
    # what the previous boot ended on: ext = the internal radio is probably broken, fail over faster
    cat "$STATE_DIR/last-active" > "$RUN_DIR/previous-boot" 2>/dev/null
    find_radios
    if [ -n "$INT" ]; then use_internal; else radio_on "$EXT"; active_set ext; fi
    log "boot: internal=${INT:-none} external=${EXT:-none} previous boot ended on $(cat "$RUN_DIR/previous-boot" 2>/dev/null || echo -)"
}

cmd_hotplug() {  # udev: a wlan interface appeared (the USB radio can appear after the boot unit)
    local i=$1 a
    [ -n "$i" ] && is_wireless "$i" || exit 0
    a=$(active_get)
    if [ "$(driver_of "$i")" = "$INTERNAL_DRIVER" ]; then
        if [ "$a" = "ext" ]; then radio_off "$i"; else radio_on "$i"; fi
    else
        if [ "$a" = "ext" ]; then radio_on "$i"; else radio_off "$i"; fi
    fi
}

cmd_run() {
    mkdir -p "$RUN_DIR" "$STATE_DIR"
    local bad_since=0 since_switch now jit a failover probing=0 probe_every=$PROBE_EVERY next_probe=0 probe_start=0
    rm -f "$RUN_DIR/probing"
    since_switch=$(uptime_s)
    [ "$(uptime_s)" -lt "$BOOT_GRACE" ] && since_switch=0
    log "guard v$VERSION started (enabled=$ENABLED)"
    while true; do
        find_radios
        now=$(uptime_s)
        a=$(active_get)
        if [ -z "$a" ]; then  # first run since boot/install: keep what works, prefer internal
            if healthy "$INT"; then a=int
            elif [ -n "$EXT" ] && healthy "$EXT"; then a=ext
            elif [ -n "$INT" ]; then a=int
            else a=ext; fi
            active_set "$a"; log "start on $a"
        fi
        if [ -z "$EXT" ]; then radio_on "$INT"; sleep "$INTERVAL"; continue; fi
        if [ -z "$INT" ]; then radio_on "$EXT"; active_set ext; sleep "$INTERVAL"; continue; fi

        if [ "$a" = "int" ]; then
            radio_off "$EXT"; radio_on "$INT"
            next_probe=0
            failover=$FAILOVER_AFTER
            [ "$(cat "$RUN_DIR/previous-boot" 2>/dev/null)" = "ext" ] && failover=$QUICK_FAILOVER
            if healthy "$INT"; then
                bad_since=0
                [ -f "$RUN_DIR/int-worked" ] || touch "$RUN_DIR/int-worked"
            elif [ $((now - since_switch)) -ge "$BOOT_GRACE" ]; then
                [ "$bad_since" -eq 0 ] && { bad_since=$now; log "internal $INT failing: $(describe "$INT")"; }
                if [ $((now - bad_since)) -ge "$failover" ]; then
                    jit=$((RANDOM % (JITTER + 1))); sleep "$jit"
                    if ! healthy "$INT"; then
                        log "internal $INT failed for $((now - bad_since + jit)) s: switch to external $EXT"
                        use_external; bad_since=0; since_switch=$(uptime_s)
                    fi
                fi
            fi
        elif [ "$probing" = 1 ]; then
            # probe (v3): the internal is switched on NEXT TO the working external (2 clients for at most
            # PROBE_WINDOW s, so the beacon never goes offline). Only checks bound to the internal radio count.
            radio_on "$EXT"; radio_on "$INT"
            if ICMP_ONLY=1 healthy "$INT"; then
                log "probe: internal $INT works again: switch off external $EXT, back on internal"
                use_internal; probing=0; probe_every=$PROBE_EVERY; next_probe=0; bad_since=0; since_switch=$(uptime_s)
                rm -f "$RUN_DIR/probing"
            elif [ $((now - probe_start)) -ge "$PROBE_WINDOW" ]; then
                probe_every=$((probe_every * 2)); [ "$probe_every" -gt "$PROBE_MAX" ] && probe_every=$PROBE_MAX
                log "probe: internal $INT still failing after $PROBE_WINDOW s, switched off again (next probe in $probe_every s)"
                radio_off "$INT"; probing=0; next_probe=$((now + probe_every))
                rm -f "$RUN_DIR/probing"
            fi
        else
            radio_off "$INT"; radio_on "$EXT"
            [ "$next_probe" -eq 0 ] && next_probe=$((now + probe_every))
            if healthy "$EXT"; then
                bad_since=0
                # the internal worked earlier this boot, so the swap was probably a network outage: try it again.
                # One that never worked this boot (broken antenna) is not probed.
                if [ "$PROBE_EVERY" != "0" ] && [ -f "$RUN_DIR/int-worked" ] && [ "$now" -ge "$next_probe" ]; then
                    log "probe: external $EXT works, switch on internal $INT next to it for at most $PROBE_WINDOW s"
                    radio_on "$INT"; probing=1; probe_start=$now; touch "$RUN_DIR/probing"
                fi
            elif [ $((now - since_switch)) -ge "$BOOT_GRACE" ]; then
                [ "$bad_since" -eq 0 ] && { bad_since=$now; log "external $EXT failing: $(describe "$EXT")"; }
                if [ $((now - bad_since)) -ge "$FAILBACK_AFTER" ]; then
                    log "external $EXT failed for $((now - bad_since)) s: try internal $INT again"
                    use_internal; bad_since=0; since_switch=$(uptime_s)
                fi
            fi
        fi
        trim_log
        sleep "$INTERVAL"
    done
}

write_if_changed() {  # $1 target, $2 mode, content on stdin; sets CHANGED
    local tmp; tmp=$(mktemp)
    cat > "$tmp"
    if [ -f "$1" ] && cmp -s "$tmp" "$1"; then rm -f "$tmp"; return 1; fi
    install -m "$2" "$tmp" "$1"; rm -f "$tmp"; CHANGED="$CHANGED $(basename "$1")"; return 0
}

cmd_install() {
    [ "$(id -u)" = "0" ] || { echo "failed not root"; exit 1; }
    for t in iw ip ping systemctl; do command -v $t >/dev/null || { echo "failed missing $t"; exit 1; }; done
    local src; src=$(readlink -f "$0")
    CHANGED=""
    mkdir -p "$STATE_DIR"
    if [ "$src" != "$SELF" ]; then write_if_changed "$SELF" 755 < "$src"; fi
    if [ ! -f "$CONF" ]; then
        sed -n '/^# defaults/,/^ENABLED=/p' "$src" | sed '1d; s/^/#/' |
            { echo "# ping-wifi-guard settings: remove the # to change a value"; cat; } > "$CONF"
        CHANGED="$CHANGED $(basename "$CONF")"
    fi
    case "$1" in  # install dry | install live: set the mode in the settings file (idempotent)
        dry|live)
            local want=1; [ "$1" = dry ] && want=0
            if ! grep -qx "ENABLED=$want" "$CONF"; then
                sed -i '/^ENABLED=/d' "$CONF"; echo "ENABLED=$want" >> "$CONF"
                CHANGED="$CHANGED mode:$1"
            fi
            ENABLED=$want ;;
    esac
    write_if_changed "$UNIT_BOOT" 644 <<EOF && UNITS=1
[Unit]
Description=Ping wifi guard: internal radio first, external off at boot
DefaultDependencies=no
After=systemd-rfkill.service local-fs.target
Before=network-pre.target dhcpcd.service
Wants=network-pre.target

[Service]
Type=oneshot
ExecStart=$SELF boot

[Install]
WantedBy=multi-user.target
EOF
    write_if_changed "$UNIT_LOOP" 644 <<EOF && UNITS=1
[Unit]
Description=Ping wifi guard: at most one wifi radio on the network
After=ping-wifi-guard-boot.service dhcpcd.service

[Service]
ExecStart=$SELF run
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
    write_if_changed "$UDEV_RULE" 644 <<EOF && udevadm control --reload >/dev/null 2>&1
ACTION=="add", SUBSYSTEM=="net", KERNEL=="wlan*", RUN+="$SELF hotplug %k"
EOF
    [ -n "$UNITS" ] && systemctl daemon-reload
    # systemd-rfkill restores the rfkill state saved at shutdown, after our boot unit (seen on cde53af8, 2026-10-04):
    # a beacon shut down on its external radio would boot with the internal blocked. The guard sets rfkill itself.
    for u in systemd-rfkill.service systemd-rfkill.socket; do
        [ "$(systemctl is-enabled "$u" 2>/dev/null)" = "masked" ] || { systemctl mask -q "$u" 2>/dev/null; CHANGED="$CHANGED mask:$u"; }
    done
    for u in ping-wifi-guard-boot.service ping-wifi-guard.service; do
        systemctl is-enabled -q "$u" 2>/dev/null || { systemctl enable -q "$u" 2>/dev/null; CHANGED="$CHANGED enable:$u"; }
    done
    if [ -n "$CHANGED" ] || ! systemctl is-active -q ping-wifi-guard.service; then
        systemctl restart ping-wifi-guard.service
    fi
    sleep 2
    if ! systemctl is-active -q ping-wifi-guard.service; then echo "failed service not running"; cmd_status; exit 1; fi
    if [ -n "$CHANGED" ]; then echo "changed$CHANGED"; log "install v$VERSION: changed$CHANGED"; else echo "ok v$VERSION"; fi
    cmd_status
}

cmd_uninstall() {
    [ "$(id -u)" = "0" ] || { echo "failed not root"; exit 1; }
    systemctl disable --now -q ping-wifi-guard.service ping-wifi-guard-boot.service 2>/dev/null
    rm -f "$UNIT_LOOP" "$UNIT_BOOT" "$UDEV_RULE" "$SELF"
    systemctl unmask -q systemd-rfkill.service systemd-rfkill.socket 2>/dev/null
    systemctl daemon-reload; udevadm control --reload >/dev/null 2>&1
    ENABLED=1; find_radios; radio_on "$INT"; radio_on "$EXT"
    rm -rf "$RUN_DIR"
    log "uninstalled: both radios on"
    echo "uninstalled (both radios on: $INT $EXT; keep the $CONF and $STATE_DIR for a reinstall)"
}

[ "$WIFI_GUARD_LIB" = "1" ] && return 0  # test-wifi-guard.sh sources the functions only

case "$1" in
    status) cmd_status ;;
    install) cmd_install "$2" ;;
    uninstall) cmd_uninstall ;;
    run) cmd_run ;;
    boot) cmd_boot ;;
    hotplug) cmd_hotplug "$2" ;;
    *) sed -n '2,24p' "$0"; exit 2 ;;
esac
