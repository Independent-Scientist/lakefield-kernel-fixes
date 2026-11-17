# The UFS wedge

Internal storage on this machine is a 256 GB UFS 3.1 device that reports itself
as `SAMSUNG` / model `KLUEG8UHDB-C2D1` (`cat /sys/block/sda/device/{vendor,model}`),
behind the Intel Lakefield UFS controller `8086:98fa` at PCI `0000:00:12.5`,
exposed as a SCSI disk. That model string is the thing to search for if you are
trying to find out whether your own laptop's UFS works on Linux. It is the
only fast storage in the machine — there is no NVMe at all — which is why losing
it is fatal rather than annoying.

## The failure

`ufshcd_wl_probe()` sets runtime PM up with a 0 ms autosuspend delay, so the
well-known LUN runtime-suspends the moment nothing is using it. The **resume**
that follows is what breaks:

```
ufshcd_wl_runtime_resume()
  -> ufshcd_reset_and_restore()
    -> ufshcd_post_device_init()
      -> ufshcd_config_pwr_mode()
        -> ufs_intel_lkf_pwr_change_notify(POST_CHANGE)
          -> ufshcd_dme_peer_get(UIC_ARG_MIB(PA_GRANULARITY))   /* 0x15AA */
```

On this Intel Lakefield host that peer read never completes: three retries,
`saved_uic_err 0x4`, then `eh_non_fatal` and a forced host reset, every time.
Three or four of those later the controller parks in `HBA state error` — and
from then on every read of the disk returns `-EIO` until the machine reboots. A
reader caught in the middle can sit in `D` state and hang the shell with it.

The same read also fires on **system** resume, which is where most people would
first notice. Numbers from the wedged state: 332 `ufshcd` kernel log lines in one
boot, `ioerr_cnt` at `0x65`, and a disk that no longer answers.

## The two patches

### 0001 — forbid runtime PM at probe

`drivers/ufs/core/ufshcd.c` and `drivers/ufs/host/ufshcd-pci.c`:
`pm_runtime_forbid()` instead of `pm_runtime_allow()` in `ufshcd_wl_probe()` and
`ufshcd_pci_probe()`. The runtime-resume path is the one that wedges the
controller, so the controller simply never runtime-suspends.

There are two ways to pin it and they are not equivalent:

- a udev rule setting `power/control=on` works, but only from the moment udev
  runs. Fine for a data disk, **too late for a root disk**, whose LUKS volume has
  to be unlocked inside the initramfs long before udev exists.
- the driver patch pins it at probe, before any userspace ordering can matter.

That difference is the whole reason this is a patch and not a rule. The udev rule
this replaced has been retired from the machine; with the driver patch alone both
the WLUN (`0:0:0:49488`) and the PCI function report `power/control=on`.

### 0002 — drop the discarded `PA_GRANULARITY` read

`drivers/ufs/host/ufshcd-pci.c`: in `ufs_intel_lkf_pwr_change_notify()`'s
`POST_CHANGE` branch, the result of `ufshcd_dme_peer_get(PA_GRANULARITY)` is read
into a local and thrown away. Keep the 1.0–1.25 ms settle delay, drop the read.

The **identical** read in `ufs_intel_lkf_apply_dev_quirks()` is deliberately left
alone: there the value is compared against the host's granularity, so it is doing
work. Don't "clean that one up too" — you would break the quirk handling.

This patch is the one that makes a cold boot quiet. It does not make suspend safe.

## Evidence

All measured on the machine this was written for, kernel 7.2.14-arch1-1.

