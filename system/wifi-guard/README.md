# Wi-Fi guard: one radio per beacon

Written 2026-09-30 (Gijs + Claude, on the control PC). **Status: v1 live on the 4 working test beacons (`cde53af8`, `9e4fab63`, `226b5ac4`, `40ab815e`); v2 on `feature/beacon-system`, v3 (probe back to internal after an outage, 2026-10-04) on `feature/wifi-guard-failback`; both pass the simulation, neither is on a beacon yet. Next: install v3 on one test beacon with both radios (step 1). Decided 2026-10-04 (F): all external radios are unblocked in UniFi before the fleet rollout.**
Update the status table at the bottom whenever a step is done: this file is how Gijs and Friso stay in sync.

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
| On external, external works, internal worked earlier this boot | every 300 s: **probe** the internal (swap to it). Works within 90 s: stay on internal. Not: back to external, next probe after 600, 1200, ... up to 3600 s (v3) |
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
  stayed there until a reboot. A radio can only be tested by switching to it, so a probe costs the beacon about
  10-20 s offline when the internal works, and up to 90 s + reconnect when it does not (then rarer and rarer).
- **The guard owns rfkill (v3):** `install` masks `systemd-rfkill` (`uninstall` unmasks it). It restored the
  rfkill state saved at shutdown *after* the guard's boot unit had run (journal of `cde53af8`, 2026-10-04), so a
  beacon shut down on its external radio could boot with the internal blocked.
- Settings: `/etc/default/ping-wifi-guard` (made on install, never overwritten). Log:
  `/var/log/ping-wifi-guard.log`. State: `/run/ping-wifi-guard/active`, `/var/lib/ping-wifi-guard/last-active`.

## Commands (all idempotent, safe to push again)

On the beacon, as root (the master's `exec` already runs as root):

| Command | Effect |
|---|---|
| `bash /root/ping-slave/system/wifi-guard/wifi-guard.sh status` | read-only; first line `WIFI-GUARD OK / TWO-RADIOS-ON-NETWORK / NO-RADIO-ASSOCIATED`, then both radios (driver, MAC, on/off, signal, ip) |
| `... wifi-guard.sh install dry` | installs the guard in **dry run**: it only logs what it would switch |
| `... wifi-guard.sh install live` | installs or updates it and lets it switch. Prints `ok v3` (nothing to do), `changed ...`, or `failed <reason>` |
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
   (from `main`, only new files plus the README), together with `system/beacon-tuning/`.

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

9. Decided 2026-10-04 (F): the external radios are unblocked in UniFi before the fleet rollout (step 14), so
   these 4 come online then. Before that, only if F unblocks them early for a test.
10. The 4 appear in `list` (through the external radio). `deploy` the branch, `install live`, `status`: expect
    `active=ext`, internal `off` or not associated, external associated.
11. `reboot` one of them: it must come back through the external radio within about 1 minute (quick failover,
    because the previous boot ended on external).

### 4. The whole fleet

13. Merge `feature/beacon-system` into ping-slave `main` (F's call), so a normal `deploy` carries it.
14. **F** unblocks the external radios in UniFi (decided 2026-10-04). Until a beacon has the guard it is on the
    network with both radios, so the client count goes up (towards ~500) until 15 is done: do 15 right after.
15. `deploy all`, then `install live` and `status` **per beacon** in a loop with the token check (see Known risks:
    not `exec all`). Repeat until every connected beacon says `ok v3` and `WIFI-GUARD OK`. Compare with `list`:
    beacons that were **not connected** don't have the guard yet. Write their serials in the status table below.
16. The broken-internal beacons are online through their external radio now: they get the guard in 15 like the rest.
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
  step 18 reaches them.
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

`bash system/wifi-guard/test-wifi-guard.sh` (Mac, Linux or Git Bash; ~2 min in Git Bash) sources the real
functions and replaces only the hardware: two radios, the clock, whether the master and the gateway answer. It
checks after every switch that two radios are never on at once. Scenarios: healthy internal, internal dies,
internal broken from boot, quick failover after a boot that ended on external, master down 10 min (with and
without the external blocked in UniFi: 0 switches), whole network down 7 min (back on internal by a probe),
internal dies for good (probes back off: 300, 600, 1200 s), both radios broken. A failing scenario prints its
simulated log. Run it after every change to the script.

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

Tested with `wifi-guard-test.ps1` (now in ping-controller `scripts/wifi-guard/`; it was `C:\Shared\Development\ping-wifi-guard\`) (sends the script to the beacon as a
here-document through the master, no branch needed; steps in `next.txt`, reports in `reports\`). The 4 beacons with a
broken internal radio were not reachable, so steps 9-11 are still open.
