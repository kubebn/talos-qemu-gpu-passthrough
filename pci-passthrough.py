#!/usr/bin/env python3
import subprocess
import re
from collections import defaultdict

def get_lspci_output():
    """Run lspci with numeric, verbose, and kernel driver information and return the result."""
    try:
        result = subprocess.run(["lspci", "-nnkv"], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, check=True)
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
    subsystem_nvidia_pattern = re.compile(r"Subsystem: NVIDIA")
    subsystem_mellanox_pattern = re.compile(r"Subsystem: Mellanox")
    pci_address_pattern = re.compile(r"^([0-9a-fA-F:.]+)")
    vendor_id_pattern = re.compile(r"\[([0-9a-fA-F]{4}:[0-9a-fA-F]{4})\]")
    device_type_pattern = re.compile(r"^[0-9a-fA-F:.]+\s+([^:]+):")

    for line in output.splitlines():
        if pci_address_match := pci_address_pattern.match(line):
            if current_device:
                devices.append(current_device)
            current_device = {
                "pci_address": pci_address_match.group(1),
                "iommu_group": None,
                "kernel_driver": None,
                "is_nvidia_subsystem": False,
                "is_mellanox_subsystem": False,
                "device_type": "",
                "vendor_ids": [],
                "raw_lines": [line]
            }
            if vendor_id_match := vendor_id_pattern.search(line):
                current_device["vendor_ids"].append(vendor_id_match.group(1))
            if device_type_match := device_type_pattern.match(line):
                current_device["device_type"] = device_type_match.group(1).strip()
        elif current_device:
            current_device["raw_lines"].append(line)
            if iommu_group_match := iommu_group_pattern.search(line):
                current_device["iommu_group"] = int(iommu_group_match.group(1))
            if kernel_driver_match := kernel_driver_pattern.search(line):
                current_device["kernel_driver"] = kernel_driver_match.group(1)
            if subsystem_nvidia_pattern.search(line):
                current_device["is_nvidia_subsystem"] = True
            if subsystem_mellanox_pattern.search(line):
                current_device["is_mellanox_subsystem"] = True
            if vendor_id_match := vendor_id_pattern.search(line):
                vendor_id = vendor_id_match.group(1)
                if vendor_id not in current_device["vendor_ids"]:
                    current_device["vendor_ids"].append(vendor_id)

    if current_device:
        devices.append(current_device)

    return devices

def find_passthrough_devices(devices):
    """Find all devices suitable for GPU passthrough (NVIDIA + Mellanox)."""
    passthrough_devices = [
        d for d in devices
        if (
            d.get("kernel_driver") in ["nvidia", "nvidia-nvswitch", "mlx5_core", "switchtec"]
            or d.get("is_nvidia_subsystem")
            or d.get("is_mellanox_subsystem")
            or any(vid.startswith("10de:") for vid in d.get("vendor_ids", []))  # NVIDIA
            or any(vid.startswith("15b3:") for vid in d.get("vendor_ids", []))  # Mellanox
        )
        and d.get("kernel_driver") != "pcieport"
    ]
    
    iommu_groups = defaultdict(list)
    for device in devices:
        if device.get("iommu_group") is not None:
            iommu_groups[device["iommu_group"]].append(device)

    for dev in passthrough_devices:
        iommu_group = dev["iommu_group"]
        if iommu_group is not None:
            other_devices = [
                d for d in iommu_groups[iommu_group]
                if d["pci_address"] != dev["pci_address"] and d.get("kernel_driver") != "pcieport"
            ]
            dev["other_devices_in_group"] = other_devices

    return passthrough_devices

def categorize_devices(devices):
    """Categorize devices by type."""
    categories = {
        "gpus": [],
        "nvswitches": [],
        "infiniband": [],
        "ethernet": [],
        "switches": [],
        "other": []
    }
    
    for d in devices:
        driver = d.get("kernel_driver", "")
        dev_type = d.get("device_type", "").lower()
        vendor_ids = d.get("vendor_ids", [])
        
        if driver == "nvidia" or (any("10de:2335" in v or "10de:2330" in v or "10de:2336" in v or "10de:2322" in v or "10de:2324" in v for v in vendor_ids) and "3D controller" in d.get("device_type", "")):
            categories["gpus"].append(d)
        elif driver == "nvidia-nvswitch" or any("10de:22a3" in v for v in vendor_ids):
            categories["nvswitches"].append(d)
        elif "infiniband" in dev_type:
            categories["infiniband"].append(d)
        elif "ethernet" in dev_type and any(v.startswith("15b3:") for v in vendor_ids):
            categories["ethernet"].append(d)
        elif driver == "switchtec":
            categories["switches"].append(d)
        else:
            categories["other"].append(d)
    
    return categories

def collect_all_vendor_ids(devices):
    """Collect all unique vendor IDs from devices."""
    all_vendor_ids = set()
    for dev in devices:
        for vendor_id in dev.get("vendor_ids", []):
            all_vendor_ids.add(vendor_id)
        for other_device in dev.get("other_devices_in_group", []):
            for vendor_id in other_device.get("vendor_ids", []):
                all_vendor_ids.add(vendor_id)
    return sorted(list(all_vendor_ids))

