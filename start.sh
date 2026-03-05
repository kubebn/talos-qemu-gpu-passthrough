#!/bin/bash
set -o nounset -o pipefail

# Save terminal settings, IFS breaks it
ORIGINAL_STTY=$(stty -g)
trap 'stty $ORIGINAL_STTY' EXIT

# Default values
VM_IP=""
IS_GPU_NODE=false
FORCE_CREATE_DISK=true
FABRIC=false
DRY_RUN=false
VM_HOSTNAME=""
host_cpu_reserve=4

# Parse flags
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --ip) VM_IP="$2"; shift ;;
        --gpu) IS_GPU_NODE="$2"; shift ;;
        --disk-force) FORCE_CREATE_DISK="$2"; shift ;;
        --fabric) FABRIC="$2"; shift ;;
        --dry-run) DRY_RUN=true ;;
        --hostname) VM_HOSTNAME="$2"; shift ;;
        *) echo "Unknown parameter passed: $1"; exit 1 ;;
    esac
    shift
done

# Ensure the .worker folder exists
WORKER_DIR="$PWD/.worker"
if [ ! -d "$WORKER_DIR" ]; then
  echo "Creating .worker directory..."
  mkdir -p "$WORKER_DIR"
else
  echo ".worker directory already exists."
fi

# Check if IP address is provided
if [ -z "$VM_IP" ]; then
    echo "Usage: $0 --ip <VM_IP> [--gpu <true|false>] [--disk-force <true|false>] [--fabric <true|false>] [--dry-run] [--hostname <name>]"
    exit 1
fi

# Function to generate a random hash
generate_hash() {
    echo $(head /dev/urandom | tr -dc a-z0-9 | head -c 16)
}

# Function to generate a random MAC address
generate_mac() {
    hexdump -n6 -e '6/1 ":%02x"' /dev/urandom | awk ' { sub(/^:../, "02"); print } '
}

# Variables for VM configuration
VM_MAC=$(generate_mac)

# Generate hostname based on node type (unless --hostname was provided)
if [ -z "$VM_HOSTNAME" ]; then
    if [ "$IS_GPU_NODE" = true ]; then
        VM_HOSTNAME="io-worker-$(generate_hash)"
    else
        VM_HOSTNAME="io-cpu-$(generate_hash)"
    fi
fi

# Extract the subnet and calculate the DHCP range dynamically
IFS='.' read -r IP1 IP2 IP3 IP4 <<< "$VM_IP"
SUBNET="$IP1.$IP2.$IP3.0/24"
DHCP_RANGE_START="$IP1.$IP2.$IP3.1"
DHCP_RANGE_END="$IP1.$IP2.$IP3.255"

# Check if QEMU is already running for this worker
if [ -f "${WORKER_DIR}/qemu-worker-vm.pid" ]; then
    EXISTING_PID=$(sudo cat "${WORKER_DIR}/qemu-worker-vm.pid" 2>/dev/null)
    if [ -n "$EXISTING_PID" ] && sudo kill -0 "$EXISTING_PID" 2>/dev/null; then
        echo "Error: QEMU VM is already running (PID $EXISTING_PID). Run clean.sh first."
        exit 1
    fi
fi

# Create bridge and tap interface (idempotent)
if ! ip link show br0 &>/dev/null; then
    sudo ip link add br0 type bridge
    sudo ip addr add "$SUBNET" dev br0
    sudo ip link set up dev br0
else
    echo "Bridge br0 already exists, reusing."
fi

if ! ip link show workertap &>/dev/null; then
    sudo ip tuntap add workertap mode tap
    sudo ip link set workertap up
    sudo ip link set workertap master br0
else
    echo "TAP workertap already exists, reusing."
fi

# Kill our previous dnsmasq if running (not all dnsmasq on the host)
DNSMASQ_DIR="${PWD}/.dnsmasq"
if [ -f "${DNSMASQ_DIR}/dnsmasq.pid" ]; then
    OLD_DNSMASQ_PID=$(cat "${DNSMASQ_DIR}/dnsmasq.pid" 2>/dev/null)
    if [ -n "$OLD_DNSMASQ_PID" ] && sudo kill -0 "$OLD_DNSMASQ_PID" 2>/dev/null; then
        sudo kill "$OLD_DNSMASQ_PID" 2>/dev/null
        sleep 1
    fi
