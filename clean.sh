#!/bin/bash
set -o pipefail

WORKER_DIR="${PWD}/.worker"
DNSMASQ_DIR="${PWD}/.dnsmasq"

# Graceful QEMU shutdown via monitor socket, then force kill as fallback
if [ -f "${WORKER_DIR}/qemu-worker-vm.pid" ]; then
  QEMU_PID=$(sudo cat "${WORKER_DIR}/qemu-worker-vm.pid")

  # Try graceful shutdown via QEMU monitor
  if [ -S "${WORKER_DIR}/worker.monitor" ]; then
    echo "Sending system_powerdown to QEMU VM..."
    echo "system_powerdown" | sudo socat - UNIX-CONNECT:"${WORKER_DIR}/worker.monitor" 2>/dev/null
    # Wait up to 30 seconds for graceful shutdown
    TIMEOUT=30
    while [ $TIMEOUT -gt 0 ] && sudo kill -0 "$QEMU_PID" 2>/dev/null; do
      sleep 1
      TIMEOUT=$((TIMEOUT - 1))
    done
  fi

  # Force kill if still running
  if sudo kill -0 "$QEMU_PID" 2>/dev/null; then
    echo "QEMU did not shut down gracefully, force killing..."
    sudo kill -9 "$QEMU_PID"
  fi
  sudo rm -f "${WORKER_DIR}/qemu-worker-vm.pid"
  echo "QEMU VM stopped."
fi

# Kill our dnsmasq process (not all dnsmasq on the host)
if [ -f "${DNSMASQ_DIR}/dnsmasq.pid" ]; then
  DNSMASQ_PID=$(sudo cat "${DNSMASQ_DIR}/dnsmasq.pid")
  sudo kill "$DNSMASQ_PID" 2>/dev/null
  sudo rm -f "${DNSMASQ_DIR}/dnsmasq.pid"
  echo "dnsmasq stopped."
fi

# Runtime VFIO unbinding — restore GPUs to their original driver
if [ -f "${WORKER_DIR}/.gpu_mode" ]; then
  if [ -f lspci.txt ]; then
    # "All Passthrough Devices (Line Format)" has all addresses on ONE line, space-separated
    ALL_PASSTHROUGH_ADDRESSES=$(awk '/^=== All Passthrough Devices \(Line Format\) ===/ {flag=1; next} /^===/ {flag=0} flag' lspci.txt | xargs)
    for dev in $ALL_PASSTHROUGH_ADDRESSES; do
      if [ -e "/sys/bus/pci/devices/$dev/driver" ]; then
        CURRENT_DRIVER=$(basename "$(readlink /sys/bus/pci/devices/$dev/driver)")
        if [ "$CURRENT_DRIVER" = "vfio-pci" ]; then
          echo "Unbinding $dev from vfio-pci..."
          echo "$dev" | sudo tee /sys/bus/pci/drivers/vfio-pci/unbind > /dev/null 2>&1
          echo "" | sudo tee /sys/bus/pci/devices/$dev/driver_override > /dev/null 2>&1
        fi
      fi
    done
    # Trigger driver re-probe so original drivers pick the devices back up
    for dev in $ALL_PASSTHROUGH_ADDRESSES; do
      echo "$dev" | sudo tee /sys/bus/pci/drivers_probe > /dev/null 2>&1
    done
    echo "Passthrough devices unbound from vfio-pci and reprobed."
  fi
  rm -f "${WORKER_DIR}/.gpu_mode"
fi

# Remove only the iptables rules that start.sh added
if [ -f "${WORKER_DIR}/.iptables_rules" ]; then
  while IFS= read -r rule; do
    # Replace -A (append) or -I (insert) with -D (delete)
    DELETE_RULE=$(echo "$rule" | sed 's/^-A /-D /; s/^-I /-D /')
    sudo iptables $DELETE_RULE 2>/dev/null
  done < "${WORKER_DIR}/.iptables_rules"
  # Remove NAT rules
  if [ -f "${WORKER_DIR}/.iptables_nat_rules" ]; then
    while IFS= read -r rule; do
      DELETE_RULE=$(echo "$rule" | sed 's/^-A /-D /; s/^-I /-D /')
      sudo iptables -t nat $DELETE_RULE 2>/dev/null
    done < "${WORKER_DIR}/.iptables_nat_rules"
    rm -f "${WORKER_DIR}/.iptables_nat_rules"
  fi
  rm -f "${WORKER_DIR}/.iptables_rules"
  echo "iptables rules removed."
fi

# Remove the bridge and tap interfaces
if ip link show workertap &>/dev/null; then
  sudo ip link set workertap down
  sudo ip link delete workertap
fi
if ip link show br0 &>/dev/null; then
  sudo ip link set br0 down
  sudo ip link delete br0
fi

# Clean up OVMF files
sudo rm -f "${WORKER_DIR}/worker-flash.img" "${WORKER_DIR}/efi-vars.raw"

# Clean dnsmasq leases
if [ -f /var/lib/misc/dnsmasq.leases ]; then
  sudo truncate -s 0 /var/lib/misc/dnsmasq.leases
fi

echo "Cleanup completed."
