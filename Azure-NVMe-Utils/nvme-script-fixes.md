# Azure-NVMe-Conversion.ps1 — Linux Bash Script Fix Implementation Guide

> **Purpose:** Technical implementation spec for all fixes to the embedded Linux bash
> script in `Azure-NVMe-Conversion.ps1` (variable `$linux_check_script`, lines 643–862).
> Validated against 148 Azure VM images in `dev/vm-data-consolidated.json`.
>
> **Audience:** AI agents and software engineers implementing the fixes.

---

## Implementation Status

> **Last updated:** 2026-03-17 — all fixes implemented across PS1, standalone script, and playbook

| Fix # | Severity | Title | Status | Notes |
|---|---|---|---|---|
| — | CRITICAL | Gen1 detection bug | ✅ Done | Gen1 check moved before controller type check; `exit` added; null `DiskControllerType` treated as SCSI |
| 1 | CRITICAL | `grub2-mkconfig` output path missing `.cfg` | ✅ Done | All occurrences now write to `/boot/grub2/grub.cfg` |
| 2 | CRITICAL | Missing `GRUB_DISABLE_OS_PROBER=true` | ✅ Done | Prefixed on all `grub2-mkconfig` and `update-grub` calls |
| 3 | CRITICAL | SUSE uses wrong GRUB variable | ✅ Done | SUSE has own `suse\|sles\|opensuse*` case targeting `GRUB_CMDLINE_LINUX_DEFAULT` |
| 4 | HIGH | `almalinux` not in case statements | ✅ Done | Added to `check_nvme_driver()` and `check_nvme_timeout()` |
| 5 | HIGH | `azurelinux` not in case statements | ✅ Done | Added as `azurelinux\|mariner` to both functions |
| 6 | MEDIUM | BLS systems need `grubby` | ✅ Done | `grubby --update-kernel=ALL --args=...` added after grub2-mkconfig for RHEL and OL when BLS enabled |
| 7 | MEDIUM | Verification grep checks non-existent files | ✅ Done | Dynamic `_grub_check_files` variable + `2>/dev/null`; removed hardcoded `/etc/grub.conf` and `/boot/grub/grub.cfg` |
| 8 | MEDIUM | OL 7.9/8.2 dracut gap | ✅ Done | `pci-hyperv` check added to initramfs verification loop + dracut config; skip `*rescue*` images |
| 9 | MEDIUM | `/etc/default/grub.conf` fallback is dead code | ✅ Done | Removed all `elif [ -f /etc/default/grub.conf ]` branches |
| 10 | LOW | `lsinitrd` checks only default kernel | ✅ Done | Loop all /boot/initramfs-*.img (skip *kdump* and *rescue*); dracut -f --regenerate-all |
| 11 | LOW | fstab check does not flag LVM paths | ✅ Done | Added comment explaining `/dev/mapper/*` and `PARTUUID=` are safe |
| 12 | LOW | Inconsistent `sudo` usage | ✅ Done | Removed all `sudo` prefixes — script runs as root via `Invoke-AzVMRunCommand` |

**Dry-run test results (2026-03-17, run 3 — with pci-hyperv check + rescue exclusion):** 41 of 41 Gen2 x64 VMs converted to NVMe and boot successfully. 12 needed grub changes (`nvme_core.io_timeout=240`), of which 6 also have BLS enabled. OL 7.9 (UEK 5.4.17) now succeeds — `pci-hyperv` was missing from initramfs and is now detected and added automatically. Post-conversion verification (`post.json`) confirmed all 41 hosts boot on `nvme0n1`.

---

## Table of Contents