| test | before | after 0001+0002 |
|---|---|---|
| cold boot, `journalctl -k \| grep -c 'ufshcd 0000:00:12.5:'` | 2 with the udev rule only (and the rule cannot help a root disk); 11 with 0001 alone, 6 × `0x15aa`, 1 `WARNING: core/ufshcd.c` | **5 lines, 0 `0x15aa`, 0 ufshcd WARN, 0 host resets** |
| idle wedge after probe | wedges within seconds; `ioerr_cnt` `0x65`, 332 log lines | link stays up, `ioerr_cnt` flat at `0x3` |
| 32 GiB of zeros written and read back (`tools/ufs/ufs-test2.sh`) | wedge mid-test | write 418 MB/s, read 860 MB/s, kernel log byte-identical |
| 4 GiB incompressible random data, sha256 per 256 MiB chunk, two `O_DIRECT` read-back passes (`tools/ufs/ufs-test3.sh`) | — | write 366 MB/s, 0 mismatches on both passes, log silent, `ioerr_cnt` `0x3` → `0x3` |
| verifier timer at boot+3 min | — | PASS on every run across 4 boots |
| system suspend (`s2idle`), 3 samples | — | 2 survived only after 5 and 4 host resets; **sample 3 never recovered** |

Two notes on reading those numbers, because they cost time:

- The throughput figures are `dd`-with-hash figures, not pure disk
  numbers — the hasher runs in the same pipeline. If you need disk speed, measure
  the hasher alone first.
- `ioerr_cnt` reads `0x3`–`0x4` right after probe, so the absolute value means
  nothing. Only the delta does.

## Daily health check

```sh
journalctl -k -b --no-pager | grep -c 'ufshcd 0000:00:12.5:'   # 2 benign, ~5 healthy, 300+ wedged
journalctl -k -b --no-pager | grep -c 'ufshcd.*0x15aa'         # want 0
cat /sys/bus/scsi/devices/*/power/control                      # the ufs_device_wlun must say "on"
```

`tools/ufs/ufs-afterboot-check.sh` does all of this plus two `O_DIRECT` reads and
a 120 s idle, and writes PASS/FAIL to its result file. It discovers the `ufshcd`
host, the WLUN and the block device from `/sys/class/scsi_host/*/proc_name`
rather than hardcoding `host0`/`sda`: `ufshcd` came up as `host1` in one boot and
`host0` in the next on this very machine, and a hard-coded path silently checks
the wrong device (or checks the wrong property — `0:0:0:0` is `control=on` by
default for every `sd` disk, so a pin check against it passes no matter what).
The verifier FAILs outright if the WLUN is not `on`.

The systemd pair `ufs-afterboot-check.{service,timer}` runs it 3 minutes after
every boot. Two traps in reading its output: the run takes ~2.5 minutes
(there is a 120 s idle inside) and `systemctl is-active` answers `activating`
with a non-zero exit, so a naive wait loop reads the **previous** boot's result
and looks like a fresh one. Poll
`systemctl show ufs-afterboot-check.service -p ActiveState` for `activating|active`
and check the file's mtime.

## Scope, honestly

- Re-apply after **every** kernel update. These are out-of-tree modules.
- The modules are unsigned, so the kernel is tainted (`O`+`E`; `tainted` reads
  `0x3200` on the reference machine, where `0x2000` is a `W` from a WARN that
  fired during GPU bring-up, not from these patches).
- The UFS now never runtime-suspends, so it holds its idle power permanently. On
  a fanless, battery-powered machine that is a real standing trade.
- **Suspend is not fixed.** Runtime PM and system sleep are different paths
  (`.suspend`/`.freeze` → `ufshcd_reset_and_restore()` → `ufshcd_post_device_init()`
  → `ufshcd_config_pwr_mode()`), and on this silicon the link does not reliably
  re-train after `s2idle`. Masking `sleep.target`/`suspend.target` is the
  supported configuration. Do not test suspend "just to check" — a failed resume
  costs the disk until reboot.
- No wear/TBW readout. This kernel exposes `ioerr_cnt` and nothing else useful
  for UFS health, so nothing here can speak to drive endurance.
- 0002 is plausibly upstreamable. 0001 is a blunt hardware-targeted workaround;
  upstream would want a quirk keyed on the Lakefield PCI ID plus an actual fix
  for the resume path.

## How this disk became the root filesystem

The install started life on the microSD and was migrated onto the UFS once these
patches made it stable, with the card left untouched as a rescue system. The
phase list and the gate that matters (the patched `ufshcd` must be inside the
initramfs, not just in `/lib/modules`) are in the main `README.md`, under "It
started on a microSD".
