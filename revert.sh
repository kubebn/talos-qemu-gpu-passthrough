# Remove the vfio.sh script used for binding devices to vfio-pci
sudo rm /etc/initramfs-tools/scripts/init-top/vfio.sh

# Remove the vfio.conf file that configures vfio module dependencies
sudo rm /etc/modprobe.d/vfio.conf

# Remove the lines from blacklist.conf
# sudo sed -i '/blacklist nouveau/d' /etc/modprobe.d/blacklist.conf
# sudo sed -i '/blacklist nvidia\*/d' /etc/modprobe.d/blacklist.conf

# Restore the original GRUB configuration from the backup
sudo cp /etc/default/grub.backup /etc/default/grub

# Update GRUB to apply the restored configuration
sudo update-grub

# Regenerate the initramfs to reflect the changes
sudo update-initramfs -u -k all

iptables-restore < iptables_bckp

# Reboot the system to apply all changes
sudo reboot