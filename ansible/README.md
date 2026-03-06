# Ansible Usage Guide

## Prerequisites

1. **SSH access** to all nodes via the Novita SSH key:
   ```bash
   ssh -i ../id_rsa_novita.txt root@213.181.104.157
   ```

2. **Worker configs** from Terraform placed in `ansible/configs/`:
   ```
   ansible/configs/worker-gpu.yaml   # GPU node Talos config
   ansible/configs/worker-cpu.yaml   # CPU node Talos config (if needed)
   ```

3. **Talos disk image** at `/opt/talos-qemu-gpu-passthrough/.build/metal-amd64.qcow2` on each node (or set `talos_image_url` in `group_vars/all.yml`).

## Node Inventory

All 6 H200 nodes are defined in `inventory/hosts.yml`:

| Host | Public IP | Intranet | Storage | Node ID |
|------|-----------|----------|---------|---------|
| h200-node-1 | 213.181.104.150 | 10.2.1.12 | 10.3.1.12 | 1 |
| h200-node-2 | 213.181.104.151 | 10.2.1.13 | 10.3.1.13 | 2 |
| h200-node-3 | 213.181.104.152 | 10.2.1.14 | 10.3.1.14 | 3 |
| h200-node-4 | 213.181.104.157 | 10.2.1.17 | 10.3.1.17 | 4 |
| h200-node-5 | 213.181.104.158 | 10.2.1.18 | 10.3.1.18 | 5 |
| h200-node-6 | 213.181.104.162 | 10.2.1.26 | 10.3.1.26 | 6 |

## Manual Testing (Before Ansible)

Test on a single node via SSH before running any playbook.

### 1. Scan PCI devices

```bash
ssh -i ../id_rsa_novita.txt root@213.181.104.157
cd /opt/talos-qemu-gpu-passthrough

# Run the PCI scanner
python3 pci-passthrough.py

# Verify output
cat lspci.txt
# Should show: GPUs, NVSwitches, InfiniBand NICs, Ethernet NICs, PCIe Switches, NVMe Drives
```

### 2. Dry-run the QEMU command

```bash
# See what QEMU command would be executed without actually starting the VM
bash start.sh --ip 192.168.100.2 --gpu true --fabric true --hostname io-worker-4 --dry-run
```

Review the output carefully. Check:
- NUMA memory backends (4 nodes, hugepages)
- `-smp` topology (sockets, cores, threads)
- All passthrough devices listed (`-device vfio-pci,host=...`)
- GPU pcie-root-port entries

### 3. Start the VM manually

```bash
bash start.sh --ip 192.168.100.2 --gpu true --fabric true --hostname io-worker-4
```

### 4. Verify the VM is running

```bash
# Check QEMU process
ps aux | grep qemu

# Watch console output
tail -f .worker/qemu-worker-vm-console.log

# Check vCPU pinning
cat .worker/qemu-worker-vm.pid
# Then check /proc/<pid>/task/*/comm for CPU threads
```

### 5. Verify inside the VM (via Talos)

```bash
# From a machine with talosctl configured
talosctl -n 192.168.100.2 get links | grep bond
talosctl -n 192.168.100.2 get addresses
talosctl -n 192.168.100.2 dmesg | grep -i nvidia
talosctl -n 192.168.100.2 dmesg | grep -i nvme
```

### 6. Clean up (stop VM, restore devices)

```bash
bash clean.sh

# Verify GPUs returned to nvidia driver
lspci -k | grep -A2 "3D controller"
```

---

## Ansible Playbooks

All commands run from the `ansible/` directory:

```bash
cd ansible
```

### Existing Nodes (Running k3s/Nomad) — Pre-Migration

**Run this ONCE per node before the main setup.** Only needed for nodes currently running k3s, Nomad, or CephFS.

```bash
# Dry-run first (safe, no changes)
ansible-playbook -i inventory/hosts.yml pre-migrate.yml --limit h200-node-4 --check --diff

# Execute on one node
ansible-playbook -i inventory/hosts.yml pre-migrate.yml --limit h200-node-4

# Execute on all nodes
ansible-playbook -i inventory/hosts.yml pre-migrate.yml
```

What it does:
- Stops and disables Nomad, k3s
- Drains the k3s node
- Unmounts CephFS, removes from fstab
- Removes netplan bond configs (NICs will be passed through to VM)
- Creates a bridge (`br0`) for QEMU networking (uses `netplan try` with auto-revert)
- Cleans up container images and data directories

### New Node — Full Setup

Deploy to a single new node that has no existing services:

```bash
# Dry-run first
ansible-playbook -i inventory/hosts.yml playbooks/setup.yml --limit h200-node-4 --check --diff

# Execute
ansible-playbook -i inventory/hosts.yml playbooks/setup.yml --limit h200-node-4
```

What it does:
1. Installs packages (QEMU, KVM, dnsmasq, OVMF, etc.)
2. Enables IOMMU
3. Configures VFIO, hugepages, GRUB (`pcie_aspm=off`, `iommu=pt`)
4. Runs PCI device scanner (`pci-passthrough.py`)
5. Checks GPU ROMs for UEFI compatibility
6. Copies Talos worker config, renders per-node network patch, generates config ISO
7. Installs systemd service (`talos-qemu@<hostname>`)

