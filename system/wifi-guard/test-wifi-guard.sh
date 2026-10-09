#!/bin/bash
# Simulation test of wifi-guard.sh's switching logic (cmd_boot + cmd_run). Runs on any bash (Mac, Linux,
# Git Bash on Windows), needs no beacon and changes nothing: the real functions are sourced, only the
# hardware is replaced (two radios, the clock, whether the master and the gateway answer).
#
#   bash system/wifi-guard/test-wifi-guard.sh        prints one line per scenario, exit 1 when one fails

HERE=$(cd "$(dirname "$0")" && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
FAILS=0

scenario() {  # $1 name, $2 seconds to simulate, $3 events function, $4 check function
    (
        export WIFI_GUARD_LIB=1
        WANT_MODE=${MODE:-single}  # the script's defaults below would reset MODE
        CONF=/nonexistent
        . "$HERE/wifi-guard.sh"
        RUN_DIR=$TMP/$1/run; STATE_DIR=$TMP/$1/state; LOG=$TMP/$1/log
        rm -rf "$TMP/$1"; mkdir -p "$RUN_DIR" "$STATE_DIR"
        [ -n "$PREV" ] && echo "$PREV" > "$STATE_DIR/last-active"
        ENABLED=1
        MODE=$WANT_MODE; PATH_NOW=""; PATHCH=0; FIRST_EXT=-; OFFS=0
        LOSS_wlan0=0; LOSS_wlan1=0     # multihome: 1 = every probe lost, alt = every other probe lost
        CLOCK=0; END=$2; SWITCHES=0; BOTH_ON=0; BOTH_FOR=0
        ON_wlan0=1; ON_wlan1=1          # the kernel brings both radios up at boot
        WORKS_wlan0=1; WORKS_wlan1=1     # the radio itself can associate (0 = broken antenna / blocked in UniFi)
        MASTER=1; GATEWAY=1
        EVENTS=$3

        uptime_s() { echo "$CLOCK"; }
        find_radios() { INT=wlan0; EXT=wlan1; }
        driver_of() { [ "$1" = wlan0 ] && echo brcmfmac || echo rt2800usb; }
        mac_of() { echo "mac-$1"; }
        on() { eval "[ \"\$ON_$1\" = 1 ]"; }
        is_blocked() { ! on "$1"; }
        associated() { on "$1" && eval "[ \"\$WORKS_$1\" = 1 ]"; }
        signal_of() { associated "$1" && echo -50; }
        ip4_of() { associated "$1" && echo 192.168.10.1; }
        reaches_master() { associated "$1" && [ "$MASTER" = 1 ]; }
        reaches_gateway() { associated "$1" && [ "$GATEWAY" = 1 ]; }
        radio_off() { [ -n "$1" ] && on "$1" || return 0; eval "ON_$1=0"; OFFS=$((OFFS + 1)); log "switched off $1"; }
        sla_probe() {
            associated "$1" || return 1
            local l; eval "l=\$LOSS_$1"
            [ "$l" = 1 ] && return 1
            [ "$l" = alt ] && [ $((CLOCK / MH_INTERVAL % 2)) = 0 ] && return 1
            [ "$MASTER" = 1 ] || [ "$GATEWAY" = 1 ]
        }
        mh_apply() {
            [ "$1" = "$PATH_NOW" ] && return 0
            [ -n "$PATH_NOW" ] && PATHCH=$((PATHCH + 1))
            [ "$1" = ext ] && [ "$FIRST_EXT" = - ] && FIRST_EXT=$CLOCK
            PATH_NOW=$1
        }
        mh_clear() { :; }
        mh_kick_socket() { :; }
        radio_on() {
            [ -n "$1" ] && ! on "$1" || return 0
            eval "ON_$1=1"; SWITCHES=$((SWITCHES + 1)); log "switched on $1"
        }
        log() { echo "t=$CLOCK $*" >> "$LOG"; }
        sleep() {
            # two radios on is allowed only during a probe, for at most PROBE_WINDOW + one check interval
            if [ "$MODE" = multihome ]; then  # multihome: no radio may ever be switched off
                [ "$OFFS" -gt 0 ] && BOTH_ON=1
            elif on wlan0 && on wlan1; then
                BOTH_FOR=$((BOTH_FOR + ${1%.*})); [ "$BOTH_FOR" -gt $((PROBE_WINDOW + INTERVAL)) ] && BOTH_ON=1
                [ -f "$RUN_DIR/probing" ] || BOTH_ON=1
            else BOTH_FOR=0; fi
            CLOCK=$((CLOCK + ${1%.*}))
            $EVENTS
            if [ "$CLOCK" -ge "$END" ]; then
                [ "$MODE" = multihome ] && SWITCHES=$PATHCH
                echo "$(cat "$RUN_DIR/active") $SWITCHES $BOTH_ON $ON_wlan0 $ON_wlan1 $FIRST_EXT" > "$TMP/result"
                exit 0
            fi
        }
        $EVENTS  # the state at t=0 (e.g. a radio broken from boot), not only after the first sleep
        cmd_boot
        BOTH_ON=0  # the kernel had both up before the boot unit; count only what the guard does after that
        cmd_run
    )
    local active switches both int ext first_ext
    read -r active switches both int ext first_ext < "$TMP/result"
    local verdict
    verdict=$(FIRST_EXT=$first_ext $4 "$active" "$switches" "$int" "$ext")
    if [ "$both" = 1 ]; then
        if [ "$MODE" = multihome ]; then verdict="FAIL multihome switched a radio off"
        else verdict="FAIL two radios on outside a probe, or longer than PROBE_WINDOW"; fi
    fi
    if [ "${verdict%% *}" = ok ]; then echo "ok    $1: $verdict"; else echo "FAIL  $1: $verdict"; sed 's/^/        /' "$TMP/$1/log"; FAILS=$((FAILS + 1)); fi
    rm -f "$TMP/result"
}

expect() {  # $1 active $2 int-on $3 ext-on $4 max switches, against the result
    local want_active=$1 want_int=$2 want_ext=$3 max=$4
    shift 4
    local a=$1 s=$2 i=$3 e=$4
    if [ "$a" = "$want_active" ] && [ "$i" = "$want_int" ] && [ "$e" = "$want_ext" ] && [ "$s" -le "$max" ]; then
        echo "ok (on $a, internal=$i external=$e, $s switch-ons)"
    else
        echo "FAIL want $want_active/$want_int/$want_ext max $max switch-ons, got $a internal=$i external=$e, $s switch-ons"
    fi
}

no_events() { :; }
internal_dies_at_300() { [ "$CLOCK" -ge 300 ] && WORKS_wlan0=0; }
master_down_300_to_900() { if [ "$CLOCK" -ge 300 ] && [ "$CLOCK" -lt 900 ]; then MASTER=0; else MASTER=1; fi; }
master_down_ext_blocked() { WORKS_wlan1=0; master_down_300_to_900; }
network_down_300_to_700() { if [ "$CLOCK" -ge 300 ] && [ "$CLOCK" -lt 700 ]; then MASTER=0; GATEWAY=0; else MASTER=1; GATEWAY=1; fi; }
network_down_ext_blocked() { WORKS_wlan1=0; network_down_300_to_700; }
internal_broken() { WORKS_wlan0=0; }
internal_broken_ext_blocked() { WORKS_wlan0=0; WORKS_wlan1=0; }

check_stays_internal() { expect int 1 0 0 "$@"; }
check_on_external() { expect ext 0 1 1 "$@"; }
check_back_on_internal() { expect int 1 0 2 "$@"; }
check_probes_back_off() { expect ext 0 1 4 "$@"; }  # failover + 3 failed probes (300, 600, 1200 s), external stays on
check_one_radio() {  # any radio, but exactly one on
    if [ $(($3 + $4)) -eq 1 ]; then echo "ok (on $1, one radio, $2 switch-ons)"; else echo "FAIL $3 + $4 radios on"; fi
}

scenario healthy-internal            3600 no_events                  check_stays_internal
scenario internal-dies-probes-back-off 3000 internal_dies_at_300     check_probes_back_off
scenario internal-broken-from-boot    600 internal_broken            check_on_external
PREV=ext scenario quick-failover-after-ext-boot 150 internal_broken check_on_external
scenario master-down-10min           1500 master_down_300_to_900     check_stays_internal
scenario master-down-ext-blocked     2400 master_down_ext_blocked    check_stays_internal
scenario network-down-7min-recovers  2400 network_down_300_to_700    check_back_on_internal
scenario network-down-ext-blocked    2400 network_down_ext_blocked   check_back_on_internal
scenario both-broken                 3600 internal_broken_ext_blocked check_one_radio

# ---------- multihome (v4): both radios stay on, only the route moves; 2nd column = path changes ----------
mh_check() {  # $1 path $2 max path changes [$3 latest failover time], then the result
    local want=$1 max=$2 by=$3; shift 3
    local a=$1 c=$2 i=$3 e=$4
    if [ "$a" != "$want" ] || [ "$i$e" != 11 ] || [ "$c" -gt "$max" ]; then
        echo "FAIL want path $want, both radios on, max $max path changes; got $a internal=$i external=$e, $c changes"
    elif [ "$by" != - ] && { [ "$FIRST_EXT" = - ] || [ "$FIRST_EXT" -gt "$by" ]; }; then
        echo "FAIL failover to external at ${FIRST_EXT} s, want by $by s"
    else echo "ok (path $a, both radios on, $c path changes, first on external at ${FIRST_EXT})"; fi
}
mh_internal_dies_at_300() { [ "$CLOCK" -ge 300 ] && LOSS_wlan0=1; }
mh_internal_lossy_300_to_900() { if [ "$CLOCK" -ge 300 ] && [ "$CLOCK" -lt 900 ]; then LOSS_wlan0=alt; else LOSS_wlan0=0; fi; }
mh_internal_flaps_300_to_900() {  # 20 s lost, 40 s fine, again and again
    if [ "$CLOCK" -ge 300 ] && [ "$CLOCK" -lt 900 ] && [ $(((CLOCK - 300) % 60)) -lt 20 ]; then LOSS_wlan0=1; else LOSS_wlan0=0; fi
}
mh_internal_broken() { LOSS_wlan0=1; }
mh_external_broken() { LOSS_wlan1=1; }

mh_stays_internal() { mh_check int 0 - "$@"; }
mh_fails_over_fast() { mh_check ext 1 330 "$@"; }       # 300 s + SLA_MAX_LOSS probes of MH_INTERVAL s, + margin
mh_back_on_internal() { mh_check int 2 330 "$@"; }      # over and back once, not per loss
mh_on_external() { mh_check ext 0 - "$@"; }

MODE=multihome scenario mh-healthy                1800 no_events                    mh_stays_internal
MODE=multihome scenario mh-internal-dies          1800 mh_internal_dies_at_300       mh_fails_over_fast
MODE=multihome scenario mh-internal-lossy-recovers 1800 mh_internal_lossy_300_to_900 mh_back_on_internal
MODE=multihome scenario mh-internal-flaps-recovers 1800 mh_internal_flaps_300_to_900 mh_back_on_internal
MODE=multihome scenario mh-master-down-10min      1500 master_down_300_to_900        mh_stays_internal
MODE=multihome scenario mh-network-down-7min      2400 network_down_300_to_700       mh_stays_internal
MODE=multihome scenario mh-internal-broken-from-boot 600 mh_internal_broken         mh_on_external
MODE=multihome scenario mh-external-broken        1800 mh_external_broken            mh_stays_internal

[ "$FAILS" -eq 0 ] && echo "all scenarios ok" || { echo "$FAILS scenario(s) failed"; exit 1; }
