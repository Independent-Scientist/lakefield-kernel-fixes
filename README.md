# Lakefield on Linux: the UFS stops dying, the panel lights up

Two out-of-tree kernel fixes for the Samsung Galaxy Book S with the Intel Core
i5-L16G7 ("Lakefield", `8086:9840`), plus the one-line Mesa patch you need
before the GPU is actually usable.

Both problems look like "this hardware is broken" and both turn out to be the
Linux driver not knowing what it is looking at. Lakefield is an odd little SoC:
no PCH south bridge at all, a Gen11 GPU that every Intel driver ships without a
PCI ID for, and a UFS 3.1 storage controller whose runtime-resume path wedges
itself permanently. Upstream has never supported any of it. This repo is what
made it work, with the evidence and the dead ends written down so nobody has to
re-derive them.

Everything here was developed and measured on one specific machine (Galaxy Book S
767XCL, Arch, kernel 7.2.14) and none of it is upstream. It is a workaround you
apply to your own kernel, not a distro.

## The exact hardware (and the things you probably searched for)

If you landed here from a search, this is the right repo:

- **Samsung Galaxy Book S** — SMBIOS product `767XCL`, board `NP767XCM-K01BR`,
  BIOS `P07AJD.053.200820.KS`. Galaxy Book S / Galaxy Book S LTE.
- **Intel Core i5-L16G7** — "Lakefield", family 6 model 138 (`0x8A`), 4 Tremont
  E-cores + 1 Sunny Cove P-core.
- **Storage:** model **`KLUEG8UHDB-C2D1`** — 256 GB UFS 3.1 (the SCSI vendor
  string reports `SAMSUNG`), behind the Intel Lakefield UFS controller
  `8086:98fa` at PCI `0000:00:12.5`, exposed as `/dev/sda`.
- **GPU:** Intel Lakefield GT2 `8086:9840` (rev 03), subsystem `144d:c18b`.
- **Panel:** internal MIPI-DSI, 1920x1080, 4 lanes, RGB888, video mode.
- **No NVMe and no PCH.** There is no `nvme0n1` on this machine and no south
  bridge. If a guide tells you to look at either, it is not this laptop.

## What actually works now

- **The internal UFS is a reliable disk.** Runtime suspend is what killed it;
  forbidding runtime PM at probe fixed it. Verified with a 32 GiB write and
  read-back, and 4 GiB of incompressible data with per-chunk sha256 on two read
  passes, zero mismatches. It is currently the root filesystem of the machine
  this was written on.
- **The GPU binds and renders.** 3D through the render node, `eglinfo` reports
  `Mesa Intel(R) UHD Graphics (LKF GT2)`.
- **The internal MIPI-DSI panel lights up**, and the desktop runs accelerated:
  Xorg's glamor reports `Mesa Intel(R) UHD Graphics (LKF GT2)` and `iris`.
- **Brightness works** (it did not, before the backlight fix).

## What does not work, or is still a liability

- **System suspend is not fixed.** This is the big one. The runtime-PM patches
  do not close the suspend path, and on this hardware `s2idle` usually loses the
  UFS controller for good (3 samples: two only recovered after 5 and 4 host
  resets, the third never recovered). Sleep is masked on the machine this was
  developed on. Do not unmask it and expect a different result.
- **Every kernel update breaks both fixes.** The patched modules are out of
  tree; a kernel upgrade replaces them and you get a dark panel and a stock UFS
  driver again. There is a pacman hook in `tools/i915/` that rebuilds if a
  source tree is present. Budget for this; it is not a one-time install.
- **The modules are unsigned and out of tree**, so the kernel is tainted
  (`/proc/sys/kernel/tainted` reads `0x3200` here, i.e. `W` + `O` + `E`). The
  `W` is a WARN that actually fired during bring-up, not something these patches
  introduce.
- **Nothing here is upstream-shaped.** The UFS patch 0002 is plausibly
  submittable; the i915 work is a platform impersonation and will never be
  accepted as-is. See `docs/i915.md` for what a real port would need.
- **No wear/TBW readout** for the UFS — the kernel exposes none without a
  `ufs-bsg` client that would have to be written from scratch.

## What each patch does

UFS (`patches/ufs/`):

1. `pm_runtime_forbid()` instead of `pm_runtime_allow()` at probe. The
   runtime-resume path is the one that wedges the controller, so never let the
   controller runtime-suspend. Doing it at probe also beats udev and the
   initramfs, which matters when root lives on this disk.
2. Delete a discarded `dme_peer_get(PA_GRANULARITY)` (`0x15AA`) from the
   Lakefield `POST_CHANGE` power-mode handler. It always fails on this silicon,
   and each failure forces a host reset. The identical read in
   `ufs_intel_lkf_apply_dev_quirks()` stays — there the value is actually used.

i915 (`patches/i915/`), in the order the failures appear:

1. Add `8086:9840` to **both** of i915's device tables — missing the first means
   nothing binds, missing the second means the driver binds with no display and
   no error message.
