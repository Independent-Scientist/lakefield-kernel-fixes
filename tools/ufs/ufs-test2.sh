#!/bin/bash
# ufs-test2.sh [LOGDIR] — Lakefield UFS probe: clear a wedged host, then stress the disk.
# Needs root. Writes 32 GiB at a 16 GiB offset (inside the disposable LUKS), reads it back,
# watches 90 s idle, and captures every kernel message the ufshcd stack emits meanwhile.
set -u
UFS_PCI=${UFS_PCI:-0000:00:12.5}
LOG=${1:-${UFS_DIR:-$(cd "$(dirname "$0")" && pwd)}/run-$(date +%Y%m%d-%H%M%S)}
mkdir -p "$LOG"
# Discover the UFS host / LUN prefix / block device: host numbering is a probe race
# (ufshcd was host1 in one boot, host0 in the next), so never hardcode it.
UFS_HOST=
for h in /sys/class/scsi_host/host*; do
  [ "$(cat "$h/proc_name" 2>/dev/null)" = ufshcd ] && UFS_HOST=${h##*/}
done
[ -n "$UFS_HOST" ] || { echo "no ufshcd scsi_host — UFS did not probe this boot"; exit 1; }
HOSTNUM=${UFS_HOST#host}
DEV=
for b in /sys/block/*; do
  case "$(readlink -f "$b/device" 2>/dev/null)" in
  *"/$UFS_HOST/"*) DEV=/dev/${b##*/} ;;
  esac
done
[ -n "$DEV" ] && [ -b "$DEV" ] || { echo "no block device on $UFS_HOST"; exit 1; }
say() { echo "[$(date -Is)] $*" | tee -a "$LOG/run.log"; }
snap() { journalctl -k -b --no-pager > "$LOG/$1" 2>&1; }
errs() {
  # grep -c always prints a count (0 when nothing matches) and exits 1 in that case;
  # an `|| echo 0` here would produce two lines ("0\n0") and break the arithmetic below.
  local n
  n=$(grep -cE 'ufshcd_abort|host_reset: total|saved_err|WARNING:|I/O error' "$LOG/$1" 2>/dev/null)
  printf '%s' "${n:-0}"
}

say "== identity =="
{ uname -r; uptime; lsblk -o NAME,MODEL,SIZE,TRAN; } | tee -a "$LOG/run.log"
say "host $UFS_HOST scsi state: $(cat /sys/class/scsi_host/$UFS_HOST/state 2>&1)"
say "sda device state: $(cat /sys/block/${DEV##*/}/device/state 2>&1)  ioerr_cnt: $(cat /sys/block/${DEV##*/}/device/ioerr_cnt 2>&1)"

snap kernel-before.log
B=$(errs kernel-before.log); say "error lines before: $B"

( journalctl -k -f --no-pager > "$LOG/kernel-live.log" 2>&1 ) & WATCH=$!
sleep 1

say "== probe 1: 4 MiB direct read, 20 s cap =="
timeout 20 dd if=$DEV of=/dev/null bs=1M count=4 iflag=direct status=none
P1=$?; say "probe1 rc=$P1 (124 = hung)"

if [ "$P1" -ne 0 ]; then
  say "== host is not servicing I/O; attempting PCI unbind/bind of $UFS_PCI =="
  echo -n $UFS_PCI > /sys/bus/pci/drivers/ufshcd/unbind && say "unbound ok"
  sleep 2
  echo -n $UFS_PCI > /sys/bus/pci/drivers/ufshcd/bind && say "bound ok"
  for i in $(seq 1 30); do [ -b "$DEV" ] && break; sleep 1; done
  say "after rebind: sda present=$([ -b "$DEV" ] && echo yes || echo no), host state=$(cat /sys/class/scsi_host/$UFS_HOST/state 2>&1), dev state=$(cat /sys/block/${DEV##*/}/device/state 2>&1)"
  sleep 3
  say "== probe 2: 4 MiB direct read after reset, 20 s cap =="
  timeout 20 dd if=$DEV of=/dev/null bs=1M count=4 iflag=direct status=none
  P2=$?; say "probe2 rc=$P2"
fi

OFFSET_MIB=16384
LEN_MIB=32768
say "== write: ${LEN_MIB} MiB zeros at ${OFFSET_MIB} MiB, oflag=direct, no verify =="
timeout 900 dd if=/dev/zero of=$DEV bs=1M seek=$OFFSET_MIB count=$LEN_MIB oflag=direct conv=notrunc status=progress 2>&1 | tail -3 | tee -a "$LOG/write.log"
WR=${PIPESTATUS[0]}; say "write rc=$WR"

say "== read back: ${LEN_MIB} MiB from ${OFFSET_MIB} MiB, iflag=direct =="
timeout 900 dd if=$DEV of=/dev/null bs=1M skip=$OFFSET_MIB count=$LEN_MIB iflag=direct status=progress 2>&1 | tail -3 | tee -a "$LOG/read.log"
RD=${PIPESTATUS[0]}; say "read rc=$RD"

say "== idle watch 90 s =="
sleep 90
say "post-idle: host state=$(cat /sys/class/scsi_host/$UFS_HOST/state 2>&1), dev state=$(cat /sys/block/${DEV##*/}/device/state 2>&1), ioerr_cnt=$(cat /sys/block/${DEV##*/}/device/ioerr_cnt 2>&1)"

kill $WATCH 2>/dev/null
snap kernel-after.log
A=$(errs kernel-after.log); A=${A:-0}
say "error lines after: $A (delta $((A-B)))"
say "== ufshcd/WARNING lines seen live =="
grep -E "ufshcd|sd $HOSTNUM:0:0:0|WARNING" "$LOG/kernel-live.log" | tee "$LOG/ufs-only.log" | tail -40
say "== done; logs in $LOG =="
