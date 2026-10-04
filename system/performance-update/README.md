# Performance update: system settings for every beacon

(Called "beacon-tuning" until 2026-10-04 (v1-v2); renamed so "tuning" stays free for audio tuning. The status
table below keeps the old names as they were logged.)

Written 2026-10-04 (Gijs + Claude, on the control PC). **Status: v1 applied and rebooted on 1 beacon (`05447fc6`): OK.
v2 (governor) applied there and survives a reboot. Next: step 2 of the rollout (five beacons).**
Update the status table at the bottom whenever a step is done.

## Why

On 2026-10-04 four beacons (`05447fc6`, `d690162b`, `299acd7f`, `a224e248`) were read through the master's
`exec`. They all run the same image, so these findings hold for the whole fleet:

| Item | Found | Why it matters |
|---|---|---|
| `powersave` | wifi power saving **on** (`iw wlan0 get power_save`) | the radio sleeps between beacons from the AP: delay and jitter on every command, so beacons go off less in sync |
| `bluetooth` | `bluetoothd` and `hciuart` running | the Pi Zero W shares one radio chip between bluetooth and 2.4 GHz wifi; nothing in Ping uses bluetooth |
| `timers` | `apt-daily`, `apt-daily-upgrade`, `man-db` timers enabled | they start apt and man-db at random moments: CPU and SD-card load during a show, and apt tries to reach the internet |
| `locale` | `/etc/default/locale` has `LC_CTYPE="en_US.utf8` (no closing quote) | typo in `install.sh`; anything that reads the file as shell breaks on it |
| `governor` | cpu governor `ondemand`: 700 MHz idle, 1 GHz under load (set at every boot by `/etc/init.d/raspi-config`) | when a command arrives the cpu first has to ramp up from 700 MHz; `performance` keeps it at 1 GHz (Gijs, 2026-10-04) |

Checked and fine: NTP synced to the master, no throttling (`get_throttled=0x0`, ~47 °C), disk 29 %, root
mounted `noatime`, no failed units, small logs. Hardware check for `bluetooth`: the leds use PWM on GPIO13 and
the sound uses I2S (hifiberry-dac); neither uses the UART that `disable-bt` moves, and nothing reads serial.

## What the script does

`performance-update.sh` sets only what is not set yet, so it is safe to run again on every beacon at every build-up:

| Item | Change | Undo (`revert`) |
|---|---|---|
| `powersave` | dhcpcd hook `/lib/dhcpcd/dhcpcd-hooks/05-ping-wifi-powersave` switches power saving off on every wifi radio at every connect (also after a wifi-guard switch), and now on the radios that are up | hook removed, power saving on |
| `bluetooth` | `dtoverlay=disable-bt` appended to `/boot/config.txt` in an `[all]` section (backup in `/var/lib/ping-performance-update/config.txt`); `hciuart` and `bluetooth` disabled and stopped. The overlay works from the next boot | overlay line removed, services enabled (back after a reboot) |
| `timers` | the three timers masked (`systemctl mask --now`); `logrotate.timer` stays | unmasked and enabled |
| `locale` | `/etc/default/locale` rewritten with the same values, quotes fixed (backup in `/var/lib/ping-performance-update/locale`) | backup put back |
| `governor` | `ping-cpu-performance.service` (oneshot, after `raspi-config`) sets `performance` at every boot, and now | unit removed, `ondemand` |

It never reboots. Log: `/var/log/ping-performance-update.log`.

## Commands

On the beacon, as root (the master's `exec` already runs as root):

| Command | Effect |
|---|---|
| `bash /root/ping-slave/system/performance-update/performance-update.sh status` | read-only; first line `PERFORMANCE-UPDATE OK v3` or `PERFORMANCE-UPDATE TODO <items>`, plus `REBOOT-NEEDED` when the bluetooth overlay waits for a reboot |
| `... performance-update.sh apply` | prints `ok v3` (nothing to do), `changed <items>`, or `failed <items>`, then the status |
| `... performance-update.sh revert` | undoes all five |

From the control PC: the updater's buttons **Performance status** (read-only) and **Performance-update ALL** (`apply` on
every connected beacon one by one; beacons that are up to date answer `ok v3` and are not touched), or
`scripts\wifi-guard\wifi-guard-test.ps1` with `performance-status|performance-update <serial>`, `fleet performance-status`
and `fleet performance-update confirm` (token check, summary at the end). The tool sends the script from the ping-slave clone, so nothing needs to be deployed first.

## Rollout