2. `MISSING_CASE()` after a constant-true `WARN()` compiles to `UD1`: an
   unexpected PHY strap value oopses instead of warning. Return a default.
3. A NULL `pch_hpd` table on a PCH-less SoC → oops at address `0x10` during
   modeset. Report "disconnected" instead of dereferencing it.
4. PCH-less EHL fell through to the legacy backlight tables and wrote PCH
   registers that do not exist. Use the SoC PWM backend.
5. PW_2 is fused off and the hardware drops its enable request; treat an
   unaccepted request as an absent power gate rather than a timeout.
6. **The actual panel fix:** Lakefield's D-PHY is an MCD ("modular configurable
   D-PHY") that does not self-configure, and Ice Lake's PHY registers alias its
   lane registers, so i915 zeroes the TX timing. Re-program the five lane blocks
   from the firmware's known-good values.
7. Two DCS reads after the transcoder is programmed. Empirically required;
   exactly why is not isolated (see the patch comment).

Mesa (`patches/mesa/`): one `CHIPSET()` line adding `0x9840` to
`include/pci_ids/iris_pci_ids.h`. Without it Mesa refuses the device and you get
llvmpipe. Read `docs/building.md` before installing it — on Arch the gallium
library is a megadriver and the version string in the soname has to match, or
the whole thing silently doesn't load.

## Applying the patches

The series were generated against **7.2.14**. They apply to that tree exactly;
on a nearby version expect fuzz or a rejected hunk, and re-read the hunk rather
than forcing it. `docs/building.md` has the same procedure with the traps
spelled out, plus the Mesa half.

### 1. Get the source tree that matches your running kernel

```sh
uname -r                                  # e.g. 7.2.14-arch1-1

curl -O https://cdn.kernel.org/pub/linux/kernel/v7.x/linux-7.2.14.tar.xz
tar -xf linux-7.2.14.tar.xz
cd linux-7.2.14
```

Version *and* config have to match. If your kernel has `CONFIG_IKCONFIG_PROC`,
`zcat /proc/config.gz > .config` is the easiest way to get the exact config;
otherwise use the distro's config file from `/boot`.

### 2. Configure it the way the running kernel is configured

```sh
zcat /proc/config.gz > .config
./scripts/config --set-str LOCALVERSION "-arch1-1"   # your kernel's suffix
make olddefconfig
cp /usr/lib/modules/$(uname -r)/build/Module.symvers .
```

That last line is not optional: without `Module.symvers`, `modpost` fails on
every exported symbol. The `LOCALVERSION` line is what puts `-arch1-1` into
vermagic — skip it and the module builds fine and then refuses to load.

### 3. Apply the patches

The two series are independent; apply whichever you need. Within a series, order
matters.

```sh
for p in /path/to/lakefield-kernel-fixes/patches/ufs/*.patch; do
    patch -p1 --dry-run < "$p" && patch -p1 < "$p"
done

for p in /path/to/lakefield-kernel-fixes/patches/i915/*.patch; do
    patch -p1 --dry-run < "$p" && patch -p1 < "$p"
done
```

`--dry-run` first, on every patch: a hunk that applies with fuzz against a
slightly different tree can still compile into a driver that does the wrong
thing. If a patch rejects, the tree is not the one it was made against.

(They are `git format-patch` output, so `git am` works too if you would rather
keep the commit messages.)

### 4. Build just the modules

```sh
make -j$(nproc) modules_prepare
make -j$(nproc) M=drivers/ufs/core modules
make -j$(nproc) M=drivers/ufs/host modules
make -j$(nproc) M=drivers/gpu/drm/i915 modules
```

No full kernel build, no rebuild of anything else. On the reference machine the
i915 module takes a few minutes on five slow cores; the UFS pair takes seconds.

### 5. Install

```sh
sudo KSRC=$PWD /path/to/tools/ufs/build-and-install.sh    # ufs
sudo /path/to/tools/i915/install-i915.sh $PWD/drivers/gpu/drm/i915/i915.ko
```

Both scripts check vermagic against the target kernel, back the distro module up
as `*.orig`, run `depmod`, and print the exact rollback. The UFS script also
regenerates the initramfs — **and that step is the one that matters if the UFS
is your root disk**: the patched `ufshcd` has to be inside the boot image, not
just in `/lib/modules`, or the wedge can hit while the kernel is looking for `/`.
On the reference setup i915 is not in the initramfs (UKIs; `lsinitrd` shows zero
i915 entries), so no image rebuild is needed for the GPU — check that on yours
before assuming.

For the panel, also add `/etc/modprobe.d/i915-lkf.conf`:

```
options i915 enable_guc=0 enable_psr=0 enable_fbc=0
```

### 6. Verify

