#!/bin/bash
set -o nounset -o pipefail

# Remove the initramfs vfio.sh script if it exists (from legacy setup)
if [ -f /etc/initramfs-tools/scripts/init-top/vfio.sh ]; then
    sudo rm /etc/initramfs-tools/scripts/init-top/vfio.sh
    echo "Removed initramfs vfio.sh."
fi

# Remove the vfio.conf modprobe file if it exists (from legacy setup)
if [ -f /etc/modprobe.d/vfio.conf ]; then
    sudo rm /etc/modprobe.d/vfio.conf
    echo "Removed vfio.conf."
fi

# Restore the original GRUB configuration from the backup
if [ -f /etc/default/grub.backup ]; then
    sudo cp /etc/default/grub.backup /etc/default/grub
    sudo update-grub
    echo "GRUB configuration restored from backup."
else
    echo "Warning: No GRUB backup found at /etc/default/grub.backup"
fi

# Regenerate the initramfs to reflect the changes
sudo update-initramfs -u -k all

# Restore iptables from backup
if [ -f iptables_bckp ]; then
    sudo iptables-restore < iptables_bckp
    echo "iptables restored from backup."
else
    echo "Warning: No iptables backup found."
fi

echo ""
echo "Revert complete. A reboot is required to apply all changes."
read -p "Reboot now? [y/N] " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    sudo reboot
fi
