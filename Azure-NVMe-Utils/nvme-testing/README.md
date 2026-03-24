# NVMe Conversion Testing Toolkit

End-to-end testing workflow for Azure SCSI-to-NVMe conversion — from fleet-wide dry-run validation through actual conversion execution.

## Testing Flow Overview

The conversion process follows three phases. Each phase must pass before proceeding to the next.

```
Phase 1: Dry-Run Assessment        Phase 2: Apply OS Fixes        Phase 3: VM Conversion
+-------------------------+    +---------------------------+    +------------------------------+
| Ansible playbook or     |    | Re-run playbook with      |    | Azure-NVMe-Conversion.ps1    |
| standalone script runs  |    | fix mode (or manual)      |    | per-VM: resize + controller  |
| checks on all hosts     |--->| to rebuild initramfs,     |--->| type change, with OS checks  |
|                         |    | update grub, fix fstab    |    | and optional -DryRun         |
| Output: JSON report     |    |                           |    |                              |
| + HTML report           |    | Re-validate until clean   |    | Loop over all VMs in RG      |
+-------------------------+    +---------------------------+    +------------------------------+
```

---

## Phase 1 — Dry-Run Assessment

Validates that every Linux host has the NVMe driver in initramfs, `nvme_core.io_timeout=240` in grub, and no deprecated `/dev/sd*` entries in fstab — **without modifying anything**.

### Option A: Ansible Playbook (recommended for fleets)

The playbook is **self-contained** — the full dry-run script is embedded inline.

```bash
# 1. Create an inventory file with your servers
cat > inventory.ini <<'EOF'
[sap_servers]
sapvm01 ansible_host=10.0.1.10
sapvm02 ansible_host=10.0.1.11
# ...add your servers
EOF

# 2. Run the playbook
ansible-playbook -i inventory.ini nvme-dryrun-playbook.yml

# 3. Review the JSON report
cat nvme-dryrun-report.json | python3 -m json.tool

# 4. Open the HTML dashboard (served at http://<control-vm>/index.html if httpd is running)
```

The playbook writes:
- `nvme-dryrun-report.json` — local JSON report in the playbook directory
- `/var/www/html/index.html` — interactive HTML dashboard with per-host detail panels

### Option B: ARM Template Lab Builder

Open `scsi2nvme-tester.html` in a browser to generate an ARM template that deploys a full test lab (control VM + image VMs) with automated playbook execution.

### Interpreting Results

```bash
# Summary counts
jq '.summary' nvme-dryrun-report.json

# Hosts that need changes (grub, initramfs, fstab)
jq '[.results[] | select(.needs_changes==true) | {hostname, warnings}]' nvme-dryrun-report.json

# Hosts with errors
jq '[.results[] | select(.error_count != "0") | {hostname, errors}]' nvme-dryrun-report.json

# Group by distro
jq '[.results | group_by(.distro)[] | {distro: .[0].distro, count: length}]' nvme-dryrun-report.json
```

**Phase 1 is complete when**: `summary.errors == 0` and you have reviewed all `needs_changes` hosts. Proceed to Phase 2 if any hosts report `needs_changes == true`.

---

## Phase 2 — Apply OS Fixes

For hosts that reported `needs_changes`, apply the actual fixes (rebuild initramfs, update grub with `nvme_core.io_timeout=240`).

Use the PowerShell script with `-FixOperatingSystemSettings`:

```powershell
.\Azure-NVMe-Conversion.ps1 -ResourceGroupName "myRG" -VMName "sapvm01" `
    -NewControllerType NVMe -VMSize "Standard_E2bds_v5" `
    -FixOperatingSystemSettings -DryRun
```

After fixing, **re-run Phase 1** to confirm all hosts now report `ready == true` and `needs_changes == false`.

---

## Phase 3 — VM Conversion with Azure-NVMe-Conversion.ps1

Once all hosts pass dry-run validation (Phase 1 clean), execute the actual SCSI-to-NVMe conversion using the PowerShell script.

