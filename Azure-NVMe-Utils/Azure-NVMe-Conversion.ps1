<#

    .SYNOPSIS
        Convert Virtual Machines from SCSI to NVMe controller

    .DESCRIPTION
        The script helps converting Azure Virtual Machines from SCSI to NVMe controller.
        This will change the way how disks are presented inside the operating systems.
        The script will check if the VM is running Windows or Linux and will run the necessary commands to prepare the operating system for the conversion when specifying the -FixOperatingSystemSettings switch.

    .PARAMETER ResourceGroupName:
        Name of the resource group where the VM is located
    .PARAMETER VMName:
        Name of the VM to be converted
    .PARAMETER NewControllerType:
        Type of controller to be used (NVMe or SCSI)
    .PARAMETER VMSize:
        Size of the VM to be used
    .PARAMETER StartVM:
        Start the VM after conversion
    .PARAMETER WriteLogfile:
        Write log file to disk
    .PARAMETER IgnoreSKUCheck:
        Ignore SKU check for availability in region/zone
    .PARAMETER IgnoreWindowsVersionCheck:
        Ignore Windows version check
    .PARAMETER FixOperatingSystemSettings:
        Fix operating system settings
    .PARAMETER IgnoreAzureModuleCheck:
        Do not check if the Azure module is installed and the version is correct
    .PARAMETER IgnoreOSCheck:
        Do not check if the operating system is supported for NVMe conversion
    .PARAMETER DryRun:
        Run Linux OS checks and stage all proposed changes in /tmp/nvme-conversion-dryrun/ without modifying system files or converting the VM. Useful for validating changes across multiple servers before applying.

    .INPUTS
        None.
    
    .OUTPUTS
        Log file with the results of the script execution
        The log file will be written to the current directory with the name Azure-NVMe-Conversion-<VMName>-<timestamp>.log when the -WriteLogfile switch is used

    .EXAMPLE
        PS> .\Azure-NVMe-Conversion.ps1 -ResourceGroupName "myResourceGroup" -VMName "myVM" -NewControllerType NVMe -VMSize "Standard_E4bds_v5" -StartVM -WriteLogfile

    .LINK
        https://github.com/Azure/SAP-on-Azure-Scripts-and-Utilities
 
#>

<#
    Copyright (c) Microsoft Corporation.
    Licensed under the MIT license.
#>


[CmdletBinding()]
param (
    # Resource Group
    [Parameter(Mandatory=$true)][string]$ResourceGroupName,
    # VM Name
    [Parameter(Mandatory=$true)][string]$VMName,
    # Disk Controller Type
    [ValidateSet("NVMe", "SCSI")][string]$NewControllerType="NVMe",
    # New VM Size
    [Parameter(Mandatory=$true)][string]$VMSize,
    # Start VM after update
    [switch]$StartVM,
    # Write Log File
    [switch]$WriteLogfile,
    # Ignore Check if SKU is available in the region/zone
    [switch]$IgnoreSKUCheck,
    # Ignore Windows Operating System Version Check
    [switch]$IgnoreWindowsVersionCheck,
    # Fix operating system settings
    [switch]$FixOperatingSystemSettings,
    # Ignore Azure Module Check
    [switch]$IgnoreAzureModuleCheck,
    # Ignore Operating System Check
    [switch]$IgnoreOSCheck,
    # Dry-run mode: stage changes without modifying the system (Linux only)
    [switch]$DryRun,
    # SleepSeconds after VM Update
    [int]$SleepSeconds=15
)

# function to write log messages
function WriteRunLog {
    [CmdletBinding()]
    param (
        # Message to write to log
        [string]$message,
        # Category of the message
        [string]$category="INFO"
    )

    # getting offset seconds to start time 
    $_offset = ((Get-Date) - $script:_starttime).ToString("mm\:ss")

    switch ($category) {
        "INFO"      {   $_prestring = "INFO      - "
                        $_color = "Green" }
        "WARNING"   {   $_prestring = "WARNING   - "
                        $_color = "Yellow" }
        "ERROR"     {   $_prestring = "ERROR     - "
                        $_color = "Red" }
        "IMPORTANT" {   $_prestring = "IMPORTANT - "
                        $_color = "Blue" }

                    }
    $_runlog_row = "" | Select-Object "Log"
    $_runlog_row.Log = [string]$_offset + " - " + [string]$_prestring + [string]$message
    $script:_runlog += $_runlog_row
    Write-Host $_runlog_row.Log -ForegroundColor $_color

    if ($WriteLogfile -and $script:_logfile) {
        $_runlog_row.Log | Out-File -FilePath $script:_logfile -Append
    }
}

function CheckInstalledModules {
    [CmdletBinding()]
    param (
        # Module Name    
        [string]$ModuleName,
        # Minimum Module Version
        [version]$ModuleVersion
    )

    $_module = Get-Module -ListAvailable -Name $ModuleName
    if (-not ($_module)) {
        WriteRunLog -message "Module $ModuleName is not installed. Please install the module and run the script again." -category "ERROR"
        WriteRunLog -message "Usage this command to install the module:" -category "ERROR"
        WriteRunLog -message "   Install-Module -Name $ModuleName -Force" -category "ERROR"
        exit
    }

    if ($ModuleVersion -and ($_module | Where-Object {$_.Version -gt $ModuleVersion}).Count -eq 0) {
        WriteRunLog -message "Module $ModuleName is installed but the version is lower than required. Please update the module and run the script again." -category "ERROR"
        WriteRunLog -message "Usage this command to update the module:" -category "ERROR"
        WriteRunLog -message "   Update-Module -Name $ModuleName" -category "ERROR"
        exit
    }
    else {
        WriteRunLog -message "Module $ModuleName is installed and the version is correct."
    }
}

function AskToContinue {
    [CmdletBinding()]
    param (
        # Message to ask for confirmation
        [string]$message
    )

    WriteRunLog -message $message -category "IMPORTANT"
    $_answer = Read-Host "Do you want to continue? (Y/N)"
    if ($_answer -ne "Y" -and $_answer -ne "y") {
        WriteRunLog -message "Script execution aborted by user" -category "ERROR"
        exit
    }
}


function CheckForNewerVersion {

    # download online version
    # and compare it with version numbers in files to see if there is a newer version available on GitHub
    $ConfigFileUpdateURL = "https://raw.githubusercontent.com/Azure/SAP-on-Azure-Scripts-and-Utilities/main/Azure-NVMe-Utils/version.json"
    try {
        $OnlineFileVersion = (Invoke-WebRequest -Uri $ConfigFileUpdateURL -UseBasicParsing -ErrorAction SilentlyContinue).Content  | ConvertFrom-Json

        if ($OnlineFileVersion.Version -gt $script:_version) {
            WriteRunLog -category "WARNING" -message "There is a newer version of Azure-NVMe-Utils available on GitHub, please consider downloading it"
            WriteRunLog -category "WARNING" -message "You can download it on https://github.com/Azure/SAP-on-Azure-Scripts-and-Utilities/tree/main/Azure-NVMe-Utils"
            WriteRunLog -category "WARNING" -message "Script will continue"
            Start-Sleep -Seconds 3
        }

    }
    catch {
        WriteRunLog -category "WARNING" -message "Can't connect to GitHub to check version"
    }
    if (-not $RunLocally) {
        WriteRunLog -category "INFO" -message "Script Version $script:_version"
    }

}


