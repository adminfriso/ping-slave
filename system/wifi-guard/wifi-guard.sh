#!/bin/bash
# ping-wifi-guard: the wifi radios of a Ping beacon. Two modes (MODE in the settings file):
#
#   single     (v1-v3, the default) at most ONE radio on the network, described below.
#   multihome  (v4) BOTH radios stay on the network. The internal radio is the primary path, the external one is a
#              standby path that is already associated. A probe bound to each radio (ping -I, SLA style: the last
#              SLA_WINDOW probes) decides which radio carries the traffic: policy routing (ip rule + tables
#              100-102), so a failover is a route change, never a radio switched off or a re-association. The
#              internal gets the traffic back after FAILBACK_HOLD s without loss. Costs 2 UniFi clients per beacon.
#              install live multihome also sets the ARP sysctls two radios on one subnet need; single removes them.
#
# Single mode. A beacon (Pi Zero W) has two radios: the internal one (driver brcmfmac) and an external USB one.
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
#   wifi-guard.sh install [dry|live] [single|multihome]  idempotent: installs/updates the guard, prints
#                             ok | changed | failed <reason>; dry = only log what it would switch (ENABLED=0),
#                             live = switch (ENABLED=1); the mode is kept in the settings file when not given
#   wifi-guard.sh diag        read-only crash/disconnect evidence: reboots, power, memory, radio errors, guard log
#   wifi-guard.sh uninstall   removes the guard and switches BOTH radios on again (2 clients per beacon!)
#   wifi-guard.sh run         the loop (started by systemd, ping-wifi-guard.service)
#   wifi-guard.sh boot        at boot: internal on, external off (ping-wifi-guard-boot.service)
#   wifi-guard.sh hotplug <if>  called by udev when a wlan interface appears
#   (multihome: the boot unit and hotplug switch every radio on)
#
# Settings: /etc/default/ping-wifi-guard (made on install when missing, never overwritten).
# Log: /var/log/ping-wifi-guard.log. Docs: README.md next to this file.

VERSION=4

SELF=/usr/local/sbin/ping-wifi-guard
CONF=/etc/default/ping-wifi-guard
STATE_DIR=/var/lib/ping-wifi-guard
RUN_DIR=/run/ping-wifi-guard
LOG=/var/log/ping-wifi-guard.log
UNIT_LOOP=/etc/systemd/system/ping-wifi-guard.service
UNIT_BOOT=/etc/systemd/system/ping-wifi-guard-boot.service
UDEV_RULE=/etc/udev/rules.d/70-ping-wifi-guard.rules
ARP_CONF=/etc/sysctl.d/90-ping-multihome.conf

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
MODE=single          # single = one radio on the network (v3); multihome = both on, routing picks the path (v4)
MH_INTERVAL=5        # multihome: s between probes
SLA_WINDOW=6         # multihome: probes remembered per radio
SLA_MAX_LOSS=3       # multihome: lost probes in the window that make a path degraded
FAILBACK_HOLD=60     # multihome: s the internal must be without loss before the traffic goes back to it

[ -r "$CONF" ] && . "$CONF"

