# Research log

How this was actually found, in the order it happened, including the parts that
wasted a day. Two separate efforts on the same machine: the UFS first, the GPU a
few days later.

Everything below was measured on the reference machine (Galaxy Book S 767XCL,
Core i5-L16G7, Arch, kernel 7.2.14-arch1-1). Where a number appears, there was a
command behind it; where something is suspicion rather than measurement, it says
so.

---

## Part 1 — the UFS (the storage that keeps dying)

### The wrong first question

The starting symptom was "the disk throws I/O errors and stops responding". The
first assumption was NVMe failure, which is wrong on two counts: this machine has
**no NVMe device at all**, and `dmesg` is blocked by `kernel.dmesg_restrict` so
the "evidence" people usually reach for is not readable anyway
(`journalctl -k -b` is). Correcting that misattribution was step zero.

The errors are `ufshcd` on the internal UFS: ready timeouts, `host_reset`
loops, `HBA state error`, and then `-EIO` on every read until reboot.

### Pinning runtime PM with udev: works, and is not enough

First working mitigation: a udev rule setting `power/control=on` for both the
WLUN (`0:0:0:49488`) and the PCI function (`0000:00:12.5`). That took a boot from
332 `ufshcd` log lines and `ioerr_cnt 0x65` to 2 lines and a flat counter. It
also survives reboots.

What it cannot do: apply before udev runs. That is fine for a data disk and
useless for a root disk, where the LUKS volume has to be unlocked inside the
initramfs. Once the plan became "put root on the UFS", the udev rule stopped
being sufficient and a driver-level pin became necessary.

### The driver patches

`pm_runtime_forbid()` in `ufshcd_wl_probe()` / `ufshcd_pci_probe()` closes the
path at probe. With patch 0001 alone the boot still produced 11 `ufshcd` lines,
six `0x15aa` peer-read failures and one `WARNING: core/ufshcd.c`.

The `0x15aa` read (`dme_peer_get(PA_GRANULARITY)`) was the second thread: it is
in the Lakefield `POST_CHANGE` handler, its return value is discarded, and on
this silicon it fails every time the link is re-configured. Delete it and keep
the settle delay → 5 `ufshcd` lines, no `0x15aa`, no WARN, no host resets.

The identical read in `ufs_intel_lkf_apply_dev_quirks()` is compared against the
host value, so it is meaningful and was left alone. That distinction matters:
a later "cleanup" that removes both would break the quirk handling.

### Verification, and one deliberate destructive test

- 32 GiB of zeros written and read back: 418 MB/s write, 860 MB/s read, kernel
  log byte-identical, `ioerr_cnt` flat.
- 4 GiB of incompressible `urandom`, sha256 per 256 MiB chunk, two `O_DIRECT`
  read-back passes: 366 MB/s write, 0 mismatches, log silent.
- A read-only verifier on a boot+3 min systemd timer: PASS on four consecutive
  boots.

The destructive one: three `s2idle` suspend/resume samples. 5 host resets, then
4, then a controller parked in `HBA state error` that never came back. That is
the measured basis for "these patches do not fix suspend" and for masking sleep
on the machine.

### Root moved to the UFS

The install had been running from the microSD. It was migrated to the UFS in
phases, with the SD left untouched as a rescue path: LUKS parameters mirrored
off the live header, a three-pass copy, a chroot `reinstall-kernels`, and an
initrd gate (the patched `ufshcd` modules have to be *inside* the initramfs, or
the wedge can hit while the kernel is looking for `/`). One-shot boot test via
`efibootmgr -n` before promoting the boot order.

`ufshcd` is now the root disk. Which is also why the "no suspend" limitation is
a bigger deal than it sounds on a laptop.

---

## Part 2 — the GPU and the panel

### Audio first, and it was a different bug

The machine had no sound either, and the two looked related because both are
`8086:98..` devices. They are not. `00:1f.3` (`8086:98c8`) is a legacy HDA
device that `snd_hda_intel` simply had no entry for; adding the id at runtime via
`new_id` produced a working card. The trap here was `snd_intel_dspcfg.dsp_driver=4`:
it makes AVS bind, which *looks* like progress, while `azx_probe()` refuses the
device permanently because it consults the same policy function. Internal
speakers are still silent (the fixup SSID is missing from `patch_realtek.c`), and
that is open — but it is a separate problem and is not in this repo.

### The GPU is fine; the driver has no entry for it

`8086:9840` is not in i915's table in any kernel version checked. One line —
`INTEL_VGA_DEVICE(0x9840, &ehl_info)` — and the driver binds: `card1` and
`renderD128` appear, four engines register (`bcs0 rcs0 vcs0 vecs0`, no VCS2), and
the GT frequency table reads back 200/500 MHz from the fuses.