##############################################################################################################
# Main Script
##############################################################################################################

$_version = "2025111001" # version of the script

# creating variable for log file
$script:_runlog = @()
$script:_starttime = Get-Date
WriteRunLog -message "Starting script Azure-NVMe-Conversion.ps1"
WriteRunLog -message "Script started at $script:_starttime"
WriteRunLog -message "Script version: $_version"
$script:_logfile = "Azure-NVMe-Conversion-$($VMName)-$((Get-Date).ToString('yyyyMMdd-HHmmss')).log"
if ($WriteLogfile) {
    WriteRunLog -message "Log file will be written to $script:_logfile"
}

# 
WriteRunLog -message "Script parameters:"
foreach ($key in $MyInvocation.BoundParameters.keys)
{
    $value = (get-variable $key).Value 
    WriteRunLog -message "  $key -> $value"
}

CheckForNewerVersion

# Check if breaking change warning is enabled
$_breakingchangewarning = Get-AzConfig -DisplayBreakingChangeWarning
if ($_breakingchangewarning.Value -eq $true) {
    Update-AzConfig -DisplayBreakingChangeWarning $false
}

# Check module versions
#CheckInstalledModules -ModuleName "Az" -ModuleVersion "11.0"
if (-not $IgnoreAzureModuleCheck) {
    CheckInstalledModules -ModuleName "Az.Compute" -ModuleVersion "9.0"
    CheckInstalledModules -ModuleName "Az.Accounts" -ModuleVersion "4.0"
    CheckInstalledModules -ModuleName "Az.Resources" -ModuleVersion "7.0"
}
else {
    WriteRunLog -message "Skipping Azure module check"
}

# Getting Azure Context
try {
    $_AzureContext = Get-AzContext
    if (!$_AzureContext) {
        WriteRunLog -message "Azure Context not found" -category "ERROR"
        WriteRunLog -message "Please login to Azure using Connect-AzAccount" -category "ERROR"
        exit
    }
    WriteRunLog -message "Connected to Azure subscription name: $($_AzureContext.Subscription.Name)"
    WriteRunLog -message "Connected to Azure subscription ID: $($_AzureContext.Subscription.Id)"

} catch {
    WriteRunLog -message "Error getting Azure Context" -category "ERROR"
    WriteRunLog $_.Exception.Message "ERROR"
    exit
}

# Get VM
try {
    $_VM = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName
    if (-not $_VM) {
        WriteRunLog -message "VM $VMName not found in Resource Group $ResourceGroupName" -category "ERROR"
        exit
    }
    WriteRunLog -message "VM $VMName found in Resource Group $ResourceGroupName"
} catch {
    WriteRunLog -message "Error getting VM $VMName" -category "ERROR"
    WriteRunLog $_.Exception.Message "ERROR"
    exit
}

# storing original VM Size
$script:_original_vm_size = $_VM.HardwareProfile.VmSize

# Check if the Azure Disk Encryption for Linux is present
if ($_VM.StorageProfile.OsDisk.OsType -eq "Linux") {
    try {
        $extension = Get-AzVMExtension -ResourceGroupName $ResourceGroupName -VMName $VMName -Name "AzureDiskEncryptionForLinux" -ErrorAction Stop

        if ($extension.ProvisioningState -eq "Succeeded") {
            WriteRunLog -message "ADE for Linux extension is installed and succeeded on VM: $($extension.VMName)" -category "ERROR"
                WriteRunLog -message "Azure Disk Encryption for Linux don't support NVMe disks" -category "ERROR"
                WriteRunLog $_.Exception.Message "ERROR"
                exit
            } else {
                WriteRunLog -message "ADE for Linux extension is installed but provisioning state is: $($extension.ProvisioningState)" -category "ERROR"
                WriteRunLog -message "If the VM has not been encrypted remove the extension and try again"  -category "ERROR"
                WriteRunLog $_.Exception.Message "ERROR"
                exit
            }
        }
        catch {
            WriteRunLog -message "ADE for Linux extension is NOT installed on this VM"
        }
}

# Get VM Power State
try {
    $_vminfo = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName -Status
    # Check if VM is running
    if (($_vminfo.Statuses | Where-Object { $_.Code -like 'PowerState*' }).Code -ne "PowerState/running") {
    #if (($_vminfo.PowerState -ne "VM running")) {
        if ($NewControllerType -eq "NVMe") {
            if ($IgnoreOSCheck) {
                WriteRunLog -message "Ignoring VM Power State check, proceeding with conversion" -category "WARNING"
                WriteRunLog -message "VM $VMName is not running, but OS check is ignored." -category "WARNING"
            }
            else {
                if ($FixOperatingSystemSettings) {
                    WriteRunLog -message "Fixing operating system settings is not supported with IgnoreOSCheck or when the VM is not running" -category "ERROR"
                    WriteRunLog -message "Please start the VM and run the script again when using FixOperatingSystemSettings" -category "ERROR"
                    exit
                }
            }
        }
    }
    else {
        WriteRunLog -message "VM $VMName is running"
    }
} catch {
    WriteRunLog -message "Error getting VM status" -category "ERROR"
    WriteRunLog $_.Exception.Message "ERROR"
    exit
}

# Check if VM is running Linux or Windows
if ($_VM.StorageProfile.OsDisk.OsType -eq "Windows") {
    $_os = "Windows"
    WriteRunLog -message "VM $VMName is running Windows"

    if ($_vm.StorageProfile.ImageReference.Publisher -eq "MicrosoftWindowsServer") {
        # Check Windows Version of OS
        $_osversion = $_VM.StorageProfile.ImageReference.Sku
        WriteRunLog -message "Windows Version: $_osversion"
        $_osversion_number = $_osversion -replace "[^0-9]", ""

        if (-not $IgnoreWindowsVersionCheck) {
            if ($_osversion_number -lt 2019) {
                WriteRunLog -message "Windows Version is lower than 2019. NVMe controller is only supported on Windows 2019 and higher" -category "ERROR"
                exit
            }
            else {
                WriteRunLog -message "Detected Windows Version: $($_osversion_number)"
            }
        }
        else {
            WriteRunLog -message "Ignoring Windows Version Check"
            WriteRunLog -message "Please make sure that the Windows Server 2019 or higher or Windows 10 1809 or higher is installed on the VM"
        }
    }
}
else {
    $_os = "Linux"
    WriteRunLog -message "VM $VMName is running Linux"
}

