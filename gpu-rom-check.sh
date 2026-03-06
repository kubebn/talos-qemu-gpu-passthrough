#!/bin/bash
set -o nounset -o pipefail

# GPU ROM UEFI Compatibility Check
# Reads GPU addresses from lspci.txt, dumps ROMs, checks for EFI signature.
# Creates .gpu_roms/good_gpu.rom (first valid ROM) and .gpu_roms/<addr>.bad markers.

if [ ! -f lspci.txt ]; then
    echo "Error: lspci.txt file not found. Run pci-passthrough.py first."
    exit 1
fi

NVIDIA_GPU_CARDS=$(awk '/^=== GPUs ===/ {flag=1; next} /^===/ {flag=0} flag' lspci.txt)

if [ -z "$NVIDIA_GPU_CARDS" ]; then
    echo "Warning: No NVIDIA GPU cards found in lspci.txt. Skipping ROM check."
    exit 0
fi

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

for GPU in $NVIDIA_GPU_CARDS; do
    echo "Processing GPU: $GPU"
    GPU_PATH="/sys/bus/pci/devices/$GPU"
    ROM_FILE="/tmp/$GPU.rom"
    GOOD_ROM="$WORKDIR/good_gpu.rom"
    BAD_ROM_FILE="$WORKDIR/$GPU.bad"

    if [ -d "$GPU_PATH" ]; then
        cd "$GPU_PATH" || continue

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