1. [Current script structure](#1-current-script-structure)
2. [Distro ID map — all 148 VMs](#2-distro-id-map--all-148-vms)
3. [GRUB variable map — per distro](#3-grub-variable-map--per-distro)
4. [Fix 1: CRITICAL — grub2-mkconfig output path missing .cfg](#4-fix-1-critical--grub2-mkconfig-output-path-missing-cfg)
5. [Fix 2: CRITICAL — Missing GRUB_DISABLE_OS_PROBER=true](#5-fix-2-critical--missing-grub_disable_os_probertrue)
6. [Fix 3: CRITICAL — SUSE uses wrong GRUB variable](#6-fix-3-critical--suse-uses-wrong-grub-variable)
7. [Fix 4: HIGH — almalinux ID not in any case statement](#7-fix-4-high--almalinux-id-not-in-any-case-statement)
8. [Fix 5: HIGH — azurelinux ID not in any case statement](#8-fix-5-high--azurelinux-id-not-in-any-case-statement)
9. [Fix 6: MEDIUM — BLS systems need grubby for reliable param update](#9-fix-6-medium--bls-systems-need-grubby-for-reliable-param-update)
10. [Fix 7: MEDIUM — Verification grep checks non-existent files](#10-fix-7-medium--verification-grep-checks-non-existent-files)
11. [Fix 8: MEDIUM — OL 7.9 and 8.2 NVMe dracut gap + grub path bug](#11-fix-8-medium--ol-79-and-82-nvme-dracut-gap--grub-path-bug)
12. [Fix 9: MEDIUM — /etc/default/grub.conf fallback is dead code](#12-fix-9-medium--etcdefaultgrubconf-fallback-is-dead-code)
13. [Fix 10: LOW — lsinitrd checks only the default kernel](#13-fix-10-low--lsinitrd-checks-only-the-default-kernel)
14. [Fix 11: LOW — fstab check does not flag LVM device paths](#14-fix-11-low--fstab-check-does-not-flag-lvm-device-paths)
15. [Fix 12: LOW — Inconsistent sudo usage](#15-fix-12-low--inconsistent-sudo-usage)
16. [Full corrected script](#16-full-corrected-script)
17. [Test matrix](#17-test-matrix)

---

## 1. Current script structure

The bash script is embedded in a PowerShell here-string (`$linux_check_script = @'....'@`).
The fix variant is produced by: `$linux_fix_script = $linux_check_script.Replace("fix=false","fix=true")`.

**Functions:**

| Function | Purpose |
|---|---|
| `check_nvme_driver()` | Verify NVMe modules exist in initramfs/initrd |
| `check_nvme_timeout()` | Verify `nvme_core.io_timeout=240` is in GRUB cmdline |
| `check_fstab()` | Verify `/etc/fstab` does not use `/dev/sd*` device names |

**Execution context:** The script runs via `Invoke-AzVMRunCommand` which executes as root on a **live, running** VM (not chroot).

---

## 2. Distro ID map — all 148 VMs

The script reads `ID` from `/etc/os-release` via `source /etc/os-release; distro="$ID"`.

| `$ID` value | Distro family | Image count | Versions in dataset |
|---|---|---|---|
| `rhel` | Red Hat Enterprise Linux | 34 | 7.4, 7.6, 7.7, 7.9, 8.1, 8.2, 8.6, 8.8, 8.9, 8.10, 9.2, 9.4, 9.5, 9.7, 10.1 |
| `ol` | Oracle Linux | 16 | 7.9, 8.2, 8.10, 9.5, 9.6, 10.0 |
| `almalinux` | AlmaLinux | 10 | 8.10, 9.5, 9.7, 10.1 |
| `ubuntu` | Ubuntu | 38 | 20.04, 22.04, 24.04, 24.10, 25.04, 25.10 |
| `debian` | Debian | 14 | 11, 12, 13 |
| `sles` | SUSE Linux Enterprise Server | 14 | 12 SP5, 15 SP4, 15 SP5, 15 SP6, 15 SP7, 16.0 |
| `azurelinux` | Azure Linux (CBL-Mariner successor) | 8 | 3.0 |
| `centos` | CentOS | 14 | 7.7, 7.9 |

**IDs NOT handled by the current script:** `almalinux`, `azurelinux`
**IDs handled but routed incorrectly:** `sles` (grouped with RHEL for GRUB variable)

---

## 3. GRUB variable map — per distro

This is the ground-truth from 148 VMs. The script must target the correct GRUB variable for each distro.

### 3.1 Distros that use `GRUB_CMDLINE_LINUX` (boot parameters here)

| Distro | `GRUB_CMDLINE_LINUX` value (representative) | `GRUB_CMDLINE_LINUX_DEFAULT` | BLS |
|---|---|---|---|
| **RHEL 7** | `"crashkernel=auto console=tty1 console=ttyS0 earlyprintk=ttyS0 rootdelay=300 scsi_mod.use_blk_mq=y"` | not present | No |
| **RHEL 8** | `"loglevel=3 crashkernel=auto console=tty1 console=ttyS0 earlyprintk=ttyS0 rootdelay=300"` | not present | Yes |
| **RHEL 9** | `"ro console=tty1 console=ttyS0 earlyprintk=ttyS0 rootdelay=300 nvme_core.io_timeout=240 net.ifnames=0"` | not present | Yes |
| **RHEL 10** | `"ro nvme_core.io_timeout=240 console=tty1 console=ttyS0 earlyprintk=ttyS0 rootdelay=300"` | not present | Yes |
| **AlmaLinux 9** | `"loglevel=3 console=tty1 console=ttyS0 earlyprintk=ttyS0 rootdelay=300 no_timer_check nvme_core.io_timeout=240 biosdevname=0 net.ifnames=0"` | not present | Yes |
| **CentOS 7** | `"crashkernel=auto console=tty0 console=ttyS0,115200n8"` | not present | No |
| **Debian 12** | `"console=tty0 console=ttyS0,115200 earlyprintk=ttyS0,115200 consoleblank=0"` | `""` (empty) | No |

### 3.2 Distros that use `GRUB_CMDLINE_LINUX_DEFAULT` (boot parameters here)

| Distro | `GRUB_CMDLINE_LINUX` | `GRUB_CMDLINE_LINUX_DEFAULT` value (representative) | BLS |
|---|---|---|---|
| **Oracle Linux 7.9** | not present | `"crashkernel=auto console=tty0 console=ttyS0,115200n8"` | No |
| **Oracle Linux 8.2** | not present | `"crashkernel=auto console=tty0 console=ttyS0,115200n8 rd.lvm.vg=rootvg rd.lvm.lv=rootvg/rootlv"` | No |
| **Oracle Linux 8.10** | not present | `"crashkernel=auto console=tty0 console=ttyS0,115200n8 rd.lvm.vg=rootvg rd.lvm.lv=rootvg/rootlv"` | Yes |
| **Oracle Linux 9.5** | not present | `"crashkernel=auto console=tty0 console=ttyS0,115200n8 rd.lvm.vg=rootvg rd.lvm.lv=rootvg/rootlv"` | Yes |
| **Oracle Linux 10.0** | not present | `"crashkernel=1G-64G:448M,64G-:512M console=tty0 console=ttyS0,115200n8 rd.lvm.vg=rootvg rd.lvm.lv=rootvg/rootlv"` | Yes |
| **SLES 12 SP5** | `""` (empty) | `"USE_BY_UUID_DEVICE_NAMES=1 earlyprintk=ttyS0 console=ttyS0 rootdelay=300 multipath=off net.ifnames=0 dis_ucode_ldr scsi_mod.use_blk_mq=1"` | No |
| **SLES 15 SP6** | `""` (empty) | `"console=ttyS0 net.ifnames=0 iommu.passthrough=1 dis_ucode_ldr earlyprintk=ttyS0 multipath=off nvme_core.io_timeout=240 rootdelay=300 scsi_mod.use_blk_mq=1 USE_BY_UUID_DEVICE_NAMES=1 systemd.unified_cgroup_hierarchy=1"` | No |
| **Ubuntu 22.04** | `""` (empty) | `"quiet splash"` | No |

### 3.3 Distros that use BOTH variables (split usage)

| Distro | `GRUB_CMDLINE_LINUX` | `GRUB_CMDLINE_LINUX_DEFAULT` | Notes |
|---|---|---|---|
| **Azure Linux 3** | `"selinux=0 rd.auto=1 net.ifnames=0 lockdown=integrity"` | `"console=ttyS0 \$kernelopts"` | Also sources `/etc/default/grub.d/*.cfg` |

### 3.4 Summary: which variable to modify per distro

| Distro ID | Variable to modify | Rationale |
|---|---|---|
| `rhel` | `GRUB_CMDLINE_LINUX` | All RHEL images store boot params here |
| `almalinux` | `GRUB_CMDLINE_LINUX` | Same as RHEL |
| `centos` | `GRUB_CMDLINE_LINUX` | Same as RHEL |
| `rocky` | `GRUB_CMDLINE_LINUX` | Same as RHEL (no images in dataset, assumed) |
| `ol` | `GRUB_CMDLINE_LINUX_DEFAULT` | All OL images (7.9–10.0) store boot params here |
| `sles` | `GRUB_CMDLINE_LINUX_DEFAULT` | All SLES images; `GRUB_CMDLINE_LINUX` is empty |
| `ubuntu` | `GRUB_CMDLINE_LINUX_DEFAULT` | Ubuntu stores boot params here; also check `/etc/default/grub.d/` |
| `debian` | `GRUB_CMDLINE_LINUX` | Debian stores boot params here; `_DEFAULT` is empty |
| `azurelinux` | `GRUB_CMDLINE_LINUX` | Primary variable; `_DEFAULT` has console + `$kernelopts` |

---

## 4. Fix 1: CRITICAL — grub2-mkconfig output path missing .cfg

### Current code (3 occurrences)

```bash
# Occurrence 1: redhat|rhel|centos|rocky|suse|sles case, /etc/default/grub branch
grub2-mkconfig -o /boot/grub2/grub

# Occurrence 2: ol case, /etc/default/grub branch
grub2-mkconfig -o /boot/grub2/grub

# Occurrence 3 (dead code): ol case, /etc/default/grub.conf branch — correct but unreachable
grub2-mkconfig -o /boot/grub2/grub.cfg
```

### Problem

`/boot/grub2/grub.cfg` is the correct path on every RHEL, OL, AlmaLinux, SUSE, CentOS, and Azure Linux VM. Writing to `/boot/grub2/grub` (no `.cfg`) creates a stray file; GRUB continues booting from the old config. The fix silently never takes effect.

### Evidence from 148-VM data

Every VM using `grub2-*` commands has:
```
FOUND: /boot/grub2/grub.cfg (NNNN bytes, ...)
```
No VM has a file at `/boot/grub2/grub` (without extension).

### Fix

Replace all occurrences of:
```bash
grub2-mkconfig -o /boot/grub2/grub
```
with:
```bash
GRUB_DISABLE_OS_PROBER=true grub2-mkconfig -o /boot/grub2/grub.cfg
```
(This also addresses Fix 2.)

### Affected distros

All `grub2-*` distros: RHEL 7–10, OL 7.9–10.0, AlmaLinux 8–10, CentOS 7, SLES 12–16, Azure Linux 3 — **110 of 148 images**.

---

## 5. Fix 2: CRITICAL — Missing GRUB_DISABLE_OS_PROBER=true

### Current code

Every `grub2-mkconfig` and `update-grub` call lacks `GRUB_DISABLE_OS_PROBER=true`.

### Problem

When the NVMe conversion script runs on a VM attached to a rescue disk (which is an Ubuntu VM), `os-prober` discovers the rescue VM's Ubuntu root partition and adds it to the target VM's GRUB menu.

### Distros with os-prober installed (from 148-VM data)

| Distro | os-prober present | Impact |
|---|---|---|
| RHEL 7–10 | All images | Rescue VM Ubuntu added to menu |
| Oracle Linux 7.9–10.0 | All 16 images | Rescue VM Ubuntu added to menu |
| AlmaLinux 8–10 | All images | Rescue VM Ubuntu added to menu |
| CentOS 7 | All images | Rescue VM Ubuntu added to menu |
| Ubuntu x86 server/minimal/Pro | ~20 images | Rescue VM added to menu |

### Fix

Prefix **every** grub regeneration call:

```bash
# For grub2-mkconfig (RHEL, OL, AlmaLinux, CentOS, SUSE, Azure Linux):
GRUB_DISABLE_OS_PROBER=true grub2-mkconfig -o /boot/grub2/grub.cfg

# For update-grub (Ubuntu, Debian):
GRUB_DISABLE_OS_PROBER=true update-grub
```

The prefix sets an environment variable that `30_os-prober` respects — it skips probing if set.

---

## 6. Fix 3: CRITICAL — SUSE uses wrong GRUB variable

### Current code

SUSE (`sles`) is grouped in the `redhat|rhel|centos|rocky|suse|sles` case:
```bash
sed -i 's/GRUB_CMDLINE_LINUX="/GRUB_CMDLINE_LINUX="nvme_core.io_timeout=240 /g' /etc/default/grub
```

### Problem

All SLES images store boot parameters in `GRUB_CMDLINE_LINUX_DEFAULT`. The `GRUB_CMDLINE_LINUX` variable is present but **empty** (`""`). The `sed` pattern `GRUB_CMDLINE_LINUX="` can match either the empty `GRUB_CMDLINE_LINUX=""` or the `_DEFAULT` variant — but since `sed` with the `/g` flag replaces all matches on each line, and `GRUB_CMDLINE_LINUX=""` comes first, it appends to the empty variable instead of to `_DEFAULT`.

### Evidence (SLES 12 SP5)

```
GRUB_CMDLINE_LINUX_DEFAULT="USE_BY_UUID_DEVICE_NAMES=1 earlyprintk=ttyS0 console=ttyS0 rootdelay=300 ..."
GRUB_CMDLINE_LINUX=""
```

The `sed` pattern matches `GRUB_CMDLINE_LINUX=""` → becomes `GRUB_CMDLINE_LINUX="nvme_core.io_timeout=240 "` — wrong line. The actual boot params line (`_DEFAULT`) is untouched.

### Evidence (SLES 15 SP6)

SLES 15 SP6 already has `nvme_core.io_timeout=240` in `GRUB_CMDLINE_LINUX_DEFAULT`. The check would still fail because the verification (Fix 7) searches the wrong files. But the fix path would incorrectly modify `GRUB_CMDLINE_LINUX=""`.

### Fix

SUSE must have its own case branch:

```bash
suse|sles|opensuse*)
    if [ -f /etc/default/grub ]; then
        sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="/GRUB_CMDLINE_LINUX_DEFAULT="nvme_core.io_timeout=240 /g' /etc/default/grub
        GRUB_DISABLE_OS_PROBER=true grub2-mkconfig -o /boot/grub2/grub.cfg
    else
        echo "[ERROR] No grub config found."
        exit 1
    fi
    ;;
```

### Affected distros

SLES 12 SP5, SLES 15 SP4–SP7, SLES 16.0 — **14 images**.

---

## 7. Fix 4: HIGH — almalinux ID not in any case statement

### Current case statements

```bash
# check_nvme_driver():
redhat|rhel|centos|rocky|suse|sles|ol)

# check_nvme_timeout():
redhat|rhel|centos|rocky|suse|sles)   # also missing ol here before the separate ol case
```

### Problem

`almalinux` is not listed in any case. All three functions fall through to `*)` → `[ERROR]`.

### Evidence

AlmaLinux `ID="almalinux"` — 10 images in dataset:
- Uses `GRUB_CMDLINE_LINUX` (same as RHEL)
- Uses `grub2-mkconfig -o /boot/grub2/grub.cfg`
- Uses dracut with `azure.conf` containing `add_drivers+=" nvme pci-hyperv "`
- BLS enabled (`GRUB_ENABLE_BLSCFG=true`)
- Has `grubby` available

AlmaLinux is functionally identical to RHEL 8+ for all three check functions.

### Fix

Add `almalinux` to the RHEL cases:

```bash
# check_nvme_driver():
redhat|rhel|centos|rocky|almalinux|ol)

# check_nvme_timeout():
redhat|rhel|centos|rocky|almalinux)
```

---

## 8. Fix 5: HIGH — azurelinux ID not in any case statement

### Problem

`azurelinux` (`ID=azurelinux`) is not listed in any case. All functions fall through to `[ERROR]`.

### Evidence from 148-VM data

Azure Linux 3 — 8 images:
- Uses `grub2-mkconfig -o /boot/grub2/grub.cfg` (GRUB 2.06)
- Uses dracut (but `/etc/dracut.conf.d/00-hyperv.conf` **lacks** NVMe drivers)
- `GRUB_CMDLINE_LINUX` has primary boot params
- No BLS
- `ID=azurelinux` (no quotes)

### Dracut config on Azure Linux 3

```
/etc/dracut.conf.d/00-hyperv.conf:
  add_drivers+=" hv_utils hv_vmbus hv_storvsc hv_netvsc hv_sock hv_balloon "
```

No `nvme` or `pci-hyperv`. The fix path must add them.

### Fix

Add `azurelinux|mariner` to both `check_nvme_driver()` and `check_nvme_timeout()`:

```bash
# check_nvme_driver() — add to dracut-based case:
redhat|rhel|centos|rocky|almalinux|azurelinux|mariner|suse|sles|ol)

# check_nvme_timeout() — add to RHEL-like case (uses GRUB_CMDLINE_LINUX):
redhat|rhel|centos|rocky|almalinux|azurelinux|mariner)
```

---

## 9. Fix 6: MEDIUM — BLS systems need grubby for reliable param update

### Background

On BLS-enabled systems, kernel command-line parameters live in individual `.conf` files under `/boot/loader/entries/`. Running `grub2-mkconfig` updates the `kernelopts` variable in `/boot/grub2/grubenv` and regenerates `grub.cfg`, but BLS entry `options` lines may use their own values (snapshotted at install time). The reliable way to update **all** entries is `grubby --update-kernel=ALL --args=...`.

### BLS-enabled distros in dataset

| Distro | BLS | grubby available |
|---|---|---|
| RHEL 8+ (8.1–10.1) | Yes | Yes |
| Oracle Linux 8.10+ (8.10, 9.5, 9.6, 10.0) | Yes | Yes |
| AlmaLinux 8+ (8.10, 9.5, 9.7, 10.1) | Yes | Yes |
| Oracle Linux 7.9, 8.2 | **No** | Yes (but no BLS) |
| RHEL 7, CentOS 7 | No | Yes (but no BLS) |

Total: **~58 BLS images**.

### Fix

After modifying `/etc/default/grub` and running `grub2-mkconfig`, also run `grubby` on BLS systems:

```bash
# After grub2-mkconfig for RHEL/AlmaLinux/OL BLS systems:
if [ -f /etc/default/grub ] && grep -q "GRUB_ENABLE_BLSCFG=true" /etc/default/grub; then
    if command -v grubby &>/dev/null; then
        grubby --update-kernel=ALL --args="nvme_core.io_timeout=240"
        echo "[INFO] Updated BLS entries via grubby."
    fi
fi
```

### Non-BLS distros — no action needed

SLES, Ubuntu, Debian, CentOS 7, RHEL 7, OL 7.9, OL 8.2, Azure Linux 3 — `grub2-mkconfig` (or `update-grub`) is sufficient.

---

## 10. Fix 7: MEDIUM — Verification grep checks non-existent files

### Current code (2 occurrences)

```bash
# Pre-check:
if grep -q "nvme_core.io_timeout=240" /etc/default/grub /etc/grub.conf /boot/grub/grub.cfg; then

# Post-fix verification:
if grep -q "nvme_core.io_timeout=240" /etc/default/grub /etc/grub.conf /boot/grub/grub.cfg; then
```

### Problem

| File checked | Exists on | Missing on |
|---|---|---|
| `/etc/default/grub` | All 148 VMs | — |
| `/etc/grub.conf` | **None** of 148 VMs | All |
| `/boot/grub/grub.cfg` | Ubuntu, Debian only (38+14=52) | RHEL, OL, AlmaLinux, SUSE, AzureLinux (96) |

Missing file: `/boot/grub2/grub.cfg` — needed for RHEL/OL/SUSE/AlmaLinux/AzureLinux.

When grep receives a nonexistent file, it prints an error to stderr but still returns success if any other file matches. However, for RHEL/OL/SUSE/AzureLinux, `nvme_core.io_timeout=240` appears in `/etc/default/grub` (on RHEL 9+ and SLES 15+), so the check may pass on those — but the intent is unclear and the error messages are noisy.

### Fix

Build the file list dynamically:

```bash
_grub_files="/etc/default/grub"
if [ -f /boot/grub2/grub.cfg ]; then
    _grub_files="$_grub_files /boot/grub2/grub.cfg"
elif [ -f /boot/grub/grub.cfg ]; then
    _grub_files="$_grub_files /boot/grub/grub.cfg"
fi

if grep -q "nvme_core.io_timeout=240" $_grub_files 2>/dev/null; then
    echo "[INFO] nvme_core.io_timeout is set to 240."
fi
```

---

## 11. Fix 8: MEDIUM — OL 7.9 and 8.2 NVMe dracut gap + grub path bug

### Problem

Oracle Linux 7.9 and 8.2 do not have NVMe drivers in their dracut config:

| OL Version | Dracut config | NVMe present |
|---|---|---|
| OL 7.9 | `/etc/dracut.conf.d/99-azure.conf` — only `hostonly="no"` | **No** |
| OL 8.2 | `/etc/dracut.conf.d/01-dracut-vm.conf` — only Hyper-V + virtio drivers | **No** |
| OL 8.10+ | `/etc/dracut.conf.d/azure.conf` — `add_drivers+=" nvme pci-hyperv "` | **Yes** |

The script's `check_nvme_driver()` fix path correctly creates `/etc/dracut.conf.d/nvme.conf` and runs `dracut -f` — this works. But because of Fix 1 (wrong grub path), `nvme_core.io_timeout=240` is written to a stray file and never takes effect.

### Compound impact

OL 7.9/8.2 are the distros most likely to need both fixes (NVMe dracut + GRUB timeout), and both fixes are currently broken.

### Fix

Resolving Fix 1 (grub path) + Fix 3 (OL variable) resolves this automatically. The OL case correctly targets `GRUB_CMDLINE_LINUX_DEFAULT` which is confirmed on all OL versions.

Additionally, the dracut fix should include `pci-hyperv` alongside `nvme`:

```bash
echo 'add_drivers+=" nvme nvme-core pci-hyperv "' | tee /etc/dracut.conf.d/nvme.conf > /dev/null
```

This matches what OL 8.10+ images have in their `azure.conf`.

---

## 12. Fix 9: MEDIUM — /etc/default/grub.conf fallback is dead code

### Current code (in both RHEL and OL cases)

```bash
elif [ -f /etc/default/grub.conf ]; then
    sed -i 's/...' /etc/default/grub.conf
    grub2-mkconfig -o /boot/grub2/grub.cfg
```

### Evidence

`/etc/default/grub.conf` does not exist on any of the 148 VMs. Every distro uses `/etc/default/grub`.

### Fix

Remove the `elif` branch. Replace with a clear error:

```bash
if [ -f /etc/default/grub ]; then
    # ... modify /etc/default/grub ...
else
    echo "[ERROR] /etc/default/grub not found."
    return 1
fi
```

---

## 13. Fix 10: LOW — lsinitrd checks only the default kernel

### Current code

```bash
if lsinitrd | grep -q nvme; then
```

### Problem

`lsinitrd` without arguments inspects only the default kernel's initramfs. If the VM has multiple kernels (common on RHEL, OL with LVM), older kernels may lack NVMe.

### Fix (optional)

Check all installed initramfs images:

```bash
# dracut-based distros:
_nvme_ok=true
for img in /boot/initramfs-*.img; do
    [ -f "$img" ] || continue
    if ! lsinitrd "$img" 2>/dev/null | grep -q nvme; then
        echo "[WARNING] NVMe driver not found in $img"
        _nvme_ok=false
    fi
done
```

For `fix=true`, `dracut -f` also only rebuilds the current kernel. Consider `dracut -f --regenerate-all` or iterating over all kernel versions.

---

## 14. Fix 11: LOW — fstab check does not flag LVM device paths

### Current fstab regex

```bash
grep -Eq '/dev/sd[a-z][0-9]*|/dev/disk/azure/scsi[0-9]*/lun[0-9]*' /etc/fstab
```

### Gap

This does not match:
- `/dev/mapper/rootvg-rootlv` — used by all RHEL LVM and all OL LVM images
- `PARTUUID=...` — used by Azure Linux 3

LVM paths (`/dev/mapper/*`) survive NVMe conversion because LVM is UUID-based underneath. `PARTUUID` also survives. So these are safe — but the script should document why they're not flagged.

No code change needed, but add a comment:

```bash
# NOTE: /dev/mapper/* (LVM) and PARTUUID= paths survive NVMe conversion
# because they use UUID-based addressing underneath. Only /dev/sd* and
# /dev/disk/azure/scsi* paths break when disks move from SCSI to NVMe.
```

---

## 15. Fix 12: LOW — Inconsistent sudo usage

### Current code

```bash
echo '...' | sudo tee /etc/dracut.conf.d/nvme.conf > /dev/null
sudo dracut -f
# But no sudo on:
sed -i 's/...' /etc/default/grub
grub2-mkconfig -o /boot/grub2/grub.cfg
```

### Context

The script runs via `Invoke-AzVMRunCommand` which executes as root. `sudo` is unnecessary.

### Fix

Remove all `sudo` prefixes for consistency:

```bash
echo '...' | tee /etc/dracut.conf.d/nvme.conf > /dev/null
dracut -f
```

---

## 16. Full corrected script

Below is the complete corrected bash script with all fixes applied. Changes are marked with `# FIX N:` comments.

```bash
#!/bin/bash

# Set default values
fix=false
distro=""

# Function to display usage
usage() {
    echo "Usage: $0 [-fix]"
    exit 1
}

# Parse command line arguments
while [ $# -gt 0 ]; do
    case "$1" in
        -fix)
            fix=true
            ;;
        *)
            usage
            ;;
    esac
    shift
done

# Determine the Linux distribution
if [ -f /etc/os-release ]; then
    source /etc/os-release
    distro="$ID"
elif [ -f /etc/debian_version ]; then
    distro="debian"
elif [ -f /etc/SuSE-release ]; then
    distro="suse"
elif [ -f /etc/redhat-release ]; then
    distro="redhat"
elif [ -f /etc/centos-release ]; then
    distro="centos"
elif [ -f /etc/rocky-release ]; then
    distro="rocky"
else
    echo "[ERROR] Unsupported distribution."
    exit 1
fi
echo "[INFO] Operating system detected: $distro"

# FIX 7: Build grub file list dynamically for verification
_grub_check_files="/etc/default/grub"
if [ -f /boot/grub2/grub.cfg ]; then
    _grub_check_files="$_grub_check_files /boot/grub2/grub.cfg"
elif [ -f /boot/grub/grub.cfg ]; then
    _grub_check_files="$_grub_check_files /boot/grub/grub.cfg"
fi

# Function to check if NVMe driver is in initrd/initramfs
check_nvme_driver() {
    echo "[INFO] Checking if NVMe driver is included in initrd/initramfs..."
    case "$distro" in
        ubuntu|debian)
            if lsinitramfs /boot/initrd.img-* 2>/dev/null | grep -q nvme; then
                echo "[INFO] NVMe driver found in initrd/initramfs."
            else
                echo "[WARNING] NVMe driver not found in initrd/initramfs."
                if $fix; then
                    echo "[INFO] Adding NVMe driver to initrd/initramfs..."
                    update-initramfs -u -k all
                    if lsinitramfs /boot/initrd.img-* 2>/dev/null | grep -q nvme; then
                        echo "[INFO] NVMe driver added successfully."
                    else
                        echo "[ERROR] Failed to add NVMe driver to initrd/initramfs."
                    fi
                else
                    echo "[ERROR] NVMe driver not found in initrd/initramfs."
                fi
            fi
            ;;
        # FIX 4, FIX 5: Added almalinux, azurelinux, mariner
        redhat|rhel|centos|rocky|almalinux|azurelinux|mariner|suse|sles|ol)
            if lsinitrd 2>/dev/null | grep -q nvme; then
                echo "[INFO] NVMe driver found in initrd/initramfs."
            else
                echo "[WARNING] NVMe driver not found in initrd/initramfs."
                if $fix; then
                    echo "[INFO] Adding NVMe driver to initrd/initramfs..."
                    mkdir -p /etc/dracut.conf.d
                    # FIX 8, FIX 12: Added pci-hyperv, removed sudo
                    echo 'add_drivers+=" nvme nvme-core pci-hyperv "' | tee /etc/dracut.conf.d/nvme.conf > /dev/null
                    dracut -f
                    if lsinitrd 2>/dev/null | grep -q nvme; then
                        echo "[INFO] NVMe driver added successfully."
                    else
                        echo "[ERROR] Failed to add NVMe driver to initrd/initramfs."
                    fi
                else
                    echo "[ERROR] NVMe driver not found in initrd/initramfs."
                fi
            fi
            ;;
        *)
            echo "[ERROR] Unsupported distribution for NVMe driver check."
            return 1
            ;;
    esac
}

# Function to check nvme_core.io_timeout parameter
check_nvme_timeout() {
    echo "[INFO] Checking nvme_core.io_timeout parameter..."
    # FIX 7: Use dynamically built file list
    if grep -q "nvme_core.io_timeout=240" $_grub_check_files 2>/dev/null; then
        echo "[INFO] nvme_core.io_timeout is set to 240."
    else
        echo "[WARNING] nvme_core.io_timeout is not set to 240."
        if $fix; then
            echo "[INFO] Setting nvme_core.io_timeout to 240..."
            case "$distro" in
                ubuntu)
                    # Ubuntu: modify GRUB_CMDLINE_LINUX_DEFAULT
                    sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="/GRUB_CMDLINE_LINUX_DEFAULT="nvme_core.io_timeout=240 /g' /etc/default/grub
                    # FIX 2: Added GRUB_DISABLE_OS_PROBER=true
                    GRUB_DISABLE_OS_PROBER=true update-grub
                    ;;
                debian)
                    # Debian: modify GRUB_CMDLINE_LINUX (boot params are here)
                    sed -i 's/GRUB_CMDLINE_LINUX="/GRUB_CMDLINE_LINUX="nvme_core.io_timeout=240 /g' /etc/default/grub
                    # FIX 2: Added GRUB_DISABLE_OS_PROBER=true
                    GRUB_DISABLE_OS_PROBER=true update-grub
                    ;;
                # FIX 4, FIX 5: Added almalinux, azurelinux, mariner
                # FIX 3: Removed suse|sles from this case
                redhat|rhel|centos|rocky|almalinux|azurelinux|mariner)
                    if [ -f /etc/default/grub ]; then
                        sed -i 's/GRUB_CMDLINE_LINUX="/GRUB_CMDLINE_LINUX="nvme_core.io_timeout=240 /g' /etc/default/grub
                        # FIX 1: Added .cfg extension
                        # FIX 2: Added GRUB_DISABLE_OS_PROBER=true
                        GRUB_DISABLE_OS_PROBER=true grub2-mkconfig -o /boot/grub2/grub.cfg
                        # FIX 6: Update BLS entries if applicable
                        if grep -q "GRUB_ENABLE_BLSCFG=true" /etc/default/grub 2>/dev/null; then
                            if command -v grubby &>/dev/null; then
                                grubby --update-kernel=ALL --args="nvme_core.io_timeout=240"
                                echo "[INFO] Updated BLS entries via grubby."
                            fi
                        fi
                    else
                        # FIX 9: Removed dead /etc/default/grub.conf fallback
                        echo "[ERROR] /etc/default/grub not found."
                        return 1
                    fi
                    ;;
                # FIX 3: SUSE gets its own case — uses GRUB_CMDLINE_LINUX_DEFAULT
                suse|sles|opensuse*)
                    if [ -f /etc/default/grub ]; then
                        sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="/GRUB_CMDLINE_LINUX_DEFAULT="nvme_core.io_timeout=240 /g' /etc/default/grub
                        # FIX 1: Added .cfg extension
                        # FIX 2: Added GRUB_DISABLE_OS_PROBER=true
                        GRUB_DISABLE_OS_PROBER=true grub2-mkconfig -o /boot/grub2/grub.cfg
                    else
                        echo "[ERROR] /etc/default/grub not found."
                        return 1
                    fi
                    ;;
                ol)
                    # OL: All versions (7.9–10.0) use GRUB_CMDLINE_LINUX_DEFAULT
                    if [ -f /etc/default/grub ]; then
                        sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="/GRUB_CMDLINE_LINUX_DEFAULT="nvme_core.io_timeout=240 /g' /etc/default/grub
                        # FIX 1: Added .cfg extension
                        # FIX 2: Added GRUB_DISABLE_OS_PROBER=true
                        GRUB_DISABLE_OS_PROBER=true grub2-mkconfig -o /boot/grub2/grub.cfg
                        # FIX 6: Update BLS entries if applicable (OL 8.10+)
                        if grep -q "GRUB_ENABLE_BLSCFG=true" /etc/default/grub 2>/dev/null; then
                            if command -v grubby &>/dev/null; then
                                grubby --update-kernel=ALL --args="nvme_core.io_timeout=240"
                                echo "[INFO] Updated BLS entries via grubby."
                            fi
                        fi
                    else
                        # FIX 9: Removed dead /etc/default/grub.conf fallback
                        echo "[ERROR] /etc/default/grub not found."
                        return 1
                    fi
                    ;;
                *)
                    echo "[ERROR] Unsupported distribution for nvme_core.io_timeout fix."
                    return 1
                    ;;
            esac

            # FIX 7: Use dynamically built file list for verification
            if grep -q "nvme_core.io_timeout=240" $_grub_check_files 2>/dev/null; then
                echo "[INFO] nvme_core.io_timeout set successfully."
            else
                echo "[ERROR] Failed to set nvme_core.io_timeout."
            fi
        else
            echo "[ERROR] nvme_core.io_timeout is not set to 240."
        fi
    fi
}

# Function to check /etc/fstab for deprecated device names
check_fstab() {
    echo "[INFO] Checking /etc/fstab for deprecated device names..."
    # FIX 11: NOTE — /dev/mapper/* (LVM) and PARTUUID= paths survive NVMe
    # conversion because they use UUID-based addressing underneath. Only
    # /dev/sd* and /dev/disk/azure/scsi* paths break on SCSI-to-NVMe.
    if grep -Eq '/dev/sd[a-z][0-9]*|/dev/disk/azure/scsi[0-9]*/lun[0-9]*' /etc/fstab; then
        if $fix; then
            echo "[WARNING] /etc/fstab contains deprecated device names."
            echo "[INFO] Replacing deprecated device names in /etc/fstab with UUIDs..."
            
            # Create a backup of the fstab file
            cp /etc/fstab /etc/fstab.bak
            
            # Use sed to replace device names with UUIDs
            while read -r line; do
                if [[ "$line" =~ ^[^#] ]]; then
                    device=$(echo "$line" | awk '{print $1}')
                    if [[ "$device" =~ ^/dev/sd[a-z][0-9]*$ ]]; then
                        uuid=$(blkid "$device" | awk -F\" '/UUID=/ {print $2}')
                        if [ -n "$uuid" ]; then
                            newline=$(echo "$line" | sed "s|$device|UUID=$uuid|g")
                            echo "[INFO] Replaced $device with UUID=$uuid"
                            echo "$newline" >> /etc/fstab.new
                        else
                            echo "[WARNING] Could not find UUID for $device. Skipping."
                            echo "$line" >> /etc/fstab.new
                        fi
                    elif [[ "$device" =~ ^/dev/disk/azure/scsi[0-9]*/lun[0-9]* ]]; then
                        uuid=$(blkid "$device" | awk -F\" '/UUID=/ {print $2}')
                        if [ -n "$uuid" ]; then
                            newline=$(echo "$line" | sed "s|$device|UUID=$uuid|g")
                            echo "[INFO] Replaced $device with UUID=$uuid"
                            echo "$newline" >> /etc/fstab.new
                        else
                            echo "[WARNING] Could not find UUID for $device. Skipping."
                            echo "$line" >> /etc/fstab.new
                        fi
                    else
                        echo "$line" >> /etc/fstab.new
                    fi
                else
                    echo "$line" >> /etc/fstab.new
                fi
            done < /etc/fstab

            # Replace the old fstab with the new fstab
            mv /etc/fstab.new /etc/fstab
            
            echo "[INFO] /etc/fstab updated with UUIDs. Original backed up to /etc/fstab.bak"
        else
            echo "[ERROR] /etc/fstab contains device names causing issues switching to NVMe"
        fi
    else
        echo "[INFO] /etc/fstab does not contain deprecated device names."
    fi
}

# Run the checks
check_nvme_driver
check_nvme_timeout
check_fstab

exit 0
```

---

## 17. Test matrix

Every fix must be validated against representative VMs from each distro family.

### Minimum test set (one per unique code path)

| # | Distro | ID | Gen | GRUB var | BLS | NVMe in dracut | Validates |
|---|---|---|---|---|---|---|---|
| 1 | RHEL 7.9 | `rhel` | Gen1 | `CMDLINE_LINUX` | No | No (empty dracut.conf.d) | Fix 1,2,7,9 |
| 2 | RHEL 8.10 | `rhel` | Gen2 | `CMDLINE_LINUX` | Yes | Yes (nvme.conf) | Fix 1,2,6,7 |
| 3 | RHEL 9.7 | `rhel` | Gen2 | `CMDLINE_LINUX` | Yes | No (empty dracut.conf.d) | Fix 1,2,6,7 |
| 4 | RHEL 10.1 | `rhel` | Gen2 | `CMDLINE_LINUX` | Yes | No (empty dracut.conf.d) | Fix 1,2,6,7 |
| 5 | OL 7.9 | `ol` | Gen2 | `CMDLINE_LINUX_DEFAULT` | No | **No** | Fix 1,2,8,9 |
| 6 | OL 8.2 | `ol` | Gen2 | `CMDLINE_LINUX_DEFAULT` | No | **No** | Fix 1,2,8,9 |
| 7 | OL 8.10 | `ol` | Gen2 | `CMDLINE_LINUX_DEFAULT` | Yes | Yes (azure.conf) | Fix 1,2,6 |
| 8 | OL 10.0 | `ol` | Gen2 | `CMDLINE_LINUX_DEFAULT` | Yes | Yes (azure.conf) | Fix 1,2,6 |
| 9 | AlmaLinux 9.7 | `almalinux` | Gen2 | `CMDLINE_LINUX` | Yes | Yes (azure.conf) | Fix 4,6 |
| 10 | AlmaLinux 10.1 | `almalinux` | Gen2 | `CMDLINE_LINUX` | Yes | Yes (azure.conf) | Fix 4,6 |
| 11 | SLES 12 SP5 | `sles` | Gen2 | `CMDLINE_LINUX_DEFAULT` | No | No | Fix 3 |
| 12 | SLES 15 SP6 | `sles` | Gen2 | `CMDLINE_LINUX_DEFAULT` | No | No | Fix 3 (already has io_timeout) |
| 13 | Ubuntu 22.04 | `ubuntu` | Gen2 | `CMDLINE_LINUX_DEFAULT` | No | N/A (initramfs-tools) | Fix 2 |
| 14 | Debian 12 | `debian` | Gen2 | `CMDLINE_LINUX` | No | N/A (initramfs-tools) | Fix 2 |
| 15 | Azure Linux 3 | `azurelinux` | Gen2 | `CMDLINE_LINUX` | No | No (00-hyperv.conf) | Fix 5 |
| 16 | CentOS 7.9 | `centos` | Gen1 | `CMDLINE_LINUX` | No | No | Fix 1,2 |

### Verification steps per test

For each test VM, after running the fix script:

1. **GRUB variable:** `grep -E "GRUB_CMDLINE_LINUX|GRUB_CMDLINE_LINUX_DEFAULT" /etc/default/grub`
   - Confirm `nvme_core.io_timeout=240` appears in the correct variable
   - Confirm it does NOT appear in the wrong variable
2. **GRUB config regenerated:** `stat /boot/grub2/grub.cfg` or `stat /boot/grub/grub.cfg`
   - Confirm timestamp is recent (after script ran)
   - Confirm NO file at `/boot/grub2/grub` (without .cfg)
3. **BLS entries (if applicable):** `grubby --info=ALL | grep nvme_core`
   - Confirm `nvme_core.io_timeout=240` in all kernel entries
4. **NVMe in initramfs:** `lsinitrd | grep nvme` (dracut) or `lsinitramfs /boot/initrd.img-* | grep nvme` (Ubuntu/Debian)
5. **os-prober not triggered:** `grep -c "menuentry" /boot/grub2/grub.cfg` or `/boot/grub/grub.cfg`
   - Confirm no unexpected Ubuntu/rescue entries
6. **No stray /etc/default/grub.conf:** `ls -la /etc/default/grub*`
   - Should only see `/etc/default/grub`

### NVMe-specific dracut state reference

| Distro | Dracut config file | NVMe drivers present before fix |
|---|---|---|
| RHEL 7 | (empty dracut.conf.d) | No |
| RHEL 8 | `/etc/dracut.conf.d/nvme.conf` | Yes: `nvme pci-hyperv` |
| RHEL 9 | (empty dracut.conf.d) | No |
| RHEL 10 | (empty dracut.conf.d) | No |
| OL 7.9 | `/etc/dracut.conf.d/99-azure.conf` — `hostonly=no` only | **No** |
| OL 8.2 | `/etc/dracut.conf.d/01-dracut-vm.conf` — Hyper-V only | **No** |
| OL 8.10+ | `/etc/dracut.conf.d/azure.conf` — `nvme pci-hyperv` | Yes |
| AlmaLinux 8+ | `/etc/dracut.conf.d/azure.conf` — `nvme pci-hyperv` | Yes |
| SLES 12–16 | (no NVMe config) | No |
| Azure Linux 3 | `/etc/dracut.conf.d/00-hyperv.conf` — Hyper-V only | **No** |
| CentOS 7 | (empty or minimal dracut.conf.d) | No |

---

## Appendix: Raw GRUB defaults from 148-VM dataset

### RHEL 7.6

```
GRUB_TIMEOUT=10
GRUB_DISTRIBUTOR="$(sed 's, release .*$,,g' /etc/system-release)"
GRUB_DEFAULT=saved
GRUB_DISABLE_SUBMENU=true
GRUB_TERMINAL_OUTPUT="console"
GRUB_CMDLINE_LINUX="crashkernel=auto console=tty1 console=ttyS0 earlyprintk=ttyS0 rootdelay=300 scsi_mod.use_blk_mq=y"
GRUB_DISABLE_RECOVERY="true"
GRUB_TIMEOUT_STYLE=countdown
GRUB_TERMINAL="serial console"
GRUB_SERIAL_COMMAND="serial --speed=115200 --unit=0 --word=8 --parity=no --stop=1"
```

### RHEL 9.7

```
GRUB_CMDLINE_LINUX="ro console=tty1 console=ttyS0 earlyprintk=ttyS0 rootdelay=300 nvme_core.io_timeout=240 net.ifnames=0"
GRUB_TIMEOUT=10
GRUB_ENABLE_BLSCFG=true
GRUB_DISABLE_RECOVERY=true
GRUB_DISABLE_SUBMENU=true
GRUB_DISTRIBUTOR="$(sed 's, release .*$,,g' /etc/system-release)"
GRUB_SERIAL_COMMAND="serial --speed=115200 --unit=0 --word=8 --parity=no --stop=1"
GRUB_TERMINAL="serial"
GRUB_TERMINAL_INPUT="serial"
GRUB_TERMINAL_OUTPUT="serial"
GRUB_TIMEOUT_STYLE=countdown
GRUB_DEFAULT=saved
```

### RHEL 10.1

```
GRUB_CMDLINE_LINUX="ro nvme_core.io_timeout=240 console=tty1 console=ttyS0 earlyprintk=ttyS0 rootdelay=300"
GRUB_TIMEOUT=10
GRUB_ENABLE_BLSCFG=true
GRUB_DISABLE_RECOVERY=true
GRUB_DISABLE_SUBMENU=true
GRUB_DISTRIBUTOR="$(sed 's, release .*$,,g' /etc/system-release)"
GRUB_SERIAL_COMMAND="serial --speed=115200 --unit=0 --word=8 --parity=no --stop=1"
GRUB_TERMINAL="serial"
GRUB_TERMINAL_INPUT="serial"
GRUB_TERMINAL_OUTPUT="serial"
GRUB_TIMEOUT_STYLE=countdown
GRUB_DEFAULT=saved
```

### Oracle Linux 7.9

```
GRUB_TIMEOUT=1
GRUB_TIMEOUT_STYLE=countdown
GRUB_DISTRIBUTOR="Oracle Linux Server"
GRUB_DEFAULT=saved
GRUB_DISABLE_SUBMENU=true
GRUB_CMDLINE_LINUX_DEFAULT="crashkernel=auto console=tty0 console=ttyS0,115200n8"
GRUB_TERMINAL="console serial"
GRUB_SERIAL_COMMAND="serial --speed=115200 --unit=0 --word=8 --parity=no --stop=1"
GRUB_DISABLE_RECOVERY=true
```

### Oracle Linux 8.10

```
GRUB_TIMEOUT=1
GRUB_TIMEOUT_STYLE=countdown
GRUB_DISTRIBUTOR="Oracle Linux Server"
GRUB_DEFAULT=saved
GRUB_DISABLE_SUBMENU=true
GRUB_CMDLINE_LINUX_DEFAULT="crashkernel=auto console=tty0 console=ttyS0,115200n8 rd.lvm.vg=rootvg rd.lvm.lv=rootvg/rootlv"
GRUB_TERMINAL="console serial"
GRUB_SERIAL_COMMAND="serial --speed=115200 --unit=0 --word=8 --parity=no --stop=1"
GRUB_DISABLE_RECOVERY=true
GRUB_ENABLE_BLSCFG=true
```

### Oracle Linux 10.0

```
GRUB_TIMEOUT=1
GRUB_TIMEOUT_STYLE=countdown
GRUB_DISTRIBUTOR="Oracle Linux Server"
GRUB_DEFAULT=saved
GRUB_DISABLE_SUBMENU=true
GRUB_CMDLINE_LINUX_DEFAULT="crashkernel=1G-64G:448M,64G-:512M console=tty0 console=ttyS0,115200n8 rd.lvm.vg=rootvg rd.lvm.lv=rootvg/rootlv"
GRUB_TERMINAL="console serial"
GRUB_SERIAL_COMMAND="serial --speed=115200 --unit=0 --word=8 --parity=no --stop=1"
GRUB_DISABLE_RECOVERY=true
GRUB_ENABLE_BLSCFG=true
```

### AlmaLinux 9.7

```
GRUB_TIMEOUT=0
GRUB_DISTRIBUTOR="$(sed 's, release .*$,,g' /etc/system-release)"
GRUB_DEFAULT=saved
GRUB_DISABLE_SUBMENU=true
GRUB_TERMINAL_OUTPUT="console"
GRUB_CMDLINE_LINUX="loglevel=3 console=tty1 console=ttyS0 earlyprintk=ttyS0 rootdelay=300 no_timer_check nvme_core.io_timeout=240 biosdevname=0 net.ifnames=0"
GRUB_DISABLE_RECOVERY="true"
GRUB_ENABLE_BLSCFG=true
```

### SLES 12 SP5

```
GRUB_DEFAULT=0
GRUB_HIDDEN_TIMEOUT=0
GRUB_HIDDEN_TIMEOUT_QUIET=true
GRUB_TIMEOUT=1
GRUB_CMDLINE_LINUX_DEFAULT="USE_BY_UUID_DEVICE_NAMES=1 earlyprintk=ttyS0 console=ttyS0 rootdelay=300 multipath=off net.ifnames=0 dis_ucode_ldr scsi_mod.use_blk_mq=1"
GRUB_CMDLINE_LINUX=""
GRUB_DISTRIBUTOR="SLES 12 SP5 Azure"
GRUB_GFXMODE=800x600
GRUB_SERIAL_COMMAND="serial --speed=38400 --unit=0 --word=8 --parity=no --stop=1"
GRUB_TERMINAL="serial"
```

### SLES 15 SP6

```
GRUB_DEFAULT=0
GRUB_HIDDEN_TIMEOUT=0
GRUB_HIDDEN_TIMEOUT_QUIET=true
GRUB_TIMEOUT=1
GRUB_CMDLINE_LINUX_DEFAULT="console=ttyS0 net.ifnames=0 iommu.passthrough=1 dis_ucode_ldr earlyprintk=ttyS0 multipath=off nvme_core.io_timeout=240 rootdelay=300 scsi_mod.use_blk_mq=1 USE_BY_UUID_DEVICE_NAMES=1 systemd.unified_cgroup_hierarchy=1"
GRUB_CMDLINE_LINUX=""
GRUB_DISTRIBUTOR="SLES15-SP6"
GRUB_GFXMODE=auto
GRUB_TERMINAL_INPUT="serial"
GRUB_TERMINAL_OUTPUT="serial"
GRUB_TIMEOUT_STYLE=countdown
```

### Ubuntu 22.04

```
GRUB_DEFAULT=0
GRUB_TIMEOUT_STYLE=hidden
GRUB_TIMEOUT=0
GRUB_DISTRIBUTOR=`lsb_release -i -s 2> /dev/null || echo Debian`
GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"
GRUB_CMDLINE_LINUX=""
```

### Debian 12

```
GRUB_DEFAULT=0
GRUB_TIMEOUT=5
GRUB_DISTRIBUTOR=`lsb_release -i -s 2> /dev/null || echo Debian`
GRUB_CMDLINE_LINUX_DEFAULT=""
GRUB_CMDLINE_LINUX="console=tty0 console=ttyS0,115200 earlyprintk=ttyS0,115200 consoleblank=0"
GRUB_TERMINAL="console serial"
GRUB_SERIAL_COMMAND="serial --speed=115200"
```

### Azure Linux 3

```
GRUB_TIMEOUT=0
GRUB_DISTRIBUTOR="AzureLinux"
GRUB_DISABLE_SUBMENU=y
GRUB_TERMINAL_OUTPUT="console"
GRUB_CMDLINE_LINUX="   selinux=0  rd.auto=1 net.ifnames=0 lockdown=integrity "
GRUB_CMDLINE_LINUX_DEFAULT="console=ttyS0 \$kernelopts"
# Also sources /etc/default/grub.d/*.cfg
```