def format_pci_address(address):
    """Add 0000: prefix to PCI address if not already present."""
    if address.startswith("0000:"):
        return address
    return f"0000:{address}"

def find_audio_devices(devices):
    """Find Audio devices."""
    return [d for d in devices if d.get("kernel_driver") and "snd_hda" in d.get("kernel_driver")]

def find_nvme_drives():
    """Find NVMe drives suitable for passthrough (>= 3.0 TB)."""
    import os
    nvme_drives = []
    nvme_base = "/sys/class/nvme"
    if not os.path.isdir(nvme_base):
        return nvme_drives
    for ctrl in sorted(os.listdir(nvme_base)):
        ctrl_path = os.path.join(nvme_base, ctrl)
        ns_path = os.path.join(ctrl_path, f"{ctrl}n1", "size")
        if not os.path.isfile(ns_path):
            continue
        try:
            with open(ns_path) as f:
                sectors = int(f.read().strip())
            size_tb = (sectors * 512) / (1024 ** 4)
        except (ValueError, IOError):
            continue
        if size_tb < 3.0:
            continue
        device_link = os.path.join(ctrl_path, "device")
        try:
            target = os.readlink(device_link)
            pci_address = target.split("/")[-1]
        except OSError:
            continue
        nvme_drives.append({"pci_address": pci_address, "size_tb": size_tb})
    return nvme_drives