log() { mkdir -p "$(dirname "$LOG")"; echo "$(date '+%F %T') $*" >> "$LOG"; }
trim_log() {
    [ -f "$LOG" ] && [ "$(stat -c %s "$LOG" 2>/dev/null || echo 0)" -gt 262144 ] &&
        tail -n 2000 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
}
dry_log() {  # dry run: log each decision once per boot (the loop repeats it every few s; SD writes, issue #12)
    mkdir -p "$RUN_DIR"
    grep -qxF "$*" "$RUN_DIR/dry-seen" 2>/dev/null && return 0
    echo "$*" >> "$RUN_DIR/dry-seen"; log "$*"
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
    if [ "$ENABLED" != "1" ]; then dry_log "dry run: would switch off $1 ($(driver_of "$1"))"; return 0; fi
    local r; r=$(rfkill_path "$1")
    if [ -n "$r" ]; then echo 1 > "$r/soft" 2>/dev/null; else
        wpa_cli -i "$1" disconnect >/dev/null 2>&1; ip link set "$1" down 2>/dev/null; fi
    # verify: a radio that did not go off must not be followed by switching the other one on (two radios)
    if ! is_blocked "$1"; then log "FAILED to switch off $1 ($(driver_of "$1") $(mac_of "$1"))"; return 1; fi
    log "switched off $1 ($(driver_of "$1") $(mac_of "$1"))"
}
radio_on() {
    [ -n "$1" ] || return 0
    is_blocked "$1" || return 0
    if [ "$ENABLED" != "1" ]; then dry_log "dry run: would switch on $1 ($(driver_of "$1"))"; return 0; fi
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
# a swap only switches the other radio on when the first one is really off; otherwise it stays as it is and the
# loop tries again at the next check
use_internal() { radio_off "$EXT" || return 1; radio_on "$INT"; active_set int; }
use_external() { radio_off "$INT" || return 1; radio_on "$EXT"; active_set ext; }

# ---------- multihome (v4): both radios on, policy routing picks the path ----------
# Tables: 101 = from the internal's address, 102 = from the external's address (each address answers through its
# own radio, so the master can reach a beacon on both), 100 = everything else, through the active path. dhcpcd keeps
# managing the main table; the rules sit before it (pref 1000-1010) and fall through to it when a table is empty.
MH_PREF_INT=1000; MH_PREF_EXT=1001; MH_PREF_PATH=1010
gw_of() { ip route show default dev "$1" 2>/dev/null | awk '{print $3; exit}'; }
net_of() {  # 192.168.9.17/22 -> 192.168.8.0/22
    local a b c d n m; IFS=./ read -r a b c d n <<< "$1"
    [ -n "$n" ] || return 1
    m=$(( (0xffffffff << (32 - n)) & 0xffffffff )); a=$(( (a << 24 | b << 16 | c << 8 | d) & m ))
    echo "$((a >> 24 & 255)).$((a >> 16 & 255)).$((a >> 8 & 255)).$((a & 255))/$n"
}
mh_fill() {  # $1 table, $2 radio: its subnet + default route, nothing when it has no address
    local cidr gw net
    cidr=$(ip -4 -o addr show dev "$2" 2>/dev/null | awk '{print $4; exit}')
    ip route flush table "$1" 2>/dev/null
    [ -n "$cidr" ] || return 1
    net=$(net_of "$cidr") || return 1
    ip route replace "$net" dev "$2" src "${cidr%/*}" table "$1"
    gw=$(gw_of "$2"); [ -n "$gw" ] && ip route replace default via "$gw" dev "$2" table "$1"
    return 0
}
mh_clear() {
    local p t
    for p in $MH_PREF_INT $MH_PREF_EXT $MH_PREF_PATH; do while ip rule del pref "$p" 2>/dev/null; do :; done; done
    for t in 100 101 102; do ip route flush table "$t" 2>/dev/null; done
    rm -f "$RUN_DIR/mh-sig"
}
mh_apply() {  # $1 = int|ext, the radio that carries the traffic. Reprograms only when something changed.
    local dev=$INT sig ii ei
    [ "$1" = ext ] && dev=$EXT
    ii=$(ip4_of "$INT"); ei=$(ip4_of "$EXT")
    sig="$1 $INT=$ii/$(gw_of "$INT") $EXT=$ei/$(gw_of "$EXT")"
    [ "$(cat "$RUN_DIR/mh-sig" 2>/dev/null)" = "$sig" ] && ip rule show 2>/dev/null | grep -q "^$MH_PREF_PATH:" && return 0
    if [ "$ENABLED" != "1" ]; then dry_log "dry run: would route through $1 ($dev)"; return 0; fi
    mh_clear
    [ -n "$ii" ] && mh_fill 101 "$INT" && ip rule add pref $MH_PREF_INT from "$ii" lookup 101
    [ -n "$ei" ] && mh_fill 102 "$EXT" && ip rule add pref $MH_PREF_EXT from "$ei" lookup 102
    mh_fill 100 "$dev" && ip rule add pref $MH_PREF_PATH lookup 100
    ip route flush cache 2>/dev/null
    mkdir -p "$RUN_DIR"; echo "$sig" > "$RUN_DIR/mh-sig"
}
mh_kick_socket() {  # $1 = the address of the path we left. The node socket to the master is pinned to it by rule
    # 1000/1001, so it would keep using the degraded radio: close it, socket.io reconnects through the new path now.
    # ss -K needs CONFIG_INET_DIAG_DESTROY in the kernel; without it socket.io reconnects after its ~30 s timeout.
    [ -n "$1" ] || return 0
    command -v ss >/dev/null || return 0
    ss -K src "$1" dst "$MASTER_IP" dport = ":$MASTER_PORT" >/dev/null 2>&1
    if ss -tn state established dst "$MASTER_IP" 2>/dev/null | grep -qF " $1:" && [ ! -f "$RUN_DIR/kick-failed" ]; then
        touch "$RUN_DIR/kick-failed"   # log once per boot (SD writes)
        log "kick failed: ss -K did not close the master socket on $1 (no INET_DIAG_DESTROY?); socket.io reconnects after its timeout"
    fi
    return 0
}

# ---------- ARP settings, multihome only (two radios on one /22 answer ARP for each other's address otherwise) ----
arp_content() {
    cat <<'EOF'
# ping-wifi-guard multihome: two wifi radios on one subnet. Each radio answers ARP only for its own address and
# announces only that one (no ARP flux); replies may come in on the other radio (loose reverse-path filter).
net.ipv4.conf.all.arp_ignore = 1
net.ipv4.conf.all.arp_announce = 2
net.ipv4.conf.all.rp_filter = 2
EOF
}
arp_sync() {  # multihome + live: the file and the values; otherwise: none, the values from before put back
    if [ "$MODE" = multihome ] && [ "$ENABLED" = "1" ]; then
        [ -f "$ARP_CONF" ] && arp_content | cmp -s - "$ARP_CONF" && return 0
        mkdir -p "$STATE_DIR"
        [ -f "$STATE_DIR/sysctl-arp" ] || for k in arp_ignore arp_announce rp_filter; do
            echo "net.ipv4.conf.all.$k=$(sysctl -n "net.ipv4.conf.all.$k" 2>/dev/null)"; done > "$STATE_DIR/sysctl-arp"
        arp_content > "$ARP_CONF.tmp" && chmod 644 "$ARP_CONF.tmp" && mv "$ARP_CONF.tmp" "$ARP_CONF"
        sysctl -q -p "$ARP_CONF" >/dev/null 2>&1
        CHANGED="$CHANGED arp:on"
    else
        [ -f "$ARP_CONF" ] || return 0
        rm -f "$ARP_CONF"
        [ -f "$STATE_DIR/sysctl-arp" ] && sysctl -q -p "$STATE_DIR/sysctl-arp" >/dev/null 2>&1 && rm -f "$STATE_DIR/sysctl-arp"
        CHANGED="$CHANGED arp:off"
    fi
}
sla_probe() {  # one probe bound to the radio: associated, an address, the master or else the gateway answers
    [ -n "$1" ] || return 1
    associated "$1" && [ -n "$(ip4_of "$1")" ] || return 1
    if [ "$MIN_SIGNAL" != "0" ]; then
        local s; s=$(signal_of "$1"); [ -n "$s" ] && [ "$s" -lt "$MIN_SIGNAL" ] && return 1
    fi
    ping -I "$1" -c 1 -W 1 "$MASTER_IP" >/dev/null 2>&1 && return 0
    local gw; gw=$(gw_of "$1"); [ -n "$gw" ] && ping -I "$1" -c 1 -W 1 "$gw" >/dev/null 2>&1
}
hist_push() {  # $1 history of 1/0, $2 the new result; keeps the last SLA_WINDOW (${h: -n} is empty when shorter)
    local h="$1$2"
    [ "${#h}" -gt "$SLA_WINDOW" ] && h=${h:$((${#h} - SLA_WINDOW))}
    echo "$h"
}
hist_lost() { local h=${1//1/}; echo ${#h}; }

cmd_run_multihome() {
    mkdir -p "$RUN_DIR" "$STATE_DIR"
    local path="" ih="" eh="" il el clean_since=0 now want kick_ip=""
    log "guard v$VERSION started (mode=multihome enabled=$ENABLED)"
    while true; do
        find_radios
        now=$(uptime_s)
        radio_on "$INT"; radio_on "$EXT"
        if sla_probe "$INT"; then ih=$(hist_push "$ih" 1); else ih=$(hist_push "$ih" 0); fi
        if sla_probe "$EXT"; then eh=$(hist_push "$eh" 1); else eh=$(hist_push "$eh" 0); fi
        il=$(hist_lost "$ih"); el=$(hist_lost "$eh")
        [ "${ih: -1}" = 1 ] && [ "$il" -eq 0 ] || clean_since=0
        [ "$clean_since" -eq 0 ] && [ "${ih: -1}" = 1 ] && [ "$il" -eq 0 ] && clean_since=$now
        want=$path
        if [ -z "$INT" ]; then want=ext
        elif [ -z "$EXT" ]; then want=int
        elif [ -z "$path" ]; then  # start: internal unless only the external answers
            if [ "${eh: -1}" = 1 ] && [ "${ih: -1}" != 1 ]; then want=ext; else want=int; fi
        elif [ "$path" = int ]; then
            # degraded internal: only move when the external is better, otherwise moving loses more
            [ "$il" -ge "$SLA_MAX_LOSS" ] && [ "${eh: -1}" = 1 ] && [ "$el" -lt "$il" ] && want=ext
        else
            if [ "$clean_since" -gt 0 ] && [ $((now - clean_since)) -ge "$FAILBACK_HOLD" ]; then want=int
            elif [ "$el" -ge "$SLA_MAX_LOSS" ] && [ "${ih: -1}" = 1 ] && [ "$il" -lt "$el" ]; then want=int; fi
        fi
        if [ "$want" != "$path" ]; then
            log "path ${path:-none} -> $want (internal $INT lost $il/${#ih}, external ${EXT:-none} lost $el/${#eh})"
            if [ -n "$path" ] && [ "$ENABLED" = "1" ]; then
                if [ "$path" = int ]; then kick_ip=$(ip4_of "$INT"); else kick_ip=$(ip4_of "$EXT"); fi
            fi
            path=$want; active_set "$path"
        fi
        mh_apply "$path"
        [ -n "$kick_ip" ] && { mh_kick_socket "$kick_ip"; kick_ip=""; }
        trim_log
        sleep "$MH_INTERVAL"
    done
}

cmd_diag() {  # read-only: what a crash or a disconnect left behind (no files written)
    local t
    echo "DIAG $(hostname) $(uptime -p 2>/dev/null) guard=v$(sed -n 's/^VERSION=//p' "$SELF" 2>/dev/null) mode=$MODE"
    t=$(vcgencmd get_throttled 2>/dev/null | cut -d= -f2)
    # bits 0-3 now, 16-19 since boot: under-voltage, freq capped, throttled, soft temp limit
    echo "  power: throttled=${t:-?} $( [ -n "$t" ] && [ $((t & 0x10000)) -ne 0 ] && echo 'UNDER-VOLTAGE-SINCE-BOOT') $(vcgencmd measure_temp 2>/dev/null)"
    echo "  load: $(cut -d' ' -f1-3 /proc/loadavg)"
    echo "  memory: $(free -m 2>/dev/null | awk '/Mem:/ {print "used " $3 " MB free " $4 " MB avail " $7 " MB"} /Swap:/ {print "swap " $3 " MB"}' | paste -sd' ')"
    echo "  apps: $(ps -eo comm,etimes,rss 2>/dev/null | awk '$1 ~ /^(node|python)/ {printf "%s up %ds %dMB; ", $1, $2, $3/1024}')"
    echo "  reboots (wtmp, a crash has no shutdown line before its reboot):"
    last -x -n 8 reboot shutdown 2>/dev/null | grep -E '^(reboot|shutdown)' | sed 's/^/    /'
    echo "  kernel (radios, usb, power, memory):"
    dmesg 2>/dev/null | grep -iE 'brcmf|rt2800|rt2x00|usb [0-9-]+: (reset|disconnect|new)|under-voltage|voltage|oom|out of memory|killed process|mmc0' | tail -n 15 | sed 's/^/    /'
    echo "  guard log: $(grep -cE 'switch (to|off|on)|path .* ->' "$LOG" 2>/dev/null || echo 0) switches/path changes in the log, last ones:"
    grep -E 'switch|path |probe|boot:|failing|kick' "$LOG" 2>/dev/null | tail -n 6 | sed 's/^/    /'
    for i in $(ls /sys/class/net | grep '^wlan'); do
        echo "  $i: $(describe "$i") retries=$(iw dev "$i" station dump 2>/dev/null | awk '/tx retries/ {print $3; exit}') fails=$(iw dev "$i" station dump 2>/dev/null | awk '/tx failed/ {print $3; exit}')"
    done
    echo "  arp: ignore=$(sysctl -n net.ipv4.conf.all.arp_ignore 2>/dev/null) announce=$(sysctl -n net.ipv4.conf.all.arp_announce 2>/dev/null) rp_filter=$(sysctl -n net.ipv4.conf.all.rp_filter 2>/dev/null)"
    echo "  rules: $(ip rule show 2>/dev/null | grep -E '^10(00|01|10):' | paste -sd';')"
    return 0
}

# ---------- commands ----------
cmd_status() {
    find_radios
    local inst="no" svc="-" n=0 verdict
    [ -x "$SELF" ] && inst="v$(sed -n 's/^VERSION=//p' "$SELF")"
    command -v systemctl >/dev/null && svc=$(systemctl is-active ping-wifi-guard.service 2>/dev/null)
    for i in $INT $EXT; do associated "$i" && n=$((n + 1)); done
    if [ "$MODE" = multihome ]; then  # two radios on the network is the point here; OK = the active path works
        case $n in 2) verdict="OK multihome" ;; 1) verdict="OK multihome (one radio associated)" ;; *) verdict=NO-RADIO-ASSOCIATED ;; esac
    else
        case $n in 1) verdict=OK ;; 0) verdict=NO-RADIO-ASSOCIATED ;; *) verdict=TWO-RADIOS-ON-NETWORK ;; esac
        [ -z "$EXT" ] && [ $n -eq 1 ] && verdict="OK (no external radio seen)"
        [ -f "$RUN_DIR/probing" ] && verdict="$verdict (probing internal)"
    fi
    echo "WIFI-GUARD $verdict installed=$inst service=$svc mode=$MODE enabled=$ENABLED active=$(active_get || echo -) last=$(cat "$STATE_DIR/last-active" 2>/dev/null || echo -)"
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
    if [ "$MODE" = multihome ]; then radio_on "$INT"; radio_on "$EXT"
    elif [ -n "$INT" ]; then use_internal; else radio_on "$EXT"; active_set ext; fi
    log "boot: internal=${INT:-none} external=${EXT:-none} previous boot ended on $(cat "$RUN_DIR/previous-boot" 2>/dev/null || echo -)"
}

cmd_hotplug() {  # udev: a wlan interface appeared (the USB radio can appear after the boot unit)
    local i=$1 a
    [ -n "$i" ] && is_wireless "$i" || exit 0
    [ "$MODE" = multihome ] && { radio_on "$i"; exit 0; }
    a=$(active_get)
    if [ "$(driver_of "$i")" = "$INTERNAL_DRIVER" ]; then
        if [ "$a" = "ext" ]; then radio_off "$i"; else radio_on "$i"; fi
    else
        if [ "$a" = "ext" ]; then radio_on "$i"; else radio_off "$i"; fi
    fi
}

cmd_run() {
    [ "$MODE" = multihome ] && { cmd_run_multihome; return; }
    mh_clear  # back from multihome: no leftover policy routes
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
        # no external radio (unplugged while active?): the internal is the active one, so a re-plugged adapter is
        # switched off by the hotplug instead of on next to the internal
        if [ -z "$EXT" ]; then radio_on "$INT"; active_set int; sleep "$INTERVAL"; continue; fi
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
        sed -n '/^# defaults/,/^FAILBACK_HOLD=/p' "$src" | sed '1d; s/^/#/' |
            { echo "# ping-wifi-guard settings: remove the # to change a value"; cat; } > "$CONF"
        CHANGED="$CHANGED $(basename "$CONF")"
    fi
    local a
    for a in "$@"; do case "$a" in  # install [dry|live] [single|multihome]: set it in the settings file (idempotent)
        single|multihome)
            if ! grep -qx "MODE=$a" "$CONF"; then
                sed -i '/^MODE=/d' "$CONF"; echo "MODE=$a" >> "$CONF"
                CHANGED="$CHANGED mode:$a"
            fi
            MODE=$a ;;
    esac; done
    for a in "$@"; do case "$a" in
        dry|live)
            local want=1; [ "$a" = dry ] && want=0
            if ! grep -qx "ENABLED=$want" "$CONF"; then
                sed -i '/^ENABLED=/d' "$CONF"; echo "ENABLED=$want" >> "$CONF"
                CHANGED="$CHANGED mode:$a"
            fi
            ENABLED=$want ;;
    esac; done
    arp_sync
    write_if_changed "$UNIT_BOOT" 644 <<EOF && UNITS=1