1. One beacon: `apply`, `apply` again (`ok v3`), `reboot`, wait 4 minutes, `status`: `PERFORMANCE-UPDATE OK`, no
   `REBOOT-NEEDED`, `hci0=gone`, `wlan0=off`, `governor: performance 1000 MHz`. Play light and sound on it.
2. Five beacons the same way. Stop at the first surprise.
3. **Performance-update ALL** (or `fleet performance-update confirm`), then reboot all at a quiet moment
   (the bluetooth overlay needs it), then **Performance status (all)**. Not `exec all`: see the wifi-guard README, Known risks.
4. Every later build-up: **Performance-update ALL** again; it only touches beacons that are not up to date.

## Adding a step later (stacking updates)

`apply` only sets the items whose check fails, so updates stack: add one item to the script (`<item>_ok`,
`<item>_apply`, `<item>_revert`, the name in `ITEMS`), bump `VERSION`, add it to the table above, and run
**Performance-update ALL**. Every beacon reports `TODO <item>` and gets only that item; the rest is not touched.
Keep the check exact (the same file content, the same unit state) so a beacon never flips between OK and TODO.

Upgrading from beacon-tuning v2 (`05447fc6`): the first run reports `changed powersave governor` because the hook and
unit comments carry the new name; the backups move from `/var/lib/ping-beacon-tuning` to `/var/lib/ping-performance-update`.

## Not in this script

- **Swap** stays (Gijs, 2026-10-04; 100 MB on the SD card). Swap that is not used costs nothing; it was 0-3 MB used with ~290 MB RAM free.
- **Unused services** (avahi, triggerhappy, nfs-client, rsync, rpi-eeprom-update) stay: they use little RAM and
  almost no CPU. If wanted later: `systemctl disable --now`, not uninstalling.

## Status

| Date | Step | Result | By |
|---|---|---|---|
| 2026-10-04 11:52 | config read on 4 beacons | findings above | G + C |
| 2026-10-04 12:40 | `05447fc6`: `status`, `apply`, `apply` again | `changed powersave bluetooth timers locale`, then `ok v1`; `wlan0=off`, `hci0=gone`, beacon stayed online | G + C |
| 2026-10-04 13:55 | `05447fc6`: reboot (by Gijs) + `status` | `BEACON-TUNING OK v1`: power saving off at boot by the hook, `hci0=gone`, `ping.py` running | G + C |
| 2026-10-04 13:57 | v2 (governor) on `05447fc6`: `apply`, `apply` again | `changed powersave governor` (the hook carries the version), then `ok v2`; 10 samples over 10 s: arm 1000 MHz, core 400 MHz, 56-57 °C, `throttled=0x0`; light + sound sent | G + C |
| 2026-10-04 14:23 | `05447fc6`: reboot (14:19:59, back 14:23:18), read at 14:23:54 (up 2 min) | `scaling_governor=performance`: survives the reboot (the unit runs after raspi-config) | G + F |
| 2026-10-04 | renamed to performance-update v3 (was beacon-tuning); Codex review: `REBOOT-NEEDED` from a boot-id marker (stopping hciuart already removes `hci0`), `revert` removes only the overlay lines this script added and enables only the bluetooth units that were enabled before; read-only `status` of v3 on `05447fc6` (`TODO powersave governor`: renamed comments) and `299acd7f` (all five TODO) | not applied yet | F + C |
| 2026-10-04 15:05 | `05447fc6`: `apply` after the rename, again | `changed powersave governor` (renamed comments), then `ok v3` | G + C |
| 2026-10-04 15:07-15:15 | step 2 on 5 beacons (`14f108d3 27c90165 299acd7f b79245d4 c9289c21`): `apply` | `changed powersave bluetooth timers locale governor`, `OK REBOOT-NEEDED v3` | G + C |
| 2026-10-04 15:23-15:34 | step 2 reboots (see the wifi-guard table) + `status` | all 5 `PERFORMANCE-UPDATE OK v3` (no `REBOOT-NEEDED`), governor performance 1000 MHz, 45-63 °C, `throttled=0x0` | G + C |
| 2026-10-04 16:00-16:26 | step 3: `fleet performance-update confirm`, 8 at a time | 25 min 25 s, 161: 150 changed + 6 ok, 5 no answer (during F's deploy of 40 beacons 16:22-16:24) | G + C |
| 2026-10-04 16:30-16:34 | again, **16 at a time** | 3 min 52 s, 164: 157 ok, 7 changed (`165633a3 b42e815e b48c5ab2 f240a491 fa0034df fad0caec fd961f32`), **0 no answer**: all 164 `PERFORMANCE-UPDATE OK v3`; 158 still `REBOOT-NEEDED` (bluetooth overlay; reboot at a quiet moment) | G + C |
