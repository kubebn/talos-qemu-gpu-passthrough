#!/bin/bash

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
sudo DEBIAN_FRONTEND=noninteractive apt install qemu-system-x86 qemu-kvm qemu-utils virt-manager libvirt-daemon-system libvirt-clients dnsmasq bridge-utils ovmf genisoimage qemu-efi-aarch64 -y

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

# Read vfio-pci.ids and GPU device addresses from lspci.txt
if [ ! -f lspci.txt ]; then
    echo "Error: lspci.txt file not found."
    exit 1
fi

VFIO_IDS=$(awk '/^=== vfio-pci.ids ===/ {flag=1; next} /^===/ {flag=0} flag' lspci.txt)
ALL_GPU_ADDRESSES=$(awk '/^=== All GPU Device Addresses \(Line Format\) ===/ {flag=1; next} /^===/ {flag=0} flag' lspci.txt)
NVIDIA_GPU_CARDS=$(awk '/^=== NVIDIA GPU Cards \(nvidia driver only\) ===/ {flag=1; next} /^===/ {flag=0} flag' lspci.txt)

if [ -z "$VFIO_IDS" ] || [ -z "$ALL_GPU_ADDRESSES" ] || [ -z "$NVIDIA_GPU_CARDS" ]; then
    echo "Error: Missing required data in lspci.txt."
    exit 1
fi

# New settings to append
NEW_SETTINGS="iommu=pt vfio-pci.ids=$VFIO_IDS module_blacklist=nvidia default_hugepagesz=1G hugepagesz=1G hugepages=$HUGE_PAGES video=efifb:off"

# Path to the GRUB configuration file
GRUB_CONFIG="/etc/default/grub"

# Extract the current GRUB_CMDLINE_LINUX_DEFAULT value
CURRENT_SETTINGS=$(grep "^GRUB_CMDLINE_LINUX_DEFAULT=" $GRUB_CONFIG | sed -E 's/^GRUB_CMDLINE_LINUX_DEFAULT="(.*)"$/\1/')

# Check if NEW_SETTINGS are already present
if [[ "$CURRENT_SETTINGS" != *"$NEW_SETTINGS"* ]]; then
    # Append NEW_SETTINGS to the existing GRUB_CMDLINE_LINUX_DEFAULT
    UPDATED_SETTINGS="$CURRENT_SETTINGS $NEW_SETTINGS"
    sudo sed -i -E "s|^GRUB_CMDLINE_LINUX_DEFAULT=\".*\"|GRUB_CMDLINE_LINUX_DEFAULT=\"$UPDATED_SETTINGS\"|" $GRUB_CONFIG
fi

# Update GRUB
sudo update-grub

# Define the path for the vfio script
VFIO_SCRIPT="/etc/initramfs-tools/scripts/init-top/vfio.sh"

# Create the vfio.sh script with the dynamic list of devices
sudo bash -c "cat > $VFIO_SCRIPT" << EOF
#!/bin/sh

PREREQ=""

prereqs()
{
   echo "\$PREREQ"
}

case \$1 in
prereqs)
   prereqs
   exit 0
   ;;
esac

# Bind each device to vfio-pci driver
for dev in $ALL_GPU_ADDRESSES
do
    echo "vfio-pci" > /sys/bus/pci/devices/\$dev/driver_override
    echo "\$dev" > /sys/bus/pci/drivers/vfio-pci/bind
done

exit 0
EOF

# Make the script executable
sudo chmod +x $VFIO_SCRIPT

# Update vfio.conf
VFIO_CONF="/etc/modprobe.d/vfio.conf"
echo "softdep nvidia pre: vfio-pci" | sudo tee $VFIO_CONF

# Ensure required vfio modules are added to /etc/modules
MODULES_FILE="/etc/modules"
REQUIRED_MODULES=("vfio" "vfio_iommu_type1" "vfio_pci" "vfio_virqfd")

for MODULE in "${REQUIRED_MODULES[@]}"; do
    if ! grep -q "^$MODULE$" $MODULES_FILE; then
        echo "$MODULE" | sudo tee -a $MODULES_FILE
    fi
done

sudo update-initramfs -u -k all

#########################################################################################################
##### Checking UEFI Compatible ROM ######################################################################
#########################################################################################################

# Use NVIDIA GPU Cards (nvidia driver only) for ROM parsing
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
            continue
        fi

        # Unbind the GPU from vfio-pci
        if ! echo "$GPU" | sudo tee /sys/bus/pci/drivers/vfio-pci/unbind 2>/dev/null; then
            echo "Warning: Failed to unbind $GPU from vfio-pci. Device might not be attached to vfio-pci."
        fi

        echo 1 | sudo tee rom
        sudo cat rom > "$ROM_FILE"
        echo 0 | sudo tee rom

        # Bind the GPU back to vfio-pci
        if ! echo "$GPU" | sudo tee /sys/bus/pci/drivers/vfio-pci/bind 2>/dev/null; then
            echo "Warning: Failed to bind $GPU back to vfio-pci. Device might not be attached to vfio-pci."
        fi

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

echo "Processing complete. Check $WORKDIR for results."

######!!!!!!!!!!!!!!!!!!!!!!!! REBOOT is required
sudo reboot now