fi
sudo truncate -s 0 /var/lib/misc/dnsmasq.leases 2>/dev/null

mkdir -p "$DNSMASQ_DIR"

# Create dnsmasq configuration file in the dnsmasq directory
sudo tee "$DNSMASQ_DIR/dnsmasq.conf" <<EOF
# Bind to the bridge device
interface=br0
bind-interfaces

# Ignore host /etc/resolv.conf and /etc/hosts
no-resolv
no-hosts

# Forward DNS requests to a public DNS resolver
domain-needed
bogus-priv
server=1.1.1.1
server=1.0.0.1

# Serve leases to hosts in the network
dhcp-range=$DHCP_RANGE_START,$DHCP_RANGE_END,60s
dhcp-lease-max=25

# Assign specific IP and hostname to the VM
dhcp-host=$VM_MAC,$VM_IP,$VM_HOSTNAME
EOF

# Start dnsmasq using the configuration file in the dnsmasq directory
sudo dnsmasq --no-daemon --conf-file="$DNSMASQ_DIR/dnsmasq.conf" > "$DNSMASQ_DIR/dnsmasq.log" 2>&1 &
echo $! > "$DNSMASQ_DIR/dnsmasq.pid"

# Configure iptables

# Get the public IP
PUBLIC_IP=$(curl -s ifconfig.me)

# Get the main interface that is up and not br0
MAIN_INTERFACE=$(ip route | grep default | sort -k5 -n | awk '{print $5}' | head -n 1)

sudo sysctl -w net.ipv4.ip_forward=1
grep -qxF 'net.ipv4.ip_forward=1' /etc/sysctl.conf || echo 'net.ipv4.ip_forward=1' | sudo tee -a /etc/sysctl.conf

# Record iptables rules for clean.sh to remove later
IPTABLES_RULES_FILE="${WORKER_DIR}/.iptables_rules"
IPTABLES_NAT_RULES_FILE="${WORKER_DIR}/.iptables_nat_rules"

sudo iptables -t nat -A POSTROUTING ! -o br0 --source "$SUBNET" -j MASQUERADE
echo "-A POSTROUTING ! -o br0 --source $SUBNET -j MASQUERADE" > "$IPTABLES_NAT_RULES_FILE"

sudo iptables -A FORWARD -i br0 -j ACCEPT
sudo iptables -A FORWARD -o br0 -j ACCEPT
sudo iptables -A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
cat > "$IPTABLES_RULES_FILE" <<RULES
-A FORWARD -i br0 -j ACCEPT
-A FORWARD -o br0 -j ACCEPT
-A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
RULES

# KubeSpan/Kilo wg tunnel
sudo iptables -t nat -A PREROUTING -p udp -d $PUBLIC_IP --dport 51820 -i $MAIN_INTERFACE -j DNAT --to-destination $VM_IP:51820
echo "-A PREROUTING -p udp -d $PUBLIC_IP --dport 51820 -i $MAIN_INTERFACE -j DNAT --to-destination $VM_IP:51820" >> "$IPTABLES_NAT_RULES_FILE"

TALOS_IMAGE_FILE="${PWD}/.build/metal-amd64.qcow2"
VM_DISK_FILE="${PWD}/.worker/worker-main.qcow2"

# Calculate the disk size for the VM (20% less than available the host machine's disk size)
HOST_DISK_AVAIL=$(df --output=avail -BG / | tail -1 | tr -d 'G')
VM_DISK_SIZE=$((HOST_DISK_AVAIL * 80 / 100))

# Create or overwrite the VM disk if FORCE_CREATE_DISK is true
if [ "$FORCE_CREATE_DISK" = true ] || [ ! -f "$VM_DISK_FILE" ]; then
    echo "Copying Talos image to create VM disk..."
    cp "$TALOS_IMAGE_FILE" "$VM_DISK_FILE"
    # Resize the disk to calculated VM_DISK_SIZE
    echo "Resizing VM disk to ${VM_DISK_SIZE}GB..."
    qemu-img resize "$VM_DISK_FILE" "${VM_DISK_SIZE}G"
