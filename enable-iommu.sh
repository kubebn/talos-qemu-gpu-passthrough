#!/bin/bash

# Install dependencies
if ! command -v lspci &> /dev/null; then
    echo "lspci not found. Please install pciutils."
    exit 1
fi

# Path to the GRUB configuration file
GRUB_CONFIG="/etc/default/grub"
GRUB_BACKUP="/etc/default/grub.backup"

# Backup the GRUB configuration file
if [ ! -f "$GRUB_BACKUP" ]; then
    sudo cp $GRUB_CONFIG $GRUB_BACKUP
    echo "Backup of GRUB configuration created at $GRUB_BACKUP"
else
    echo "Backup already exists at $GRUB_BACKUP"
fi

# Detect CPU vendor and set appropriate IOMMU setting
CPU_VENDOR=$(grep -m 1 "vendor_id" /proc/cpuinfo | awk '{print $3}')
if [ "$CPU_VENDOR" = "GenuineIntel" ]; then
    IOMMU_SETTING="intel_iommu=on"
elif [ "$CPU_VENDOR" = "AuthenticAMD" ]; then
    IOMMU_SETTING="amd_iommu=on"
else
    echo "Unsupported CPU vendor: $CPU_VENDOR"
    exit 1
fi
echo "Detected CPU vendor: $CPU_VENDOR. Using IOMMU setting: $IOMMU_SETTING"

# Extract the current GRUB_CMDLINE_LINUX_DEFAULT value
CURRENT_SETTINGS=$(grep "^GRUB_CMDLINE_LINUX_DEFAULT=" $GRUB_CONFIG | sed -E 's/^GRUB_CMDLINE_LINUX_DEFAULT="(.*)"$/\1/')

# Check if IOMMU_SETTING is already present
if [[ "$CURRENT_SETTINGS" != *"$IOMMU_SETTING"* ]]; then
    # Append IOMMU_SETTING to the existing GRUB_CMDLINE_LINUX_DEFAULT
    UPDATED_SETTINGS="$CURRENT_SETTINGS $IOMMU_SETTING"
    sudo sed -i -E "s|^GRUB_CMDLINE_LINUX_DEFAULT=\".*\"|GRUB_CMDLINE_LINUX_DEFAULT=\"$UPDATED_SETTINGS\"|" $GRUB_CONFIG
    echo "IOMMU setting added to GRUB configuration."
else
    echo "IOMMU setting is already present in GRUB configuration."
fi

# Update GRUB
sudo update-grub

echo "IOMMU enablement complete. A reboot is required to apply the changes."

sudo reboot