# Check if VM is running a Gen1 or Gen2 image (must be checked before controller type)
try {
    $_diskrg = $_vm.StorageProfile.OsDisk.ManagedDisk.Id.Split("/")[4]

    $_vm_osdisk = Get-AzDisk -Name $_vm.StorageProfile.OsDisk.Name -ResourceGroupName $_diskrg
    if ($_vm_osdisk.HyperVGeneration -eq 'V1') { 
        WriteRunLog -message "VM $VMName is running a Generation 1 image" -category "ERROR"
        WriteRunLog -message "NVMe controllers are only supported on Generation 2 images" -category "ERROR"
        exit
    }
    else {
        WriteRunLog -message "VM $VMName is running a Generation 2 image"
    }
}
catch {
    WriteRunLog -message "Error getting VM Generation" -category "ERROR"
    WriteRunLog $_.Exception.Message "ERROR"
    exit
}

# Check if VM is running SCSI or NVMe
# Note: DiskControllerType can be null for VMs that haven't been explicitly set — treat as SCSI
$_currentController = $_VM.StorageProfile.DiskControllerType
if ([string]::IsNullOrEmpty($_currentController) -or $_currentController -eq "SCSI") {
    WriteRunLog -message "VM $VMName is running SCSI"
    if ($NewControllerType -eq "SCSI") {
        WriteRunLog -message "VM $VMName is already running SCSI. No action required."
        WriteRunLog -message "If you want to convert to NVMe, please specify -NewControllerType NVMe"
        exit
    }
}
else {
    WriteRunLog -message "VM $VMName is running NVMe"
    if ($NewControllerType -eq "NVMe") {
        WriteRunLog -message "VM $VMName is already running NVMe. No action required."
        WriteRunLog -message "If you want to convert to SCSI, please specify -NewControllerType SCSI"
        exit
    }
}


### trusted launch is supported now
##if ($_VM.SecurityProfile.SecurityType -eq "TrustedLaunch" -and $VMSize.StartsWith("Standard_M")) {
##    WriteRunLog -message "VM $VMName is running with Trusted Launch enabled" -category "ERROR"
##    WriteRunLog -message "Trusted Launch is not supported with M-Series VMs" -category "ERROR"
##    exit
##}
##else {
##    if ($_VM.SecurityProfile.SecurityType -eq "TrustedLaunch") {
##        WriteRunLog -message "VM $VMName is running Trusted Launch"
##   }
##    else {
##        WriteRunLog -message "VM $VMName is not running Trusted Launch"
##    }
##}

# getting authentication token for REST API calls
try {
    $access_token = (Get-AzAccessToken).Token

    # Check if running in Azure Cloud Shell
    if ($env:ACC_TERM_ID) {
        WriteRunLog -message "Running in Azure Cloud Shell"
    } else {
        WriteRunLog -message "Not running in Azure Cloud Shell"
    }

    # Check if the access token is a SecureString
    # might be needed for Azure Cloud Shell
    if ($access_token.GetType().Name -eq "SecureString") {
        WriteRunLog -message "Authentication token is a SecureString"
        $_Ptr = [System.Runtime.InteropServices.Marshal]::SecureStringToCoTaskMemUnicode($access_token)
        $_result = [System.Runtime.InteropServices.Marshal]::PtrToStringUni($_Ptr)
        [System.Runtime.InteropServices.Marshal]::ZeroFreeCoTaskMemUnicode($_Ptr)
        $access_token = $_result
    } else {
        WriteRunLog -message "Authentication token is not a SecureString, no conversion needed"
    }

    WriteRunLog -message "Authentication token received"
} catch {
    WriteRunLog -message "Error getting authentication token" -category "ERROR"
    WriteRunLog $_.Exception.Message "ERROR"
    exit
}

if (-not $IgnoreSKUCheck) {
    WriteRunLog -message "Getting available SKU resources"
    WriteRunLog -message "This might take a while ..."
    $_VMSKUs = Get-AzComputeResourceSku -Location $_vm.Location | Where-Object { $_.ResourceType.Contains("virtualMachines") }
    $_VMSKU = $_VMSKUs | Where-Object { $_.Name -eq $VMSize }

    # Check if VM SKU is available in the VM's zone
    if ($_VM.Zones -and $_VM.Zones.Count -gt 0) {
        $vmZone = $_VM.Zones[0]
        if (-not ($_VMSKU.LocationInfo | Where-Object { $_.Zones -contains $vmZone })) {
            WriteRunLog -message "VM SKU $VMSize is not available in zone $vmZone" -category "ERROR"
            exit
        }
        else {
            WriteRunLog -message "VM SKU $VMSize is available in zone $vmZone"
        }
    }

    # Check if VM SKU has supported capabilities
    $_originalVMHasResourceDisk = ($_VMSKUs | Where-Object { $_.Name -eq $script:_original_vm_size }).Capabilities | Where-Object { $_.Name -eq "MaxResourceVolumeMB" -and $_.Value -eq 0 }
    $_newVMHasResourceDisk = ($_VMSKU.Capabilities | Where-Object { $_.Name -eq "MaxResourceVolumeMB" -and $_.Value -eq 0 })

    if ($_os -eq "Linux") {
        WriteRunLog -message "Skipping resource disk support check for Linux VMs"
    }
    else {
        WriteRunLog -message "Checking resource disk support for Windows VMs"
        if (($_originalVMHasResourceDisk -and -not $_newVMHasResourceDisk) -or (-not $_originalVMHasResourceDisk -and $_newVMHasResourceDisk)) {
            WriteRunLog -message "Mismatch in resource disk support between original VM size ($script:_original_vm_size) and new VM size ($VMSize)." -category "ERROR"
            WriteRunLog -message "Please check the VM sizes and their capabilities." -category "ERROR"
            WriteRunLog -message "IMPORTANT: If you try to convert to a v6 VM size (e.g. Standard_E4ds_v6 or Standard_E4ads_v6) an error might occur." -category "ERROR"
            WriteRunLog -message "We are working on a fix for this issue." -category "ERROR"
            exit
        }
        else {
            WriteRunLog -message "Resource disk support matches between original VM size and new VM size."
        }
    }

    if ($_VMSKU) {
        WriteRunLog -message "Found VM SKU - Checking for Capabilities"
        $_supported_controller = ($_VMSKU.Capabilities | Where-Object { $_.Name -eq "DiskControllerTypes" }).Value

        if ([string]::IsNullOrEmpty($_supported_controller) -and $NewControllerType -eq "NVMe") {
            WriteRunLog -message "VM SKU doesn't have supported capabilities" -category "ERROR"
            exit
        }
        else {
            WriteRunLog -message "VM SKU has supported capabilities"
            if ($NewControllerType -eq "NVMe") {
                # NVMe destination
                if ($_supported_controller.Contains("NVMe") ) {
                    WriteRunLog -message "VM supports NVMe" 
                }
                else {
                    WriteRunLog -message "VM doesn't support NVMe" -category "ERROR"
                    exit
                }
            }
            else {
                # SCSI is supported by all VM types
                WriteRunLog -message "VM supports SCSI"
            }  
        }
    }
    else {
        WriteRunLog -category "ERROR" -message ("VM SKU doesn't exist, please check your input: " + $VMSize )
        exit
    }
}