else
    echo "VM disk already exists. Skipping creation: $VM_DISK_FILE"
fi

# Calculate the memory and CPU for the VM
if [ "$IS_GPU_NODE" = true ]; then
    HugePages_Total=$(grep HugePages_Total /proc/meminfo | awk '{print $2}')
    VM_MEMORY=$((HugePages_Total)) # Each hugepage is 1GB, so it's already in gigabytes
else
    # Ensure FREE_MEMORY is in MB and convert to GB
    FREE_MEMORY=$(free -m | awk '/^Mem:/ {print $7}')
    VM_MEMORY=$((FREE_MEMORY / 1024 * 90 / 100)) # Convert MB to GB and take 90%
fi

# Calculate the total CPUs (use logical CPUs, subtract host_cpu_reserve)
TOTAL_CPUS=$(nproc)
SOCKETS=$(lscpu | grep "^Socket(s):" | awk '{print $2}')
VM_CPUS=$((TOTAL_CPUS - host_cpu_reserve))
if [ "$VM_CPUS" -lt 1 ]; then
    VM_CPUS=1
fi

# Check if OVMF is installed, set UEFI configuration
if [ -f /usr/share/ovmf/OVMF.fd ]; then
    cp /usr/share/ovmf/OVMF.fd ${PWD}/.worker/worker-flash.img
    dd if=/dev/zero of=${PWD}/.worker/efi-vars.raw bs=1M count=3
    OVMF_DRIVES="-drive if=pflash,format=raw,readonly=on,file=${PWD}/.worker/worker-flash.img \
                 -drive if=pflash,format=raw,file=${PWD}/.worker/efi-vars.raw"
else
    echo "qemu-efi-aarch64 is not installed. Skipping OVMF configuration."
    OVMF_DRIVES=""
fi

# ISO configuration for Talos machine configuration
mkdir -p ${PWD}/.iso

# Find the worker YAML file dynamically
WORKER_YAML_FILE=$(find . -maxdepth 1 -type f -name "worker*.yaml" | head -n 1)

if [ -z "$WORKER_YAML_FILE" ]; then
    echo "Error: No worker YAML file found in the current directory."
    exit 1
fi

# Copy the worker YAML file to the ISO directory
cp "$WORKER_YAML_FILE" ${PWD}/.iso/config.yaml

# Create the ISO file
sudo mkisofs -joliet -rock -volid 'metal-iso' -output ${PWD}/.worker/config.iso ${PWD}/.iso/

# Handle --fabric flag
if [ "$FABRIC" = true ]; then
  # Check if any good_gpu.rom file exists in the folder
  if ls "${PWD}/.gpu_roms/"good_gpu.rom 1> /dev/null 2>&1; then
    echo "Found good_gpu.rom file. Ignoring FABRIC=true condition."
  else
    OVMF_DRIVES=""
  fi
fi

# Generate a unique UUID for the VM
VM_UUID=$(cat /proc/sys/kernel/random/uuid)

# Start QEMU VM
QEMU_CMD="sudo qemu-system-x86_64 \
  -name talos-worker,process=talos-worker \
  -uuid $VM_UUID \
  -m ${VM_MEMORY}G \
  -smp $VM_CPUS,sockets=$SOCKETS,cores=$((VM_CPUS / SOCKETS / 2)),threads=2 \
  -cpu host,+x2apic,+invtsc \
  -machine q35,accel=kvm,kernel_irqchip=split \
  -overcommit mem-lock=on \
  -enable-kvm \
  -display none \
  -daemonize \
  -pidfile ${PWD}/.worker/qemu-worker-vm.pid \
  -serial file:${PWD}/.worker/qemu-worker-vm-console.log \
  -cdrom ${PWD}/.worker/config.iso \
  -device \"virtio-net-pci,netdev=workertap,mac=$VM_MAC\" \
  -netdev \"tap,id=workertap,ifname=workertap,script=no,downscript=no\" \
  -device virtio-rng-pci \
  -monitor unix:${PWD}/.worker/worker.monitor,server,nowait \
  -boot order=cn,reboot-timeout=5000 \
  -chardev socket,path=${PWD}/.worker/worker.sock,server=on,wait=off,id=qga0 \
  -device virtio-serial \
  -device virtserialport,chardev=qga0,name=org.qemu.guest_agent.0 \
  -device i6300esb,id=watchdog0 \
  -watchdog-action pause \
  -drive file=$VM_DISK_FILE,if=virtio,media=disk,index=0,cache=writeback,discard=ignore,format=qcow2"