Then the discovery that cost the next hour: binding the driver and having a
display are different things. i915 picks the display descriptor from a **second**
table, and `find_platform_desc()` returning NULL only logs at `drm_dbg_kms`
level. The result is a driver that renders happily, has no connectors, and says
nothing. `HAS_DISPLAY()` is false, `debugfs/dri/0/` has only GT files, and it
looks exactly like a fused-off display.

With both entries added, connectors appeared: `card0-DP-1` and `card0-DSI-1`.
The internal panel is DSI, not eDP — there is no `eDP-1` on this machine at all,
which is why "expect `card1-eDP-*`" checks came back empty rather than wrong.

### The oops era

`disable_display=0` produced an immediate kernel oops in
`icl_get_procmon_ref_values()`. Root cause: `MISSING_CASE()` is a `WARN()` with a
constant-true condition, so the `fallthrough;` after it is provably unreachable
and GCC emits `UD1`. Any unexpected strap value (and `0xffffffff` is the normal
value before the PHY is powered) turns into an invalid-opcode oops that wedges
the display subsystem and needs a power cycle.

That lesson produced the first real workflow rule: **arm a watchdog before any
display test** (`hung_task_panic`, `panic=15`, `sysrq=1`), and use `sysrq-b`
rather than waiting for a machine to come back on its own.

Next oops: NULL dereference at `0x10` in `lpt_digital_port_connected()`. That is
`pch_hpd[hpd_pin]` on a device with no PCH. Falling back to `DEISR` was tried and
is wrong too — `0x44000` is not implemented either, it just logs "Unclaimed
read". Reporting "disconnected" is the correct behaviour.

Then the panel stayed black while the pipe, plane and connector all said
"enabled". The cause was not the display engine at all: the backlight was being
driven through the legacy i9xx tables because EHL with `PCH_NONE` falls through
the GLK/BXT and CNP tests. The tell was `Unclaimed read from register 0x61254` in
the log. Routing PCH-less EHL to `bxt_pwm_funcs` fixed brightness
(`max_brightness` 6400 instead of 1000).

### The firmware-diff technique

The panel works under the UEFI GOP, so the firmware-left register state is a
**known-good reference**. Dump it inside the driver on the first i915 load after
a boot, before anything is programmed, and diff it against the post-init state.
Dumps taken after any earlier load only show the previous run's leftovers, so
this needs a real reboot each time.

That is what turned guesswork into a job. Result: i915 reproduces the firmware
state exactly for the combo PHY CL/TX block, exactly for the combo PLL (64/64
registers), and exactly for the DSI transcoder once the firmware timings were
forced. Everything matched — and the panel was still black.

### The expensive mistake

The comparison window stopped at `0x1621ff`. The D-PHY lane blocks start at
`0x162280`. So "everything matches, therefore it cannot be a register" was a
false conclusion drawn from an incomplete dump, and it cost hours of reasoning
about panel power sequencing, GPIOs and PLLs that were all fine.

When a register diff comes back clean and the hardware still fails, suspect the
window before the hardware.

### Finding the MCD

Reading Lakefield PRM Vol 12 settled it: Lakefield's D-PHY is a **Modular
Configurable D-PHY**, explicitly non-VPG, i.e. it does not self-configure.
i915 has zero references to any MCD register, and — worse — the ICL register
layout aliases it: `ICL_PORT_TX_DW5` is `DBBUDLN_MST_SLV_INIT_CTL` here, and the
ICL `TX_DW` writes zero the lane TX timing. That is the actual bug: the lanes
have no TX timing, nothing leaves the PHY, and a video-mode DSI panel produces no
error at all when that happens.

Restoring the five lane blocks (per-lane values, clock lane different, AUX lane
different) plus clearing `SOFT_RST_CTL` lit the panel. `fb0` became `i915drmfb`,
`card0-DSI-1` connected and enabled, and a lightdm login rendered on it.

Finding Vol 12 is its own lesson: it surfaced through **Chinese-language**
search terms (`Lakefield 点屏`, `数据手册`, `规格书`) and the Intel CDN document
ids, not through English queries. The full PRM set is still live on Intel's CDN;
`docs/field-notes.md` has the links.

### Mesa, and the soname that ate an evening

With the module working, Mesa still refused the devid and 3D stayed on llvmpipe.
One `CHIPSET()` line fixed the refusal, and the renderer string then literally
reported `Mesa Intel(R) UHD Graphics (LKF GT2)`.

Three separate problems then stood between "works in a build tree" and "the
desktop is accelerated":

