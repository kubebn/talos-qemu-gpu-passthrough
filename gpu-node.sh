#!/bin/bash
set -o nounset -o pipefail

# Function to check if apt update works
check_apt_update() {
    echo "Checking if apt update works..."
    if ! sudo apt-get update -y; then
        echo "Error: Unable to update package lists. Please check your network or repository configuration."
        exit 1
    fi
    echo "apt update completed successfully."
}

# Run the checks before proceeding
check_apt_update

# Check for IOMMU enablement
IOMMU_GROUPS=$(find /sys/kernel/iommu_groups/ -type l | wc -l)
if [ "$IOMMU_GROUPS" -eq 0 ]; then
    echo "Error: IOMMU is not enabled. Please run the enable-iommu.sh script and ensure IOMMU is enabled in your BIOS/UEFI settings."
    exit 1
else
    echo "IOMMU is enabled with $IOMMU_GROUPS groups."
fi

# Install necessary packages
sudo DEBIAN_FRONTEND=noninteractive apt install qemu-system-x86 qemu-kvm qemu-utils virt-manager libvirt-daemon-system libvirt-clients dnsmasq bridge-utils ovmf genisoimage qemu-efi-aarch64 socat -y

# Backup iptables cause we are going to add some new, and if you run cleanup.sh script, all iptables will be erased.
if [ ! -f iptables_bckp ]; then
    sudo iptables-save > iptables_bckp
    echo "iptables rules backed up to iptables_bckp"
else
    echo "iptables backup already exists. Skipping backup."
fi

# Disable cloud-init
sudo touch /etc/cloud/cloud-init.disabled

# Get total RAM in MB
TOTAL_RAM_MB=$(free -m | awk '/^Mem:/{print $2}')

# Calculate reserved RAM for the host (5% of total RAM)
RESERVED_RAM_MB=$((TOTAL_RAM_MB * 5 / 100))

# Convert reserved RAM to GB (rounded down)
RESERVED_RAM_GB=$((RESERVED_RAM_MB / 1024))

# Calculate the number of hugepages
if [ "$TOTAL_RAM_MB" -gt "$RESERVED_RAM_MB" ]; then
    HUGE_PAGES=$(((TOTAL_RAM_MB - RESERVED_RAM_MB) / 1024))
else
    echo "Error: Not enough RAM to reserve $RESERVED_RAM_GB GB for the host system."
    exit 1
fi

echo "Total RAM: $((TOTAL_RAM_MB / 1024)) GB"
echo "Reserved RAM for host: $RESERVED_RAM_GB GB"
echo "Calculated hugepages: $HUGE_PAGES"

# Distribute hugepages evenly across NUMA nodes for balanced allocation
# Format: hugepages=0:N,1:N,2:N,3:N ensures each NUMA node gets its share at boot
NUMA_COUNT=$(lscpu | grep "^NUMA node(s):" | awk '{print $NF}' 2>/dev/null)
if [ -n "$NUMA_COUNT" ] && [ "$NUMA_COUNT" -gt 1 ]; then
    PER_NUMA=$((HUGE_PAGES / NUMA_COUNT))
    HUGEPAGES_PARAM=""
    for ((n=0; n<NUMA_COUNT; n++)); do
        [ -n "$HUGEPAGES_PARAM" ] && HUGEPAGES_PARAM+=","
        HUGEPAGES_PARAM+="${n}:${PER_NUMA}"
    done
    echo "Per-NUMA hugepage allocation: $HUGEPAGES_PARAM"
else
    HUGEPAGES_PARAM="$HUGE_PAGES"
fi

# GRUB configuration: IOMMU passthrough, PCIe ASPM off, hugepages
# No module_blacklist=nvidia, no vfio-pci.ids — GPU binding is done at runtime by start.sh
NEW_SETTINGS="iommu=pt pcie_aspm=off default_hugepagesz=1G hugepagesz=1G hugepages=$HUGEPAGES_PARAM"

# Path to the GRUB configuration file
GRUB_CONFIG="/etc/default/grub"

# Extract the current GRUB_CMDLINE_LINUX_DEFAULT value
CURRENT_SETTINGS=$(grep "^GRUB_CMDLINE_LINUX_DEFAULT=" $GRUB_CONFIG | sed -E 's/^GRUB_CMDLINE_LINUX_DEFAULT="(.*)"$/\1/')

NEEDS_REBOOT=false

# Check if NEW_SETTINGS are already present
if [[ "$CURRENT_SETTINGS" != *"$NEW_SETTINGS"* ]]; then
    # Remove any old vfio-pci.ids, module_blacklist, video=efifb:off from previous gpu-node.sh runs
    CLEANED_SETTINGS=$(echo "$CURRENT_SETTINGS" | sed -E 's/vfio-pci\.ids=[^ ]*//g; s/module_blacklist=[^ ]*//g; s/video=efifb:off//g; s/iommu=pt//g; s/pcie_aspm=off//g; s/default_hugepagesz=[^ ]*//g; s/hugepagesz=[^ ]*//g; s/hugepages=[^ ]*//g; s/  +/ /g; s/^ //; s/ $//')
    UPDATED_SETTINGS="$CLEANED_SETTINGS $NEW_SETTINGS"
    sudo sed -i -E "s|^GRUB_CMDLINE_LINUX_DEFAULT=\".*\"|GRUB_CMDLINE_LINUX_DEFAULT=\"$UPDATED_SETTINGS\"|" $GRUB_CONFIG
    sudo update-grub
    NEEDS_REBOOT=true
    echo "GRUB updated with hugepages and IOMMU passthrough mode."
