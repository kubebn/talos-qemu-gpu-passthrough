#!/bin/bash
set -o nounset -o pipefail

# Get all NVIDIA device IDs, excluding "Subsystem:" lines
NVIDIA_DEVICES=$(lspci -nnvD | grep -i nvidia | grep -o "[0-9a-f]\+:[0-9a-f]\+\.[0-9a-f]\+" | sort | uniq)

# Flag to track if all devices are using vfio-pci
ALL_USING_VFIO=true

echo "Checking if vfio-pci driver is in use for NVIDIA devices..."

for DEVICE in $NVIDIA_DEVICES; do
    # Check the kernel driver in use for the device
    DRIVER=$(lspci -nnk -s $DEVICE | grep "Kernel driver in use" | awk -F': ' '{print $2}')
    
    if [[ "$DRIVER" == "vfio-pci" ]]; then
        echo "Device $DEVICE: vfio-pci driver is in use."
    else
        echo "Device $DEVICE: vfio-pci driver is NOT in use (current: $DRIVER)."
        ALL_USING_VFIO=false
    fi
done

if $ALL_USING_VFIO; then
    echo "All NVIDIA devices are using the vfio-pci driver."
else
    echo "Not all NVIDIA devices are using the vfio-pci driver."
    exit 1
fi