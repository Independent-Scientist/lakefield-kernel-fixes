#!/bin/bash
# install-ufs-rpm-patch.sh — install the locally built ufshcd modules that call
# pm_runtime_forbid() at probe time, then retire the udev rule that used to do the
# same thing later, and reboot to prove the patch stands on its own.
#
# Why: ufshcd_wl_probe() enables runtime PM with a 0 ms autosuspend delay, so the
# well-known LUN suspends at the first idle moment. The resume that follows walks
# ufshcd_reset_and_restore() -> ufshcd_post_device_init() -> ufshcd_config_pwr_mode(),
# where the Intel Lakefield POST_CHANGE dme_peer_get(PA_GRANULARITY 0x15AA) times out
# and parks the controller in "HBA state error" (every later read: -EIO).
# The udev rule pins power/control=on but only from the moment udev runs — too late to
# help a root filesystem that must be unlocked inside the initramfs. The patch forbids
# runtime PM at probe, before anything can touch the disk.
#
# Built from a kernel source tree matching the running kernel, with two patches:
#   0001-ufs-forbid-runtime-pm.patch          pm_runtime_forbid() in ufshcd_wl_probe()/ufshcd_pci_probe()
#   0002-ufs-lkf-drop-unused-peer-granularity-read.patch
#                                            drops the discarded dme_peer_get(PA_GRANULARITY) in the
#                                            Lakefield POST_CHANGE handler — the read that actually fails on
#                                            every system resume (3 retries, saved_uic_err 0x4) and
#                                            forces eh_non_fatal + repeated host resets
# CONFIG_MODVERSIONS is off and MODULE_SIG_FORCE is off on this kernel, so a rebuilt
# module drops in as long as vermagic matches — checked below.
#
# Rollback (any time):
#   sudo zstd -dq -f /lib/modules/$KVER/kernel/drivers/ufs/core/ufshcd-core.ko.zst.orig \
#                    -o /lib/modules/$KVER/kernel/drivers/ufs/core/ufshcd-core.ko.zst
#   sudo zstd -dq -f /lib/modules/$KVER/kernel/drivers/ufs/host/ufshcd-pci.ko.zst.orig \
#                    -o /lib/modules/$KVER/kernel/drivers/ufs/host/ufshcd-pci.ko.zst
#   sudo mv /etc/udev/rules.d/59-ufs-pm-pin.rules.disabled /etc/udev/rules.d/59-ufs-pm-pin.rules
#   sudo depmod -a && sudo reinstall-kernels && sudo reboot
set -uo pipefail

KVER=$(uname -r)
SRC=${KSRC:?set KSRC to the kernel source tree you built the modules in}
BUILT_CORE=$SRC/drivers/ufs/core/ufshcd-core.ko
BUILT_PCI=$SRC/drivers/ufs/host/ufshcd-pci.ko
DEST=/lib/modules/$KVER/kernel/drivers/ufs
RULE=/etc/udev/rules.d/59-ufs-pm-pin.rules
LOG=${UFS_DIR:-$(cd "$(dirname "$0")" && pwd)}/patch-install.log

say() { printf '%s  %s\n' "$(date +%H:%M:%S)" "$*" | tee -a "$LOG" ; }
die() { say "ABORT: $*"; say "nothing was rebooted; the udev rule is still in place unless a step above says otherwise"; exit 1; }

[ "$(id -u)" -eq 0 ] || { echo "run me with sudo: sudo bash $0"; exit 1; }
: > "$LOG"
say "== 0. prerequisites =="
[ -f "$BUILT_CORE" ] || die "missing $BUILT_CORE — rebuild first"
[ -f "$BUILT_PCI" ]  || die "missing $BUILT_PCI — rebuild first"

