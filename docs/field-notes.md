# Field notes

The rules this work produced. Each one cost real time, and several of them cost
it twice. Read this before writing another probe for this hardware.

## Building and installing

1. **Match the tree to the running kernel exactly — version *and* config.** Copy
   `Module.symvers` from `/usr/lib/modules/$(uname -r)/build/` or `modpost` fails
   on every export. Reproduce the localversion in the tree
   (`./scripts/config --set-str LOCALVERSION "-arch1-1"`, then `make olddefconfig`),
   or vermagic is the bare version and the module will not load.
2. **Gate on vermagic, not on the build succeeding.**
   `modinfo -F vermagic <built>.ko` must equal the installed module's, exactly.
3. **`make -s kernelrelease` lies before generated files settle.** The
   authoritative string is `include/generated/utsrelease.h`.
4. **A header-only change does not rebuild its users.** `make M=...` reused stale
   objects after editing `intel_combo_phy_regs.h`. Delete the `.o` files of every
   `.c` that includes it.
5. **Never let the module go into the initramfs stale.** If the module is on the
   boot path (UFS root, i915 in a UKI), regenerate the image and then verify the
   copy *inside* it (`lsinitrd -f ... > /tmp/i.zst; modinfo -F srcversion /tmp/i.zst`).
6. **A module parameter only counts if sysfs says so.** For an undeclared
   parameter kmod logs `unknown parameter '…' ignored` and loads the module
   anyway. Check `/sys/module/<mod>/parameters/<p>`.
7. **`srcversion` does not always change across a real code change.** Neither do
   `strings`. When it matters, verify against the disassembly
   (`objdump -d i915.ko | grep <immediate>`) or add an explicit readback in the
   driver.

## Testing on live hardware

8. **Arm a watchdog before any display test.** `hung_task_timeout_secs=30
   hung_task_panic=1 panic=15 sysrq=1`, runtime-only. `hung_task_panic` does not
   catch a spinning task, so `sysrq-b` remains the reliable escape.
9. **Never load a wedged i915 twice.** `rmmod` on a wedged module hangs; the only
   recovery is a reboot. Bound every `rmmod` with `timeout`.
10. **A panel that "shows nothing" is not evidence.** Check the machine side
    first: `/sys/class/graphics/fb0/name` (i915drmfb vs simpledrm),
    `/sys/class/backlight/intel_backlight/brightness` (0 is dim, not broken), and
    the connector's `status`/`enabled`. State which framebuffer owns the screen,
    because the eye cannot supply that.
11. **A video-mode DSI panel fails silently.** No link training, no
    acknowledgement. Silence is expected, not proof of a working link.
12. **Do not test suspend on hardware whose resume path is the thing being
    fixed.** A failed resume costs the device until reboot.

## Reading registers

13. **Never probe the GPU BAR from userspace.** Reading
    `/sys/bus/pci/devices/0000:00:02.0/resource0` (or `/dev/mem`) to scan the
    combo PHY hung the machine hard enough to need a forced power-off: those
    accesses bypass i915's forcewake and power-domain handling. Probe through
    `intel_de_read()` inside the driver, or through `intel_reg` (which does take
    forcewake) for status.
14. **A Dump window that ends early reads exactly like a match.** Enumerate the
    full block from the PRM before declaring a comparison clean. Every
    comparison here covered `0x162000..0x1621ff` while the D-PHY lane registers
    that mattered start at `0x162280`.
15. **A register whose write does not stick is not a config bit.** If a write
    reads back the old value immediately, it is hardware-updated state. Move on.
16. **Use the firmware's working state as the reference.** Dump it on the first
    driver load after a boot, before anything is programmed. Dumps taken later
    only show the previous run's leftovers, so this needs a real reboot each time.
17. **`debugfs/dri/0/i915_capabilities` is the authority** on what the driver
    decided. Read it before theorising from source.

## Instrumenting

