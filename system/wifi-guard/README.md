# Wi-Fi guard: one radio per beacon, or both with failover routing (v4)

Written 2026-09-30 (Gijs + Claude, on the control PC). **Status (2026-10-04): v1 live on the 4 working test beacons (`cde53af8`, `9e4fab63`, `226b5ac4`, `40ab815e`); v3 (probe back to internal after an outage, internal fixed as primary) on `feature/beacon-system`, passes the simulation, runbook steps 3-7 done on `05447fc6`. Next: step 8 (more test beacons). Decided 2026-10-04 (F): the fleet gets the guard with the external radios still blocked, then F unblocks them (steps 14-16).**
**Status (2026-10-09): v4 on branch `feature/wifi-multihome`, not on a beacon yet.** Beacons crash or disconnect
since the v3 wifi + performance updates (F, 2026-10-09); cause not proven yet, see [v4](#v4-multihome-both-radios-on-failover-by-routing).
Update the status table at the bottom whenever a step is done: this file is how Gijs and Friso stay in sync.

## v4: multihome (both radios on, failover by routing)

From the design notes "Raspberry Pi WLAN Failover" (F, 2026-10-09). v1-v3 fail over by **switching radios**: the
internal goes off, the external comes on and has to associate and get a lease, so every failover (and every probe
back) is an outage of the node socket, and a flapping internal means repeated outages. v4 adds `MODE=multihome`:

| | `single` (v3, still the default) | `multihome` (v4) |
|---|---|---|
| Radios on the network | one (two for at most 90 s during a probe) | **both, always**; no radio is ever switched off |
| UniFi clients per beacon | 1 | **2** (~500 for the fleet: why the externals were blocked, 2026-09-30) |
| Failover | swap radios after 120 s failing (offline while the other associates) | **route change** after `SLA_MAX_LOSS` (3) of the last `SLA_WINDOW` (6) probes lost, probes every 5 s: ~15 s, the standby radio is already associated |
| Failback | probe after 300 s, up to 3600 s | internal without loss for `FAILBACK_HOLD` (60 s) |
| Whole network down (master + gateway) | swaps after 120 s | no change: it moves only when the other path is **better** |

How the routing works (tested on Debian iproute2-ss190107, the buster generation, 2026-10-09):

- `ip rule` 1000/1001: traffic **from** the internal's / external's address leaves through that radio (tables 101/102),
  so the master can reach a beacon on both addresses and replies never cross radios.
- `ip rule` 1010 → table 100: everything else (the node socket, new connections) leaves through the **active path**.
- dhcpcd keeps the main table; a radio without an address simply falls through to it. `single` mode and
  `uninstall` remove the rules and tables (`mh_clear`).
- The probes are `ping -I <radio>`: bound to the radio, they bypass table 100, so each radio is measured on its own.
- On a failover the node socket to the master (it still has the old path's address) is closed with `ss -K`, so
  socket.io reconnects through the new path at once instead of after its ~30 s ping timeout. Best effort: a
  kernel without socket-destroy support leaves it to socket.io.
- ARP flux (two radios on one /22 answering for each other's address) is fixed by performance-update v4 (`arpflux`),
  also for the v3 probe.

Switching (per beacon, idempotent; the mode is stored in `/etc/default/ping-wifi-guard`):

```sh
bash /root/ping-slave/system/wifi-guard/wifi-guard.sh install live multihome   # both radios on
bash /root/ping-slave/system/wifi-guard/wifi-guard.sh install live single      # back to v3 behaviour
```

**Multihome needs F's go first**: UniFi must accept ~500 clients (more APs, or the APs' client limit), which nobody has
confirmed yet (qm, 2026-10-09). Decided 2026-10-09 (F): ship it switchable; the fleet gets v4 in `single` mode through
performance-update v4, then beacons are switched to `multihome` once UniFi is confirmed.

**Finding the crash cause first:** `wifi-guard.sh diag` (read-only, writes nothing) prints what a crash or a
disconnect leaves behind: reboots without a shutdown before them (`last -x`), under-voltage since boot
(`get_throttled` bit 16; powersave off + governor performance + the USB radio draw more current), memory and the
uptime of node/python (an app crash vs. a beacon reboot), kernel lines about brcmfmac/rt2800usb/USB resets/OOM, and the
guard's recent switches. Run it on the beacons that dropped before deciding it is wifi.

## Why

- Every beacon (Pi Zero W) has two radios: the **internal** one (driver `brcmfmac`, usually `wlan0`) and
  an **external USB** one (the Legra adapter, usually `wlan1`).
- The UniFi network has **5 APs for ~250 beacons**. With both radios on, the APs saw ~500 clients, which was
  too many. So the external radios were **blocked in UniFi** (Gijs, 2026-09-30).
- The catch: beacons whose **internal antenna is broken** can't get online now. They should fall back to the
  external radio, but the external radios can only be unblocked in UniFi once **every beacon with a working
  internal radio has switched its external radio off itself**. Otherwise the network is back at 500 clients.

## What the guard does

`wifi-guard.sh` installs a small service on the beacon (`ping-wifi-guard`) that keeps **at most one radio on**:

| Situation | What the guard does |
|---|---|
| Boot | internal radio on, external radio off (`rfkill`), before the network starts |
| Internal reaches the master | external stays off |
| Internal fails for 120 s (30 s when the previous boot ended on external) | **swap**: internal off first, then external on (never both on) |
| On external, external works, internal worked earlier this boot | after 300 s: **probe**: the internal is switched on **next to** the external (two radios for at most 90 s, the beacon stays online). Internal works (master or gateway answers through it): external off, back on internal. Not: internal off again, next probe after 600, 1200, ... up to 3600 s (v3) |
| On external, external works, internal never worked this boot | stays on external until the next boot (broken antenna: no probes, so no needless outages) |
| On external, external fails for 600 s | swap back to internal and try again |
| Only one radio present | keeps that one on |

- "Works" means: switched on, associated, has an IPv4 address and reaches the master (`192.168.8.50`, ping,
  or TCP port 4000) **or, when the master does not answer, its default gateway** (v2). In v1 only the master
  counted, so a master restart of a few minutes made every beacon swap to its external radio and stay there
  until the next boot (found by the simulation test, 2026-10-04).
- It recognises the radios **by driver** (`brcmfmac` = internal), not by name, because `wlan0`/`wlan1` can
  swap between boots.
- A random 0–30 s delay before each switch stops all beacons switching at the same moment after an AP outage.
- **Why probes (v3):** a network outage of more than 2 minutes (build-up, partial power cut) is common. Every beacon
  that stayed powered then swaps to its external radio, and once the network is back that one works, so in v2 it
  stayed there until a reboot. A probe switches the internal on next to the external, so the beacon never goes
  offline; two radios on for at most 90 s is fine (F, 2026-10-04). During a probe only checks bound to the internal
  radio count (`ping -I`; the TCP fallback is skipped because it could pass through the external). Checked
  2026-10-04 on `05447fc6` and `299acd7f`: master and gateway answer ICMP through `wlan0`. When the external goes
  off, the node app's socket on it drops and reconnects through the internal (a few seconds). `status` shows
  `(probing internal)` while a probe runs.
- **Two radios are only ever on during a probe** (at most `PROBE_WINDOW` s); the simulation fails on anything else.
- **The guard owns rfkill (v3):** `install` masks `systemd-rfkill` (`uninstall` unmasks it). It restored the
  rfkill state saved at shutdown *after* the guard's boot unit had run (journal of `cde53af8`, 2026-10-04), so a
  beacon shut down on its external radio could boot with the internal blocked.
- Settings: `/etc/default/ping-wifi-guard` (made on install, never overwritten). Log:
  `/var/log/ping-wifi-guard.log`. State: `/run/ping-wifi-guard/active`, `/var/lib/ping-wifi-guard/last-active`.

## Why the internal radio is the primary (measured 2026-10-04)

The internal radio is hard-coded as the preferred one. Hardware: internal = Cypress CYW43438 on the Pi Zero W (PCB
antenna, `brcmfmac`); external = Ralink RT5370 USB adapter (`148f:5370`, `rt2800usb`) on the micro-USB OTG port.
Both are the same class: 2.4 GHz only, one antenna, 802.11n, 72 Mbit/s link at 20 MHz.

Signal of the **same access point** seen by both radios (read-only; internal: `iw link`, external: `iw scan` of that
BSSID while it was on but not associated; `299acd7f` had both associated). dBm, higher is better:

| Beacon | internal | external | difference |
|---|---|---|---|
| `25cd1d0a` | -45 | -47 | internal +2 |
| `0e7ab203` | -43 | -55 | internal +12 |
| `190d23d5` | -54 | -57 | internal +3 |
| `8f5cea45` | -60 | -57 | external +3 |
| `34c1d188` | -58 | -63 | internal +5 |
| `821d7fe4` | -57 | -81 | internal +24 |
| `2d782d5b` | -48 | -57 | internal +9 |
| `f347b8fd` | -55 | -47 | external +8 |
| `1b1a1cc7` | -57 | -65 | internal +8 |
| `a4c00b23` | -56 | -61 | internal +5 |
| `299acd7f` | -50 | -59 | internal +9 |

Internal stronger on 9 of 11, median **5 dB** better; every internal link ran at 58-72 Mbit/s without retries. The
external also hangs on a USB adapter (an extra contact that can work loose, extra power). One scan per beacon is
noisy (a few dB); `821d7fe4` (-81 external) may have a badly seated adapter. Decided (F, 2026-10-04): internal stays
primary, no setting to switch it. (T5, a node-side `PING_ANTENNA` choice on a never-pushed branch, is dropped.)

## Commands (all idempotent, safe to push again)

On the beacon, as root (the master's `exec` already runs as root):

| Command | Effect |
|---|---|
| `bash /root/ping-slave/system/wifi-guard/wifi-guard.sh status` | read-only; first line `WIFI-GUARD OK / TWO-RADIOS-ON-NETWORK / NO-RADIO-ASSOCIATED`, then both radios (driver, MAC, on/off, signal, ip) |
| `... wifi-guard.sh install dry` | installs the guard in **dry run**: it only logs what it would switch, each decision once until it changes (not every 15 s: SD card writes) |
| `... wifi-guard.sh install live` | installs or updates it and lets it switch. Prints `ok v4` (nothing to do), `changed ...`, or `failed <reason>` |
| `... wifi-guard.sh install live multihome` / `... single` | (v4) sets the mode, see v4 above; `install` without a mode keeps it |
| `... wifi-guard.sh diag` | (v4) read-only crash/disconnect evidence: reboots, power, memory, app uptimes, kernel radio/USB lines, guard log |
| `... wifi-guard.sh uninstall` | removes it and switches **both** radios on again (2 clients per beacon!) |

From the control PC (`scripts\beacons` in ping-controller):

```powershell
$env:PING_BRANCH = 'feature/beacon-system'         # until the branch is merged into main
.\beacons.ps1 deploy <serial>                        # puts the script on the beacon (git reset + app restart)
.\beacons.ps1 exec <serial> "bash /root/ping-slave/system/wifi-guard/wifi-guard.sh status"
.\beacons.ps1 exec <serial> "bash /root/ping-slave/system/wifi-guard/wifi-guard.sh install live"
```

Read-only MAC survey that works **before** the script is on a beacon (for the UniFi lists):

```powershell
.\beacons.ps1 exec all "for i in /sys/class/net/wlan*; do echo `$(basename `$i) `$(basename `$(readlink -f `$i/device/driver)) `$(cat `$i/address); done"
```

## Rollout: every step, in order

Who: **G** = Gijs (control PC), **F** = Friso, **C** = Claude. Nothing on the master server changes.

### 0. Before anything

1. **F confirms the UniFi setup** as it is now: how the external radios are blocked (MAC block list, a
   per-client block, or something else) and whether that is the only change. *Not confirmed yet: nothing in
   this plan assumes it until F says so.*
2. ~~**G/F** commit this folder on a new ping-slave branch~~ Done 2026-10-04: committed on `feature/beacon-system`
   (from `main`, only new files plus the README), together with `system/beacon-tuning/` (now `system/performance-update/`).

### 1. One working beacon (test beacon `0000000005447fc6`: both radios, external not associated; `f0b5fdbc` has no external radio)

3. `deploy` the branch to it (above), then `status`: expect the internal radio `associated` with an ip, the
   external radio `on` but not associated (blocked in UniFi). Note both MACs.
4. `install dry`, wait 5 minutes, `status`: the log must say `dry run: would switch off wlan1 (...)` and nothing else.
5. `install live`, `status`: `WIFI-GUARD OK`, external `off`. The beacon stays connected to the master.
6. Run `install live` again: it must print `ok v3` (proves it is idempotent).
7. `reboot`, wait 3 minutes, `status`: internal on, external off, log shows `boot:`.

### 2. The other 3 working beacons

8. Same as 3–7, or directly `install live` once step 1 was clean. Stop at the first surprise.

### 3. The 4 beacons with a broken internal radio

9. Decided 2026-10-04 (F): the external radios are unblocked in UniFi only **after** the fleet has the guard (step 15),
   so these 4 come online then. Before that, only if F unblocks them early for a test.
10. The 4 appear in `list` (through the external radio). `deploy` the branch, `install live`, `status`: expect
    `active=ext`, internal `off` or not associated, external associated.
11. `reboot` one of them: it must come back through the external radio within about 1 minute (quick failover,
    because the previous boot ended on external).

### 4. The whole fleet

13. Merge `feature/beacon-system` into ping-slave `main` (F's call), so a normal `deploy` carries it.
14. With the external radios **still blocked** in UniFi: `fleet install live confirm` (wifi-guard-test.ps1, or the
    updater button **Wi-Fi guard ALL**): every connected beacon one by one, about 40 s each, so ~1.5 h for ~140
    beacons. Nothing changes on the network meanwhile: beacons whose internal radio works switch their (blocked)
    external off. Then `fleet status` until every connected beacon says `ok v3` and `WIFI-GUARD OK`; write the
    serials that did not answer in the status table below.
15. **F** unblocks the external radios in UniFi (decided 2026-10-04: install first, then unblock, so there is no
    window with ~500 clients). Only beacons without the guard come in with two radios: the broken-internal ones and
    any that were off or missed in 14.
16. Right after the unblock: `fleet install live confirm` again. Beacons that have the guard answer `ok v3`; the
    broken-internal ones (now online through their external radio) and the missed ones get it.
17. Check in UniFi: client count ≈ number of powered beacons (~250, not ~500). `status` on every beacon (per-beacon loop)
    must show no `TWO-RADIOS-ON-NETWORK`.
18. Every later build-up: re-run `install live` on all as part of the normal deploy. It's idempotent, so
    beacons that were missed get it.

### Rollback

- One beacon: `wifi-guard.sh uninstall` (both radios back on), or set `ENABLED=0` in
  `/etc/default/ping-wifi-guard` and `systemctl restart ping-wifi-guard`.
- Fleet: block the external radios in UniFi again first, then uninstall where needed.

## Updater integration (to build on ping-controller `dev`, not done yet)

- `beacons.ps1` / `beacons.sh`: new action `wifi-guard <status|install|uninstall> <serial|all> [dry|live]` that
  wraps the `exec` commands above (prints the real command with `▶`, `all` asks for confirmation for anything
  that isn't `status`).
- `remote/test-beacon.txt`: `wifi-guard-status [serial|all]` (read-only) and, only after G/F agree,
  `wifi-guard-install <serial> [dry|live]` (one beacon; `all` stays a manual action).
- `updater.ps1` changes go through a branch + the PowerShell check first (see AGENTS.md).

## Known risks

- **The master mixes up replies.** A reply to a command can be the output of another command (seen on
  2026-09-30: `0.68`, `1.93`, `1.58`, `1.00`, most likely a load-average poll by the controller). Scripts that
  read beacon output must check that the answer is theirs: `wifi-guard-test.ps1` writes each output to
  `/tmp/wgt-<token>.out` on the beacon and reads it again when the reply lacks the token. `beacons.ps1`/`.sh`
  don't do this yet.
- The master's `wLan1` field is only refreshed when a beacon reconnects, so `list` can show an old wlan1 ip.

- A radio whose driver has no `rfkill` is switched off with `ip link set down` instead. The loop re-applies
  that every 15 s. `status` shows which radio is which.
- `ping.py` has a `p` (probe) command that puts `wlan0` into monitor mode. On a beacon that runs on `wlan0`, that
  takes it off the network. Don't send `p` (it's also broken: it crashes right after switching).
- Beacons that are powered off during step 14 come up with both radios once the externals are unblocked, until
  step 16 reaches them (or the next build-up, step 18).
- v1 was tested on 4 beacons (status table). v2 changes what counts as "works" (gateway added), v3 adds the probes
  and masks systemd-rfkill; both pass the simulation and still need step 1 on a beacon. The 4 v1 beacons update
  with `install live`.
- When the master **and** the router are both unreachable for 2 minutes (AP or network outage), beacons still
  swap radios. v3: once the network is back they probe the internal after 5 minutes and return to it.
- **Fleet commands through the master: loop per beacon, don't use `exec all`.** The master's `/commands/execute`
  (all) only answers when the number of replies equals the number of connected sockets, and it takes the first
  reply a socket sends (`.once`). One beacon dropping mid-way, or a reply to another command, and the request hangs
  until the 4-minute HTTP timeout (`res.setTimeout` in ping-master `src/services/express.js`) with no results,
  although the command did run everywhere. Per-beacon calls with a token check (`wifi-guard-test.ps1`) are reliable.

## Simulation test

`bash system/wifi-guard/test-wifi-guard.sh` (Mac, Linux or Git Bash; ~10 s on a Mac, ~2 min in Git Bash) sources the real
functions and replaces only the hardware: two radios, the clock, whether the master and the gateway answer. It
checks after every switch that two radios are never on at once. Scenarios: healthy internal, internal dies,
internal broken from boot, quick failover after a boot that ended on external, master down 10 min (with and
without the external blocked in UniFi: 0 switches), whole network down 7 min (back on internal by a probe),
internal dies for good (probes back off: 300, 600, 1200 s, the external stays on), both radios broken. It fails
when two radios are on outside a probe or for longer than `PROBE_WINDOW` + one interval. A failing scenario prints its
simulated log. Run it after every change to the script.

v4 adds 8 multihome scenarios (`mh-*`, the probe and the routing replaced by the simulation): healthy, internal
dies (failover by 330 s, it lands at 310 s), internal lossy and internal flapping for 10 min (over and back once, not
per loss), master down, whole network down (no path change), internal broken from boot, external broken. A multihome
scenario fails when a radio is ever switched off. 17/17 ok on 2026-10-09.

## Status

| Date | Step | Result | By |
|---|---|---|---|
| 2026-09-30 | script + this runbook written, in the ping-slave clone on the control PC, not committed | - | G + C |
| 2026-09-30 13:36 | survey of the 4 connected beacons (step 3) | `cde53af8` and `9e4fab63`: **both radios associated** (2 clients each); `226b5ac4`, `40ab815e`: only internal. External radios: Ralink RT5370, driver `rt2800usb`, rfkill works | G + C |
| 2026-09-30 13:48 | `cde53af8` install dry (step 4) | log every 15 s: `would switch off wlan1`, nothing switched | G + C |
| 2026-09-30 13:58 | `cde53af8` install live (step 5) | `WIFI-GUARD OK`, external off, beacon stayed online | G + C |
| 2026-09-30 14:03 | `cde53af8` install live again, twice (step 6) | `ok v1`: idempotent | G + C |
| 2026-09-30 14:04 | `9e4fab63` install live (step 8) | `WIFI-GUARD OK`, external off, stayed online | G + C |
| 2026-09-30 14:04 | `cde53af8` reboot (step 7) | back online, internal on, external stays off from boot (`rfkill_soft=1`); it takes more than 2.5 min after the reboot command before it answers again: wait 4 min | G + C |
| 2026-09-30 14:16 | `226b5ac4`, `40ab815e` install live | both `WIFI-GUARD OK`, external off | G + C |
| 2026-09-30 14:31 | status of all 4 connected beacons | **all 4 `WIFI-GUARD OK`**: 1 radio each (internal), guard active, external off. Steps 3-8 done | G + C |
| 2026-10-04 | read-only `status` on `299acd7f` (guard not installed) | `TWO-RADIOS-ON-NETWORK`: internal and external (RT5370) both associated, same /22, two default routes | G + C |
| 2026-10-04 | simulation test written; v1 failed "master down 10 min" (whole fleet would swap to external) | v2: gateway counts as works; all 7 scenarios pass, never two radios on | G + C |
| 2026-10-04 | committed on ping-slave `feature/beacon-system`, test tool moved to ping-controller `scripts/wifi-guard/` | - | G + C |
| 2026-10-04 | API preflight (read-only) on `05447fc6`, `cde53af8`, `299acd7f`, `f0b5fdbc` | exec runs as root under `dash` (so always `bash <script>`), node v10 in `/root/ping-slave`, all tools present (iw ip ping systemctl udevadm install timeout cmp wpa_cli lsusb), all install paths writable, root fs rw, rfkill on both radios (rt2800usb + brcmfmac), master socket on `wlan0` on all four. `f0b5fdbc` has **no external radio** (not a good guard test beacon); `cde53af8` swapped to external at 10:04 after a network outage (v1, gateway not counted) | F + C |
| 2026-10-04 | v3: probes back to internal after an outage, systemd-rfkill masked; simulation 9 scenarios ok (v2 fails `network-down-7min-recovers`) | branch `feature/wifi-guard-failback`, not on a beacon yet | F + C |
| 2026-10-04 | v3 probe changed: internal on **next to** the external (no offline gap), ICMP-only checks during a probe; ICMP to master and gateway through `wlan0` verified on `05447fc6`, `299acd7f`; simulation 9/9 | not on a beacon yet | F + C |

| 2026-10-04 14:26 | review of #2 on the control PC, merged into `feature/beacon-system` (twice: 9e997d3, then the probe update 4df7b20); simulation 9/9 ok | risk to watch: ARP flux during a probe (both radios on the same /22) can fail a probe although the internal works | G + C |
| 2026-10-04 14:26-14:33 | `05447fc6` step 4: `install dry` (first v3 build, then reinstalled with 4df7b20) | 7 min: only `dry run: would switch off wlan1` every 15 s; `systemd-rfkill` service + socket masked | G + C |
| 2026-10-04 14:33 | `05447fc6` steps 5-6: `install live`, again | `changed mode:live`, external switched off, beacon stayed online; then `ok v3` | G + C |
| 2026-10-04 14:33-14:37 | `05447fc6` step 7: reboot (back after 3 min 18 s), `status` | `WIFI-GUARD OK`, internal on, external off. Boot unit ran before the USB radio existed (`external=none`), the udev hotplug rule switched it off 8 s later. beacon-tuning still `OK v2` | G + C |
| 2026-10-04 | review fixes: dry run logs a decision once (was every 15 s), `install.sh` locale typo fixed (and `>` instead of `>>`); radio survey of 11 beacons: internal stays primary | simulation 9/9 | F + C |
| 2026-10-04 | Codex review: a swap switches the other radio on only when the first is verified off (`radio_off` checks `is_blocked`); active set to internal when the external radio disappears; `systemd-rfkill` masked only in live mode (dry unmasks); rollout back to install first, then unblock | simulation 9/9 | F + C |
| 2026-10-04 15:06 | `05447fc6` updated to the Codex-fix build (`f0113d5`): `install live` | `changed ping-wifi-guard`, `WIFI-GUARD OK` | G + C |
| 2026-10-04 15:00-15:13 | fleet `status` (read-only, 139 beacons): 119 one radio no guard, 9 no external radio, **5 both radios on the network** (`14f108d3 27c90165 299acd7f b79245d4 e1278223`), 4 v1, 1 v3, 1 no answer (`1b1a1cc7`) | the first try stopped at 114/138 on an HTTP error (fixed in the tool, ping-controller `8713151`) | G + C |
| 2026-10-04 15:07-15:23 | step 8 on 5 beacons: `14f108d3 27c90165 299acd7f b79245d4` (both radios on the network) + `c9289c21`: `install dry`, ~6-13 min, `live`, `live` again | dry: one decision each (`would switch off wlan1`, logged once); live: `changed mode:live mask:systemd-rfkill.*`, external off, all stayed online; then `ok v3` | G + C |
| 2026-10-04 15:23-15:34 | step 8 reboots: `14f108d3` alone (back in 3 min 12 s), `27c90165`, then `299acd7f b79245d4 c9289c21` together (back in 3 min 10 s) | all 5 `WIFI-GUARD OK`, internal on, external off. Both boot paths seen: USB radio present at boot (boot unit switched it off: `27c90165`, `b79245d4`) and appearing ~8 s later (hotplug rule: `299acd7f`, `c9289c21`) | G + C |
| 2026-10-04 15:41-15:57 | step 14 (externals still blocked): `fleet install live confirm`, 8 at a time, from the command line (the updater on `dev` has no buttons yet) | 15 min 14 s, 160 beacons: 144 changed + 6 ok `WIFI-GUARD OK v3`, 9 changed `(no external radio seen)`, 1 no answer (`d6ebbe3d`, -82 dBm, done by serial); report has all 160 blocks | G + C |
| 2026-10-04 15:58 | fleet `status` | 1 min 31 s, 161: 159 one radio v3, 0 two radios; `fd961f32` (connected late, done by serial), `b48c5ab2` no answer (old code, deployed by F 16:16) | G + C |
| 2026-10-04 ~16:20 | F unblocks the external radios in UniFi; F deploys 40 beacons still on 0ae011f (16:22-16:24) | - | F |
| 2026-10-04 16:26-16:30 | step 16: `fleet install live confirm` again, 8 at a time | 3 min 22 s, 165: 160 ok, 3 changed (`165633a3 9e37fba1 b42e815e`), `f240a491` changed (status read 4 s before its first switch; external off at 16:29:59, -78 dBm), 1 no answer (`d6ebbe3d`, now disconnected) | G + C |
| 2026-10-04 16:35 | step 17: fleet `status`, 16 at a time | 49 s, 164 connected of 206: **all 164 `WIFI-GUARD OK v3`, all `active=int`, 0 on external, 0 two radios**. Open: `d6ebbe3d` disconnected (weak internal); no broken-internal beacon has come online through its external radio yet; UniFi client count to check (F) | G + C |
| 2026-10-09 | F: beacons crash or disconnect since the v3 wifi + performance updates; design notes "Raspberry Pi WLAN Failover" (both radios on, failover by routing) | v4 written: `MODE=multihome` (default stays `single`), `diag`; simulation 17/17; routing tested on Debian iproute2-ss190107 (tables, rules, probe bypass, fallback to main, clear); v3→v4 upgrade and idempotence tested in a container through performance-update v4. Branch `feature/wifi-multihome`, not on a beacon yet. Open: F confirms UniFi takes ~500 clients before any `multihome` | F + C |
Tested with `wifi-guard-test.ps1` (now in ping-controller `scripts/wifi-guard/`; it was `C:\Shared\Development\ping-wifi-guard\`) (sends the script to the beacon as a
here-document through the master, no branch needed; steps in `next.txt`, reports in `reports\`). The 4 beacons with a
broken internal radio were not reachable, so steps 9-11 are still open.