# generate URL for OS disk update
$osdisk_url = "https://management.azure.com/subscriptions/$($_AzureContext.Subscription.Id)/resourceGroups/$ResourceGroupName/providers/Microsoft.Compute/disks/$($_vm_osdisk.Name)?api-version=2023-04-02"

# auth header for web request
$auth_header = @{
    'Content-Type'  = 'application/json'
    'Authorization' = 'Bearer ' + $access_token
  }

# body for SCSI/NVMe enabled OS Disk
$body_nvmescsi = @'
{
    "properties": {
        "supportedCapabilities": {
            "diskControllerTypes":"SCSI, NVMe"
        }
    }
}
'@

# body for SCSI enabled OS Disk
$body_scsi = @'
{
    "properties": {
        "supportedCapabilities": {
            "diskControllerTypes":"SCSI"
        }
    }
}
'@

# Windows Check script for NVMe
$Check_Windows_Script = @'
$start = (Get-ItemProperty -Path HKLM:\SYSTEM\CurrentControlSet\Services\stornvme -Name Start).Start
if ($start -eq 0) {
    Write-Host "Start:OK"
}
else {
    Write-Host "Start:ERROR"
}
$startoverride = Get-ItemProperty -Path HKLM:\SYSTEM\CurrentControlSet\Services\stornvme\StartOverride -ErrorAction SilentlyContinue
if ($startoverride) {
    Write-Host "StartOverride:ERROR"
}
else {
    Write-Host "StartOverride:OK"
}
'@

# Pre-Checks completed
WriteRunLog -message "Pre-Checks completed"