else
    echo "GRUB settings already configured. No changes needed."
fi

# Ensure vfio modules are available (loaded at runtime, not forced at boot)
MODULES_FILE="/etc/modules"
REQUIRED_MODULES=("vfio" "vfio_iommu_type1" "vfio_pci")

for MODULE in "${REQUIRED_MODULES[@]}"; do
    if ! grep -q "^$MODULE$" $MODULES_FILE; then
        echo "$MODULE" | sudo tee -a $MODULES_FILE
    fi
done

# Remove old initramfs vfio.sh and vfio.conf if they exist from previous setup
if [ -f /etc/initramfs-tools/scripts/init-top/vfio.sh ]; then
    sudo rm /etc/initramfs-tools/scripts/init-top/vfio.sh
    echo "Removed old initramfs vfio.sh (no longer needed — binding is done at runtime)."
fi
if [ -f /etc/modprobe.d/vfio.conf ]; then
    sudo rm /etc/modprobe.d/vfio.conf
    echo "Removed old vfio.conf (no longer needed — nvidia is not blacklisted)."
fi

sudo update-initramfs -u -k all

#########################################################################################################
##### Checking UEFI Compatible ROM ######################################################################
#########################################################################################################

# Read GPU addresses from lspci.txt
if [ ! -f lspci.txt ]; then
    echo "Error: lspci.txt file not found. Run pci-passthrough.py first."
    exit 1
fi

NVIDIA_GPU_CARDS=$(awk '/^=== GPUs ===/ {flag=1; next} /^===/ {flag=0} flag' lspci.txt)

if [ -z "$NVIDIA_GPU_CARDS" ]; then
    echo "Warning: No NVIDIA GPU cards found in lspci.txt. Skipping ROM check."
else
    GPUS=$(echo "$NVIDIA_GPU_CARDS")

    # Define working directories
    WORKDIR=${PWD}/.gpu_roms
    mkdir -p "$WORKDIR"

    # Clone and build rom-parser
    if [ ! -d "rom-parser" ]; then
        git clone https://github.com/awilliam/rom-parser
    fi
    cd rom-parser || exit
    make
    cd ..

    ROM_PARSER="$(pwd)/rom-parser/rom-parser"

    for GPU in $GPUS; do
        echo "Processing GPU: $GPU"
        GPU_PATH="/sys/bus/pci/devices/$GPU"
        ROM_FILE="/tmp/$GPU.rom"
        GOOD_ROM="$WORKDIR/good_gpu.rom"
        BAD_ROM_FILE="$WORKDIR/$GPU.bad"

        if [ -d "$GPU_PATH" ]; then
            cd "$GPU_PATH" || continue

            # Check if the 'rom' file exists
            if [ ! -e rom ]; then
                echo "No 'rom' file found for GPU: $GPU. Skipping."
                cd - > /dev/null
                continue
            fi

            # Unbind the GPU from its current driver to access ROM
            CURRENT_DRIVER=""
            if [ -e "$GPU_PATH/driver" ]; then
                CURRENT_DRIVER=$(basename "$(readlink $GPU_PATH/driver)")
                echo "$GPU" | sudo tee /sys/bus/pci/drivers/$CURRENT_DRIVER/unbind 2>/dev/null || true
            fi

            echo 1 | sudo tee rom
            sudo cat rom > "$ROM_FILE"
            echo 0 | sudo tee rom

            # Bind the GPU back to its original driver
            if [ -n "$CURRENT_DRIVER" ]; then
                echo "$GPU" | sudo tee /sys/bus/pci/drivers/$CURRENT_DRIVER/bind 2>/dev/null || true
            fi

            cd - > /dev/null

            OUTPUT=$($ROM_PARSER "$ROM_FILE")
            if echo "$OUTPUT" | grep -q "EFI: Signature Valid"; then
                echo "$GPU is UEFI compatible."
                [ ! -f "$GOOD_ROM" ] && sudo cp "$ROM_FILE" "$GOOD_ROM"
            else
                echo "$GPU is NOT UEFI compatible."
                sudo touch "$BAD_ROM_FILE"
            fi
        else
            echo "GPU path $GPU_PATH does not exist. Skipping."
        fi
    done

    echo "ROM processing complete. Check $WORKDIR for results."
fi

if [ "$NEEDS_REBOOT" = true ]; then
    echo ""
    echo "========================================"
    echo "A reboot is required to apply GRUB changes (hugepages, IOMMU passthrough)."
    echo "After reboot, run start.sh to launch the VM — GPU binding will happen at runtime."
    echo "========================================"
    echo ""
    read -p "Reboot now? [y/N] " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        sudo reboot now
    fi
else
    echo ""
    echo "No reboot needed. You can run start.sh to launch the VM."
fi
