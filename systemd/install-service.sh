#!/bin/bash
set -o nounset -o pipefail

# Install the talos-qemu systemd service template
# Usage: ./install-service.sh <instance-name> [--ip IP] [--gpu true|false] [--fabric true|false]

INSTANCE_NAME="${1:-}"
if [ -z "$INSTANCE_NAME" ]; then
    echo "Usage: $0 <instance-name> [--ip IP] [--gpu true|false] [--fabric true|false]"
    echo "Example: $0 gpu-worker-01 --ip 192.168.100.2 --gpu true --fabric false"
    exit 1
fi
shift

# Defaults
VM_IP="192.168.100.2"
GPU_PASSTHROUGH="false"
FABRIC="false"

# Parse flags
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --ip) VM_IP="$2"; shift ;;
        --gpu) GPU_PASSTHROUGH="$2"; shift ;;
        --fabric) FABRIC="$2"; shift ;;
        *) echo "Unknown parameter: $1"; exit 1 ;;
    esac
    shift
done

WORKING_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Install the systemd service template
sudo cp "$SCRIPT_DIR/talos-qemu@.service" /etc/systemd/system/
echo "Installed systemd service template."

# Create the config directory and instance config
sudo mkdir -p /etc/talos-qemu
sudo tee "/etc/talos-qemu/${INSTANCE_NAME}.conf" > /dev/null <<EOF
WORKING_DIR=${WORKING_DIR}
VM_IP=${VM_IP}
GPU_PASSTHROUGH=${GPU_PASSTHROUGH}
FABRIC=${FABRIC}
EOF
echo "Created config at /etc/talos-qemu/${INSTANCE_NAME}.conf"

# Reload systemd and enable the service
sudo systemctl daemon-reload
sudo systemctl enable "talos-qemu@${INSTANCE_NAME}"
echo ""
echo "Service installed and enabled: talos-qemu@${INSTANCE_NAME}"
echo ""
echo "Commands:"
echo "  Start:   sudo systemctl start talos-qemu@${INSTANCE_NAME}"
echo "  Stop:    sudo systemctl stop talos-qemu@${INSTANCE_NAME}"
echo "  Status:  sudo systemctl status talos-qemu@${INSTANCE_NAME}"
echo "  Logs:    journalctl -u talos-qemu@${INSTANCE_NAME} -f"