# running preparation for operating systems
if ($_os -eq "Windows") {
    
    if ($NewControllerType -eq "NVMe") {
        WriteRunLog -message "Starting OS section"

        try {

            if (-not $IgnoreOSCheck) {
                if ($FixOperatingSystemSettings) {
                    WriteRunLog -message "Fixing operating system settings"
                    WriteRunLog -message "Running command to set stornvme to boot"
                    WriteRunLog -message "   sc.exe config stornvme start=boot"
                    $RunCommandResult = Invoke-AzVMRunCommand -ResourceGroupName $ResourceGroupName -VMName $VMName -CommandId 'RunPowerShellScript' -ScriptString 'Start-Process -FilePath "C:\Windows\System32\sc.exe" -ArgumentList "config stornvme start=boot"'
                }
                else {
                    if (-not $IgnoreSKUCheck) {
                        WriteRunLog -message "Collecting details from OS"
                        $_error = 0
                        $_okay = 0
                        $_scriptoutput = ""
                        $RunCommandResult = Invoke-AzVMRunCommand -ResourceGroupName $ResourceGroupName -VMName $VMName -CommandId 'RunPowerShellScript' -ScriptString $Check_Windows_Script

                        $_result = ($RunCommandResult.Value | ForEach-Object { $_.Message }) -split "`n"

                        foreach ($_line in $_result) {
                            WriteRunLog -message ("   Script output: " + $_line)
                            if ($_line.Contains("OK") -or $_line.Contains("ERROR")) {
                                $_scriptoutput += $_line + "`n"

                                if ($_line.Contains("Start:")) {
                                    if ($_line.Contains("ERROR")) {
                                        WriteRunLog -message "Start is not set to boot in the operating system" -category "ERROR"
                                        $_error++
                                    }
                                    else {
                                        WriteRunLog -message "Start is set to boot in the operating system" -category "INFO"
                                        $_okay++
                                    }
                                }

                                if ($_line.Contains("StartOverride:")) {
                                    if ($_line.Contains("ERROR")) {
                                        WriteRunLog -message "StartOverride is set in the operating system" -category "ERROR"
                                        $_error++
                                    }
                                    else {
                                        WriteRunLog -message "StartOverride does not exist" -category "INFO"
                                        $_okay++
                                    }
                                }
                            }
                        }

                        WriteRunLog -message "Windows OS Check result:"
                        WriteRunLog -message "Errors: $_error - OK: $_okay"

                        if ($_error -gt 0) {
                            WriteRunLog -message "Operating system does not seem to be ready, it might not after the conversion" -category "WARNING"
                            WriteRunLog -message "Please check the operating system settings" -category "WARNING"
                            WriteRunLog -message "If you want to continue, please use the -FixOperatingSystemSettings switch" -category "IMPORTANT"
                            WriteRunLog -message "alternative: you can run 'sc.exe config stornvme start=boot' in the operating system and continue or stop the script" -category "IMPORTANT"
                            AskToContinue -message "Do you want to continue?"
                        }
                    }
                    else {
                        WriteRunLog -message "Skipping OS Check, assuming that the operating system is ready for conversion"
                    }
                }
            }
            else {
                WriteRunLog -message "Skipping OS Check, assuming that the operating system is ready for conversion"
                if ($FixOperatingSystemSettings) {
                    WriteRunLog -message "Fixing operating system settings not supported with skipped OS Check" -category "ERROR"
                    exit
                }
            }
        } catch {
            WriteRunLog -message "Error running preparation for Windows OS" -category "ERROR"
            WriteRunLog $_.Exception.Message "ERROR"
            exit
        }
    }
    else {
        WriteRunLog -message "No preparation required for SCSI"
    }
}
else {
    WriteRunLog -message "Entering Linux OS section"

    try {

    # Define the bash script
$linux_check_script = @'
#!/bin/bash

# Set default values
fix=false
dry_run=false
distro=""

# Staging directory for dry-run mode
staging_dir=""

setup_dryrun() {
    staging_dir="/tmp/nvme-conversion-dryrun"
    rm -rf "$staging_dir"
    mkdir -p "$staging_dir/original" "$staging_dir/modified" "$staging_dir/diffs"
    echo "$(hostname)" > "$staging_dir/hostname"
    echo "$distro" > "$staging_dir/distro"
    uname -r > "$staging_dir/kernel"
    echo "[INFO] Dry-run mode: staging changes in $staging_dir"
}

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

# Setup dry-run staging if enabled
if $dry_run && $fix; then
    setup_dryrun
fi

# Function to check if NVMe driver is in initrd/initramfs or built into the kernel
check_nvme_driver() {
    echo "[INFO] Checking if NVMe driver is available for boot..."

    # Check if nvme is compiled directly into the kernel (built-in)
    if grep -qw nvme "/lib/modules/$(uname -r)/modules.builtin" 2>/dev/null; then
        echo "[INFO] NVMe driver is built into the kernel. No initramfs entry needed."
        if $dry_run && $fix; then
            echo "[DRYRUN] NVMe driver is built-in (kernel $(uname -r)). No initramfs or dracut changes needed."
            echo "nvme_builtin=true" > "$staging_dir/modified/nvme-driver-status.txt"
            echo "kernel=$(uname -r)" >> "$staging_dir/modified/nvme-driver-status.txt"
            grep -w nvme "/lib/modules/$(uname -r)/modules.builtin" >> "$staging_dir/modified/nvme-driver-status.txt"
        fi
        return 0
    fi

    echo "[INFO] NVMe is not built-in. Checking initrd/initramfs..."
    case "$distro" in
        ubuntu|debian)
            _initramfs_ok=true
            if ! lsinitramfs /boot/initrd.img-* 2>/dev/null | grep -q nvme; then
                echo "[WARNING] NVMe driver not found in initrd/initramfs."
                _initramfs_ok=false
            fi
            if ! lsinitramfs /boot/initrd.img-* 2>/dev/null | grep -qE 'hv_pci|pci.hyperv'; then
                echo "[WARNING] pci-hyperv/hv_pci driver not found in initrd/initramfs (required for Azure NVMe)."
                _initramfs_ok=false
            fi
            if $_initramfs_ok; then
                echo "[INFO] NVMe driver found in initrd/initramfs."
                if $dry_run && $fix; then
                    echo "[DRYRUN] NVMe and pci-hyperv drivers already in initramfs. No changes needed."
                    echo "nvme_in_initramfs=true" > "$staging_dir/modified/nvme-driver-status.txt"
                    echo "kernel=$(uname -r)" >> "$staging_dir/modified/nvme-driver-status.txt"
                fi
            else
                if modinfo nvme &>/dev/null; then
                    echo "[INFO] NVMe module exists on disk."
                fi
                if $fix; then
                    if $dry_run; then
                        echo "[DRYRUN] Would run: update-initramfs -u -k all"
                        echo "update-initramfs -u -k all" > "$staging_dir/modified/initramfs-commands.txt"
                    else
                        echo "[INFO] Adding NVMe/pci-hyperv drivers to initrd/initramfs..."
                        update-initramfs -u -k all
                        if lsinitramfs /boot/initrd.img-* | grep -q nvme; then
                            echo "[INFO] NVMe driver added successfully."
                        else
                            echo "[ERROR] Failed to add NVMe driver to initrd/initramfs."
                        fi
                    fi
                else
                    echo "[ERROR] NVMe driver not found in initrd/initramfs."
                fi
            fi
            ;;
        redhat|rhel|centos|rocky|almalinux|azurelinux|mariner|suse|sles|ol)
            # Fix 10: check ALL installed initramfs images, not just the running kernel
            _nvme_missing=false
            for _img in /boot/initramfs-*.img; do
                [ -f "$_img" ] || continue
                [[ "$_img" == *kdump* ]] && continue
                [[ "$_img" == *rescue* ]] && continue
                if ! lsinitrd "$_img" 2>/dev/null | grep -q nvme; then
                    echo "[WARNING] NVMe driver not found in $_img"
                    _nvme_missing=true
                fi
                if ! lsinitrd "$_img" 2>/dev/null | grep -qE 'hv_pci|pci.hyperv'; then
                    echo "[WARNING] pci-hyperv/hv_pci driver not found in $_img (required for Azure NVMe)"
                    _nvme_missing=true
                fi
            done
            if ! $_nvme_missing; then
                echo "[INFO] NVMe and pci-hyperv drivers found in initrd/initramfs."
                if $dry_run && $fix; then
                    echo "[DRYRUN] NVMe and pci-hyperv drivers already in all initramfs images. No changes needed."
                    echo "nvme_in_initramfs=true" > "$staging_dir/modified/nvme-driver-status.txt"
                    echo "kernel=$(uname -r)" >> "$staging_dir/modified/nvme-driver-status.txt"
                fi
            else
                if modinfo nvme &>/dev/null; then
                    echo "[INFO] NVMe module exists on disk but is not in all initramfs images."
                fi
                if $fix; then
                    if $dry_run; then
                        echo "[DRYRUN] Would run: dracut -f --regenerate-all (with nvme nvme-core in /etc/dracut.conf.d/nvme.conf)"
                        echo 'add_drivers+=" nvme nvme-core pci-hyperv "' > "$staging_dir/modified/dracut-nvme.conf"
                        echo "dracut -f --regenerate-all" >> "$staging_dir/modified/initramfs-commands.txt"
                    else
                        echo "[INFO] Adding NVMe driver to initrd/initramfs (all kernels)..."
                        mkdir -p /etc/dracut.conf.d
                        echo 'add_drivers+=" nvme nvme-core pci-hyperv "' | tee /etc/dracut.conf.d/nvme.conf > /dev/null
                        dracut -f --regenerate-all
                        _verify_ok=true
                        for _img in /boot/initramfs-*.img; do
                            [ -f "$_img" ] || continue
                            [[ "$_img" == *kdump* ]] && continue
                            [[ "$_img" == *rescue* ]] && continue
                            if ! lsinitrd "$_img" 2>/dev/null | grep -q nvme; then
                                echo "[ERROR] NVMe driver still missing in $_img after rebuild."
                                _verify_ok=false
                            fi
                            if ! lsinitrd "$_img" 2>/dev/null | grep -qE 'hv_pci|pci.hyperv'; then
                                echo "[ERROR] pci-hyperv/hv_pci driver still missing in $_img after rebuild."
                                _verify_ok=false
                            fi
                        done
                        if $_verify_ok; then
                            echo "[INFO] NVMe driver added successfully."
                        else
                            echo "[ERROR] Failed to add NVMe driver to all initramfs images."
                        fi
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

    # Build grub file list dynamically for verification
    _grub_check_files="/etc/default/grub"
    if [ -f /boot/grub2/grub.cfg ]; then
        _grub_check_files="$_grub_check_files /boot/grub2/grub.cfg"
    elif [ -f /boot/grub/grub.cfg ]; then
        _grub_check_files="$_grub_check_files /boot/grub/grub.cfg"
    fi

    if grep -q "nvme_core.io_timeout=240" $_grub_check_files 2>/dev/null; then
        echo "[INFO] nvme_core.io_timeout is set to 240."
        if $dry_run && $fix; then
            echo "[DRYRUN] nvme_core.io_timeout already set to 240. No grub changes needed."
            echo "nvme_core_io_timeout=240" > "$staging_dir/modified/nvme-timeout-status.txt"
            echo "status=already_configured" >> "$staging_dir/modified/nvme-timeout-status.txt"
        fi
    elif command -v grubby &>/dev/null && grubby --info=ALL 2>/dev/null | grep -q "nvme_core.io_timeout=240"; then
        echo "[INFO] nvme_core.io_timeout is set to 240 (BLS entries)."
    else
        echo "[WARNING] nvme_core.io_timeout is not set to 240."
        if $fix; then
            if $dry_run; then
                echo "[DRYRUN] Staging grub changes..."
                # Find the grub config file to stage
                local grub_file=""
                if [ -f /etc/default/grub ]; then
                    grub_file="/etc/default/grub"
                fi
                if [ -n "$grub_file" ]; then
                    cp "$grub_file" "$staging_dir/original/grub"
                    cp "$grub_file" "$staging_dir/modified/grub"
                    case "$distro" in
                        ubuntu)
                            sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="/GRUB_CMDLINE_LINUX_DEFAULT="nvme_core.io_timeout=240 /g' "$staging_dir/modified/grub"
                            ;;
                        debian)
                            sed -i 's/GRUB_CMDLINE_LINUX="/GRUB_CMDLINE_LINUX="nvme_core.io_timeout=240 /g' "$staging_dir/modified/grub"
                            ;;
                        suse|sles|opensuse*)
                            sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="/GRUB_CMDLINE_LINUX_DEFAULT="nvme_core.io_timeout=240 /g' "$staging_dir/modified/grub"
                            ;;
                        ol)
                            sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="/GRUB_CMDLINE_LINUX_DEFAULT="nvme_core.io_timeout=240 /g' "$staging_dir/modified/grub"
                            ;;
                        *)
                            sed -i 's/GRUB_CMDLINE_LINUX="/GRUB_CMDLINE_LINUX="nvme_core.io_timeout=240 /g' "$staging_dir/modified/grub"
                            ;;
                    esac
                    diff -u "$staging_dir/original/grub" "$staging_dir/modified/grub" > "$staging_dir/diffs/grub.diff" 2>&1 || true
                    echo "[DRYRUN] Grub diff staged in $staging_dir/diffs/grub.diff"
                    cat "$staging_dir/diffs/grub.diff"
                    # Check for BLS (BootLoaderSpec) — RHEL 8+, AlmaLinux 8+, OL 8.10+
                    if grep -q "GRUB_ENABLE_BLSCFG=true" "$grub_file" 2>/dev/null; then
                        echo "[INFO] BLS (BootLoaderSpec) is enabled."
                        if command -v grubby &>/dev/null; then
                            echo "[DRYRUN] Would run: grubby --update-kernel=ALL --args=nvme_core.io_timeout=240"
                            echo "bls_enabled=true" >> "$staging_dir/modified/nvme-timeout-status.txt"
                            echo "grubby_available=true" >> "$staging_dir/modified/nvme-timeout-status.txt"
                        else
                            echo "[WARNING] BLS is enabled but grubby is not installed."
                            echo "bls_enabled=true" >> "$staging_dir/modified/nvme-timeout-status.txt"
                            echo "grubby_available=false" >> "$staging_dir/modified/nvme-timeout-status.txt"
                        fi
                    fi
                else
                    echo "[DRYRUN] No grub config found to stage."
                fi
            else
                echo "[INFO] Setting nvme_core.io_timeout to 240..."
                case "$distro" in
                    ubuntu)
                        sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="/GRUB_CMDLINE_LINUX_DEFAULT="nvme_core.io_timeout=240 /g' /etc/default/grub
                        GRUB_DISABLE_OS_PROBER=true update-grub
                        ;;
                    debian)
                        sed -i 's/GRUB_CMDLINE_LINUX="/GRUB_CMDLINE_LINUX="nvme_core.io_timeout=240 /g' /etc/default/grub
                        GRUB_DISABLE_OS_PROBER=true update-grub
                        ;;
                    suse|sles|opensuse*)
                        if [ -f /etc/default/grub ]; then
                            sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="/GRUB_CMDLINE_LINUX_DEFAULT="nvme_core.io_timeout=240 /g' /etc/default/grub
                            GRUB_DISABLE_OS_PROBER=true grub2-mkconfig -o /boot/grub2/grub.cfg
                        else
                            echo "[ERROR] /etc/default/grub not found."
                            return 1
                        fi
                        ;;
                    redhat|rhel|centos|rocky|almalinux|azurelinux|mariner)
                        if [ -f /etc/default/grub ]; then
                            sed -i 's/GRUB_CMDLINE_LINUX="/GRUB_CMDLINE_LINUX="nvme_core.io_timeout=240 /g' /etc/default/grub
                            GRUB_DISABLE_OS_PROBER=true grub2-mkconfig -o /boot/grub2/grub.cfg
                            # Update BLS entries if applicable (RHEL 8+, AlmaLinux 8+)
                            if grep -q "GRUB_ENABLE_BLSCFG=true" /etc/default/grub 2>/dev/null; then
                                if command -v grubby &>/dev/null; then
                                    grubby --update-kernel=ALL --args="nvme_core.io_timeout=240"
                                    echo "[INFO] Updated BLS entries via grubby."
                                fi
                            fi
                        else
                            echo "[ERROR] /etc/default/grub not found."
                            return 1
                        fi
                        ;;
                    ol)
                        if [ -f /etc/default/grub ]; then
                            sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="/GRUB_CMDLINE_LINUX_DEFAULT="nvme_core.io_timeout=240 /g' /etc/default/grub
                            GRUB_DISABLE_OS_PROBER=true grub2-mkconfig -o /boot/grub2/grub.cfg
                            # Update BLS entries if applicable (OL 8.10+)
                            if grep -q "GRUB_ENABLE_BLSCFG=true" /etc/default/grub 2>/dev/null; then
                                if command -v grubby &>/dev/null; then
                                    grubby --update-kernel=ALL --args="nvme_core.io_timeout=240"
                                    echo "[INFO] Updated BLS entries via grubby."
                                fi
                            fi
                        else
                            echo "[ERROR] /etc/default/grub not found."
                            return 1
                        fi
                        ;;
                    *)
                        echo "[ERROR] Unsupported distribution for nvme_core.io_timeout fix."
                        return 1
                        ;;
                esac

                if grep -q "nvme_core.io_timeout=240" $_grub_check_files 2>/dev/null; then
                    echo "[INFO] nvme_core.io_timeout set successfully."
                elif command -v grubby &>/dev/null && grubby --info=ALL 2>/dev/null | grep -q "nvme_core.io_timeout=240"; then
                    echo "[INFO] nvme_core.io_timeout set successfully (BLS entries)."
                else
                    echo "[ERROR] Failed to set nvme_core.io_timeout."
                fi
            fi
        else
            echo "[ERROR] nvme_core.io_timeout is not set to 240."
        fi
    fi
}

