# Building, installing, verifying, rolling back

Written against Arch (kernel `7.2.14-arch1-1`, systemd-boot + dracut). The module
build steps work on any distro; the install paths and the initramfs command are
distro-specific and marked.

## 0. Prerequisites

- Kernel **source** matching the running kernel exactly: same version, same
  config. `zcat /proc/config.gz > .config` if your kernel has
  `CONFIG_IKCONFIG_PROC`; otherwise take the config from `/boot`.
- `linux-headers` (or equivalent) for that kernel — it provides `Module.symvers`.
- The compiler that built your kernel. Mixing compilers is usually fine and
  occasionally produces a module that oopses for reasons you will spend a day on.
- `zstd`, and for the i915 panel check `intel-gpu-tools`.

Two rules that catch almost every "the fix is installed but the symptom is still
there":

```sh
# 1. vermagic must match EXACTLY
modinfo -F vermagic /path/to/built.ko
modinfo -F vermagic /lib/modules/$(uname -r)/kernel/drivers/.../<mod>.ko.zst

# 2. after installing, prove the kernel loaded the patched build
cat /sys/module/<mod>/srcversion
modinfo -F srcversion /lib/modules/$(uname -r)/kernel/drivers/.../<mod>.ko.zst
modinfo -F filename <mod>          # which file is actually in use
```

## 1. UFS

```sh
cd linux-$(uname -r | sed 's/-arch.*//')
zcat /proc/config.gz > .config
./scripts/config --set-str LOCALVERSION "-arch1-1"    # match your kernel's suffix
make -s olddefconfig
cp /usr/lib/modules/$(uname -r)/build/Module.symvers .

for p in /path/to/patches/ufs/*.patch; do patch -p1 < "$p"; done

make M=drivers/ufs/core modules
make M=drivers/ufs/host modules
```

Install (both modules, vermagic check, `.orig` backups, `0x15aa` assertion,
`depmod`, initramfs, udev-rule retirement, printed rollback):

```sh
sudo KSRC=$PWD /path/to/tools/ufs/build-and-install.sh
```

**If the UFS is your root disk, the initramfs step is not optional.** The patched
`ufshcd` must be inside the image that runs before root is mounted, or the wedge
can hit while the kernel is looking for `/`. The script runs
`reinstall-kernels` on kernel-install/dracut hosts and falls back to
`dracut -f`.

Verify:

```sh
cat /sys/bus/scsi/devices/*/power/control              # ufs_device_wlun must be "on"
cat /sys/bus/pci/devices/0000:00:12.5/power/control    # "on"
sudo tools/ufs/ufs-afterboot-check.sh                  # read-only, PASS/FAIL
```

Optional: install `ufs-afterboot-check.{service,timer}` to run the verifier 3
minutes after every boot. Read `docs/ufs.md` for how to read its output
correctly — the naive wait loop lies.

## 2. i915

```sh
cd linux-$(uname -r | sed 's/-arch.*//')
zcat /proc/config.gz > .config
./scripts/config --set-str LOCALVERSION "-arch1-1"
make -s olddefconfig
cp /usr/lib/modules/$(uname -r)/build/Module.symvers .
make -s -j$(nproc) modules_prepare
make -j$(nproc) M=drivers/gpu/drm/i915 modules
```

That produces `drivers/gpu/drm/i915/i915.ko` (~184 MB unstripped). Keep it
compressed and side by side with the distro module rather than installing
straight away.

Install:

```sh
sudo /path/to/tools/i915/install-i915.sh
```

It checks vermagic, backs the distro module up as `i915.ko.zst.orig`, installs
and runs `depmod`. i915 is not in the initramfs on the reference setup (UKIs,
`lsinitrd` shows zero i915 entries), so no image rebuild is needed there — but if
your initramfs does carry i915, regenerate it.

Then `/etc/modprobe.d/i915-lkf.conf`:

```
options i915 enable_guc=0 enable_psr=0 enable_fbc=0
```

`enable_guc=0` avoids pulling GuC/HuC firmware that this SoC's tables do not
describe. PSR and FBC are disabled in the same breath because on this panel they
buy nothing and add a failure mode while you are bisecting.

Reboot. Verify:

```sh
cat /sys/class/graphics/fb0/name                    # i915drmfb
ls /dev/dri                                         # card1, renderD128
cat /sys/class/drm/card*-DSI-1/status               # connected
cat /sys/class/drm/card*-DSI-1/enabled              # enabled
cat /sys/class/backlight/intel_backlight/max_brightness   # 6400
grep -E 'glamor|iris' /var/log/Xorg.0.log           # once Mesa is installed
```