### Prerequisites

- PowerShell 7+ with Az module installed (`Install-Module Az`)
- Connected to Azure: `Connect-AzAccount`
- Correct subscription selected: `Select-AzSubscription -Subscription <id>`
- All target VMs in the resource group are **stopped/deallocated** or will be stopped by the script
- Dry-run assessment (Phase 1) is clean for all target hosts

### Convert a Single VM

```powershell
.\Azure-NVMe-Conversion.ps1 `
    -ResourceGroupName "myRG" `
    -VMName "sapvm01" `
    -NewControllerType NVMe `
    -VMSize "Standard_E2bds_v5" `
    -StartVM -WriteLogfile
```

### Convert All VMs in a Resource Group

Run conversions in parallel using background jobs (works on PowerShell 5.1+):

```powershell
# Define parameters
$ResourceGroup = "myRG"
$NewVMSize     = "Standard_E2bds_v5"   # Target NVMe-capable size
$Controller    = "NVMe"
$ThrottleLimit = 10                     # Max concurrent jobs

# Get all VMs in the resource group
$vms = Get-AzVM -ResourceGroupName $ResourceGroup

Write-Host "Found $($vms.Count) VMs in resource group '$ResourceGroup'" -ForegroundColor Cyan

# Dry-run first (recommended) — validates without converting, runs in parallel
$jobs = @()
foreach ($vm in $vms) {
    # Throttle: wait if we already have $ThrottleLimit running jobs
    while (($jobs | Where-Object { $_.State -eq 'Running' }).Count -ge $ThrottleLimit) {
        Start-Sleep -Seconds 2
    }
    $jobs += Start-Job -ScriptBlock {
        param($RG, $Name, $Ctrl, $Size)
        Set-Location $using:PWD
        .\Azure-NVMe-Conversion.ps1 `
            -ResourceGroupName $RG `
            -VMName $Name `
            -NewControllerType $Ctrl `
            -VMSize $Size `
            -DryRun -WriteLogfile
    } -ArgumentList $ResourceGroup, $vm.Name, $Controller, $NewVMSize
    Write-Host "=== DRY-RUN started: $($vm.Name) ===" -ForegroundColor Yellow
}
# Wait for all jobs and collect output
$jobs | Wait-Job | Receive-Job
$jobs | Remove-Job

# When dry-run is clean, execute the actual conversion in parallel
$jobs = @()
foreach ($vm in $vms) {
    while (($jobs | Where-Object { $_.State -eq 'Running' }).Count -ge $ThrottleLimit) {
        Start-Sleep -Seconds 2
    }
    $jobs += Start-Job -ScriptBlock {
        param($RG, $Name, $Ctrl, $Size)
        Set-Location $using:PWD
        .\Azure-NVMe-Conversion.ps1 `
            -ResourceGroupName $RG `
            -VMName $Name `
            -NewControllerType $Ctrl `
            -VMSize $Size `
            -FixOperatingSystemSettings `
            -StartVM -WriteLogfile
    } -ArgumentList $ResourceGroup, $vm.Name, $Controller, $NewVMSize
    Write-Host "=== CONVERTING started: $($vm.Name) ===" -ForegroundColor Green
}
$jobs | Wait-Job | Receive-Job
$jobs | Remove-Job
```

> **Note:** Each background job inherits the current Azure context. Ensure `Connect-AzAccount` has been run before starting. Adjust `$ThrottleLimit` based on Azure API rate limits and subscription quotas (10 is a safe default). Log files are written per-VM via `-WriteLogfile`.

### Key Parameters

| Parameter | Description |
|---|---|
| `-ResourceGroupName` | Azure resource group containing the VM |
| `-VMName` | Name of the VM to convert |
| `-NewControllerType` | `NVMe` or `SCSI` |
| `-VMSize` | Target NVMe-capable VM SKU |
| `-DryRun` | Stage OS changes without modifying system files or converting |
| `-FixOperatingSystemSettings` | Auto-fix initramfs, grub, and fstab via Azure RunCommand |
| `-StartVM` | Start the VM after conversion |
| `-WriteLogfile` | Create a log file for the conversion |
| `-IgnoreOSCheck` | Skip OS readiness check (use when Phase 1 already validated) |

---

## Files

| File | Purpose |
|---|---|
| `nvme-dryrun-playbook.yml` | Self-contained Ansible playbook — runs dry-run assessment and produces JSON + HTML reports |
| `nvme-postconversion-check.yml` | Ansible playbook — post-conversion verification (IMDS + lsblk) |
| `scsi2nvme-tester.html` | Browser-based ARM template builder for deploying a test lab in Azure |

## Tested VM Images

The following 44 Azure Marketplace images (x64, Gen2 only) were validated in the dry-run assessment and post-conversion verification. All 44 VMs converted successfully to NVMe and boot on `nvme0n1`.

### AlmaLinux (3 images)

| URN | Kernel | Needs Changes |
|---|---|---|
| almalinux:almalinux-x86_64:8-gen2:latest | 4.18.0-553.72.1.el8_10.x86_64 | No |
| almalinux:almalinux-x86_64:9-gen2:latest | 5.14.0-611.13.1.el9_7.x86_64 | No |
| almalinux:almalinux-x86_64:10-gen2:latest | 6.12.0-124.20.1.el10_1.x86_64 | No |

### Azure Linux (2 images)

| URN | Kernel | Needs Changes |
|---|---|---|
| MicrosoftCBLMariner:azure-linux-3:azure-linux-3-gen2:latest | 6.6.126.1-1.azl3 | Yes — grub |
| MicrosoftCBLMariner:azure-linux-3:azure-linux-3-gen2-fips:latest | 6.6.126.1-1.azl3 | Yes — grub |

### Debian (3 images)

| URN | Kernel | Needs Changes |
|---|---|---|
| Debian:debian-11:11-gen2:latest | 5.10.0-39-cloud-amd64 | Yes — grub |
| Debian:debian-12:12-gen2:latest | 6.1.0-44-cloud-amd64 | No |
| Debian:debian-13:13-gen2:latest | 6.12.74+deb13+1-cloud-amd64 | No |

### Oracle Linux (4 images)

| URN | Kernel | Needs Changes |
|---|---|---|
| Oracle:Oracle-Linux:ol79-gen2:latest | 5.4.17-2036.101.2.el7uek.x86_64 | Yes — initramfs (pci-hyperv), grub |
| Oracle:Oracle-Linux:ol810-lvm-gen2:latest | 5.15.0-317.197.5.1.el8uek.x86_64 | Yes — grub, grubby (BLS) |
| Oracle:Oracle-Linux:ol95-lvm-gen2:latest | 5.15.0-307.178.5.el9uek.x86_64 | Yes — grub, grubby (BLS) |
| Oracle:Oracle-Linux:ol10-lvm-gen2:latest | 6.12.0-104.43.4.3.el10uek.x86_64 | Yes — grub, grubby (BLS) |

### RHEL (12 images)

| URN | Kernel | Needs Changes |
|---|---|---|
| RedHat:RHEL:8-lvm-gen2:latest | 4.18.0-553.el8_10.x86_64 | Yes — grub, grubby (BLS) |
| RedHat:rhel-raw:8-raw-gen2:latest | 4.18.0-553.56.1.el8_10.x86_64 | No |
| RedHat:rhel-raw:89-gen2:latest | 4.18.0-513.11.1.el8_9.x86_64 | Yes — grub, grubby (BLS) |
| RedHat:RHEL-HA:8_8-gen2:latest | 4.18.0-477.36.1.el8_8.x86_64 | Yes — grub, grubby (BLS) |
| RedHat:RHEL-SAP-HA:84sapha-gen2:latest | 4.18.0-305.150.1.el8_4.x86_64 | Yes — grub, grubby (BLS) |
| RedHat:RHEL:96-gen2:latest | 5.14.0-570.94.1.el9_6.x86_64 | No |
| RedHat:RHEL:9-lvm-gen2:latest | 5.14.0-611.36.1.el9_7.x86_64 | No |
| RedHat:rhel-raw:9-raw-gen2:latest | 5.14.0-611.36.1.el9_7.x86_64 | No |
| RedHat:RHEL-SAP-APPS:96sapapps-gen2:latest | 5.14.0-570.94.1.el9_6.x86_64 | No |
| RedHat:RHEL-SAP-HA:96sapha-gen2:latest | 5.14.0-570.94.1.el9_6.x86_64 | No |
| RedHat:RHEL:10-lvm-gen2:latest | 6.12.0-124.38.1.el10_1.x86_64 | No |
| RedHat:rhel-raw:10-raw-gen2:latest | 6.12.0-124.38.1.el10_1.x86_64 | No |

### SLES (4 images)

| URN | Kernel | Needs Changes |
|---|---|---|
| SUSE:sles-12-sp5:gen2:latest | 4.12.14-16.200-azure | Yes — grub |
| SUSE:sles-15-sp6:gen2:latest | 6.4.0-150600.8.58-azure | No |
| SUSE:sles-15-sp7-basic:gen2:latest | 6.4.0-150700.20.24-azure | No |
| SUSE:sles-16-0-x86-64:gen2:latest | 6.12.0-160000.9-default | No |

> **Known issue — SLES 12 SP5 incompatible with v6/v7 hardware:** Kernel 4.12.14-16.200-azure cannot run on v6/v7 VM families at all. Two separate failures: **(1)** On v6/v7 sizes with a temp disk (e.g. `Standard_D2ds_v6`, `Standard_D2ads_v7`), the temp disk NVMe controller triggers `can't allocate MSI-X affinity masks for 1 vectors` → NULL pointer dereference in `suse_msi_set_irq_unmanaged` → kernel panic. **(2)** On v6/v7 sizes without a temp disk (e.g. `Standard_D2s_v6`), NVMe boots successfully but the MANA network driver logs `TX: unknown CQE type 42` and has no network connectivity — the driver in kernel 4.12.14 is too old for v6/v7 NIC firmware. No kernel update is available (SLES 12 SP5 EOL Oct 2024). SLES 12 SP5 works on dual-controller sizes like `Standard_E2bds_v5` (v5 family) where the temp disk uses SCSI and the NIC uses an older firmware revision.

### SLES SAP (1 image)

| URN | Kernel | Needs Changes |
|---|---|---|
| SUSE:sles-sap-15-sp7:gen2:latest | 6.4.0-150700.53.28-default | No |

### Ubuntu (15 images)

| URN | Kernel | Needs Changes |
|---|---|---|
| Canonical:0001-com-ubuntu-minimal-focal:minimal-20_04-lts-gen2:latest | 5.15.0-1089-azure | No |
| Canonical:0001-com-ubuntu-server-focal:20_04-lts-gen2:latest | 5.15.0-1089-azure | No |
| Canonical:0001-com-ubuntu-minimal-jammy:minimal-22_04-lts-gen2:latest | 6.8.0-1044-azure | No |
| Canonical:0001-com-ubuntu-server-jammy:22_04-lts-gen2:latest | 6.8.0-1044-azure | No |
| Canonical:ubuntu-22_04-lts:server:latest | 6.8.0-1044-azure | No |
| Canonical:ubuntu-22_04-lts:ubuntu-minimal:latest | 6.8.0-1044-azure | No |
| Canonical:ubuntu-22_04-lts:ubuntu-pro:latest | 6.8.0-1044-azure | No |
| Canonical:ubuntu-22_04-lts:ubuntu-pro-fips:latest | 6.8.0-1044-azure | No |
| Canonical:ubuntu-22_04-lts:ubuntu-pro-minimal:latest | 6.8.0-1044-azure | No |
| Canonical:ubuntu-24_04-lts:server:latest | 6.17.0-1008-azure | No |
| Canonical:ubuntu-24_04-lts:minimal:latest | 6.14.0-1017-azure | No |
| Canonical:ubuntu-24_04-lts:ubuntu-pro:latest | 6.14.0-1017-azure | No |
| Canonical:ubuntu-24_04-lts:ubuntu-pro-minimal:latest | 6.17.0-1008-azure | No |
| Canonical:ubuntu-25_10:server:latest | 6.17.0-1006-azure | No |
| Canonical:ubuntu-25_10:minimal:latest | 6.17.0-1006-azure | No |

### Summary

| Distro | Images | Ready | Needs Changes | BLS (grubby) |
|---|---|---|---|---|
| AlmaLinux | 3 | 3 | 0 | 0 |
| Azure Linux | 2 | 2 | 2 | 0 |
| Debian | 3 | 3 | 1 | 0 |
| Oracle Linux | 4 | 4 | 4 | 3 |
| RHEL | 12 | 12 | 4 | 4 |
| SLES | 4 | 4 | 1 | 0 |
| SLES SAP | 1 | 1 | 0 | 0 |
| Ubuntu | 15 | 15 | 0 | 0 |
| **Total** | **44** | **44** | **12** | **7** |

> **44 of 44 VMs converted successfully to NVMe** with zero boot failures on `Standard_E2bds_v5` (dual-controller). The 12 that needed changes had `nvme_core.io_timeout=240` added to grub (and/or initramfs rebuilt with `pci-hyperv`) automatically via `-FixOperatingSystemSettings`. Of those, 7 also had BLS enabled and used `grubby --update-kernel=ALL`. **OL 7.9 (UEK 5.4.17)** required both `pci-hyperv` addition to initramfs and `nvme_core.io_timeout=240` in grub — the script now detects and fixes this automatically. Post-conversion verification confirmed all 44 hosts boot on `nvme0n1` with OS disk mounted correctly.
>
> **On NVMe-only sizes** (Intel Ddsv6 `Standard_D2ds_v6`, AMD Dadsv7 `Standard_D2ads_v7`): 44 of 45 VMs converted successfully. **1 failure: SLES 12 SP5** — incompatible with v6/v7 hardware entirely (NVMe kernel panic with temp disk, MANA networking failure without). See known issue note under SLES section above. SLES 12 SP5 only works on v5 and older VM families.

---

## JSON Report Structure

```json
{
    "_meta": {
        "description": "SCSI-to-NVMe Conversion Dry-Run Assessment - 44 hosts",
        "generated_at": "2026-03-20T17:02:00Z",
        "total_hosts": "44"
    },
    "hosts": {
        "rhel-10-lvm-gen2-x64-gen2": {
            "distro": "redhat",
            "distro_version": "10.1",
            "kernel": "6.12.0-124.38.1.el10_1.x86_64",
            "exit_code": "0",
            "ready": true,
            "needs_changes": false,
            "error_count": "0",
            "errors": [],
            "dryrun": ["[DRYRUN] NVMe driver already in initramfs...", "..."],
            "staged_files": { "distro": "rhel\n", "kernel": "6.12...\n" },
            "raw_stdout": "...",
            "raw_stderr": ""
        }
    }
}
```

### Key Fields per Host

| Field | Description |
|---|---|
| `ready` | `true` if no errors — server is ready for NVMe conversion |
| `needs_changes` | `true` if warnings were found (grub, initramfs, or fstab changes needed) |
| `error_count` | Number of `[ERROR]` lines |
| `staged_files` | Contents of proposed changes (grub diffs, fstab diffs, driver status) |
| `dryrun` | All `[DRYRUN]` output lines describing what would change |

```bash
# Show grub diffs for servers that need timeout changes
jq '[.hosts | to_entries[] | select(.value.staged_files["diffs/grub.diff"] != null) | {hostname: .key, diff: .value.staged_files["diffs/grub.diff"]}]' nvme-dryrun-report.json
```