# Hugepages / NUMA memory configuration
HUGEPAGES_PATH="/dev/hugepages"

if [ "$IS_GPU_NODE" = true ]; then
    # Ensure the hugepages directory exists
    if [ ! -d "$HUGEPAGES_PATH" ]; then
        echo "Hugepages directory not found at $HUGEPAGES_PATH. Please ensure hugepages are configured."
        exit 1
    fi

    NUMA_COUNT=$(lscpu | grep "^NUMA node(s):" | awk '{print $NF}')
    if [ "$NUMA_COUNT" -gt 1 ]; then
        # Per-NUMA memory backends (replaces -mem-path/-mem-prealloc)
        PER_NUMA_MEM=$((VM_MEMORY / NUMA_COUNT))

        for ((n=0; n<NUMA_COUNT; n++)); do
            # Get CPU list for this NUMA node
            NUMA_CPUS=$(lscpu --parse=CPU,NODE | grep -v '^#' | awk -F, -v node=$n '$2==node {print $1}' | tr '\n' ',' | sed 's/,$//')
            # Skip host_cpu_reserve CPUs from NUMA 0
            if [ $n -eq 0 ]; then
                NUMA_CPUS=$(echo "$NUMA_CPUS" | tr ',' '\n' | tail -n +$((host_cpu_reserve + 1)) | tr '\n' ',' | sed 's/,$//')
            fi
            QEMU_CMD+=" -object memory-backend-file,id=mem${n},size=${PER_NUMA_MEM}G,mem-path=/dev/hugepages,share=on,prealloc=on,host-nodes=${n},policy=bind"
            QEMU_CMD+=" -numa node,nodeid=${n},cpus=${NUMA_CPUS},memdev=mem${n}"
        done
    else
        # Single NUMA node — use simple hugepages
        QEMU_CMD+=" -mem-path $HUGEPAGES_PATH -mem-prealloc"
    fi
fi

# Append OVMF_DRIVES only if it is not empty
if [ -n "$OVMF_DRIVES" ]; then
  QEMU_CMD+=" $OVMF_DRIVES"
fi

