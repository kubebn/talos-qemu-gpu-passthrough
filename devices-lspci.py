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

def find_gpu_devices(devices):
    """Find GPU devices and check their IOMMU groups."""
    gpu_devices = [
        d for d in devices
        if (d.get("kernel_driver") in ["nvidia", "nvidia-nvswitch"] or d.get("is_nvidia_subsystem"))
        and d.get("kernel_driver") != "pcieport"
    ]
    iommu_groups = defaultdict(list)

    # Group devices by IOMMU group
    for device in devices:
        if device.get("iommu_group") is not None:
            iommu_groups[device["iommu_group"]].append(device)

    # Check for other devices in the same IOMMU group
    for gpu in gpu_devices:
        iommu_group = gpu["iommu_group"]
        if iommu_group is not None:
            other_devices = [
                d for d in iommu_groups[iommu_group]
                if d["pci_address"] != gpu["pci_address"] and d.get("kernel_driver") != "pcieport"
            ]
            gpu["other_devices_in_group"] = other_devices

    return gpu_devices

def collect_all_vendor_ids(gpu_devices):
    """Collect all unique vendor IDs from the GPU devices and their related devices."""
    all_vendor_ids = set()
    
    for gpu in gpu_devices:
        # Add vendor IDs from the GPU itself
        for vendor_id in gpu.get("vendor_ids", []):
            all_vendor_ids.add(vendor_id)
        
        # Add vendor IDs from other devices in the same IOMMU group
        for other_device in gpu.get("other_devices_in_group", []):
            for vendor_id in other_device.get("vendor_ids", []):
                all_vendor_ids.add(vendor_id)
    
    return sorted(list(all_vendor_ids))

def format_pci_address(address):
    """Add 0000: prefix to PCI address if not already present."""
    if address.startswith("0000:"):
        return address
    return f"0000:{address}"

def find_audio_devices(devices):
    """Find Audio devices and check their IOMMU groups."""
    audio_devices = [
        d for d in devices
        if d.get("kernel_driver") and "snd_hda" in d.get("kernel_driver")
    ]
    return audio_devices

def main():
    lspci_output = get_lspci_output()
    if not lspci_output:
        print("Failed to retrieve lspci output.")
        return

    devices = parse_lspci_output(lspci_output)
    gpu_devices = find_gpu_devices(devices)
    audio_devices = find_audio_devices(devices)

    # Open gather.txt for writing
    with open("gather.txt", "w") as gather_file:
        # Redirect output to both console and file
        def write_and_print(line):
            print(line)
            gather_file.write(line + "\n")

        for gpu in gpu_devices:
            write_and_print(f"GPU Device: {gpu['pci_address']}")
            if gpu["vendor_ids"]:
                write_and_print(f"  Vendor ID: {', '.join(gpu['vendor_ids'])}")
            else:
                write_and_print("  Vendor ID: Unknown")
            write_and_print(f"  IOMMU Group: {gpu['iommu_group']}")
            write_and_print(f"  Kernel Driver: {gpu['kernel_driver']}")
            if gpu.get("is_nvidia_subsystem"):
                write_and_print(f"  Subsystem: NVIDIA")
            if "other_devices_in_group" in gpu:
                write_and_print("  Other devices in the same IOMMU group:")
                for other in gpu["other_devices_in_group"]:
                    write_and_print(f"    - PCI Address: {other['pci_address']}")
                    if other.get("vendor_ids"):
                        write_and_print(f"      Vendor ID: {', '.join(other['vendor_ids'])}")
                    else:
                        write_and_print("      Vendor ID: Unknown")
                    write_and_print(f"      Kernel Driver: {other.get('kernel_driver')}")
            write_and_print("")
        
        # Collect and print all unique vendor IDs for vfio-pci.ids
        all_vendor_ids = collect_all_vendor_ids(gpu_devices)
        if all_vendor_ids:
            vfio_ids_string = ",".join(all_vendor_ids)
            write_and_print(f"vfio-pci.ids={vfio_ids_string}")
            write_and_print("")
        
        # Print all GPU device addresses with 0000: prefix in column format
        write_and_print("All GPU Device Addresses (Column Format):")
        for gpu in gpu_devices:
            formatted_address = format_pci_address(gpu['pci_address'])
            write_and_print(formatted_address)
        write_and_print("")
        
        # Print all GPU device addresses with 0000: prefix in line format
        write_and_print("All GPU Device Addresses (Line Format):")
        formatted_addresses = [format_pci_address(gpu['pci_address']) for gpu in gpu_devices]
        write_and_print(" ".join(formatted_addresses))
        write_and_print("")
        
        # Print only GPU cards with nvidia driver
        write_and_print("NVIDIA GPU Cards (nvidia driver only):")
        nvidia_gpus = [gpu for gpu in gpu_devices if gpu.get('kernel_driver') in ('nvidia', 'nouveau')]
        for gpu in nvidia_gpus:
            formatted_address = format_pci_address(gpu['pci_address'])
            write_and_print(formatted_address)
        write_and_print("")

        write_and_print("Audio Devices:")
        for audio in audio_devices:
            formatted_address = format_pci_address(audio['pci_address'])
            write_and_print(formatted_address)
        write_and_print("")

    with open("lspci.txt", "w") as file:
        # Collect and write all unique vendor IDs for vfio-pci.ids
        all_vendor_ids = collect_all_vendor_ids(gpu_devices)
        file.write("=== vfio-pci.ids ===\n")
        if all_vendor_ids:
            vfio_ids_string = ",".join(all_vendor_ids)
            file.write(f"{vfio_ids_string}\n")

        # Write all GPU device addresses with 0000: prefix in column format
        file.write("=== All GPU Device Addresses (Column Format) ===\n")
        for gpu in gpu_devices:
            formatted_address = format_pci_address(gpu['pci_address'])
            file.write(f"{formatted_address}\n")

        # Write all GPU device addresses with 0000: prefix in line format
        file.write("=== All GPU Device Addresses (Line Format) ===\n")
        formatted_addresses = [format_pci_address(gpu['pci_address']) for gpu in gpu_devices]
        file.write(" ".join(formatted_addresses) + "\n")

        # Write only GPU cards with nvidia driver
        file.write("=== NVIDIA GPU Cards (nvidia driver only) ===\n")
        nvidia_gpus = [gpu for gpu in gpu_devices if gpu.get('kernel_driver') in ('nvidia', 'nouveau')]
        for gpu in nvidia_gpus:
            formatted_address = format_pci_address(gpu['pci_address'])
            file.write(f"{formatted_address}\n")

        file.write("=== Audio Devices ===\n")
        audio_devices = find_audio_devices(devices)
        for audio in audio_devices:
            formatted_address = format_pci_address(audio['pci_address'])
            file.write(f"{formatted_address}\n")  
        
if __name__ == "__main__":
    main()