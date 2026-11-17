#!/bin/bash
# ufs-afterboot-check.sh — read-only health/liveness check for a UFS that wedges on runtime PM.
# Run as root after a reboot; the boot+3min timer runs it automatically.
# Expected state now that the ufshcd driver patch is installed (runtime PM forbidden inside
# ufshcd_wl_probe/ufshcd_pci_probe, udev rule retired): ufs_device_wlun AND the PCI function
# both read power/control=on with no rule present, and this script FAILS if they don't.
#
# It never writes to the disk (no LUKS open, no mkfs, no dd of=). It reads:
#   - the partition-table region (first 4 MiB of the UFS block device)
#   - 256 MiB of raw data at the 16 GiB offset (inside the disposable LUKS in partition 2)
# then idles 120 s and reads again, to see whether the link wedges on its own.
# A wedged read cannot be killed (D state), so each dd runs in the background and is
# polled; a stuck read is reported and the remaining reads are skipped instead of
# hanging the script. If one does stick, reboot — it will not clear otherwise.
set -u
UFS_PCI=${UFS_PCI:-0000:00:12.5}
OUT=${UFS_DIR:-$(cd "$(dirname "$0")" && pwd)}
LOG=${1:-$OUT/afterboot-$(date +%Y%m%d-%H%M%S)}
mkdir -p "$LOG" || exit 1
say() { printf '[%s] %s\n' "$(date -Is)" "$*" | tee -a "$LOG/run.log"; }

[ "$(id -u)" -eq 0 ] || { echo "run me with sudo"; exit 1; }