# Function to check /etc/fstab for deprecated device names
check_fstab() {
    echo "[INFO] Checking /etc/fstab for deprecated device names..."
    # NOTE: /dev/mapper/* (LVM) and PARTUUID= paths survive NVMe conversion
    # because they use UUID-based addressing underneath. Only /dev/sd* and
    # /dev/disk/azure/scsi* paths break when disks move from SCSI to NVMe.
    if grep -Eq '/dev/sd[a-z][0-9]*|/dev/disk/azure/scsi[0-9]*/lun[0-9]*' /etc/fstab; then
        if $fix; then
            echo "[WARNING] /etc/fstab contains deprecated device names."
            if $dry_run; then
                echo "[DRYRUN] Staging fstab changes..."
                cp /etc/fstab "$staging_dir/original/fstab"

                # Build modified fstab in staging directory
                while read -r line; do
                    if [[ "$line" =~ ^[^#] ]]; then
                        device=$(echo "$line" | awk '{print $1}')
                        if [[ "$device" =~ ^/dev/sd[a-z][0-9]*$ ]]; then
                            uuid=$(blkid "$device" | awk -F\" '/UUID=/ {print $2}')
                            if [ -n "$uuid" ]; then
                                newline=$(echo "$line" | sed "s|$device|UUID=$uuid|g")
                                echo "[DRYRUN] Would replace $device with UUID=$uuid"
                                echo "$newline" >> "$staging_dir/modified/fstab"
                            else
                                echo "[DRYRUN] Could not find UUID for $device. Would skip."
                                echo "$line" >> "$staging_dir/modified/fstab"
                            fi
                        elif [[ "$device" =~ ^/dev/disk/azure/scsi[0-9]*/lun[0-9]* ]]; then
                            uuid=$(blkid "$device" | awk -F\" '/UUID=/ {print $2}')
                            if [ -n "$uuid" ]; then
                                newline=$(echo "$line" | sed "s|$device|UUID=$uuid|g")
                                echo "[DRYRUN] Would replace $device with UUID=$uuid"
                                echo "$newline" >> "$staging_dir/modified/fstab"
                            else
                                echo "[DRYRUN] Could not find UUID for $device. Would skip."
                                echo "$line" >> "$staging_dir/modified/fstab"
                            fi
                        else
                            echo "$line" >> "$staging_dir/modified/fstab"
                        fi
                    else
                        echo "$line" >> "$staging_dir/modified/fstab"
                    fi
                done < /etc/fstab

                diff -u "$staging_dir/original/fstab" "$staging_dir/modified/fstab" > "$staging_dir/diffs/fstab.diff" 2>&1 || true
                echo "[DRYRUN] Fstab diff staged in $staging_dir/diffs/fstab.diff"
                cat "$staging_dir/diffs/fstab.diff"
            else
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
                                echo "[WARNING] Could not find UUID for $device.  Skipping."
                                echo "$line" >> /etc/fstab.new
                            fi
                        elif [[ "$device" =~ ^/dev/disk/azure/scsi[0-9]*/lun[0-9]* ]]; then
                            uuid=$(blkid "$device" | awk -F\" '/UUID=/ {print $2}')
                            if [ -n "$uuid" ]; then
                                newline=$(echo "$line" | sed "s|$device|UUID=$uuid|g")
                                echo "[INFO] Replaced $device with UUID=$uuid"
                                echo "$newline" >> /etc/fstab.new
                            else
                                echo "[WARNING] Could not find UUID for $device.  Skipping."
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
            
                echo "[INFO] /etc/fstab updated with UUIDs.  Original fstab backed up to /etc/fstab.bak"
            fi
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

# Generate dry-run summary report
if $dry_run && $fix; then
    echo ""
    echo "[DRYRUN] ============================================"
    echo "[DRYRUN] Summary report for $(hostname)"
    echo "[DRYRUN] Distro: $distro | Kernel: $(uname -r)"
    echo "[DRYRUN] Staging directory: $staging_dir"
    echo "[DRYRUN] ============================================"
    echo "[DRYRUN] Files in staging directory:"
    find "$staging_dir" -type f | sort | while read -r f; do
        echo "[DRYRUN]   $f"
    done
    echo "[DRYRUN] ============================================"
    echo "[DRYRUN] No system files were modified."
fi

exit 0
'@

$linux_fix_script = $linux_check_script.Replace("fix=false","fix=true")
$linux_dryrun_script = $linux_check_script.Replace("fix=false","fix=true").Replace("dry_run=false","dry_run=true")

        if ($NewControllerType -eq "NVMe") {
            if (-not $IgnoreOSCheck) {

                if ($FixOperatingSystemSettings -or $DryRun) {
                    if ($DryRun) {
                        WriteRunLog -message "Dry-run mode: staging changes without modifying the system"
                        $RunCommandResult = Invoke-AzVMRunCommand -ResourceGroupName $resourceGroupName -Name $vmName -CommandId 'RunShellScript' -ScriptString $linux_dryrun_script
                    } else {
                        # Invoke the Run Command
                        $RunCommandResult = Invoke-AzVMRunCommand -ResourceGroupName $resourceGroupName -Name $vmName -CommandId 'RunShellScript' -ScriptString $linux_fix_script
                    }
                }
                else {
                    # Invoke the Run Command
                    $RunCommandResult = Invoke-AzVMRunCommand -ResourceGroupName $resourceGroupName -Name $vmName -CommandId 'RunShellScript' -ScriptString $linux_check_script

                }

                $_result = ($RunCommandResult.Value | ForEach-Object { $_.Message }) -split "`n"

                $_scriptoutput = ""
                $_error=0
                $_info=0
                $_warning=0
                foreach ($_line in $_result) {
                    if ($_line.Contains("[INFO]") -or $_line.Contains("[ERROR]") -or $_line.Contains("[WARNING]") -or $_line.Contains("[DRYRUN]")) {
                        $_scriptoutput += $_line + "`n"
                        if ($_line.Contains("[ERROR]")) {
                            $_error++
                        }
                        if ($_line.Contains("[INFO]")) {
                            $_info++
                        }
                        if ($_line.Contains("[WARNING]")) {
                            $_warning++
                        }
                    }
                    WriteRunLog -message ("   Script output: " + $_line)
                }

                WriteRunLog -message "Errors: $_error - Warnings: $_warning - Info: $_info"

                if ($_error -gt 0) {
                    WriteRunLog -message "Operating system does not seem to be ready, it might not after the conversion" -category "WARNING"
                    WriteRunLog -message "Please check the operating system settings" -category "WARNING"
                    WriteRunLog -message "If you want to continue, please use the -FixOperatingSystemSettings switch" -category "IMPORTANT"
                    WriteRunLog -message "alternative: you can enable NVMe driver manually" -category "IMPORTANT"
                    AskToContinue -message "Do you want to continue?"
                }
            }
            else {
                WriteRunLog -message "Skipping OS Check, assuming that the operating system is ready for conversion"
                if ($FixOperatingSystemSettings) {
                    WriteRunLog -message "Fixing operating system settings not supported with skipped OS Check" -category "ERROR"
                    exit
                }
            }
        }
        else {
            WriteRunLog -message "No preparation required for SCSI."
        }

    } catch {
        WriteRunLog -message "Error running preparation for Linux OS" -category "ERROR"
        WriteRunLog $_.Exception.Message "ERROR"
        exit
    }
}

# In dry-run mode, stop here — do not shut down or convert the VM
if ($DryRun) {
    WriteRunLog -message "Dry-run complete. No VM changes were made."
    WriteRunLog -message "Review the [DRYRUN] output above for staged changes."
    WriteRunLog -message "Staged files are in /tmp/nvme-conversion-dryrun/ on the target VM."
    WriteRunLog -message "Script ended at $(Get-Date)"
    exit
}

# Shutting down VM
WriteRunLog -message "Shutting down VM $VMName"
try {
    $_stopvm = Stop-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName -Force
    WriteRunLog -message "VM $VMName stopped"
} catch {
    WriteRunLog -message "Error stopping VM $VMName" -category "ERROR"
    WriteRunLog $_.Exception.Message "ERROR"
    exit
}

# Checking status of VM
WriteRunLog -message "Checking if VM is stopped and deallocated"
$_vminfo = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName -Status
if (($_vminfo.Statuses | Where-Object { $_.Code -like 'PowerState*' }).Code -ne "PowerState/deallocated") {
#if ($_vminfo.PowerState -ne "deallocated") {
    WriteRunLog -message "VM is not deallocated. Please deallocate the VM before running this script."
    WriteRunLog -message "giving it another try"
    $_stopvm = Stop-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName -Force
    $_vminfo = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName -Status
    if ($_vminfo.PowerState -ne "deallocated") {
        WriteRunLog -message "VM is not deallocated. Please check why the VM is not deallocated." -category "ERROR"
        exit
    }
}

# Enabling NVMe capabilities on OS disk
WriteRunLog -message "Setting OS Disk capabilities for $($_vm_osdisk.Name) to new Disk Controller Type to $NewControllerType"
try {
    WriteRunLog -message "generated URL for OS disk update:"
    WriteRunLog -message $osdisk_url
    if ($NewControllerType -eq "NVMe") {
        $_response = Invoke-RestMethod -Uri $osdisk_url -Method PATCH -Headers $auth_header -Body $body_nvmescsi
    }
    else {
        $_response = Invoke-RestMethod -Uri $osdisk_url -Method PATCH -Headers $auth_header -Body $body_scsi
    }
    WriteRunLog -message "OS Disk updated"
} catch {
    WriteRunLog -message "Error updating OS Disk" -category "ERROR"
    WriteRunLog $_.Exception.Message "ERROR"
    exit
}


# Setting new VM Size and storage controller
WriteRunLog -message "Setting new VM Size from $($_VM.HardwareProfile.VmSize) to $VMSize and Controller to $NewControllerType"
try {
    $_VM.HardwareProfile.VmSize = $VMSize
    $_VM.StorageProfile.DiskControllerType = $NewControllerType
} catch {
    WriteRunLog -message "Error updating VM Size" -category "ERROR"
    WriteRunLog $_.Exception.Message "ERROR"
    exit
}

# Update VM
WriteRunLog -message "Updating VM $VMName"
try {
    $_updatevm = Update-AzVM -ResourceGroupName $ResourceGroupName -VM $_VM
    if ($_updatevm.StatusCode -eq "OK") {
        WriteRunLog -message "VM $VMName updated"
    }
    else {
        WriteRunLog -message "Error updating VM $VMName" -category "ERROR"
        exit
    }
} catch {
    WriteRunLog -message "Error updating VM $VMName" -category "ERROR"
    WriteRunLog $_.Exception.Message "ERROR"
    exit
}

# Start VM
if ($StartVM) {
    WriteRunLog -message "Start after update enabled for VM $VMName"
    try {
        # waiting for X seconds before starting the VM - parameter SleepSeconds
        WriteRunLog -message "Waiting for $SleepSeconds seconds before starting the VM"
        Start-Sleep -Seconds $SleepSeconds
        # starting the VM
        WriteRunLog -message "Starting VM $VMName"
        $_startvm = Start-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName
        if ($_startvm.Status -eq "Succeeded") {
            WriteRunLog -message "VM $VMName started"
        }
        else {
            WriteRunLog -message "Error starting VM $VMName" -category "ERROR"
            if ($NewControllerType -eq "NVMe") {
                WriteRunLog -message "If you have any issues after the conversion you can revert the changes by running the script with the old settings"
                WriteRunLog -message "Here is the command to revert the changes:" -category "IMPORTANT"
                WriteRunLog -message "   .\Azure-NVMe-Conversion.ps1 -ResourceGroupName $ResourceGroupName -VMName $VMName -NewControllerType SCSI -VMSize $script:_original_vm_size -StartVM"
            }
            exit
        }
    } catch {
        WriteRunLog -message "Error starting VM $VMName" -category "ERROR"
        if ($NewControllerType -eq "NVMe") {
            WriteRunLog -message "If you have any issues after the conversion you can revert the changes by running the script with the old settings"
            WriteRunLog -message "Here is the command to revert the changes:" -category "IMPORTANT"
            WriteRunLog -message "   .\Azure-NVMe-Conversion.ps1 -ResourceGroupName $ResourceGroupName -VMName $VMName -NewControllerType SCSI -VMSize $script:_original_vm_size -StartVM"
        }
        WriteRunLog $_.Exception.Message "ERROR"
        exit
    }
}
else {
    WriteRunLog -message "VM $VMName is stopped. Please start the VM manually."
    WriteRunLog -message "If the VM should be started automatically use -StartVM switch"
}

# Check if breaking change warning was enabled before
if ($_breakingchangewarning.Value -eq $true) {
    WriteRunLog -message "Breaking Change Warning was enabled before script execution. Enabling it again."
    Update-AzConfig -DisplayBreakingChangeWarning $true
}

# Info for next steps
if ($StartVM) {
    WriteRunLog -message "As the virtual machine got started using the script you can check the operating system now"
}
else {
    WriteRunLog -message "Please start the virtual machine manually and check the operating system" -category "IMPORTANT"
    WriteRunLog -message "You can also use -StartVM switch to start the VM automatically"
}
if ($NewControllerType -eq "NVMe") {
    WriteRunLog -message "If you have any issues after the conversion you can revert the changes by running the script with the old settings"
    WriteRunLog -message "Here is the command to revert the changes:" -category "IMPORTANT"
    WriteRunLog -message "   .\Azure-NVMe-Conversion.ps1 -ResourceGroupName $ResourceGroupName -VMName $VMName -NewControllerType SCSI -VMSize $script:_original_vm_size -StartVM"
}

# Done
WriteRunLog -message "Script ended at $(Get-Date)"
WriteRunLog -message "Exiting"
