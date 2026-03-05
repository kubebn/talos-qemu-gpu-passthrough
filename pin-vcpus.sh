#!/bin/bash
# Pin QEMU vCPU threads to physical CPUs for NUMA locality,
# set CPU governor to performance on VM cores, and align VFIO IRQ affinity
set -o nounset -o pipefail

HOST_CPU_RESERVE=${1:-4}

# Find QEMU process
QEMU_PID=$(pgrep -f "qemu-system-x86_64.*talos-worker" | head -1)
if [ -z "$QEMU_PID" ]; then
    echo "Error: QEMU process not found."
    exit 1
fi

echo "Found QEMU PID: $QEMU_PID"

# Wait briefly for vCPU threads to be created
sleep 2

# Get all vCPU thread TIDs (named "CPU X/KVM" in /proc)
VCPU_TIDS=($(ls /proc/$QEMU_PID/task/ | while read tid; do
    name=$(cat /proc/$QEMU_PID/task/$tid/comm 2>/dev/null)
    if [[ "$name" == CPU* ]]; then
        echo "$tid"
    fi
done))

if [ ${#VCPU_TIDS[@]} -eq 0 ]; then
    echo "Error: No vCPU threads found."
    exit 1
fi

echo "Found ${#VCPU_TIDS[@]} vCPU threads."

# Build list of physical CPUs (skip first HOST_CPU_RESERVE from NUMA 0)
PHYSICAL_CPUS=($(lscpu --parse=CPU,NODE | grep -v '^#' | sort -t, -k2,2n -k1,1n | awk -F, -v skip=$HOST_CPU_RESERVE '
    BEGIN { skipped=0 }
    $2==0 && skipped < skip { skipped++; next }
    { print $1 }
'))

# Pin each vCPU thread to corresponding physical CPU
VM_CPU_LIST=""
for i in "${!VCPU_TIDS[@]}"; do
    tid=${VCPU_TIDS[$i]}
    if [ $i -lt ${#PHYSICAL_CPUS[@]} ]; then
        pcpu=${PHYSICAL_CPUS[$i]}
        taskset -pc $pcpu $tid > /dev/null 2>&1
        echo "  vCPU $i (TID $tid) -> pCPU $pcpu"
        [ -n "$VM_CPU_LIST" ] && VM_CPU_LIST+=" "
        VM_CPU_LIST+="$pcpu"
    fi
done

# Pin I/O threads to reserved CPUs
RESERVED_CPUS=$(seq 0 $((HOST_CPU_RESERVE - 1)) | tr '\n' ',' | sed 's/,$//')
IO_TIDS=($(ls /proc/$QEMU_PID/task/ | while read tid; do
    name=$(cat /proc/$QEMU_PID/task/$tid/comm 2>/dev/null)
    if [[ "$name" != CPU* ]] && [[ "$tid" != "$QEMU_PID" ]]; then
        echo "$tid"
    fi
done))

for tid in "${IO_TIDS[@]}"; do
    taskset -pc $RESERVED_CPUS $tid > /dev/null 2>&1
done
echo "I/O threads pinned to reserved CPUs: $RESERVED_CPUS"

# Set CPU governor to 'performance' on VM-pinned cores
# Prevents frequency scaling latency on cores running vCPUs
if [ -d /sys/devices/system/cpu/cpu0/cpufreq ]; then
    GOVERNOR_SET=0
    for pcpu in $VM_CPU_LIST; do
        GOV_PATH="/sys/devices/system/cpu/cpu${pcpu}/cpufreq/scaling_governor"
        if [ -f "$GOV_PATH" ]; then
            echo "performance" | sudo tee "$GOV_PATH" > /dev/null 2>&1
            GOVERNOR_SET=$((GOVERNOR_SET + 1))
        fi
    done
    if [ $GOVERNOR_SET -gt 0 ]; then
        echo "CPU governor set to 'performance' on $GOVERNOR_SET VM cores."
    fi
fi

# Set VFIO device IRQ affinity to match VM CPU NUMA nodes
# This ensures hardware interrupts from passthrough devices are handled on the same
# NUMA node as the vCPU processing the interrupt, avoiding cross-node cache misses
if [ -d /proc/irq ]; then
    VFIO_IRQS=$(grep vfio /proc/interrupts 2>/dev/null | awk '{print $1}' | tr -d ':')
    if [ -n "$VFIO_IRQS" ]; then
        # Build CPU mask from VM cores
        VM_CPU_MASK=0
        for pcpu in $VM_CPU_LIST; do
            VM_CPU_MASK=$((VM_CPU_MASK | (1 << pcpu)))
        done
        VM_CPU_HEX=$(printf "%x" $VM_CPU_MASK)
        IRQ_SET=0
        for irq in $VFIO_IRQS; do
            if [ -f "/proc/irq/$irq/smp_affinity" ]; then
                echo "$VM_CPU_HEX" | sudo tee "/proc/irq/$irq/smp_affinity" > /dev/null 2>&1
                IRQ_SET=$((IRQ_SET + 1))
            fi
        done
        if [ $IRQ_SET -gt 0 ]; then
            echo "VFIO IRQ affinity set on $IRQ_SET interrupts."
        fi
    fi
fi

echo "vCPU pinning complete."
