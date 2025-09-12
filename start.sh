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

# Parse flags
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --ip) VM_IP="$2"; shift ;;
        --gpu) IS_GPU_NODE="$2"; shift ;;
        --disk-force) FORCE_CREATE_DISK="$2"; shift ;;
        --fabric) FABRIC="$2"; shift ;;
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
    echo "Usage: $0 --ip <VM_IP> [--gpu <true|false>] [--disk-force <true|false>] [--fabric <true|false>]"
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

# Generate hostname based on node type
if [ "$IS_GPU_NODE" = true ]; then
    VM_HOSTNAME="io-gpu-$(generate_hash)"
else
    VM_HOSTNAME="io-cpu-$(generate_hash)"
fi

# Extract the subnet and calculate the DHCP range dynamically
IFS='.' read -r IP1 IP2 IP3 IP4 <<< "$VM_IP"
SUBNET="$IP1.$IP2.$IP3.0/24"
DHCP_RANGE_START="$IP1.$IP2.$IP3.1"
DHCP_RANGE_END="$IP1.$IP2.$IP3.255"

# Create a bridge and tap interface
sudo ip link add br0 type bridge
sudo ip addr add "$SUBNET" dev br0
sudo ip link set up dev br0
sudo ip tuntap add workertap mode tap
sudo ip link set workertap up
sudo ip link set workertap master br0
sudo pkill dnsmasq
sudo truncate -s 0 /var/lib/misc/dnsmasq.leases

# Create a directory for dnsmasq files
DNSMASQ_DIR="${PWD}/.dnsmasq"
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

sudo iptables -t nat -A POSTROUTING ! -o br0 --source "$SUBNET" -j MASQUERADE
sudo iptables -A FORWARD -i br0 -j ACCEPT
sudo iptables -A FORWARD -o br0 -j ACCEPT
sudo iptables -A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# KubeSpan/Kilo wg tunnel
sudo iptables -t nat -A PREROUTING -p udp -d $PUBLIC_IP --dport 51820 -i $MAIN_INTERFACE -j DNAT --to-destination $VM_IP:51820

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

# Calculate the memory and CPU for the VM (10% of the host machine's free memory, we use preallocated hugepages)
if [ "$IS_GPU_NODE" = true ]; then
    HugePages_Total=$(grep HugePages_Total /proc/meminfo | awk '{print $2}')
    VM_MEMORY=$((HugePages_Total)) # Each hugepage is 1GB, so it's already in gigabytes
else
    # Ensure FREE_MEMORY is in MB and convert to GB
    FREE_MEMORY=$(free -m | awk '/^Mem:/ {print $7}')
    VM_MEMORY=$((FREE_MEMORY / 1024 * 90 / 100)) # Convert MB to GB and take 90%
fi

#######!!!!!!!!!!#######
# Does not work with big host machines therefore, we apply all cpu's to vm to avoid kernel mem warnings - $(nproc)
#######!!!!!!!!!!#######

# Calculate the total CPUs (prefer physical cores if available)
PHYSICAL_CPUS=$(lscpu | grep "^Core(s) per socket:" | awk '{print $4}')
SOCKETS=$(lscpu | grep "^Socket(s):" | awk '{print $2}')
TOTAL_PHYSICAL_CPUS=$((PHYSICAL_CPUS * SOCKETS))

if [ -n "$TOTAL_PHYSICAL_CPUS" ] && [ "$TOTAL_PHYSICAL_CPUS" -gt 0 ]; then
    TOTAL_CPUS=$TOTAL_PHYSICAL_CPUS
else
    TOTAL_CPUS=$(nproc)
fi

# Allocate 95% of the total CPUs to the VM
VM_CPUS=$((TOTAL_CPUS * 95 / 100))

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
  -smp cpus=$(nproc) \
  -cpu host,kvm=off,pdpe1gb=on \
  -machine q35,accel=kvm,smm=on,mem-merge=off \
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

# Path to the hugepages mount point
HUGEPAGES_PATH="/dev/hugepages"

if [ "$IS_GPU_NODE" = true ]; then
    # Ensure the hugepages directory exists
    if [ ! -d "$HUGEPAGES_PATH" ]; then
        echo "Hugepages directory not found at $HUGEPAGES_PATH. Please ensure hugepages are configured."
        exit 1
    fi

    QEMU_CMD+=" -mem-path $HUGEPAGES_PATH -mem-prealloc"
fi

# Append OVMF_DRIVES only if it is not empty
if [ -n "$OVMF_DRIVES" ]; then
  QEMU_CMD+=" $OVMF_DRIVES"
