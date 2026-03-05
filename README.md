# Talos QEMU GPU Passthrough Toolkit

Deploy Talos Linux Kubernetes worker nodes as QEMU/KVM VMs on bare metal with full NVIDIA GPU passthrough (VFIO). Designed for HPE Cray XD670 nodes with H200 SXM GPUs, NVSwitch, InfiniBand, and NVMe drives.

Control plane nodes are provisioned separately (via Terraform in AWS). This toolkit handles the **bare metal worker nodes** only.

---

## Architecture

```
┌─────────────────────────────────────────────┐
│  AWS                                        │
│  ┌───────────────────────────────────────┐  │
│  │  Talos Control Plane (Terraform)      │  │
│  │  cp-1, cp-2, cp-3 (t4g.medium ARM)   │  │
│  └──────────────┬────────────────────────┘  │
│                 │ KubeSpan (WireGuard)       │
└─────────────────┼───────────────────────────┘
                  │
   ┌──────────────┼──────────────┐
   │              │              │
┌──┴───────┐ ┌───┴──────┐ ┌────┴─────┐
│ H200     │ │ H200     │ │ H200     │   x6 nodes
│ Host     │ │ Host     │ │ Host     │
│ ┌──────┐ │ │ ┌──────┐ │ │ ┌──────┐ │
│ │ QEMU │ │ │ │ QEMU │ │ │ │ QEMU │ │
│ │ Talos│ │ │ │ Talos│ │ │ │ Talos│ │
│ │Worker│ │ │ │Worker│ │ │ │Worker│ │
│ │8xH200│ │ │ │8xH200│ │ │ │8xH200│ │
│ │4xNVSw│ │ │ │4xNVSw│ │ │ │4xNVSw│ │
│ │8xIB  │ │ │ │8xIB  │ │ │ │8xIB  │ │
│ │8xNVMe│ │ │ │8xNVMe│ │ │ │8xNVMe│ │
│ └──────┘ │ │ └──────┘ │ │ └──────┘ │
└──────────┘ └──────────┘ └──────────┘
```

Each bare metal host runs one QEMU VM containing a Talos Linux worker. All GPUs, NVSwitches, InfiniBand NICs, Ethernet NICs, PCIe switches, and NVMe drives are passed through via VFIO. Workers join the cluster over KubeSpan (port 51820 UDP forwarded from host to VM).

---

## Repository Structure

```
.
├── start.sh                  # Launch QEMU VM with full device passthrough + NUMA
├── clean.sh                  # Graceful shutdown, unbind all VFIO devices
├── pin-vcpus.sh              # Pin vCPU threads to physical CPUs (NUMA-aware)
├── gpu-node.sh               # One-time host setup (hugepages, IOMMU, VFIO, ROM check)
├── cpu-node.sh               # Host setup for CPU-only VMs
├── enable-iommu.sh           # Enable IOMMU in GRUB (one-time, requires reboot)
├── revert.sh                 # Restore host to original state
├── pci-passthrough.py        # Scan PCI + NVMe devices, generate lspci.txt
│
├── checks/
│   ├── iommu-check.sh        # Verify IOMMU is enabled
│   ├── vfio-check.sh         # Verify vfio-pci driver is loaded
│   └── vfio-check-full.py    # Full PCI/VFIO/IOMMU analysis
│
├── systemd/
│   ├── talos-qemu@.service   # Systemd template unit for auto-start
│   ├── install-service.sh    # Install helper
│   └── example.conf          # Example instance config
│
└── ansible/                  # Multi-node deployment (see ansible/README.md)
    ├── README.md             # Detailed Ansible usage guide
    ├── pre-migrate.yml       # Pre-migration for existing k3s/Nomad nodes
    ├── inventory/hosts.yml   # 6 H200 nodes with per-node IPs
    ├── group_vars/all.yml    # Shared config (NUMA, network, packages)
    ├── configs/              # Place Terraform-generated worker YAMLs here
    ├── roles/
    │   ├── common/           # Packages, sysctl, iptables backup
    │   ├── iommu/            # IOMMU enablement + reboot handler
    │   ├── vfio/             # Hugepages, VFIO, PCI scanning, pcie_aspm=off
    │   ├── talos-config/     # Worker config + per-node network patches
    │   ├── qemu-vm/          # Systemd service + per-node instance config
    │   └── pre-migrate/      # k3s/Nomad/CephFS teardown
    └── playbooks/
        ├── setup.yml         # Full setup (packages → IOMMU → VFIO → configs → systemd)
        ├── start.yml         # Start VMs
        ├── stop.yml          # Graceful stop
        └── revert.yml        # Full teardown
```

