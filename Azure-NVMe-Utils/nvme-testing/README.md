# NVMe Conversion Testing Toolkit

End-to-end testing workflow for Azure SCSI-to-NVMe conversion — from fleet-wide dry-run validation through actual conversion execution.

## Testing Flow Overview

The conversion process follows three phases. Each phase must pass before proceeding to the next.

```
Phase 1: Dry-Run Assessment          Phase 2: Apply OS Fixes          Phase 3: VM Conversion
┌─────────────────────────┐    ┌──────────────────────────┐    ┌─────────────────────────────┐
│ Ansible playbook or     │    │ Re-run playbook with     │    │ Azure-NVMe-Conversion.ps1   │
│ standalone script runs  │    │ fix mode (or manual)     │    │ per-VM: resize + controller │
│ checks on all hosts     │──▷ │ to rebuild initramfs,    │──▷ │ type change, with OS checks │
│                         │    │ update grub, fix fstab   │    │ and optional -DryRun         │
│ Output: results.json    │    │                          │    │                              │
│ + HTML report           │    │ Re-validate until clean  │    │ Loop over all VMs in RG     │
└─────────────────────────┘    └──────────────────────────┘    └─────────────────────────────┘
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
- `/var/www/html/results.json` — same JSON, downloadable via httpd
- `/var/www/html/index.html` — interactive HTML dashboard with per-host detail panels

### Option B: Standalone Script (single host)

```bash
# Check only — reports NVMe readiness, no changes
./nvme-check-dryrun.sh

# Dry-run — stages all proposed changes in /tmp/nvme-conversion-dryrun
sudo ./nvme-check-dryrun.sh -fix -dry
```

### Option C: ARM Template Lab Builder

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

```bash
# Fix mode — applies changes on a single host
sudo ./nvme-check-dryrun.sh -fix
```

Or use the PowerShell script with `-FixOperatingSystemSettings`:

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

Use a PowerShell loop to iterate over every VM in the resource group:

```powershell
# Define parameters
$ResourceGroup = "myRG"
$NewVMSize     = "Standard_E2bds_v5"   # Target NVMe-capable size
$Controller    = "NVMe"

# Get all VMs in the resource group
$vms = Get-AzVM -ResourceGroupName $ResourceGroup

Write-Host "Found $($vms.Count) VMs in resource group '$ResourceGroup'" -ForegroundColor Cyan

