#!/bin/bash
# Pin QEMU vCPU threads to physical CPUs for NUMA locality
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
for i in "${!VCPU_TIDS[@]}"; do
    tid=${VCPU_TIDS[$i]}
    if [ $i -lt ${#PHYSICAL_CPUS[@]} ]; then
        pcpu=${PHYSICAL_CPUS[$i]}
        taskset -pc $pcpu $tid > /dev/null 2>&1
        echo "  vCPU $i (TID $tid) -> pCPU $pcpu"
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
echo "vCPU pinning complete."