**Note:** If GRUB changes are needed, the node will reboot automatically. Re-run the playbook after reboot to complete setup.

### Deploy to All Nodes

```bash
# Dry-run
ansible-playbook -i inventory/hosts.yml playbooks/setup.yml --check --diff

# Execute
ansible-playbook -i inventory/hosts.yml playbooks/setup.yml
```

### Start VMs

```bash
# One node
ansible-playbook -i inventory/hosts.yml playbooks/start.yml --limit h200-node-4

# All nodes
ansible-playbook -i inventory/hosts.yml playbooks/start.yml
```

### Stop VMs

```bash
# One node (graceful shutdown, restores VFIO devices)
ansible-playbook -i inventory/hosts.yml playbooks/stop.yml --limit h200-node-4

# All nodes
ansible-playbook -i inventory/hosts.yml playbooks/stop.yml
```

### Revert (Full Teardown)

```bash
# One node — stops VM, removes systemd service, cleans up
ansible-playbook -i inventory/hosts.yml playbooks/revert.yml --limit h200-node-4
```

---

## Common Patterns

### Target a subset of nodes

```bash
# Single node
--limit h200-node-4

# Multiple nodes
--limit "h200-node-1,h200-node-2"

# All except one
--limit 'all:!h200-node-6'
```

### Step-by-step execution

```bash
# Run one task at a time (confirm each step)
ansible-playbook -i inventory/hosts.yml playbooks/setup.yml --limit h200-node-4 --step

# Start from a specific task
ansible-playbook -i inventory/hosts.yml playbooks/setup.yml --limit h200-node-4 --start-at-task="Run PCI device scanner"
```

### Run a single ad-hoc command on nodes

```bash
# Check GPU status on all nodes
ansible -i inventory/hosts.yml gpu_nodes -m shell -a "nvidia-smi --query-gpu=index,name,driver_version --format=csv"

# Check hugepages
ansible -i inventory/hosts.yml gpu_nodes -m shell -a "grep HugePages /proc/meminfo"

# Check if VM is running
ansible -i inventory/hosts.yml gpu_nodes -m shell -a "ps aux | grep qemu-system | grep -v grep"

# Check lspci.txt exists and has content
ansible -i inventory/hosts.yml gpu_nodes -m shell -a "wc -l /opt/talos-qemu-gpu-passthrough/lspci.txt"
```

### Only run specific roles

```bash
# Just update Talos configs and regenerate ISOs (no reboot, no VFIO changes)
ansible-playbook -i inventory/hosts.yml playbooks/setup.yml --limit h200-node-4 --tags talos-config
```

---

## Recommended Deployment Order

### First node (validate everything works)

```bash
# 1. Pre-migrate if existing node
ansible-playbook -i inventory/hosts.yml pre-migrate.yml --limit h200-node-4 --check --diff
ansible-playbook -i inventory/hosts.yml pre-migrate.yml --limit h200-node-4

# 2. Setup
ansible-playbook -i inventory/hosts.yml playbooks/setup.yml --limit h200-node-4

# 3. SSH in and do a dry-run manually
ssh -i ../id_rsa_novita.txt root@213.181.104.157
cd /opt/talos-qemu-gpu-passthrough
bash start.sh --ip 192.168.100.2 --gpu true --fabric true --hostname io-worker-4 --dry-run

# 4. Start manually first
bash start.sh --ip 192.168.100.2 --gpu true --fabric true --hostname io-worker-4

# 5. Verify VM, GPUs, networking
tail -f .worker/qemu-worker-vm-console.log

# 6. If everything works, clean up manual run
bash clean.sh

# 7. Start via systemd (how Ansible does it)
ansible-playbook -i inventory/hosts.yml playbooks/start.yml --limit h200-node-4
```

### Remaining nodes (roll out)

```bash
# Pre-migrate all remaining existing nodes
ansible-playbook -i inventory/hosts.yml pre-migrate.yml --limit 'all:!h200-node-4'

# Setup all remaining
ansible-playbook -i inventory/hosts.yml playbooks/setup.yml --limit 'all:!h200-node-4'

# Start all remaining
ansible-playbook -i inventory/hosts.yml playbooks/start.yml --limit 'all:!h200-node-4'
```

---

## Troubleshooting

| Issue | Check |
|-------|-------|
| VM won't start | `cat .worker/qemu-worker-vm-console.log` |
| VFIO bind fails | `dmesg \| grep vfio`, check IOMMU groups with `find /sys/kernel/iommu_groups/ -type l` |
| No hugepages | `grep HugePages /proc/meminfo`, check GRUB with `cat /proc/cmdline` |
| GPU not visible in VM | `lspci -k \| grep vfio-pci` on host (should show GPUs bound to vfio-pci) |
| Network patch wrong | Check `.iso/config.yaml` on the host, validate with `talosctl validate -m cloud -c .iso/config.yaml` |
| NVMe not detected | `python3 pci-passthrough.py` then `cat lspci.txt \| grep -A5 NVMe` |
| Clean.sh didn't restore devices | `lspci -k \| grep -A2 "3D controller"` — driver should show `nvidia` not `vfio-pci` |
