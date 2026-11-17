#!/bin/bash
# ufs-test3.sh — data-integrity test for the Lakefield UFS (sda).
#
# ufs-test2.sh proved the I/O path survives 64 GiB of zeros. Zeros prove little: they are the
# most compressible payload a flash device can be given, and test2 never compared a byte it
# read. This test writes INCOMPRESSIBLE random data, keeps a per-chunk sha256 manifest of the
# source bytes, and reads it back with O_DIRECT twice, comparing chunk by chunk so a failure
# names the byte offset instead of just "it broke".
#
#   ./ufs-test3.sh --dry-run          # no root, no writes: show the plan and run the guards
#   sudo ./ufs-test3.sh --force       # real run on the UFS (destroys the target range)
#   ./ufs-test3.sh --selftest         # no root, no disk: proves the checker detects corruption
#
# Env overrides: OFFSET_MIB (65536 = 64 GiB) LEN_MIB (4096) CHUNK_MIB (256) PASSES (2)
#                DEV (auto-discovered) TMPDIR (buffer dir; prefers /dev/shm)
#
# Nothing outside [OFFSET_MIB, OFFSET_MIB+LEN_MIB) is written. The range is checked against
# the partition table first: overlapping a partition needs --force, being mounted is refused.
set -u
set -o pipefail

UFS_PCI=${UFS_PCI:-0000:00:12.5}
OFFSET_MIB=${OFFSET_MIB:-65536}
LEN_MIB=${LEN_MIB:-4096}
CHUNK_MIB=${CHUNK_MIB:-256}
PASSES=${PASSES:-2}
READ_CAP=${READ_CAP:-300}          # seconds per chunk I/O; a wedged read never returns
SELFTEST=0; FORCE=${FORCE:-0}; DRY=0

for a in "$@"; do
  case $a in
    --selftest)      SELFTEST=1 ;;
    --force)         FORCE=1 ;;
    --dry-run|--dry) DRY=1 ;;
    -h|--help)       sed -n '2,17p' "$0"; exit 0 ;;
    *) echo "unknown argument: $a (try --help)"; exit 2 ;;
  esac
done

die() { echo "REFUSED: $*" >&2; exit 1; }
say() { echo "[$(date -Is)] $*" | tee -a "$LOG/run.log"; }
now() { date +%s.%N; }
rate() { awk -v b="$1" -v s="$2" 'BEGIN{ if (s<=0) s=0.001; printf "%.0f", b/1048576/s }'; }
el()   { awk -v a="$1" -v b="$2" 'BEGIN{ printf "%.1f", b-a }'; }

# ------------------------------------------------------------------ buffers & log dir
# The source and read-back buffers must not live on the same slow microSD/eMMC the
# machine boots from: a 25 MB/s temp file silently caps the measurement and can stall
# the write phase on dirty-page writeback. Prefer tmpfs (256 MiB chunks are fine in 3.8 GB).
pick_bufdir() {
  local need=$(( 2 * CHUNK_MIB + 64 )) free
  for d in /dev/shm /var/tmp "${TMPDIR:-}"; do
    [ -n "$d" ] && [ -d "$d" ] && [ -w "$d" ] || continue
    free=$(df -Pm "$d" | awk 'NR==2{print $4}')
    [ "${free:-0}" -ge "$need" ] && { printf '%s' "$d"; return; }
  done
  printf '/var/tmp'
}
BUF_BASE=${BUFDIR:-$(pick_bufdir)}

if [ "$SELFTEST" -eq 1 ]; then
  LOG=${LOG:-${UFS_DIR:-/var/lib/ufs-check}/selftest-$(date +%Y%m%d-%H%M%S)}
  mkdir -p "$LOG" || die "cannot create $LOG"
  BUF=$(mktemp -d "$BUF_BASE/ufs3-chunks.XXXXXX") || die "no buffer dir"
  IMG=${IMG:-$(mktemp -d /var/tmp/ufs3-image.XXXXXX)/selftest.img}
  truncate -s "$(( OFFSET_MIB + LEN_MIB ))M" "$IMG" || die "truncate failed"
  DEV=$IMG; BACKING=selftest.img; UFS_HOST=selftest; HOSTNUM=0