def main():
    lspci_output = get_lspci_output()
    if not lspci_output:
        print("Failed to retrieve lspci output.")
        return

    devices = parse_lspci_output(lspci_output)
    passthrough_devices = find_passthrough_devices(devices)
    categories = categorize_devices(passthrough_devices)
    audio_devices = find_audio_devices(devices)
    nvme_drives = find_nvme_drives()

    with open("gather.txt", "w") as gather_file:
        def write_and_print(line):
            print(line)
            gather_file.write(line + "\n")

        # GPUs
        write_and_print("=" * 60)
        write_and_print("NVIDIA GPUs")
        write_and_print("=" * 60)
        for dev in categories["gpus"]:
            addr = dev["pci_address"]
            write_and_print(f"GPU: {addr}")
            write_and_print(f"  Vendor ID: {', '.join(dev['vendor_ids'])}")
            write_and_print(f"  IOMMU Group: {dev['iommu_group']}")
            write_and_print(f"  Kernel Driver: {dev['kernel_driver']}")
            if dev.get("other_devices_in_group"):
                write_and_print("  Other devices in IOMMU group:")
                for other in dev["other_devices_in_group"]:
                    write_and_print(f"    - {other['pci_address']} ({other.get('kernel_driver', 'none')})")
            write_and_print("")

        # NVSwitches
        write_and_print("=" * 60)
        write_and_print("NVSwitches (require Fabric Manager)")
        write_and_print("=" * 60)
        for dev in categories["nvswitches"]:
            write_and_print(f"NVSwitch: {dev['pci_address']}")
            write_and_print(f"  Vendor ID: {', '.join(dev['vendor_ids'])}")
            write_and_print(f"  IOMMU Group: {dev['iommu_group']}")
            write_and_print(f"  Kernel Driver: {dev['kernel_driver']}")
            write_and_print("")

        # InfiniBand
        write_and_print("=" * 60)
        write_and_print("InfiniBand NICs (for multi-node training)")
        write_and_print("=" * 60)
        for dev in categories["infiniband"]:
            write_and_print(f"IB NIC: {dev['pci_address']}")
            write_and_print(f"  Vendor ID: {', '.join(dev['vendor_ids'])}")
            write_and_print(f"  IOMMU Group: {dev['iommu_group']}")
            write_and_print(f"  Kernel Driver: {dev['kernel_driver']}")
            write_and_print("")

        # Ethernet
        write_and_print("=" * 60)
        write_and_print("Ethernet NICs (for storage/management)")
        write_and_print("=" * 60)
        for dev in categories["ethernet"]:
            write_and_print(f"ETH NIC: {dev['pci_address']}")
            write_and_print(f"  Vendor ID: {', '.join(dev['vendor_ids'])}")
            write_and_print(f"  IOMMU Group: {dev['iommu_group']}")
            write_and_print(f"  Kernel Driver: {dev['kernel_driver']}")
            write_and_print("")

        # PCIe Switches
        if categories["switches"]:
            write_and_print("=" * 60)
            write_and_print("PCIe Switches")
            write_and_print("=" * 60)
            for dev in categories["switches"]:
                write_and_print(f"Switch: {dev['pci_address']}")
                write_and_print(f"  Vendor ID: {', '.join(dev['vendor_ids'])}")
                write_and_print(f"  IOMMU Group: {dev['iommu_group']}")
                write_and_print(f"  Kernel Driver: {dev['kernel_driver']}")
                write_and_print("")

        # NVMe Drives
        if nvme_drives:
            write_and_print("=" * 60)
            write_and_print("NVMe Drives (for VFIO passthrough)")
            write_and_print("=" * 60)
            for drv in nvme_drives:
                write_and_print(f"NVMe: {drv['pci_address']}")
                write_and_print(f"  Size: {drv['size_tb']:.2f} TB")
                write_and_print("")

        # Summary
        write_and_print("=" * 60)
        write_and_print("SUMMARY")
        write_and_print("=" * 60)
        write_and_print(f"Total GPUs: {len(categories['gpus'])}")
        write_and_print(f"Total NVSwitches: {len(categories['nvswitches'])}")
        write_and_print(f"Total InfiniBand NICs: {len(categories['infiniband'])}")
        write_and_print(f"Total Ethernet NICs: {len(categories['ethernet'])}")
        write_and_print(f"Total PCIe Switches: {len(categories['switches'])}")
        write_and_print(f"Total NVMe Drives: {len(nvme_drives)}")
        write_and_print("")

        # VFIO IDs
        all_vendor_ids = collect_all_vendor_ids(passthrough_devices)
        if all_vendor_ids:
            vfio_ids_string = ",".join(all_vendor_ids)
            write_and_print("=" * 60)
            write_and_print("VFIO-PCI IDs (for passthrough)")
            write_and_print("=" * 60)
            write_and_print(f"vfio-pci.ids={vfio_ids_string}")
            write_and_print("")

        # Device addresses by category
        write_and_print("=" * 60)
        write_and_print("PCI Addresses by Category")
        write_and_print("=" * 60)
        
        write_and_print("\nGPUs:")
        for dev in categories["gpus"]:
            write_and_print(f"  {format_pci_address(dev['pci_address'])}")
        
        write_and_print("\nNVSwitches:")
        for dev in categories["nvswitches"]:
            write_and_print(f"  {format_pci_address(dev['pci_address'])}")
        
        write_and_print("\nInfiniBand NICs:")
        for dev in categories["infiniband"]:
            write_and_print(f"  {format_pci_address(dev['pci_address'])}")
        
        write_and_print("\nEthernet NICs:")
        for dev in categories["ethernet"]:
            write_and_print(f"  {format_pci_address(dev['pci_address'])}")
        
        if categories["switches"]:
            write_and_print("\nPCIe Switches:")
            for dev in categories["switches"]:
                write_and_print(f"  {format_pci_address(dev['pci_address'])}")

        if nvme_drives:
            write_and_print("\nNVMe Drives:")
            for drv in nvme_drives:
                write_and_print(f"  {format_pci_address(drv['pci_address'])}")

        write_and_print("")

        # All addresses (line format)
        write_and_print("=" * 60)
        write_and_print("All Passthrough Devices (Line Format)")
        write_and_print("=" * 60)
        all_addresses = [format_pci_address(d["pci_address"]) for d in passthrough_devices]
        all_addresses += [format_pci_address(drv["pci_address"]) for drv in nvme_drives]
        write_and_print(" ".join(all_addresses))
        write_and_print("")

        # Audio devices
        if audio_devices:
            write_and_print("=" * 60)
            write_and_print("Audio Devices")
            write_and_print("=" * 60)
            for dev in audio_devices:
                write_and_print(f"  {format_pci_address(dev['pci_address'])}")
            write_and_print("")

    # Write lspci.txt (compact format)
    with open("lspci.txt", "w") as file:
        all_vendor_ids = collect_all_vendor_ids(passthrough_devices)
        file.write("=== vfio-pci.ids ===\n")
        file.write(",".join(all_vendor_ids) + "\n\n")

        file.write("=== GPUs ===\n")
        for dev in categories["gpus"]:
            file.write(f"{format_pci_address(dev['pci_address'])}\n")

        file.write("\n=== NVSwitches ===\n")
        for dev in categories["nvswitches"]:
            file.write(f"{format_pci_address(dev['pci_address'])}\n")

        file.write("\n=== InfiniBand NICs ===\n")
        for dev in categories["infiniband"]:
            file.write(f"{format_pci_address(dev['pci_address'])}\n")

        file.write("\n=== Ethernet NICs ===\n")
        for dev in categories["ethernet"]:
            file.write(f"{format_pci_address(dev['pci_address'])}\n")

        if categories["switches"]:
            file.write("\n=== PCIe Switches ===\n")
            for dev in categories["switches"]:
                file.write(f"{format_pci_address(dev['pci_address'])}\n")

        if nvme_drives:
            file.write("\n=== NVMe Drives ===\n")
            for drv in nvme_drives:
                file.write(f"{format_pci_address(drv['pci_address'])}\n")

        file.write("\n=== All Passthrough Devices (Line Format) ===\n")
        all_addresses = [format_pci_address(d["pci_address"]) for d in passthrough_devices]
        all_addresses += [format_pci_address(drv["pci_address"]) for drv in nvme_drives]
        file.write(" ".join(all_addresses) + "\n")

if __name__ == "__main__":
    main()