# Dry-run first (recommended) — validates without converting
foreach ($vm in $vms) {
    Write-Host "=== DRY-RUN: $($vm.Name) ===" -ForegroundColor Yellow
    .\Azure-NVMe-Conversion.ps1 `
        -ResourceGroupName $ResourceGroup `
        -VMName $vm.Name `
        -NewControllerType $Controller `
        -VMSize $NewVMSize `
        -DryRun -WriteLogfile
}

# When dry-run is clean, execute the actual conversion
foreach ($vm in $vms) {
    Write-Host "=== CONVERTING: $($vm.Name) ===" -ForegroundColor Green
    .\Azure-NVMe-Conversion.ps1 `
        -ResourceGroupName $ResourceGroup `
        -VMName $vm.Name `
        -NewControllerType $Controller `
        -VMSize $NewVMSize `
        -FixOperatingSystemSettings `
        -StartVM -WriteLogfile
}
```

### Convert VMs with Per-VM Size Mapping

If different VMs need different target sizes:

```powershell
$ResourceGroup = "myRG"

# Define size mapping per VM (or use a CSV)
$vmSizeMap = @{
    "sapvm01" = "Standard_E2bds_v5"
    "sapvm02" = "Standard_E2bds_v5"
    "sapvm03" = "Standard_E2bds_v5"
}

foreach ($vmName in $vmSizeMap.Keys) {
    $targetSize = $vmSizeMap[$vmName]
    Write-Host "=== CONVERTING: $vmName -> $targetSize ===" -ForegroundColor Green
    .\Azure-NVMe-Conversion.ps1 `
        -ResourceGroupName $ResourceGroup `
        -VMName $vmName `
        -NewControllerType NVMe `
        -VMSize $targetSize `
        -FixOperatingSystemSettings `
        -StartVM -WriteLogfile
}
```

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
| `nvme-check-dryrun.sh` | Standalone bash script — supports check, fix, and dry-run modes via `-fix` and `-dry` flags |
| `scsi2nvme-tester.html` | Browser-based ARM template builder for deploying a test lab in Azure |
| `results.json` | Sample output from an 81-host dry-run assessment |

## Tested VM Images

The following 81 Azure Marketplace images (x64 only, Gen1 + Gen2) were validated in the dry-run assessment. All returned `ready=true` with zero errors.

### AlmaLinux (6 images)

| Hostname | Version | Kernel | Needs Changes |
|---|---|---|---|
| almalinux-x86-64-8-gen1-x64-gen1 | 8.10 | 4.18.0-553.72.1.el8_10.x86_64 | No |
| almalinux-x86-64-8-gen2-x64-gen2 | 8.10 | 4.18.0-553.72.1.el8_10.x86_64 | No |
| almalinux-x86-64-9-gen1-x64-gen1 | 9.7 | 5.14.0-611.13.1.el9_7.x86_64 | No |
| almalinux-x86-64-9-gen2-x64-gen2 | 9.7 | 5.14.0-611.13.1.el9_7.x86_64 | No |
| almalinux-x86-64-10-gen1-x64-gen1 | 10.1 | 6.12.0-124.20.1.el10_1.x86_64 | No |
| almalinux-x86-64-10-gen2-x64-gen2 | 10.1 | 6.12.0-124.20.1.el10_1.x86_64 | No |

### Azure Linux / Mariner (4 images)

| Hostname | Version | Kernel | Needs Changes |
|---|---|---|---|
| azure-linux-3-azure-linux-3-x64-gen1 | 3.0 | 6.6.126.1-1.azl3 | Yes — initramfs |
| azure-linux-3-azure-linux-3-gen2-x64-gen2 | 3.0 | 6.6.126.1-1.azl3 | Yes — initramfs |
| azure-linux-3-azure-linux-3-fips-x64-gen1 | 3.0 | 6.6.126.1-1.azl3 | Yes — initramfs |
| azure-linux-3-azure-linux-3-gen2-fips-x64-gen2 | 3.0 | 6.6.126.1-1.azl3 | Yes — initramfs |

### Debian (6 images)

| Hostname | Version | Kernel | Needs Changes |
|---|---|---|---|
| debian-11-11-x64-gen1 | 11 | 5.10.0-38-cloud-amd64 | Yes — initramfs |
| debian-11-11-gen2-x64-gen2 | 11 | 5.10.0-38-cloud-amd64 | Yes — initramfs |
| debian-12-12-x64-gen1 | 12.13 | 6.1.0-44-cloud-amd64 | No |
| debian-12-12-gen2-x64-gen2 | 12.13 | 6.1.0-44-cloud-amd64 | No |
| debian-13-13-x64-gen1 | 13.3 | 6.12.74+deb13+1-cloud-amd64 | No |
| debian-13-13-gen2-x64-gen2 | 13.3 | 6.12.74+deb13+1-cloud-amd64 | No |

### Oracle Linux (9 images)

| Hostname | Version | Kernel | Needs Changes |
|---|---|---|---|
| oracle-linux-ol79-gen2-x64-gen2 | 7.9 | 5.4.17-2036.101.2.el7uek.x86_64 | Yes — initramfs, grub |
| oracle-linux-ol82-gen2-x64-gen2 | 8.2 | 5.4.17-2011.4.6.el8uek.x86_64 | Yes — initramfs, grub |
| oracle-linux-ol810-lvm-x64-gen1 | 8.10 | 5.15.0-317.197.5.1.el8uek.x86_64 | Yes — grub |
| oracle-linux-ol810-lvm-gen2-x64-gen2 | 8.10 | 5.15.0-317.197.5.1.el8uek.x86_64 | Yes — grub |
| oracle-linux-ol95-lvm-x64-gen1 | 9.5 | 5.15.0-307.178.5.el9uek.x86_64 | Yes — grub |
| oracle-linux-ol95-lvm-gen2-x64-gen2 | 9.5 | 5.15.0-307.178.5.el9uek.x86_64 | Yes — grub |
| oracle-linux-ol96-lvm-x64-gen1 | 9.6 | 6.12.0-104.43.4.2.el9uek.x86_64 | Yes — grub |
| oracle-linux-ol10-lvm-x64-gen1 | 10.0 | 6.12.0-104.43.4.3.el10uek.x86_64 | Yes — grub |
| oracle-linux-ol10-lvm-gen2-x64-gen2 | 10.0 | 6.12.0-104.43.4.3.el10uek.x86_64 | Yes — grub |

### RHEL (21 images)

| Hostname | Version | Kernel | Needs Changes |
|---|---|---|---|
| rhel-7-6-x64-gen1 | 7.6 | 3.10.0-957.72.1.el7.x86_64 | Yes — initramfs, grub |
| rhel-7-8-x64-gen1 | 7.8 | 3.10.0-1127.el7.x86_64 | Yes — initramfs, grub |
| rhel-8-9-x64-gen1 | 8.9 | 4.18.0-513.18.1.el8_9.x86_64 | Yes — grub |
| rhel-raw-8-4-x64-gen1 | 8.4 | 4.18.0-305.40.1.el8_4.x86_64 | Yes — initramfs, grub |
| rhel-raw-8-9-x64-gen1 | 8.9 | 4.18.0-513.11.1.el8_9.x86_64 | Yes — grub |
| rhel-raw-89-gen2-x64-gen2 | 8.9 | 4.18.0-513.11.1.el8_9.x86_64 | Yes — grub |
| rhel-ha-8-8-x64-gen1 | 8.8 | 4.18.0-477.36.1.el8_8.x86_64 | Yes — grub |
| rhel-8-lvm-gen2-x64-gen2 | 8.10 | 4.18.0-553.el8_10.x86_64 | Yes — grub |
| rhel-raw-8-raw-gen2-x64-gen2 | 8.10 | 4.18.0-553.56.1.el8_10.x86_64 | No |
| rhel-raw-8-raw-x64-gen1 | 8.10 | 4.18.0-553.56.1.el8_10.x86_64 | No |
| rhel-raw-9-5-x64-gen1 | 9.5 | 5.14.0-503.15.1.el9_5.x86_64 | Yes — grub |
| rhel-sap-ha-84sapha-gen2-x64-gen2 | 8.4 | 4.18.0-305.150.1.el8_4.x86_64 | Yes — grub |
| rhel-sap-ha-96sapha-gen2-x64-gen2 | 9.6 | 5.14.0-570.94.1.el9_6.x86_64 | No |
| rhel-9-7-x64-gen1 | 9.7 | 5.14.0-611.36.1.el9_7.x86_64 | No |
| rhel-9-lvm-gen2-x64-gen2 | 9.7 | 5.14.0-611.36.1.el9_7.x86_64 | No |
| rhel-raw-9-raw-gen2-x64-gen2 | 9.7 | 5.14.0-611.36.1.el9_7.x86_64 | No |
| rhel-raw-9-raw-x64-gen1 | 9.7 | 5.14.0-611.36.1.el9_7.x86_64 | No |
| rhel-10-1-x64-gen1 | 10.1 | 6.12.0-124.38.1.el10_1.x86_64 | No |
| rhel-10-lvm-gen2-x64-gen2 | 10.1 | 6.12.0-124.38.1.el10_1.x86_64 | No |
| rhel-raw-10-1-x64-gen1 | 10.1 | 6.12.0-124.38.1.el10_1.x86_64 | No |
| rhel-raw-10-raw-gen2-x64-gen2 | 10.1 | 6.12.0-124.38.1.el10_1.x86_64 | No |

### SLES (7 images)

| Hostname | Version | Kernel | Needs Changes |
|---|---|---|---|
| sles-12-sp5-gen2-x64-gen2 | 12.5 | 4.12.14-16.200-azure | Yes — initramfs, grub |
| sles-15-sp6-gen2-x64-gen2 | 15.6 | 6.4.0-150600.8.58-azure | No |
| sles-15-sp7-gen1-x64-gen1 | 15.7 | 6.4.0-150700.20.24-azure | No |
| sles-15-sp7-basic-gen2-x64-gen2 | 15.7 | 6.4.0-150700.20.24-azure | No |
| sles-16-0-x86-64-gen1-x64-gen1 | 16.0 | 6.12.0-160000.9-default | No |
| sles-16-0-x86-64-gen2-x64-gen2 | 16.0 | 6.12.0-160000.9-default | No |
| sles-sap-15-sp7-gen1-x64-gen1 | 15.7 | 6.4.0-150700.53.28-default | No |

### SLES SAP (2 images)

| Hostname | Version | Kernel | Needs Changes |
|---|---|---|---|
| sles-sap-15-sp7-gen1-x64-gen1 | 15.7 | 6.4.0-150700.53.28-default | No |
| sles-sap-15-sp7-gen2-x64-gen2 | 15.7 | 6.4.0-150700.53.28-default | No |

### Ubuntu (28 images)

| Hostname | Version | Kernel | Needs Changes |
|---|---|---|---|
| 0001-com-ubuntu-server-focal-20-04-lts-x64-gen1 | 20.04 | 5.15.0-1089-azure | No |
| 0001-com-ubuntu-server-focal-20-04-lts-gen2-x64-gen2 | 20.04 | 5.15.0-1089-azure | No |
| 0001-com-ubuntu-minimal-focal-minimal-20-04-lts-x64-gen1 | 20.04 | 5.15.0-1089-azure | No |
| ubuntu-22-04-lts-server-gen1-x64-gen1 | 22.04 | 6.8.0-1044-azure | No |
| ubuntu-22-04-lts-server-x64-gen2 | 22.04 | 6.8.0-1044-azure | No |
| ubuntu-22-04-lts-ubuntu-minimal-gen1-x64-gen1 | 22.04 | 6.8.0-1044-azure | No |
| ubuntu-22-04-lts-ubuntu-minimal-x64-gen2 | 22.04 | 6.8.0-1044-azure | No |
| ubuntu-22-04-lts-ubuntu-pro-gen1-x64-gen1 | 22.04 | 6.8.0-1044-azure | No |
| ubuntu-22-04-lts-ubuntu-pro-x64-gen2 | 22.04 | 6.8.0-1044-azure | No |
| ubuntu-22-04-lts-ubuntu-pro-minimal-gen1-x64-gen1 | 22.04 | 6.8.0-1044-azure | No |
| ubuntu-22-04-lts-ubuntu-pro-minimal-x64-gen2 | 22.04 | 6.8.0-1044-azure | No |
| ubuntu-22-04-lts-ubuntu-pro-fips-x64-gen2 | 22.04 | 5.15.0-1102-azure-fips | No |
| 0001-com-ubuntu-server-jammy-22-04-lts-x64-gen1 | 22.04 | 6.8.0-1044-azure | No |
| 0001-com-ubuntu-server-jammy-22-04-lts-gen2-x64-gen2 | 22.04 | 6.8.0-1044-azure | No |
| 0001-com-ubuntu-minimal-jammy-minimal-22-04-lts-x64-gen1 | 22.04 | 6.8.0-1044-azure | No |
| ubuntu-24-04-lts-server-gen1-x64-gen1 | 24.04 | 6.17.0-1008-azure | No |
| ubuntu-24-04-lts-server-x64-gen2 | 24.04 | 6.17.0-1008-azure | No |
| ubuntu-24-04-lts-minimal-gen1-x64-gen1 | 24.04 | 6.14.0-1017-azure | No |
| ubuntu-24-04-lts-minimal-x64-gen2 | 24.04 | 6.14.0-1017-azure | No |
| ubuntu-24-04-lts-ubuntu-pro-gen1-x64-gen1 | 24.04 | 6.14.0-1017-azure | No |
| ubuntu-24-04-lts-ubuntu-pro-x64-gen2 | 24.04 | 6.14.0-1017-azure | No |
| ubuntu-24-04-lts-ubuntu-pro-minimal-x64-gen2 | 24.04 | 6.17.0-1008-azure | No |
| ubuntu-25-10-server-gen1-x64-gen1 | 25.10 | 6.17.0-1006-azure | No |
| ubuntu-25-10-server-x64-gen2 | 25.10 | 6.17.0-1006-azure | No |
| ubuntu-25-10-minimal-gen1-x64-gen1 | 25.10 | 6.17.0-1006-azure | No |
| ubuntu-25-10-minimal-x64-gen2 | 25.10 | 6.17.0-1006-azure | No |

### Summary

| Distro | Images | Ready | Needs Changes |
|---|---|---|---|
| AlmaLinux | 6 | 6 | 0 |
| Azure Linux | 4 | 4 | 4 |
| Debian | 6 | 6 | 2 |
| Oracle Linux | 9 | 9 | 9 |
| RHEL | 21 | 21 | 10 |
| SLES | 7 | 7 | 1 |
| SLES SAP | 2 | 2 | 0 |
| Ubuntu | 28 | 28 | 0 |
| **Total** | **81** | **81** | **26** |

> All 81 images returned `ready=true` (exit code 0). The 26 that need changes require only `nvme_core.io_timeout=240` in grub and/or initramfs rebuild — fixable via Phase 2.

---

## JSON Report Structure

```json
{
    "generated_at": "2026-03-16T23:41:16Z",
    "total_hosts": 83,
    "collected_hosts": "81",
    "unreachable_hosts": "2",
    "summary": {
        "ready": 81,
        "needs_changes": 26,
        "errors": 0,
        "total": 81,
        "unreachable": 2
    },
    "results": [
        {
            "hostname": "rhel-10-1-x64-gen1",
            "ip": "10.10.0.10",
            "distro": "redhat",
            "distro_version": "10.1",
            "kernel": "6.12.0-124.38.1.el10_1.x86_64",
            "exit_code": "0",
            "ready": true,
            "needs_changes": false,
            "error_count": "0",
            "warning_count": "0",
            "errors": [],
            "warnings": [],
            "info": ["[INFO] Operating system detected: rhel", "..."],
            "dryrun": ["[DRYRUN] NVMe driver already in initramfs...", "..."],
            "staged_files": { "distro": "rhel\n", "kernel": "6.12...\n" },
            "raw_stdout": "...",
            "raw_stderr": ""
        }
    ]
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
jq '[.results[] | select(.staged_files["diffs/grub.diff"] != null) | {hostname, diff: .staged_files["diffs/grub.diff"]}]' nvme-dryrun-report.json
```