Do **not** read `/sys/class/drm/card*-DSI-1/modes` on a broken build: that read
blocks forever and stalls whatever script is doing the probing.

## 3. Mesa (for acceleration, not for the panel)

One `CHIPSET()` line in `include/pci_ids/iris_pci_ids.h`. Building and installing
it on a distro with a megadriver is the fiddly part:

```sh
# VERSION must carry the distro's exact project version, or the soname and the
# versioned symbols will not match what the loader asks for.
cat VERSION                      # e.g. 26.2.6-arch1.1

meson setup build --buildtype=release \
  -Dgallium-drivers=iris,llvmpipe \
  -Dvulkan-drivers= -Dplatforms=x11 \
  -Degl-native-platform=surfaceless -Dglx=disabled \
  -Dbuild-tests=false -Dvalgrind=disabled
ninja -C build
```

- `iris,llvmpipe` — Arch ships one libgallium containing every gallium driver;
  building `iris` alone removes llvmpipe from it too.
- `surfaceless` is not a `platforms` value; it is `-Degl-native-platform=`.
- If `meson` picks up a venv python without `mako`, run it as
  `env -u VIRTUAL_ENV -u PYTHONPATH PATH=/usr/bin:/bin meson setup ...`.
- `-Dplatforms=drm` does not exist. EGL/GBM come from `-Dgbm=enabled -Degl=enabled`.

Check before installing:

```sh
nm -D build/src/gallium/targets/dri/libgallium-*.so | grep dri_create_drawable
# want: ...@@libgallium-<the exact string from your distro's libgallium>
```

Install (back up first — this is a single-file swap and a single-file rollback):

```sh
sudo cp -a /usr/lib/libgallium-<ver>.so /root/libgallium-<ver>.so.bak
sudo install -m644 build/src/gallium/targets/dri/libgallium-<ver>.so /usr/lib/
```

Then restart X and confirm the renderer:

```sh
DISPLAY=:0 glxinfo -B | grep -E 'OpenGL renderer|OpenGL version'
# Mesa Intel(R) UHD Graphics (LKF GT2), 26.2.6-arch1.1
```

`tools/gl-probe.c` is the stronger check — a shader draw with pixel readback,
which proves execution rather than context creation:

```sh
cc -O2 -o gl-probe tools/gl-probe.c -lEGL -lGLESv2
EGL_PLATFORM=surfaceless ./gl-probe
```

## 4. Kernel updates

This is the standing cost. A package update replaces both patched modules, and
you get a dark panel and a stock UFS driver until they are rebuilt.

Minimum: keep the distro `.orig` files, and keep a source tree for the new kernel
before rebooting into it. `tools/i915/lkf-i915-rebuild` does the patch-and-install
step for a given kernel; `tools/i915/lkf-i915-post-update` is a pacman hook that
calls it after every transaction and refuses to pretend when there is no source
tree (it logs a loud warning instead, because silently booting into a dark panel
is worse).

## 5. Rollback

Every piece is independent, and every piece is one file.

```sh
# UFS
sudo zstd -dq -f /lib/modules/$KVER/kernel/drivers/ufs/core/ufshcd-core.ko.zst.orig \
                 -o /lib/modules/$KVER/kernel/drivers/ufs/core/ufshcd-core.ko.zst
sudo zstd -dq -f /lib/modules/$KVER/kernel/drivers/ufs/host/ufshcd-pci.ko.zst.orig \
                 -o /lib/modules/$KVER/kernel/drivers/ufs/host/ufshcd-pci.ko.zst
sudo depmod -a && sudo reinstall-kernels && sudo reboot     # dracut -f elsewhere

# i915
sudo cp -a /lib/modules/$KVER/kernel/drivers/gpu/drm/i915/i915.ko.zst.orig \
           /lib/modules/$KVER/kernel/drivers/gpu/drm/i915/i915.ko.zst
sudo depmod -a && sudo reboot

# Mesa
sudo cp -a /root/libgallium-<ver>.so.bak /usr/lib/libgallium-<ver>.so
# then restart X
```

If a patched i915 wedges the machine, `echo b > /proc/sysrq-trigger` (or Alt+SysRq+B)
is the reliable escape — a shadowed boot with `i915.modeset=0` gets you a usable
text console to roll back from.