fi

if [ "$IS_GPU_NODE" = true ]; then
    # Read All GPU Device Addresses (Line Format) from lspci.txt
    if [ ! -f lspci.txt ]; then
        echo "Error: lspci.txt file not found."
        exit 1
    fi

    # Extract NVIDIA GPU addresses
    if [ "$FABRIC" = true ]; then
        # Extract all GPU addresses in column format
        NVIDIA_GPU_ADDRESSES=$(awk '/^=== All GPU Device Addresses \(Column Format\) ===/ {flag=1; next} /^===/ {flag=0} flag' lspci.txt)
    else
        # Extract NVIDIA GPU addresses in line format
        NVIDIA_GPU_ADDRESSES=$(awk '/^=== NVIDIA GPU Cards \(nvidia driver only\) ===/ {flag=1; next} /^===/ {flag=0} flag' lspci.txt)
    fi
    AUDIO_DEVICE_ADDRESSES=$(awk '/^=== Audio Devices ===/ {flag=1; next} /^===/ {flag=0} flag' lspci.txt)

    # Check if NVIDIA GPU addresses exist
    if [ -z "$NVIDIA_GPU_ADDRESSES" ]; then
        echo "Error: No NVIDIA GPU addresses found in lspci.txt."
        echo "Existing devices in lspci.txt:"
        cat lspci.txt
        exit 1
    fi

    # Warn if Audio device addresses are missing
    if [ -z "$AUDIO_DEVICE_ADDRESSES" ]; then
        echo "Warning: No Audio device addresses found in lspci.txt. Proceeding with NVIDIA devices only."
    fi

    # Add NVIDIA devices dynamically with pcie-root-port
    GPU_ROMS_DIR="${PWD}/.gpu_roms"
    PORT_INDEX=1
    for dev in $NVIDIA_GPU_ADDRESSES; do
        DEVICE_PATH="$dev"
        BAD_ROM_FILE="$GPU_ROMS_DIR/$DEVICE_PATH.bad"
        ROOT_PORT_ID="pcie.$PORT_INDEX" # Ensure ROOT_PORT_ID is unique
        PORT_HEX=$(printf "0x%02x" $((PORT_INDEX + 0x10))) # Ensure port is within 0x10 to 0xFF
        PORT_INDEX=$((PORT_INDEX + 1)) # Increment PORT_INDEX for uniqueness

        QEMU_CMD+=" -device pcie-root-port,id=$ROOT_PORT_ID,port=$PORT_HEX,chassis=$PORT_INDEX,slot=$PORT_INDEX,bus=pcie.0"

        if [[ -f "$BAD_ROM_FILE" ]]; then
            # If the device is non-compatible, use the good GPU ROM
            QEMU_CMD+=" -device vfio-pci,host=$dev,bus=$ROOT_PORT_ID,multifunction=on,romfile=${GPU_ROMS_DIR}/good_gpu.rom"
        else
            # Apply all NVIDIA devices with multifunction=on
            QEMU_CMD+=" -device vfio-pci,host=$dev,bus=$ROOT_PORT_ID,multifunction=on,rombar=0"
        fi
    done

    # Add Audio devices without multifunction=on
    for dev in $AUDIO_DEVICE_ADDRESSES; do
        DEVICE_PATH="$dev"
        ROOT_PORT_ID="pcie.$PORT_INDEX" # Ensure ROOT_PORT_ID is unique
        PORT_HEX=$(printf "0x%02x" $((PORT_INDEX + 0x10))) # Ensure port is within 0x10 to 0xFF
        PORT_INDEX=$((PORT_INDEX + 1)) # Increment PORT_INDEX for uniqueness

        QEMU_CMD+=" -device pcie-root-port,id=$ROOT_PORT_ID,port=$PORT_HEX,chassis=$PORT_INDEX,slot=$PORT_INDEX,bus=pcie.0"
        QEMU_CMD+=" -device vfio-pci,host=$dev,bus=$ROOT_PORT_ID,rombar=0"
    done
fi

# Log the start time
START_TIME=$(date +%s)

# Notify the user that the QEMU VM is starting
echo "Starting QEMU VM..."

# Execute the QEMU command
eval $QEMU_CMD

# Log the end time
END_TIME=$(date +%s)

# Calculate and display the time taken to start the VM
TIME_TAKEN=$((END_TIME - START_TIME))
echo "QEMU VM started successfully in $TIME_TAKEN seconds."