---

## Runtime GPU Passthrough

GPU binding happens **at runtime** when the VM starts, not at boot:

1. **One-time setup** (single reboot): `gpu-node.sh` configures IOMMU, hugepages, and `pcie_aspm=off` in GRUB
2. **VM start** (no reboot): `start.sh` unbinds devices from their drivers and binds to vfio-pci using `driver_override`
3. **VM stop** (no reboot): `clean.sh` unbinds from vfio-pci, clears `driver_override`, reprobes original drivers

The nvidia driver is **not blacklisted**. Devices can be freely toggled between host use and VM passthrough without rebooting.

---

## Device Passthrough

`pci-passthrough.py` scans the host and generates `lspci.txt` with categorized device addresses:

| Category | H200 per node | Detection method |
|----------|---------------|------------------|
| GPUs | 8x H200 SXM | nvidia driver / NVIDIA vendor ID |
| NVSwitches | 4x NV18 | nvidia-nvswitch driver |
| InfiniBand NICs | 8x ConnectX-7 | "InfiniBand" device type |
| Ethernet NICs | 4x ConnectX-7 | Mellanox vendor ID + "Ethernet" type |
| PCIe Switches | 1x Microsemi | switchtec driver |
| NVMe Drives | 8x 3.5TB | `/sys/class/nvme/` size filtering (>= 3TB) |

NVMe detection uses **size-based filtering** (not device IDs) to avoid accidentally grabbing the 894GB RAID1 boot drives, which share the same vendor:device ID.

---

## Quick Start (Single Host)

### 1. Prepare the host

```bash
# Enable IOMMU (one-time, reboots)
sudo ./enable-iommu.sh

# After reboot: scan PCI devices
python3 pci-passthrough.py

# Configure hugepages, VFIO, GRUB (may reboot for GRUB changes)
sudo ./gpu-node.sh
```

### 2. Dry-run

```bash
./start.sh --ip 192.168.100.2 --gpu true --fabric true --hostname io-worker-1 --dry-run
```

Review the QEMU command: check NUMA backends, `-smp` topology, all `-device vfio-pci` entries.

### 3. Start the VM

```bash
./start.sh --ip 192.168.100.2 --gpu true --fabric true --hostname io-worker-1
```

### 4. Verify

```bash
# Console output
tail -f .worker/qemu-worker-vm-console.log

# Inside VM (via talosctl)
talosctl -n 192.168.100.2 get links | grep bond
talosctl -n 192.168.100.2 dmesg | grep -i nvidia
```

### 5. Stop

```bash
./clean.sh

# Verify GPUs returned to nvidia driver
lspci -k | grep -A2 "3D controller"
```

---

## start.sh

Launches a QEMU VM with full H200 passthrough and NUMA topology.

| Flag | Default | Description |
|------|---------|-------------|
| `--ip` | (required) | VM IP address |
| `--gpu` | `false` | Enable GPU/device passthrough |
| `--disk-force` | `true` | Overwrite existing VM disk |
| `--fabric` | `false` | NVSwitch Fabric Manager support |
| `--hostname` | auto-generated | VM hostname (e.g., `io-worker-1`) |
| `--dry-run` | `false` | Print QEMU command without executing |

**What it does:**
1. Creates bridge (`br0`) and TAP (`workertap`) interfaces
2. Starts dnsmasq for DHCP/DNS
3. Configures iptables NAT/forwarding + KubeSpan port forwarding (51820 UDP)
4. Copies and resizes Talos disk image
5. **GPU nodes:** Binds all passthrough devices to vfio-pci at runtime via `driver_override`
6. Builds QEMU command with:
   - NUMA topology: per-node memory backends with hugepages, bound to physical NUMA nodes
   - CPU: `-smp` with sockets/cores/threads matching host, `-cpu host,+x2apic,+invtsc`
   - Machine: `kernel_irqchip=split`, `mem-lock=on`
   - All device categories as `-device vfio-pci,host=...`
7. Launches QEMU in daemon mode
8. Pins vCPU threads to physical CPUs (NUMA-aware) via `pin-vcpus.sh`

---

## clean.sh

Gracefully stops the VM and restores all devices:

1. Sends `system_powerdown` via QEMU monitor socket (30s timeout, then force kill)
2. Stops our dnsmasq instance
3. Unbinds all passthrough devices from vfio-pci, clears `driver_override`, reprobes original drivers
4. Removes iptables rules (only the ones `start.sh` added)
5. Removes bridge and TAP interfaces

---

## pin-vcpus.sh

