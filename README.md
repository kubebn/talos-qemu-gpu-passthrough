# Talos QEMU GPU Passthrough Toolkit

This repository provides a set of scripts and utilities to automate the setup and management of virtual machines running [Talos Linux](https://www.talos.dev/) with QEMU/KVM, supporting both CPU-only and GPU passthrough nodes. It is designed for on-premise environments where you need to run Talos clusters with advanced features such as NVIDIA GPU passthrough, IOMMU configuration, and VFIO driver management.

The toolkit simplifies the process of preparing host machines, configuring kernel parameters, managing PCI devices, and launching Talos VMs with the required hardware access. It also includes scripts for cleaning up configurations, reverting changes, and verifying system status.

Typical use cases include:
- Building custom Talos images with NVIDIA drivers and Fabric Manager
- Setting up CPU or GPU nodes for Talos clusters in QEMU/KVM environments
- Automating IOMMU and VFIO configuration for GPU passthrough
- Verifying and troubleshooting virtualization and passthrough setups

> **Note:** These scripts are intended for users familiar with Linux virtualization, kernel parameters, and Talos cluster management.

---

## Scripts

### CPU Node

- [cpu-node.sh](cpu-node.sh) - install virtualization, networking and img toolings for CPU node. Backup existing iptables on the host.

### GPU Node

- [enable-iommu.sh](enable-iommu.sh) - enables IOMMU groups on the host via modifying the kernel parameter based on CPU model.

- [devices-lspci.py](devices-lspci.py) - gather host information about PCI devices related to GPU cards and their IOMMU groups. Creates lspci.txt file with devices list, this list is in use by [gpu-node](gpu-node.sh) & [start.sh](start.sh) scripts.

- [gpu-node](gpu-node.sh) - install virtualization, networking, img toolings, VFIO drivers, hugepages, kernel parameters and ROM dumps for GPU nodes. Backup existing iptables on the host. **Reboots the node.**


### Start / clean virtual machine

- [start.sh](start.sh) - prepares the host machine bridged networking & dns, calculates cpu and memory/hugepages, setup ovmf if supported, start qemu vm. **(Should have pre-built talos image and worker-*.yaml Talos machine configuration before running the script)**

- [clean.sh](clean.sh) - cleans everything, including all existing iptables on the host therefore, if you need to restore iptables you can do it from the backup `sudo iptables-restore < iptables_bckp`. Disks for vms are not deleted, you can overwrite them using `--disk_force` true variable.

### Revert the host machine back to NVIDIA drivers

- [revert.sh](revert.sh) - reverts grub & vfio back to NVIDIA drivers on the host. **Reboots the node.**


## Check scripts

- [vfio-check.sh](checks/vfio-check.sh) - this can be run after reboot to confirm that vfio-pci drivers are in use on GPU node.

- [vfio-check-full.py](checks/vfio-check-full.py) - full analysis of PCI devices attached to vfio-pci driver after the kernel params are added and changes are applied.

- [iommu-check.sh](checks/iommu-check.sh) - check if IOMMU is enabled on the node after reboot.


# Build image talos script

- [build-image-talos.sh](https://github.com/kubebn/talos-packer-custom-nvidia/blob/main/scripts/06-talos-image-builder.sh) - build the Talos image with locally cached images. The Fabric Manager can be added if supported on the host machine.

---

## Script usage example

```bash

## Build script

./build-image-talos.sh --fabric true --gpu true --talos_version v1.9.5 --cp false # build talos image with nvidia drivers + fabric manager driver.

## Talosctl version is very important here because we are not going to specify it version at the Talos installation process, images will be pulled from local cache on the disk.

---

./start.sh --gpu false --disk-force true --fabric false --ip 10.2.1.10 # create CPU on-premise node and add it to the cluster.

./start.sh --gpu true --disk-force true --fabric true --ip 10.2.1.11 # Add gpu node with fabric manager added.

## --disk-force true - everything on Talos should be ephemeral therefore, we overwrite qemu vm disk every time we create a new node

## --fabric flag is added for OVMF/UEFI compatability. Might be deleted in the future cause drivers are added at the image build stage anyways.

```