```sh
cat /sys/module/i915/srcversion                                   # == modinfo -F srcversion of the installed .zst
cat /sys/class/graphics/fb0/name                                  # i915drmfb
cat /sys/class/drm/card*-DSI-1/status                             # connected
cat /sys/bus/scsi/devices/*/power/control                          # the ufs_device_wlun: "on"
journalctl -k -b --no-pager | grep -c 'ufshcd 0000:00:12.5:'      # 2-5, not 300
```

The `srcversion` check is the one people skip: it proves the kernel loaded the
build you installed, which is a different claim from "the install succeeded".

### If it does not apply at all

The patches are version-specific by nature. If your kernel is much newer, take
the hunk's intent from the commit message and re-implement it against your tree
— every patch explains the mechanism, not just the edit. Or ask: an issue with
`uname -r` and the rejected hunk is enough to get a rebased version.

## It started on a microSD

The machine did not always run from the UFS. It ran everything from the
microSD (`mmcblk0`): its own ESP, a LUKS2→ext4 root, systemd-boot. The UFS sat
unused because it wedged within seconds of being touched — which is exactly why
the patches in `patches/ufs/` exist.

Once the driver was stable, root was **migrated onto the UFS in phases**, with
the microSD deliberately never modified, so the old system stayed bootable the
whole time:

1. **Firmware gate** — can this firmware boot from an ESP on the UFS at all?
   Nothing written; just a boot entry pointed at a copied loader.
2. **Create the targets** — `sda1` as the ESP, `sda2` as LUKS2→ext4, with the
   LUKS parameters (cipher, key size, KDF) mirrored off the live header so the
   new volume behaves like the old one.
3. **Copy** — a three-pass copy of the SD root into the new LUKS volume, then a
   drift check against the source to prove nothing moved underneath.
4. **Reconfigure the copy** — `fstab`, `crypttab`, `/etc/kernel/cmdline`, then
   `reinstall-kernels` inside a chroot.
5. **Initrd gate** — unpack the generated image and prove the patched `ufshcd`
   is actually inside it, with matching vermagic. This is the step that catches
   the failure the whole migration is exposed to: root on a disk whose driver
   fix is missing from the initramfs.
6. **One-shot boot** — `efibootmgr -n` into the UFS entry once, `BootOrder`
   untouched, so a failure falls back to the SD on the next power cycle.
7. **Soak, then promote** — the UFS entry becomes default only after the
   counters stayed flat over sustained I/O. The microSD stays second in
   `BootOrder` as the rescue system, and is still there.

What that buys: root on the fast disk, with the SD as a permanent escape hatch.
What it costs: **sleep has to stay masked** (see above), because suspend is the
one path these patches do not fix, and root on the UFS makes a lost controller
a lost system rather than a lost data disk.

The full phase-by-phase runbook with the checks at each gate is not in this repo
— it is host-specific, down to partition UUIDs. The rules that made it safe are
in `docs/field-notes.md` (see "Judgement" and the initramfs entries).

## Layout

```
patches/i915/   7 patches, clean series against 7.2.14
patches/ufs/    2 patches
patches/mesa/   1 patch
docs/
  i915.md           the GPU/panel bring-up: root causes, register values, what to check
  ufs.md            the UFS wedge: signature, both fixes, evidence, non-goals
  research-log.md   how this was actually found, in order, including the wrong turns
  field-notes.md    the rules we ended up with (read this before writing a probe)
  building.md       build, install, verify, roll back
tools/              install scripts, the UFS verifier + stress tests, a GPU probe
```

## How this was found

Slowly, and mostly by reading registers on a machine that was on fire.
`docs/research-log.md` keeps the whole trail: the `UD1` trap, the power well that
did not exist, the four-hour rabbit hole caused by a register dump window that
stopped 0x80 bytes before the registers that mattered, the Mesa soname problem,
and the panel that was "black" because its backlight was at zero. `docs/field-notes.md`
distils those into rules. If you are about to debug this hardware, that file will
save you a day.

## Provenance

Every number and symptom in these docs was measured on the reference machine —
none of it is copied from a datasheet or inferred from source alone. The UFS
patches are exactly what is installed and running there, with the UFS as root.

The i915 series was cleaned up for publication: the working build also carried
debug logging and three experiments that turned out to be irrelevant, all listed
in `docs/research-log.md`. The cleaned series applies to pristine 7.2.14 and
compiles (matching vermagic, `9840` alias present, no instrumentation), but it
has not been booted since the cleanup. Details and the one-command rollback are
at the end of `docs/i915.md`.

## Licence

GPL-2.0-only. The patches are derived from GPL-2.0 kernel sources; the Mesa
patch from MIT-licensed Mesa sources. See `LICENSE`.

## Buy me a coffee

If this saved you a day of register archaeology, or got a laptop out of a drawer,
here is a Bitcoin address:

```
bc1qavtv0vuwplmuty56prpf7as8j55rxh0kflz98a
```

Entirely optional. A bug report with `uname -r` and the rejected hunk is worth
more than coins — that is what keeps this working on kernels past 7.2.14.