1. `INTEL_FORCE_PROBE` does not bypass an unknown devid. Tested; no effect.
2. Arch's `libgallium` is a megadriver with versioned symbols. A build whose
   project version differs produces `libgallium-26.2.6.so` where Arch's shim
   wants `@@libgallium-26.2.6-arch1.1.so`; the load fails and glamor says
   `couldn't get display device`. Fix: set `VERSION` to the distro string,
   reconfigure, rebuild.
3. `-Dplatforms=drm` is not a valid value (allowed: `auto x11 wayland haiku
   android windows macos`); EGL/GBM comes from `-Dgbm=enabled -Degl=enabled`.
   A failed `meson configure` leaves the old config in place and the following
   `ninja` then rebuilds nothing, which reads exactly like "the change had no
   effect".

And one perceptual trap: **GLX takes its renderer from the X server's Mesa, not
the client's.** A patched build tree under `meson devenv` prints llvmpipe in
`glxinfo` while the render node is fine. That is not a build failure, and
chasing it as one is wasted time.

After installing the rebuilt libgallium (with the distro soname), Xorg's glamor
reports `Mesa Intel(R) UHD Graphics (LKF GT2)` and `DRI driver: iris`. That is
the current state: accelerated desktop, not a render-node demo.

---

## Things that were wrong on purpose, and stayed wrong

Not every experiment belongs in the final patch set. These were built, measured
and then deliberately left out:

- **Moving the COMBO PHY `COMP` block from `+0x100` to `+0x1000`.** The ICL
  offset reads `0xffffffff` on this part, and `+0x1000` is readable — but writes
  there do not stick (they read back 0), so it is not COMP either. The working
  firmware state contains no procmon trims anywhere in the PHY. Irrelevant on
  LKF.
- **Forcing the firmware's DSI timing values** (`HSTX_TO 0xffff0000`,
  `LPRX_HOST_TO 0x2bb`, `TA_TO 0x87`, `CLK_TIMING_PARAM 0xc8608400`,
  `T_INIT_MASTER 0xfa0`, `ESC_CLK_DIV 0x5002f`). It makes the whole transcoder
  block match the firmware byte for byte — and the panel stays black. Not the
  cause.
- **Writing `0x6b028`.** It is not defined in i915's headers or in PRM Vol 2c,
  and writing 0 reads back `0x364` immediately: hardware-updated state, not a
  config bit. Do not chase it.
- **Forcing panel power through `PP_CONTROL` (`0x61204`).** Readable, but
  `PANEL_POWER_ON` / `EDP_BLC_ENABLE` never stick. In the firmware state where
  the panel *is* lit, the whole PPS block `0x61200`–`0x6123c` reads zero: the
  rails are always-on on this board and the PPS is not in the path.
- **Forcing the non-native GPIO path in `mipi_exec_gpio()`** (`native = false`)
  to drive the board's pinctrl pins. Every request fails `-ENOENT`: the panel
  power/reset pins are not described to the GPU device in ACPI. Leaving this in
  silently breaks all panel power sequencing — it was a leftover that invalidated
  several test cycles before being spotted and removed.
- **`icl_info` instead of `ehl_info`.** Binds, but the engine mask is wrong for
  this part (ICL has VCS2, Lakefield does not).

## Things that look like leads and are not

- **`dmesg` is empty / "no kernel messages".** `kernel.dmesg_restrict`; use
  `journalctl -k -b`.
- **SoundWire `_DSD` "received [Buffer], requested [Package]"** ACPI errors.
  Every Lakefield machine prints them.
- **The DSI register base "swap"** (PRM says `0x6B8xx`, i915 maps `0x6B0xx`). A
  first-load firmware dump shows the firmware configures `0x6B000` and leaves
  `0x6B800` mostly zero. Cosmetic numbering difference.
- **DCS reads as a liveness probe.** `gen11_dsi_host_transfer()` has no payload
  receive path, so `mipi_dsi_dcs_read()` always "succeeds" and leaves the buffer
  untouched.
- **`lane_count` in `i915_display_info`** is a DisplayPort field and reads 0 for
  DSI; `intel_dsi->lane_count` is the real one.

## Timeline

Rough, because the work spanned late nights rather than sprints:

| when | what |
|---|---|
| day 1–2 | UFS error storm diagnosed; NVMe misattribution corrected; udev pin works |
| day 2–3 | driver patch 0001, then 0002; throughput and integrity tests; verifier on a boot timer |
| day 3 | suspend tested three times, fails; sleep masked; root migration plan and cutover to the UFS |
| day 4 | GPU: audio id separate; `ehl_info` binds; second device table found; UD1 and `pch_hpd` oopses fixed; backlight fixed |
| day 4–5 | ~25 instrumented module builds; firmware register diff; MCD D-PHY found in PRM Vol 12; panel lights |
| day 5 | Mesa devid, soname mismatch, install; glamor on iris; repo assembled |