18. **`MISSING_CASE()` followed by `fallthrough` is a landmine.** `MISSING_CASE`
    is `WARN(1, ...)` with a constant-true condition, so GCC emits `UD1` for the
    unreachable case: an unexpected value becomes an invalid-opcode oops.
19. **`module_param()` must exist in exactly one translation unit.** Duplicating
    it makes the module fail to load with `sysfs: cannot create duplicate
    filename`, i915 never probes, and the panel stays on simpledrm.
20. **A dynamic-debug rule written before `insmod` matches nothing** (the sites do
    not exist yet), and `drm_dbg_kms` is gated by the `drm.debug` mask, not by
    dyndbg at all. Use `pr_info` behind a module parameter, and verify presence
    with `strings module.ko | grep <marker>`.
21. **Do not trust `grep -c` of a debug line to prove a code path was skipped.**
    "No message" is not "no code path".
22. **Bound every slow probe and print progress around it.** A 37 MB initrd takes
    minutes in `lsinitrd` with no output, which reads as a hang and gets the task
    killed.
23. **Never poll a long build with a foreground sleep loop.** Start it in the
    background with a notification, then read short tails. For liveness use the
    artifact's mtime or `pgrep -x ninja` — `pgrep -f "ninja -C build"` matches
    the polling shell's own command line and reports RUNNING forever.

## Verifying claims about userspace

24. **A renderer string means "the driver loaded"; a shader draw with
    `glReadPixels` means "the GPU executes".** Different claims. `eglinfo -B` only
    proves a context exists.
25. **GLX takes its renderer from the X server's Mesa.** A patched build tree
    never shows up in `glxinfo`; test the render node with
    `EGL_PLATFORM=surfaceless`.
26. **Versioned symbols are part of the ABI.** A library built with a different
    project version cannot satisfy a shim that resolves
    `symbol@@libgallium-<distro-ver>.so`. `nm -D` before installing.
27. **A failed `meson configure` leaves the old configuration in place**, and the
    following `ninja` then rebuilds nothing — which reads exactly like "the change
    had no effect". Check the exit status and the artifact's mtime.

## Sysfs and scripts

28. **Never hardcode `host0`/`sda` in a probe.** `ufshcd` came up as `host1` in one
    boot and `host0` in the next. Discover the host from
    `/sys/class/scsi_host/*/proc_name`, then the WLUN and block device, then
    assert the path resolved to the device you meant.
29. **`0:0:0:0` is `control=on` by default for every `sd` disk**, so a
    runtime-PM pin check against it passes no matter what. Check the
    `ufs_device_wlun` and the PCI function.
30. **Escaped quotes inside a generated shell script can double up and fail
    silently.** `printf \"%.2f\"` shipped as `printf \\\"%.2f\\\"` made `awk` abort
    and every timing field come out empty while the PASS/FAIL logic (which keyed
    off a different exit code) still looked fine. `bash -n` plus `cat -A` on the
    exact line.
31. **Test the script's own logic, including the failure branch.** Copy it,
    remove the root gate, redirect the output dir, zero the sleeps, and stub the
    privileged command — run a synthetic PASS *and* a FAIL, because the FAIL
    branch is the one that fires unattended.
32. **A scheduled probe's PASS is a claim to re-check.** `systemctl is-active`
    answers `activating` with a non-zero exit, so a naive wait loop reads the
    previous boot's file. Poll `ActiveState` and check the mtime.

## Judgement

33. **Keep measured numbers attached to the command that produced them.** "N
    lines" means nothing without saying which pattern, over which boot, in which
    phase. A `grep -c` over a whole boot counts a later error storm; `ioerr_cnt`
    reads `0x3`–`0x4` from probe so its absolute value says nothing, only the
    delta does.
34. **When a diff comes back clean and the hardware still fails, suspect the
    measurement before the hardware.** Twice here the answer was "you looked at
    the wrong thing", not "the silicon is broken".
