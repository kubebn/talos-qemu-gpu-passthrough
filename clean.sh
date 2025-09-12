#!/bin/bash

# Remove the bridge and tap interfaces
sudo ip link set workertap down
sudo ip link delete workertap
sudo ip link set br0 down
sudo ip link delete br0
sudo rm ${PWD}/.worker/worker-flash.img
sudo rm ${PWD}/.worker/efi-vars.raw
sudo pkill dnsmasq
sudo truncate -s 0 /var/lib/misc/dnsmasq.leases


# Kill the QEMU process
if [ -f "${PWD}/.worker/qemu-worker-vm.pid" ]; then
  QEMU_PID=$(sudo cat ${PWD}/.worker/qemu-worker-vm.pid)
  sudo kill -9 $QEMU_PID
  sudo rm ${PWD}/.worker/qemu-worker-vm.pid
fi

# Kill the dnsmasq process
if [ -f "${PWD}/dnsmasq.pid" ]; then
  DNSMASQ_PID=$(sudo cat ${PWD}/dnsmasq.pid)
  sudo kill -9 $DNSMASQ_PID
  sudo rm ${PWD}/dnsmasq.pid
fi

# Clean up sudo iptables rules
sudo iptables -P INPUT ACCEPT
sudo iptables -P FORWARD ACCEPT
sudo iptables -P OUTPUT ACCEPT
sudo iptables -t nat -F
sudo iptables -t mangle -F
sudo iptables -F
sudo iptables -X
sudo ip6tables -P INPUT ACCEPT
sudo ip6tables -P FORWARD ACCEPT
sudo ip6tables -P OUTPUT ACCEPT
sudo ip6tables -t nat -F
sudo ip6tables -t mangle -F
sudo ip6tables -F
sudo ip6tables -X

echo "Cleanup completed."