[Unit]
Description=Ping wifi guard: radios at boot (internal first; external off unless MODE=multihome)
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
Description=Ping wifi guard: one radio on the network, or both with failover routing (MODE)
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
    # Only in live mode: a dry run switches nothing, so after a reboot the saved state must still be restored.
    for u in systemd-rfkill.service systemd-rfkill.socket; do
        if [ "$ENABLED" = "1" ]; then
            [ "$(systemctl is-enabled "$u" 2>/dev/null)" = "masked" ] || { systemctl mask -q "$u" 2>/dev/null; CHANGED="$CHANGED mask:$u"; }
        else
            [ "$(systemctl is-enabled "$u" 2>/dev/null)" = "masked" ] && { systemctl unmask -q "$u" 2>/dev/null; CHANGED="$CHANGED unmask:$u"; }
        fi
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
    ENABLED=1; find_radios; radio_on "$INT"; radio_on "$EXT"; mh_clear
    MODE=single; arp_sync
    rm -rf "$RUN_DIR"
    log "uninstalled: both radios on"
    echo "uninstalled (both radios on: $INT $EXT; keep the $CONF and $STATE_DIR for a reinstall)"
}

[ "$WIFI_GUARD_LIB" = "1" ] && return 0  # test-wifi-guard.sh sources the functions only

case "$1" in
    status) cmd_status ;;
    install) shift; cmd_install "$@" ;;
    diag) cmd_diag ;;
    uninstall) cmd_uninstall ;;
    run) cmd_run ;;
    boot) cmd_boot ;;
    hotplug) cmd_hotplug "$2" ;;
    *) sed -n '2,42p' "$0"; exit 2 ;;
esac