say "== 1. vermagic must match the running kernel ($KVER) =="
for pair in "$BUILT_CORE:$DEST/core/ufshcd-core.ko.zst" "$BUILT_PCI:$DEST/host/ufshcd-pci.ko.zst"; do
  built=${pair%%:*}; inst=${pair##*:}
  want=$(modinfo -F vermagic "$inst")
  got=$(modinfo -F vermagic "$built")
  say "   $(basename "$built"): built='$got' installed='$want'"
  [ "$got" = "$want" ] || die "vermagic mismatch for $built — do not install"
done

say "== 2. back up the distro modules (kept as .orig) =="
for f in core/ufshcd-core.ko.zst host/ufshcd-pci.ko.zst; do
  [ -f "$DEST/$f.orig" ] || cp -a "$DEST/$f" "$DEST/$f.orig"
  say "   $DEST/$f.orig  $(stat -c%s "$DEST/$f.orig") bytes"
done

say "== 3. install the patched modules =="
zstd -q -f "$BUILT_CORE" -o "$DEST/core/ufshcd-core.ko.zst" || die "zstd core failed"
zstd -q -f "$BUILT_PCI"  -o "$DEST/host/ufshcd-pci.ko.zst"  || die "zstd pci failed"
for m in core/ufshcd-core host/ufshcd-pci; do
  grep -q pm_runtime_forbid "$SRC/drivers/ufs/$m.ko" 2>/dev/null || \
    readelf -sW "$SRC/drivers/ufs/$m.ko" | grep -q pm_runtime_forbid || die "$m does not reference pm_runtime_forbid"
  say "   $DEST/$m.ko.zst installed ($(stat -c%s "$DEST/$m.ko.zst") bytes)"
done
# patch 0002 assert: the discarded PA_GRANULARITY peer read must be gone from the POST_CHANGE
# handler, while the meaningful reads in ufs_intel_lkf_apply_dev_quirks() must survive.
if command -v objdump >/dev/null 2>&1; then
  gone=$(objdump -d --no-show-raw-insn "$BUILT_PCI" |
           awk '/<ufs_intel_lkf_pwr_change_notify>:/,/^$/' | grep -c '15aa')
  kept=$(objdump -d --no-show-raw-insn "$BUILT_PCI" |
           awk '/<ufs_intel_lkf_apply_dev_quirks>:/,/^$/' | grep -c '15aa')
  say "   pwr_change_notify PA_GRANULARITY refs=$gone (want 0), apply_dev_quirks refs=$kept (want 2)"
  [ "$gone" = "0" ] || die "patch 0002 not in the pci module — rebuild before installing"
else
  say "   objdump missing: skipped the patch-0002 assert"
fi

say "== 4. depmod =="
depmod -a "$KVER" || die "depmod failed"

say "== 5. regenerate the initramfs so the boot image carries the patched modules =="
if command -v reinstall-kernels >/dev/null 2>&1; then
  reinstall-kernels >>"$LOG" 2>&1 || die "reinstall-kernels failed — modules are installed but the initramfs is stale; fix before the next reboot"
  say "   reinstall-kernels ok"
else
  dracut -f --regenerate-all >>"$LOG" 2>&1 || die "dracut failed"
  say "   dracut ok"
fi

say "== 6. retire the udev rule (the patch replaces it) =="
if [ -f "$RULE" ]; then
  mv "$RULE" "$RULE.disabled" && say "   moved $RULE -> .disabled"
  udevadm control --reload && say "   udev reloaded"
else
  say "   no rule present (already retired)"
fi

say "== 7. what happens at the next boot =="
cat <<EOF 2>&1 | tee -a "$LOG"

   ufshcd-core probes the LUN, calls pm_runtime_forbid() immediately, so
   /sys/bus/scsi/devices/0:0:0:0/power/control must read "on" with NO udev rule.
   The boot+3min timer runs the read-only verifier and rewrites
   last-result.txt in $UFS_DIR (default /var/lib/ufs-check). After the reboot, check:

     cat /sys/bus/scsi/devices/0:0:0:0/power/control      # expect: on
     cat /sys/devices/pci0000:00/0000:00:12.5/power/control
     cat /sys/block/sda/device/ioerr_cnt                   # delta is what matters
     journalctl -k -b | grep -c 'ufshcd 0000:00:12.5:'     # expect 2

   If sda comes up dead (the verifier will say FAIL), roll back with the four
   commands in the header of this script and the machine is exactly as it is now.

EOF

if [ "${1:-}" = "--reboot" ]; then
  say "== 8. rebooting in 20 s (Ctrl-C to cancel) =="
  systemd-run --on-active=20s --unit=ufs-patch-reboot --description="UFS rpm patch: reboot" systemctl reboot
else
  say "== done. Reboot when ready:  sudo reboot   (or re-run with --reboot) =="
fi