# Discover the UFS host, its device WLUN and the block device on it.  Host numbering is
# a probe race (ufshcd was host1 in one boot, host0 in the next) and /dev/sdX depends on
# enumeration order, so nothing below may hardcode either: a hardcoded path that silently
# matches the wrong device is how a check reports PASS without testing anything.
UFS_HOST=
for h in /sys/class/scsi_host/host*; do
	[ "$(cat "$h/proc_name" 2>/dev/null)" = ufshcd ] && UFS_HOST=${h##*/}
done
[ -n "$UFS_HOST" ] || { echo "no ufshcd scsi_host — UFS did not probe this boot"; exit 1; }
HOSTNUM=${UFS_HOST#host}

# The UFS-device well-known LUN (0xD0) is the device whose runtime resume walked
# ufshcd_reset_and_restore -> config_pwr_mode -> the 0x15AA peer read that wedges the
# controller.  It is the device the patch has to pin; sda itself is 'on' by default.
UFS_WLUN=
for d in /sys/bus/scsi/devices/"$HOSTNUM":*; do
	[ -e "$d" ] || continue
	[ "$(basename "$(readlink "$d/driver" 2>/dev/null)")" = ufs_device_wlun ] && UFS_WLUN=${d##*/}
done

DEV=
for b in /sys/block/*; do
	case "$(readlink -f "$b/device" 2>/dev/null)" in
	*"/$UFS_HOST/"*) DEV=/dev/${b##*/} ;;
	esac
done
[ -n "$DEV" ] && [ -b "$DEV" ] || { echo "no block device on $UFS_HOST — UFS did not enumerate this boot"; exit 1; }
DISK=${DEV##*/}

ufs_count() { journalctl -k -b --no-pager 2>/dev/null | grep -c "ufshcd $UFS_PCI:"; }
io_count()  { journalctl -k -b --no-pager 2>/dev/null | grep -c "I/O error, dev $DISK"; }
warn_count(){ journalctl -k -b --no-pager 2>/dev/null | grep -cE 'WARNING: (core|drivers)/ufshcd'; }

say "kernel $(uname -r), uptime $(uptime -p)"
say "device: $(cat /sys/block/$DISK/device/model 2>/dev/null | tr -s ' ') fw $(cat /sys/block/$DISK/device/rev 2>/dev/null) on $DEV via $UFS_HOST"
say "BEFORE  ufshcd-lines=$(ufs_count) sda-io-errors=$(io_count) ufs-WARNs=$(warn_count) ioerr_cnt=$(cat /sys/block/$DISK/device/ioerr_cnt 2>/dev/null)"

PRECHECK_ERRORS=$(ufs_count)
STUCK=0

echo
say "== runtime PM state =="
# The proof the driver patch, not a udev rule, is holding the link up: the UFS-device WLUN
# and the PCI function must both read control=on with nothing in /etc/udev/rules.d.
WLUN_CTRL=
if [ -n "$UFS_WLUN" ]; then
  WLUN_CTRL=$(cat "/sys/bus/scsi/devices/$UFS_WLUN/power/control" 2>/dev/null)
  say "  WLUN $UFS_WLUN (ufs_device_wlun, the patched path): control=$WLUN_CTRL status=$(cat /sys/bus/scsi/devices/$UFS_WLUN/power/runtime_status 2>/dev/null)"
else
  say "  WLUN: ufs_device_wlun not bound — cannot confirm the patch is holding the link"
fi
P=$(cat "/sys/devices/pci0000:00/$UFS_PCI/power/control" 2>/dev/null)
say "  PCI  $UFS_PCI (patched path): control=$P status=$(cat /sys/devices/pci0000:00/$UFS_PCI/power/runtime_status 2>/dev/null)"
say "  $DEV (sd, informational): control=$(cat /sys/bus/scsi/devices/$(basename "$(readlink -f /sys/block/$DISK/device)")/power/control 2>/dev/null) — sd devices are 'on' by default, so this proves nothing"
say "  udev pin rule: $(ls /etc/udev/rules.d/ | grep -E '^59-ufs-pm-pin\.rules$' || echo 'absent (good: the driver patch must stand alone)')"

read_chunk() { # label offset_mib len_mib -> 0 ok, 1 io-error, 124 stuck
  local label=$1 off=$2 len=$3 t0 t1 rc pid i
  if [ "$STUCK" -ne 0 ]; then say "-- $label: skipped (controller already stuck)"; return 124; fi
  say "-- $label: reading ${len} MiB at ${off} MiB (direct, 120 s cap)"
  t0=$(date +%s.%N)
  dd if="$DEV" of=/dev/null bs=1M skip="$off" count="$len" \
     iflag=direct status=none 2>>"$LOG/dd.log" &
  pid=$!
  for i in $(seq 1 120); do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
  if kill -0 "$pid" 2>/dev/null; then
    STUCK=1
    say "   STUCK: dd pid $pid still blocked after 120 s (D state) — controller wedged, needs reboot"
    return 124
  fi
  wait "$pid"; rc=$?
  t1=$(date +%s.%N)
  say "   rc=$rc elapsed=$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.2f", b-a}')s"
  [ "$rc" -ne 0 ] && say "   ^ non-zero rc: 1 = I/O error (controller not servicing requests)"
  return $rc
}

echo
say "== read tests =="
read_chunk "partition table" 0 4; R1=$?
read_chunk "data (sda2 LUKS area, read-only)" 16384 256; R2=$?

echo
say "== idle 120 s (does the link wedge with nobody touching it?) =="
sleep 120
say "idle  ufshcd-lines=$(ufs_count) sda-io-errors=$(io_count) dev-state=$(cat /sys/block/$DISK/device/state 2>/dev/null)"
read_chunk "post-idle re-read" 0 4; R3=$?

AFTER_ERRORS=$(ufs_count)
IO_ERR=$(io_count)
IOERR_CNT=$(cat /sys/block/$DISK/device/ioerr_cnt 2>/dev/null)
say "AFTER   ufshcd-lines=$AFTER_ERRORS sda-io-errors=$IO_ERR ufs-WARNs=$(warn_count) ioerr_cnt=$IOERR_CNT"

echo
say "== verdict =="
if [ "$R1" -eq 0 ] && [ "$R2" -eq 0 ] && [ "$R3" -eq 0 ] && [ "$IO_ERR" -eq 0 ] && [ "$AFTER_ERRORS" -eq "$PRECHECK_ERRORS" ] && [ "$WLUN_CTRL" = "on" ]; then
  VERDICT="PASS: UFS read cleanly at direct-I/O speed, no new ufshcd messages, link survived 120 s idle, and the ufs_device_wlun + PCI function are control=on from the driver patch alone. Next step is the stress test (ufs-test2.sh) before trusting the disk."
elif [ "$WLUN_CTRL" != "on" ]; then
  VERDICT="FAIL: reads rc=$R1/$R2/$R3, sda I/O errors=$IO_ERR, new ufshcd lines=$((AFTER_ERRORS-PRECHECK_ERRORS)) — but the decisive failure is WLUN control='$WLUN_CTRL' (want 'on'): the runtime-PM pin is NOT held by the patched driver. Check the loaded module (srcversion vs on-disk .zst) before trusting any read result."
else
  VERDICT="FAIL: reads rc=$R1/$R2/$R3 (124 = stuck), sda I/O errors=$IO_ERR, new ufshcd lines=$((AFTER_ERRORS-PRECHECK_ERRORS)). Pin did not prevent the wedge — blacklist ufshcd_pci instead."
fi
say "$VERDICT"

if [ "$AFTER_ERRORS" -gt "$PRECHECK_ERRORS" ] || [ "$IO_ERR" -gt 0 ]; then
  echo
  say "== new kernel messages =="
  journalctl -k -b --no-pager 2>/dev/null | grep -E "ufshcd $UFS_PCI:|dev $DISK" | tail -25 | tee -a "$LOG/run.log"
fi

say "logs in $LOG"
{
  echo "when: $(date -Is)"
  echo "kernel: $(uname -r), uptime: $(uptime -p)"
  PCI_SV_LOADED=$(cat /sys/module/ufshcd_pci/srcversion 2>/dev/null)
  PCI_SV_DISK=$(modinfo -F srcversion /lib/modules/$(uname -r)/kernel/drivers/ufs/host/ufshcd-pci.ko.zst 2>/dev/null)
  if [ -n "$PCI_SV_LOADED" ] && [ "$PCI_SV_LOADED" = "$PCI_SV_DISK" ]; then PCI_SV_NOTE="(patched module loaded)"; else PCI_SV_NOTE="(MISMATCH — verify the patch before trusting this verdict)"; fi
  echo "module: ufshcd_pci loaded '$PCI_SV_LOADED' / on-disk '$PCI_SV_DISK' $PCI_SV_NOTE ; ufshcd_core $(cat /sys/module/ufshcd_core/srcversion 2>/dev/null)"
  echo "PM: WLUN $UFS_WLUN=${WLUN_CTRL:-?} PCI $UFS_PCI=$P udev-rule=$(ls /etc/udev/rules.d/ | grep -cE '^59-ufs-pm-pin\.rules$')"

  echo "reads rc: $R1 $R2 $R3 ; sda io errors: $IO_ERR ; ufshcd lines: $PRECHECK_ERRORS -> $AFTER_ERRORS ; ioerr_cnt: $IOERR_CNT"
  echo "$VERDICT"
  echo "logdir: $LOG"
} > "$OUT/last-result.txt"
