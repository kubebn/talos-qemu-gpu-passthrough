#!/bin/bash

#### Talos Imager requires latest kernel version. " bootloader: error mounting partitions: error mounting /dev/loop6p3: 
#### 2 error(s) occurred:" - build-image script is fixed by updating to latest hwe kernel
####

# sudo DEBIAN_FRONTEND=noninteractive apt install --install-recommends linux-generic-hwe-22.04 -y

# Install necessary packages
sudo DEBIAN_FRONTEND=noninteractive apt install qemu-system-x86 qemu-kvm qemu-utils virt-manager libvirt-daemon-system libvirt-clients dnsmasq bridge-utils ovmf genisoimage qemu-efi-aarch64 -y

# Backup iptables cause we are going to add some new, and if you run cleanup.sh script, all iptables will be erased.
if [ ! -f iptables_bckp ]; then
    sudo iptables-save > iptables_bckp
    echo "iptables rules backed up to iptables_bckp"
else
    echo "iptables backup already exists. Skipping backup."
fi