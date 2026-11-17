#!/bin/bash
# install-i915.sh — install a locally built i915.ko for a given kernel.
#
# Usage: sudo ./install-i915.sh /path/to/i915.ko [kernel-version]
#        (kernel defaults to the running one)
#
# Refuses to install a module whose vermagic does not match the target kernel
# exactly. Keeps the distro module as i915.ko.zst.orig beside it, so the rollback
# is a copy, not a rebuild.
set -euo pipefail

KO=${1:?usage: install-i915.sh <i915.ko> [kernel-version]}
K=${2:-$(uname -r)}
DSTDIR=/lib/modules/$K/kernel/drivers/gpu/drm/i915
DST=$DSTDIR/i915.ko.zst

[ "$(id -u)" -eq 0 ] || { echo "run me with sudo" >&2; exit 1; }
[ -f "$KO" ] || { echo "no such module: $KO" >&2; exit 1; }
[ -f "$DST" ] || { echo "target kernel has no i915 module at $DST" >&2; exit 1; }

want=$(modinfo -F vermagic "$DST")
got=$(modinfo -F vermagic "$KO")
echo "built:   $got"
echo "target:  $want"
[ "$got" = "$want" ] || {
	echo "vermagic mismatch — NOT installing. Rebuild against $K." >&2
	exit 1
}

if [ ! -f "$DST.orig" ]; then
	echo "backing up the distro module -> $DST.orig"
	cp -a "$DST" "$DST.orig"
else
	echo "keeping existing backup $DST.orig"
fi

echo "installing $(basename "$KO") -> $DST"
zstd -19 -q -f "$KO" -o "$DST"
depmod -a "$K"

echo
echo "installed srcversion: $(modinfo -F srcversion "$DST")"
echo "loaded  srcversion: $(cat /sys/module/i915/srcversion 2>/dev/null || echo '(i915 not loaded)')"
echo
echo "reboot to load it, then check:"
echo "  cat /sys/class/graphics/fb0/name        # i915drmfb"
echo "  ls /dev/dri                             # cardN + renderD128"
echo
echo "rollback:"
echo "  cp -a $DST.orig $DST && depmod -a $K && reboot"