else
  [ "$DRY" -eq 1 ] || [ "$(id -u)" -eq 0 ] || die "needs root (raw device writes); --dry-run does not"
  LOG=${LOG:-${UFS_DIR:-/var/lib/ufs-check}/run3-$(date +%Y%m%d-%H%M%S)}
  mkdir -p "$LOG" || die "cannot create $LOG"
  BUF=$(mktemp -d "$BUF_BASE/ufs3-chunks.XXXXXX") || die "no buffer dir"
  # Discover the UFS host and its block device: host numbering is a probe race
  # (ufshcd was host1 one boot, host0 the next), so never hardcode host0/sda.
  UFS_HOST=
  for h in /sys/class/scsi_host/host*; do
    [ "$(cat "$h/proc_name" 2>/dev/null)" = ufshcd ] && UFS_HOST=${h##*/}
  done
  [ -n "$UFS_HOST" ] || die "no ufshcd scsi_host — UFS did not probe this boot"
  HOSTNUM=${UFS_HOST#host}
  DEV=${DEV:-}
  if [ -z "$DEV" ]; then
    for b in /sys/block/*; do
      case "$(readlink -f "$b/device" 2>/dev/null)" in
        *"/$UFS_HOST/"*) DEV=/dev/${b##*/} ;;
      esac
    done
  fi
  [ -n "$DEV" ] && [ -b "$DEV" ] || die "no block device on $UFS_HOST"
  BACKING=${DEV##*/}
fi

cleanup() { rm -rf "$BUF"; [ "$SELFTEST" -eq 1 ] && rm -rf "$(dirname "$IMG")"; }
trap cleanup EXIT INT TERM

snap() { journalctl -k -b --no-pager > "$LOG/$1" 2>&1; }
errs() {
  # grep -c prints a count and exits 1 when nothing matches; an `|| echo 0` would emit two
  # lines and break the arithmetic.
  local n
  n=$(grep -cE 'ufshcd_abort|host_reset: total|saved_err|WARNING:|I/O error' "$LOG/$1" 2>/dev/null)
  printf '%s' "${n:-0}"
}

command -v sha256sum >/dev/null || die "sha256sum missing"

# ------------------------------------------------------------------ validate the plan
case $OFFSET_MIB$LEN_MIB$CHUNK_MIB$PASSES in *[!0-9]*) die "sizes/passes must be integers (MiB)" ;; esac
{ [ "$CHUNK_MIB" -gt 0 ] && [ "$LEN_MIB" -gt 0 ] && [ "$PASSES" -ge 1 ]; } || \
  die "LEN_MIB, CHUNK_MIB and PASSES must be > 0"
AVAIL_MIB=$(df -Pm "$BUF" | awk 'NR==2{print $4}')
[ "${AVAIL_MIB:-0}" -ge $(( 2 * CHUNK_MIB + 64 )) ] || \
  die "need $(( 2 * CHUNK_MIB + 64 )) MiB free in $BUF for the buffers (have ${AVAIL_MIB:-0}); set BUFDIR"

OVERLAP=
if [ "$SELFTEST" -eq 0 ]; then
  DISK_MIB=$(( $(cat "/sys/block/$BACKING/size") / 2048 ))
  [ $(( OFFSET_MIB + LEN_MIB )) -le "$DISK_MIB" ] || \
    die "range ${OFFSET_MIB}+${LEN_MIB} MiB runs past the end of $DEV (${DISK_MIB} MiB)"
  # Refuse outright if the disk or any partition/mapping ON IT is mounted (or swap):
  # the target range may then hold live filesystem data. Descendants from lsblk are the
  # only reliable way to see a dm/LUKS layer backed by this disk — a blanket
  # /dev/mapper/ match would trip on the root itself, which is on the microSD.
  MOUNTED=$(lsblk -P -nlo NAME,MOUNTPOINT "$DEV" 2>/dev/null | awk -F'"' '$4 != "" {print $2" -> "$4}' | tr '\n' ';')
  [ -z "$MOUNTED" ] || die "mounted/swapped, so the target range may be live data: $MOUNTED"
  # Which partition(s) does the range land in, and how much of them does it destroy?
  for p in /sys/block/"$BACKING"/"${BACKING}"*; do
    [ -d "$p" ] || continue
    pstart=$(( $(cat "$p/start") / 2048 ))     # MiB
    psize=$(( $(cat "$p/size") / 2048 ))       # MiB
    pend=$(( pstart + psize ))
    lo=$OFFSET_MIB; hi=$(( OFFSET_MIB + LEN_MIB ))
    if [ "$hi" -le "$pstart" ] || [ "$lo" -ge "$pend" ]; then continue; fi
    ilo=$(( lo > pstart ? lo : pstart ))
    ihi=$(( hi < pend ? hi : pend ))
    OVERLAP="${OVERLAP}${OVERLAP:+, }${p##*/} [${ilo}-${ihi} MiB, $(( ihi - ilo )) MiB]"
  done
  if [ -n "$OVERLAP" ] && [ "$FORCE" -ne 1 ]; then
    die "range ${OFFSET_MIB}..$(( OFFSET_MIB + LEN_MIB )) MiB overwrites existing partition data:
        $OVERLAP
        Everything in that range is replaced with random bytes and is unrecoverable.
        Re-run with --force if that is genuinely what you want."
  fi
fi

# ------------------------------------------------------------------ identity
say "== identity =="
{ uname -r; uptime; } | tee -a "$LOG/run.log"
say "buffers: $BUF ($(df -PT "$BUF" | awk 'NR==2{print $1" ("$2")"}'))"
if [ "$SELFTEST" -eq 1 ]; then
  say "SELFTEST: target is a plain file $IMG — the real disk is untouched"
else
  lsblk -o NAME,MODEL,SIZE,TRAN,MOUNTPOINTS "$DEV" | tee -a "$LOG/run.log"
  say "host $UFS_HOST scsi state: $(cat /sys/class/scsi_host/$UFS_HOST/state 2>&1)"
  say "dev $BACKING state: $(cat /sys/block/$BACKING/device/state 2>&1)  ioerr_cnt: $(cat /sys/block/$BACKING/device/ioerr_cnt 2>&1)"
  [ -n "$OVERLAP" ] && say "DESTRUCTIVE (--force): overwriting $OVERLAP"
fi
say "plan: write ${LEN_MIB} MiB of random data at ${OFFSET_MIB} MiB in ${CHUNK_MIB} MiB chunks, then $PASSES O_DIRECT read-back pass(es)"
if [ "$DRY" -eq 1 ]; then
  say "DRY RUN: guards passed, nothing was written. Real run: sudo $0 --force"
  exit 0
fi

snap kernel-before.log 2>/dev/null || true
B=$(errs kernel-before.log 2>/dev/null || echo 0); B=${B:-0}
say "kernel error lines before: $B"

WATCH=
if [ "$SELFTEST" -eq 0 ]; then
  ( journalctl -k -f --no-pager > "$LOG/kernel-live.log" 2>&1 ) & WATCH=$!
  sleep 1
  say "== probe: 4 MiB direct read, 20 s cap =="
  timeout 20 dd if="$DEV" of=/dev/null bs=1M count=4 iflag=direct status=none
  P0=$?; say "probe rc=$P0 (124 = hung)"
  if [ "$P0" -ne 0 ]; then kill "$WATCH" 2>/dev/null; die "device is not servicing reads (rc=$P0) — run ufs-test2.sh first"; fi
fi

# ------------------------------------------------------------------ write phase
: > "$LOG/manifest.txt"
WRITE_RC=0; written=0; idx=0
say "== write phase: random payload, O_DIRECT, sha256 of the source taken before it lands =="
t_all=$(now)
while [ "$written" -lt "$LEN_MIB" ]; do
  n=$CHUNK_MIB
  [ $(( written + n )) -gt "$LEN_MIB" ] && n=$(( LEN_MIB - written ))
  src=$BUF/chunk
  if ! dd if=/dev/urandom of="$src" bs=1M count="$n" status=none; then
    WRITE_RC=1; say "chunk $idx: could not generate random data"; break
  fi
  h=$(sha256sum "$src" | awk '{print $1}')
  echo "$idx $(( OFFSET_MIB + written )) $n $h" >> "$LOG/manifest.txt"
  t0=$(now)
  timeout 900 dd if="$src" of="$DEV" bs=1M seek=$(( OFFSET_MIB + written )) count="$n" \
        oflag=direct conv=notrunc status=none
  wrc=$?
  t1=$(now)
  if [ "$wrc" -ne 0 ]; then
    WRITE_RC=1; say "chunk $idx @ $(( OFFSET_MIB + written )) MiB: write rc=$wrc (124 = hung) — stopping"; break
  fi
  say "  chunk $idx @ $(( OFFSET_MIB + written )) MiB  ${n} MiB  $(rate $(( n * 1048576 )) "$(el "$t0" "$t1")") MB/s  ${h:0:16}…"
  written=$(( written + n )); idx=$(( idx + 1 ))
done
WCHUNKS=$idx
say "write phase: ${written}/${LEN_MIB} MiB in $WCHUNKS chunks, rc=$WRITE_RC, wall $(el "$t_all" "$(now)") s"
sync

# ------------------------------------------------------------------ verify phase
MISMATCH=; PASS_FAIL=
verify_pass() {   # $1 = pass number
  local p=$1 bad=0 readmib=0 t0 t1 rc r out off n expect chunk
  t0=$(now)
  while read -r chunk off n expect; do
    # Hash while streaming: piping into sha256sum overlaps the digest with the read, so the
    # measured rate is closer to the device than a dd→tmpfs→sha256 round trip (which costs
    # roughly 2x and reads ~315 MB/s where the raw dd does ~860). pipefail is set globally,
    # so $? is dd's status — 124 means the read wedged and the hash is truncated.
    out=$(timeout "$READ_CAP" dd if="$DEV" bs=1M skip="$off" count="$n" iflag=direct status=none | sha256sum)
    rc=$?
    if [ "$rc" -ne 0 ]; then
      bad=$(( bad + 1 ))
      MISMATCH="${MISMATCH}${MISMATCH:+, }pass$p:chunk$chunk@${off}MiB(read rc=$rc)"
      PASS_FAIL="${PASS_FAIL}chunk $chunk at byte $(( off * 1048576 )) could not be read back (dd rc=$rc, 124 = wedged); "
      continue
    fi
    r=${out%% *}
    readmib=$(( readmib + n ))
    if [ "$r" != "$expect" ]; then
      bad=$(( bad + 1 ))
      MISMATCH="${MISMATCH}${MISMATCH:+, }pass$p:chunk$chunk@${off}MiB"
      say "  MISMATCH pass$p chunk $chunk @ ${off} MiB: expected ${expect:0:16}… got ${r:0:16}…"
      PASS_FAIL="${PASS_FAIL}chunk $chunk at byte $(( off * 1048576 )) ($(( n )) MiB) did not read back as written; "
    fi
  done < "$LOG/manifest.txt"
  t1=$(now)
  say "pass $p: ${readmib} MiB compared in $(el "$t0" "$t1") s ($(rate $(( readmib * 1048576 )) "$(el "$t0" "$t1")") MB/s read+hash), mismatching chunks: $bad"
  [ "$bad" -eq 0 ]
}

for p in $(seq 1 "$PASSES"); do
  say "== read-back pass $p/$PASSES: O_DIRECT, sha256 per chunk vs manifest =="
  verify_pass "$p" || PASS_FAIL="${PASS_FAIL}pass $p had mismatches; "
done

# ------------------------------------------------------------------ counters / verdict
IO_ERR=0; IO_ERR_A=0; IOERR_BEFORE=unknown; IOERR_AFTER=unknown; A=$B; LIVE_ERR=0; HSTATE=selftest; DSTATE=selftest
if [ "$SELFTEST" -eq 0 ]; then
  [ -n "$WATCH" ] && kill "$WATCH" 2>/dev/null
  snap kernel-after.log
  A=$(errs kernel-after.log); A=${A:-0}
  IOERR_BEFORE=$(awk '/ioerr_cnt:/ {print $NF; exit}' "$LOG/run.log")
  IOERR_AFTER=$(cat "/sys/block/$BACKING/device/ioerr_cnt" 2>&1)
  IO_ERR_B=$(grep -c "I/O error, dev $BACKING" "$LOG/kernel-before.log" 2>/dev/null); IO_ERR_B=${IO_ERR_B:-0}
  IO_ERR_A=$(grep -c "I/O error, dev $BACKING" "$LOG/kernel-after.log" 2>/dev/null); IO_ERR_A=${IO_ERR_A:-0}
  IO_ERR=$(( IO_ERR_A - IO_ERR_B ))
  LIVE_ERR=$(grep -cE 'ufshcd_error|host_reset: total|WARNING:|I/O error' "$LOG/kernel-live.log" 2>/dev/null); LIVE_ERR=${LIVE_ERR:-0}
  HSTATE=$(cat "/sys/class/scsi_host/$UFS_HOST/state" 2>&1)
  DSTATE=$(cat "/sys/block/$BACKING/device/state" 2>&1)
  say "error lines after: $A (delta $(( A - B ))); new '$BACKING' I/O errors: $IO_ERR (total $IO_ERR_A); live ufshcd/WARN/I/O lines: $LIVE_ERR"
  say "post: host state=$HSTATE dev state=$DSTATE ioerr_cnt=$IOERR_BEFORE -> $IOERR_AFTER"
  say "== ufshcd/sd/WARNING lines seen live =="
  { grep -E "ufshcd|sd $HOSTNUM:0:0:0|WARNING" "$LOG/kernel-live.log" 2>/dev/null || true; } | tee "$LOG/ufs-only.log" | tail -40
  # A silent kernel log is part of the pass condition, not a nicety.
  if [ $(( A - B )) -ne 0 ] || [ "$IO_ERR" -ne 0 ] || [ "$LIVE_ERR" -ne 0 ]; then
    PASS_FAIL="${PASS_FAIL}kernel logged errors during the test (new lines $(( A - B )), I/O errors $IO_ERR, live $LIVE_ERR); "
  fi
  [ "$HSTATE" = running ] || PASS_FAIL="${PASS_FAIL}host state '$HSTATE'; "
  [ "$DSTATE" = running ] || PASS_FAIL="${PASS_FAIL}device state '$DSTATE'; "
  [ "$IOERR_BEFORE" = "$IOERR_AFTER" ] || PASS_FAIL="${PASS_FAIL}ioerr_cnt moved $IOERR_BEFORE -> $IOERR_AFTER; "
fi
[ "$WRITE_RC" -eq 0 ] || PASS_FAIL="${PASS_FAIL}write phase rc=$WRITE_RC after $written MiB; "

if [ -n "$PASS_FAIL" ]; then
  VERDICT="FAIL: $PASS_FAIL"
elif [ "$SELFTEST" -eq 1 ]; then
  VERDICT="PASS (selftest): ${LEN_MIB} MiB of random data in $WCHUNKS chunks written O_DIRECT and read back identically in $PASSES pass(es)."
else
  VERDICT="PASS: ${LEN_MIB} MiB of incompressible random data at ${OFFSET_MIB} MiB written O_DIRECT and read back byte-identical (sha256 per ${CHUNK_MIB} MiB chunk) in $PASSES pass(es); no new kernel lines, no I/O errors, ioerr_cnt $IOERR_BEFORE unchanged. Data integrity under load — not a statement about endurance or resume."
fi
say "$VERDICT"

{
  echo "when: $(date -Is)"
  echo "kernel: $(uname -r), uptime: $(uptime -p)"
  echo "target: $DEV range ${OFFSET_MIB}..$(( OFFSET_MIB + LEN_MIB )) MiB, $WCHUNKS chunks of ${CHUNK_MIB} MiB, $PASSES read-back pass(es)"
  [ "$SELFTEST" -eq 1 ] && echo "mode: SELFTEST (real disk untouched)"
  echo "manifest: $LOG/manifest.txt sha256 $(sha256sum "$LOG/manifest.txt" | awk '{print $1}')"
  echo "kernel error lines: $B -> $A ; new $BACKING I/O errors: $IO_ERR ; ioerr_cnt: $IOERR_BEFORE -> $IOERR_AFTER"
  echo "$VERDICT"
  echo "mismatches: ${MISMATCH:-none}"
  echo "logdir: $LOG"
} > "$LOG/last-result3.txt"
say "wrote $LOG/last-result3.txt"

# ------------------------------------------------------------------ selftest: prove it bites
if [ "$SELFTEST" -eq 1 ]; then
  # Corrupt inside the LAST chunk (a 1-chunk run has no chunk 1) and require the verifier
  # to name that chunk; then repair it and require a clean pass.
  read -r cidx coff cn _ < <(tail -1 "$LOG/manifest.txt")
  bad_off=$(( coff * 1048576 + (cn / 2) * 1048576 + 4096 ))
  say "== selftest: flip one byte inside chunk $cidx at byte $bad_off and confirm the verifier catches it =="
  printf '\xff' | dd of="$DEV" bs=1 seek="$bad_off" conv=notrunc status=none || die "corruption injection failed"
  MISMATCH=; PASS_FAIL=
  if verify_pass 99; then say "SELFTEST BROKEN: one flipped byte went undetected"
  else say "selftest ok: corruption of one byte in chunk $cidx detected as $MISMATCH"; fi
  # repair = re-randomise that chunk using the manifest's own offset and length (the last
  # chunk may be shorter than CHUNK_MIB), update the manifest, expect a clean pass
  dd if=/dev/urandom of="$BUF/fix" bs=1M count="$cn" status=none
  h=$(sha256sum "$BUF/fix" | awk '{print $1}')
  awk -v i="$cidx" -v h="$h" '$1==i {$4=h} {print}' "$LOG/manifest.txt" > "$LOG/manifest.tmp" \
    && mv "$LOG/manifest.tmp" "$LOG/manifest.txt"
  timeout 900 dd if="$BUF/fix" of="$DEV" bs=1M seek="$coff" count="$cn" oflag=direct conv=notrunc status=none \
    || die "repair write failed"
  MISMATCH=; PASS_FAIL=
  if verify_pass 100; then say "selftest ok: after repairing chunk $cidx the same verifier reports a clean pass"
  else say "SELFTEST PROBLEM: still failing after repair (${MISMATCH:-reason unknown})"; fi
  say "== selftest done =="
fi