if [ "$IS_GPU_NODE" = true ]; then
    # Read device addresses from lspci.txt sections
    if [ ! -f lspci.txt ]; then
        echo "Error: lspci.txt file not found."
        exit 1
    fi

    # Helper to extract a section (one address per line)
    read_section() {
        local section="$1"
        awk -v sect="$section" '/^=== / { if (index($0, sect)) flag=1; else if (flag) flag=0; next } flag { print }' lspci.txt
    }

    GPU_ADDRESSES=$(read_section "GPUs")
    NVSWITCH_ADDRESSES=$(read_section "NVSwitches")
    IB_ADDRESSES=$(read_section "InfiniBand NICs")
    ETH_ADDRESSES=$(read_section "Ethernet NICs")
    PCIE_SWITCH_ADDRESSES=$(read_section "PCIe Switches")
    NVME_ADDRESSES=$(read_section "NVMe Drives")

    # "All Passthrough Devices (Line Format)" has all addresses on ONE line, space-separated
    ALL_PASSTHROUGH_ADDRESSES=$(awk '/^=== All Passthrough Devices \(Line Format\) ===/ {flag=1; next} /^===/ {flag=0} flag' lspci.txt | xargs)

    # Runtime VFIO binding — unbind all passthrough devices and bind to vfio-pci
    echo "Binding passthrough devices to vfio-pci at runtime..."
    sudo modprobe vfio-pci

    for dev in $ALL_PASSTHROUGH_ADDRESSES; do
        if [ -e "/sys/bus/pci/devices/$dev/driver" ]; then
            CURRENT_DRIVER=$(basename "$(readlink /sys/bus/pci/devices/$dev/driver)")
            if [ "$CURRENT_DRIVER" != "vfio-pci" ]; then
                echo "  Unbinding $dev from $CURRENT_DRIVER..."
                echo "$dev" | sudo tee /sys/bus/pci/drivers/$CURRENT_DRIVER/unbind > /dev/null 2>&1
            fi
        fi
        echo "vfio-pci" | sudo tee /sys/bus/pci/devices/$dev/driver_override > /dev/null 2>&1
        echo "$dev" | sudo tee /sys/bus/pci/drivers_probe > /dev/null 2>&1
    done

    # Mark GPU mode for clean.sh
    touch "${WORKER_DIR}/.gpu_mode"
    echo "Passthrough devices bound to vfio-pci."

    # Check if GPU addresses exist
    if [ -z "$GPU_ADDRESSES" ]; then
        echo "Error: No GPU addresses found in lspci.txt."
        cat lspci.txt
        exit 1
    fi

    # Add GPU devices with pcie-root-port
    GPU_ROMS_DIR="${PWD}/.gpu_roms"
    PORT_INDEX=1
    for dev in $GPU_ADDRESSES; do
        DEVICE_PATH="$dev"
        BAD_ROM_FILE="$GPU_ROMS_DIR/$DEVICE_PATH.bad"
        ROOT_PORT_ID="pcie.$PORT_INDEX"
        PORT_HEX=$(printf "0x%02x" $((PORT_INDEX + 0x10)))
        PORT_INDEX=$((PORT_INDEX + 1))

        QEMU_CMD+=" -device pcie-root-port,id=$ROOT_PORT_ID,port=$PORT_HEX,chassis=$PORT_INDEX,slot=$PORT_INDEX,bus=pcie.0"

        if [[ -f "$BAD_ROM_FILE" ]]; then
            QEMU_CMD+=" -device vfio-pci,host=$dev,bus=$ROOT_PORT_ID,multifunction=on,romfile=${GPU_ROMS_DIR}/good_gpu.rom"
        else
            QEMU_CMD+=" -device vfio-pci,host=$dev,bus=$ROOT_PORT_ID,multifunction=on,rombar=0"
        fi
    done

    # Add NVSwitch devices
    for dev in $NVSWITCH_ADDRESSES; do
        QEMU_CMD+=" -device vfio-pci,host=$dev"
    done

    # Add InfiniBand NIC devices
    for dev in $IB_ADDRESSES; do
        QEMU_CMD+=" -device vfio-pci,host=$dev"
    done

    # Add Ethernet NIC devices
    for dev in $ETH_ADDRESSES; do
        QEMU_CMD+=" -device vfio-pci,host=$dev"
    done

    # Add PCIe Switch devices
    for dev in $PCIE_SWITCH_ADDRESSES; do
        QEMU_CMD+=" -device vfio-pci,host=$dev"
    done

    # Add NVMe devices
    for dev in $NVME_ADDRESSES; do
        QEMU_CMD+=" -device vfio-pci,host=$dev"
    done
fi

# Log the start time
START_TIME=$(date +%s)

# Notify the user that the QEMU VM is starting
echo "Starting QEMU VM..."

if [ "$DRY_RUN" = true ]; then
    echo "=== DRY RUN — QEMU command ==="
    echo "$QEMU_CMD"
    exit 0
fi

# Execute the QEMU command
eval $QEMU_CMD

# Log the end time
END_TIME=$(date +%s)

# Calculate and display the time taken to start the VM
TIME_TAKEN=$((END_TIME - START_TIME))
echo "QEMU VM started successfully in $TIME_TAKEN seconds."

# Pin vCPUs to physical CPUs for NUMA locality (GPU nodes only)
if [ "$IS_GPU_NODE" = true ] && [ -f "${PWD}/pin-vcpus.sh" ]; then
    echo "Pinning vCPU threads..."
    "${PWD}/pin-vcpus.sh" "$host_cpu_reserve"
fi
