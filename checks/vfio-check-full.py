#!/usr/bin/env python3
import subprocess
import re
from collections import defaultdict

def get_lspci_output():
    """Run lspci with numeric, verbose, and kernel driver information and return the result."""
    try:
        result = subprocess.run(['lspci', '-nnkv'], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, check=True)
        return result.stdout
    except subprocess.CalledProcessError as e:
        print(f"Error running lspci: {e}")
        return ""

def parse_lspci_output(output):
    """Parse lspci output to find devices and their IOMMU groups."""
    devices = []
    current_device = {}
    iommu_group_pattern = re.compile(r"IOMMU group (\d+)")
    kernel_driver_pattern = re.compile(r"Kernel driver in use: (\S+)")
    subsystem_pattern = re.compile(r"Subsystem: NVIDIA")
    pci_address_pattern = re.compile(r"^([0-9a-fA-F:.]+)")
    vendor_id_pattern = re.compile(r"\[([0-9a-fA-F]{4}:[0-9a-fA-F]{4})\]")  # Pattern to match vendor IDs

    for line in output.splitlines():
        if pci_address_match := pci_address_pattern.match(line):
            # Save the previous device if it exists
            if current_device:
                devices.append(current_device)
            # Start a new device entry
            current_device = {
                "pci_address": pci_address_match.group(1),
                "iommu_group": None,
                "kernel_driver": None,
                "is_nvidia_subsystem": False,
                "vendor_ids": [],  # Store all vendor IDs
                "raw_lines": [line]
            }
            # Check for vendor ID in the first line
            if vendor_id_match := vendor_id_pattern.search(line):
                current_device["vendor_ids"].append(vendor_id_match.group(1))
        elif current_device:
            current_device["raw_lines"].append(line)
            if iommu_group_match := iommu_group_pattern.search(line):
                current_device["iommu_group"] = int(iommu_group_match.group(1))
            if kernel_driver_match := kernel_driver_pattern.search(line):
                current_device["kernel_driver"] = kernel_driver_match.group(1)
            if subsystem_pattern.search(line):
                current_device["is_nvidia_subsystem"] = True
            if vendor_id_match := vendor_id_pattern.search(line):
                vendor_id = vendor_id_match.group(1)
                if vendor_id not in current_device["vendor_ids"]:
                    current_device["vendor_ids"].append(vendor_id)

    # Append the last device if it exists
    if current_device:
        devices.append(current_device)

    return devices

def find_nvidia_related_devices(devices):
    """Find NVIDIA GPU devices and related devices in the same IOMMU groups."""
    nvidia_devices = [
        d for d in devices
        if d.get("is_nvidia_subsystem") or (d.get("kernel_driver") and "nvidia" in d.get("kernel_driver"))
    ]
    iommu_groups = defaultdict(list)

    # Group devices by IOMMU group
    for device in devices:
        if device.get("iommu_group") is not None:
            iommu_groups[device["iommu_group"]].append(device)

    # Check for other devices in the same IOMMU group
    for nvidia_device in nvidia_devices:
        iommu_group = nvidia_device["iommu_group"]
        if iommu_group is not None:
            other_devices = [
                d for d in iommu_groups[iommu_group]
                if d["pci_address"] != nvidia_device["pci_address"]
            ]
            nvidia_device["other_devices_in_group"] = other_devices

    return nvidia_devices

def report_non_vfio_devices_in_gpu_groups(nvidia_devices):
    """Report devices in IOMMU groups of NVIDIA GPUs where the kernel driver is not pcieport or vfio-pci."""
    for gpu_device in nvidia_devices:
        iommu_group = gpu_device.get("iommu_group")
        if not iommu_group:
            continue

        other_devices = gpu_device.get("other_devices_in_group", [])
        problematic_devices = [
            d for d in other_devices
            if d["kernel_driver"] not in ["pcieport", "vfio-pci"]
        ]

        if problematic_devices:
            print(f"Problematic devices in IOMMU group {iommu_group} (related to GPU {gpu_device['pci_address']}):")
            for device in problematic_devices:
                print(f"  PCI Address: {device['pci_address']}")
                print(f"  Vendor ID: {', '.join(device['vendor_ids'])}")
                print(f"  Kernel Driver: {device['kernel_driver']}")
            print()

def main():
    lspci_output = get_lspci_output()
    if not lspci_output:
        print("Failed to retrieve lspci output.")
        return

    devices = parse_lspci_output(lspci_output)
    nvidia_devices = find_nvidia_related_devices(devices)

    for device in nvidia_devices:
        print(f"GPU Device: {device['pci_address']}")
        if device["vendor_ids"]:
            print(f"  Vendor ID: {', '.join(device['vendor_ids'])}")
        else:
            print("  Vendor ID: Unknown")
        print(f"  IOMMU Group: {device['iommu_group']}")
        print(f"  Kernel Driver: {device['kernel_driver']}")
        if device.get("is_nvidia_subsystem"):
            print(f"  Subsystem: NVIDIA")
        if "other_devices_in_group" in device:
            print("  Other devices in the same IOMMU group:")
            for other in device["other_devices_in_group"]:
                print(f"    - PCI Address: {other['pci_address']}")
                if other.get("vendor_ids"):
                    print(f"      Vendor ID: {', '.join(other['vendor_ids'])}")
                else:
                    print("      Vendor ID: Unknown")
                print(f"      Kernel Driver: {other.get('kernel_driver')}")
        print()

    # Report problematic devices in GPU-related IOMMU groups
    report_non_vfio_devices_in_gpu_groups(nvidia_devices)

if __name__ == "__main__":
    main()