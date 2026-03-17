#!/bin/bash
# NVMe Conversion Check Script
# Full script from Azure-NVMe-Conversion.ps1
# Standalone version with -fix and -dry CLI options
#
# Usage:
#   ./nvme-check-dryrun.sh              # check only (no changes)
#   ./nvme-check-dryrun.sh -fix         # apply fixes
#   ./nvme-check-dryrun.sh -fix -dry    # dry-run: stage changes without modifying system
# Output: structured lines with [INFO], [WARNING], [ERROR], [DRYRUN] tags

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
    echo "Usage: $0 [-fix] [-dry]"
    echo "  -fix  Apply fixes (update initramfs, grub, fstab)"
    echo "  -dry  Dry-run mode (requires -fix): stage changes without modifying system"
    exit 1
}

# Parse command line arguments
while [ $# -gt 0 ]; do
    case "$1" in
        -fix)
            fix=true
            ;;
        -dry)
            dry_run=true
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
            if lsinitramfs /boot/initrd.img-* | grep -q nvme; then
                echo "[INFO] NVMe driver found in initrd/initramfs."
                if $dry_run && $fix; then
                    echo "[DRYRUN] NVMe driver already in initramfs. No changes needed."
                    echo "nvme_in_initramfs=true" > "$staging_dir/modified/nvme-driver-status.txt"
                    echo "kernel=$(uname -r)" >> "$staging_dir/modified/nvme-driver-status.txt"
                fi
            else
                echo "[WARNING] NVMe driver not found in initrd/initramfs."
                if modinfo nvme &>/dev/null; then
                    echo "[INFO] NVMe module exists on disk but is not in the initramfs."
                fi
                if $fix; then
                    if $dry_run; then
                        echo "[DRYRUN] Would run: update-initramfs -u -k all"
                        echo "update-initramfs -u -k all" > "$staging_dir/modified/initramfs-commands.txt"
                    else
                        echo "[INFO] Adding NVMe driver to initrd/initramfs..."
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
            if lsinitrd | grep -q nvme; then
                echo "[INFO] NVMe driver found in initrd/initramfs."
                if $dry_run && $fix; then
                    echo "[DRYRUN] NVMe driver already in initramfs. No changes needed."
                    echo "nvme_in_initramfs=true" > "$staging_dir/modified/nvme-driver-status.txt"
                    echo "kernel=$(uname -r)" >> "$staging_dir/modified/nvme-driver-status.txt"
                fi
            else
                echo "[WARNING] NVMe driver not found in initrd/initramfs."
                if modinfo nvme &>/dev/null; then
                    echo "[INFO] NVMe module exists on disk but is not in the initramfs."
                fi
                if $fix; then
                    if $dry_run; then
                        echo "[DRYRUN] Would run: dracut -f (with nvme nvme-core in /etc/dracut.conf.d/nvme.conf)"
                        echo 'add_drivers+=" nvme nvme-core "' > "$staging_dir/modified/dracut-nvme.conf"
                        echo "dracut -f" >> "$staging_dir/modified/initramfs-commands.txt"
                    else
                        echo "[INFO] Adding NVMe driver to initrd/initramfs..."
                        mkdir -p /etc/dracut.conf.d
                        echo 'add_drivers+=" nvme nvme-core "' | sudo tee /etc/dracut.conf.d/nvme.conf > /dev/null
                        sudo dracut -f   
                        if lsinitrd | grep -q nvme; then
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
        *)
            echo "[ERROR] Unsupported distribution for NVMe driver check."
            return 1
            ;;
    esac
}

# Function to check nvme_core.io_timeout parameter
check_nvme_timeout() {
    echo "[INFO] Checking nvme_core.io_timeout parameter..."
    if grep -q "nvme_core.io_timeout=240" /etc/default/grub /etc/grub.conf /boot/grub/grub.cfg; then
        echo "[INFO] nvme_core.io_timeout is set to 240."
        if $dry_run && $fix; then
            echo "[DRYRUN] nvme_core.io_timeout already set to 240. No grub changes needed."
            echo "nvme_core_io_timeout=240" > "$staging_dir/modified/nvme-timeout-status.txt"
            echo "status=already_configured" >> "$staging_dir/modified/nvme-timeout-status.txt"
        fi
    else
        echo "[WARNING] nvme_core.io_timeout is not set to 240."
        if $fix; then
            if $dry_run; then
                echo "[DRYRUN] Staging grub changes..."
                # Find the grub config file to stage
                local grub_file=""
                if [ -f /etc/default/grub ]; then
                    grub_file="/etc/default/grub"
                elif [ -f /etc/default/grub.conf ]; then
                    grub_file="/etc/default/grub.conf"
                fi
                if [ -n "$grub_file" ]; then
                    cp "$grub_file" "$staging_dir/original/grub"
                    cp "$grub_file" "$staging_dir/modified/grub"
                    case "$distro" in
                        ubuntu|debian)
                            sed -i 's/GRUB_CMDLINE_LINUX="/GRUB_CMDLINE_LINUX="nvme_core.io_timeout=240 /g' "$staging_dir/modified/grub"
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
                else
                    echo "[DRYRUN] No grub config found to stage."
                fi
            else
                echo "[INFO] Setting nvme_core.io_timeout to 240..."
                case "$distro" in
                    ubuntu|debian)
                        sed -i 's/GRUB_CMDLINE_LINUX="/GRUB_CMDLINE_LINUX="nvme_core.io_timeout=240 /g' /etc/default/grub
                        update-grub
                        ;;
                    redhat|rhel|centos|rocky|almalinux|azurelinux|mariner|suse|sles)
                        if [ -f /etc/default/grub ]; then
                            sed -i 's/GRUB_CMDLINE_LINUX="/GRUB_CMDLINE_LINUX="nvme_core.io_timeout=240 /g' /etc/default/grub
                            grub2-mkconfig -o /boot/grub2/grub
                        elif [ -f /etc/default/grub.conf ]; then
                            sed -i 's/GRUB_CMDLINE_LINUX="/GRUB_CMDLINE_LINUX="nvme_core.io_timeout=240 /g' /etc/default/grub.conf
                            grub2-mkconfig -o /boot/grub2/grub.cfg
                        else
                            echo "[ERROR] No grub config found."
                            exit 1
                        fi
                        ;;
                    ol)
                        if [ -f /etc/default/grub ]; then
                            sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="/GRUB_CMDLINE_LINUX_DEFAULT="nvme_core.io_timeout=240 /g' /etc/default/grub
                            grub2-mkconfig -o /boot/grub2/grub
                        elif [ -f /etc/default/grub.conf ]; then
                            sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="/GRUB_CMDLINE_LINUX_DEFAULT="nvme_core.io_timeout=240 /g' /etc/default/grub.conf
                            grub2-mkconfig -o /boot/grub2/grub.cfg
                        else
                            echo "[ERROR] No grub config found."
                            exit 1
                        fi
                        ;;
                    *)
                        echo "[ERROR] Unsupported distribution for nvme_core.io_timeout fix."
                        return 1
                        ;;
                esac

                if grep -q "nvme_core.io_timeout=240" /etc/default/grub /etc/grub.conf /boot/grub/grub.cfg; then
                    echo "[INFO] nvme_core.io_timeout set successfully."
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