Pins QEMU vCPU threads to physical CPUs for optimal NUMA locality:

- Skips first N CPUs from NUMA 0 (reserved for host, default: 4)
- Maps each vCPU thread to a corresponding physical CPU
- Pins I/O threads to the reserved host CPUs

```bash
# Called automatically by start.sh, or run manually:
./pin-vcpus.sh 4   # reserve 4 CPUs for host
```

---

## Systemd Service

Auto-start VMs after host reboots.

```bash
# Install manually
./systemd/install-service.sh io-worker-1 --ip 192.168.100.2 --gpu true --fabric true

# Or via Ansible (setup.yml handles this automatically)
```

Instance config at `/etc/talos-qemu/<name>.conf`:
```ini
WORKING_DIR=/opt/talos-qemu-gpu-passthrough
VM_IP=192.168.100.2
GPU_PASSTHROUGH=true
FABRIC=true
VM_HOSTNAME=io-worker-1
```

```bash
sudo systemctl start talos-qemu@io-worker-1
sudo systemctl stop talos-qemu@io-worker-1
sudo systemctl status talos-qemu@io-worker-1
journalctl -u talos-qemu@io-worker-1 -f
```

---

## Ansible Multi-Node Deployment

See **[ansible/README.md](ansible/README.md)** for the full Ansible usage guide covering:

- Manual testing before running playbooks
- Pre-migration for existing k3s/Nomad nodes
- Deploying to a single node vs. all nodes
- Per-node network patches (bonds, IPs, hostnames)
- Ad-hoc commands and troubleshooting

### Quick reference

```bash
cd ansible

# Pre-migrate existing node (k3s/Nomad teardown)
ansible-playbook -i inventory/hosts.yml pre-migrate.yml --limit h200-node-4

# Setup one node
ansible-playbook -i inventory/hosts.yml playbooks/setup.yml --limit h200-node-4

# Start VM
ansible-playbook -i inventory/hosts.yml playbooks/start.yml --limit h200-node-4

# Stop VM
ansible-playbook -i inventory/hosts.yml playbooks/stop.yml --limit h200-node-4

# Full teardown
ansible-playbook -i inventory/hosts.yml playbooks/revert.yml --limit h200-node-4
```

---

## Node Inventory

| Host | Public IP | Intranet | Storage | Hostname |
|------|-----------|----------|---------|----------|
| h200-node-1 | 213.181.104.150 | 10.2.1.12 | 10.3.1.12 | io-worker-1 |
| h200-node-2 | 213.181.104.151 | 10.2.1.13 | 10.3.1.13 | io-worker-2 |
| h200-node-3 | 213.181.104.152 | 10.2.1.14 | 10.3.1.14 | io-worker-3 |
| h200-node-4 | 213.181.104.157 | 10.2.1.17 | 10.3.1.17 | io-worker-4 |
| h200-node-5 | 213.181.104.158 | 10.2.1.18 | 10.3.1.18 | io-worker-5 |
| h200-node-6 | 213.181.104.162 | 10.2.1.26 | 10.3.1.26 | io-worker-6 |

---

## Hardware (per H200 node)

- HPE Cray XD670
- 2x Intel Xeon 8558 (192 logical CPUs, 4 NUMA nodes)
- 2TB RAM
- 8x NVIDIA H200 SXM (141GB HBM3e each)
- 4x NVSwitch NV18 (full mesh)
- 8x ConnectX-7 400Gbps InfiniBand
- 4x ConnectX-7 Ethernet
- 8x 3.5TB NVMe (data, passed through to VM)
- 2x 894GB NVMe (RAID1 host boot, NOT passed through)

---

## Troubleshooting

| Issue | Check |
|-------|-------|
| VM won't start | `cat .worker/qemu-worker-vm-console.log` |
| VFIO bind fails | `dmesg \| grep vfio` and `find /sys/kernel/iommu_groups/ -type l` |
| No hugepages | `grep HugePages /proc/meminfo` and `cat /proc/cmdline` |
| GPU not visible in VM | `lspci -k \| grep vfio-pci` on host (GPUs should show vfio-pci driver) |
| NVMe not detected | `python3 pci-passthrough.py` then `cat lspci.txt \| grep -A5 NVMe` |
| Network patch wrong | Check `.iso/config.yaml` on host, `talosctl validate -m cloud -c .iso/config.yaml` |
| clean.sh didn't restore | `lspci -k \| grep -A2 "3D controller"` should show `nvidia` not `vfio-pci` |
| KubeSpan not connecting | Check port 51820 forwarding: `iptables -t nat -L PREROUTING -n` |
