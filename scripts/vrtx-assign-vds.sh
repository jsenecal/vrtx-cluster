#!/bin/bash
# Script to assign virtual disks to blade servers on Dell VRTX
# Usage: ./vrtx-assign-vds.sh <blade-slot> <vd-ids...>
# Example: ./vrtx-assign-vds.sh 1 12 13 14 15

set -euo pipefail

# Configuration
CMC_IP="192.168.255.200"
CMC_USER="admin"
CMC_PASS="0235629xD!"
CONTROLLER="RAID.ChassisIntegrated.1-1"

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Check arguments
if [ $# -lt 2 ]; then
    echo "Usage: $0 <blade-slot> <vd-id> [vd-id...]"
    echo "Example: $0 1 12 13 14 15"
    echo ""
    echo "Blade slots:"
    echo "  1 = vrtx-alpha"
    echo "  2 = vrtx-bravo"
    echo "  3 = vrtx-charlie"
    exit 1
fi

BLADE_SLOT=$1
shift
VD_IDS=("$@")

# Map blade slot to name
case $BLADE_SLOT in
    1)
        BLADE_NAME="vrtx-alpha"
        ;;
    2)
        BLADE_NAME="vrtx-bravo"
        ;;
    3)
        BLADE_NAME="vrtx-charlie"
        ;;
    *)
        echo -e "${RED}Error: Invalid blade slot $BLADE_SLOT${NC}"
        exit 1
        ;;
esac

echo "Dell VRTX Virtual Disk Assignment"
echo "================================="
echo ""
echo "Blade: $BLADE_NAME (slot $BLADE_SLOT)"
echo "Virtual Disks to assign: ${VD_IDS[@]}"
echo ""

# Function to execute RACADM command
racadm_exec() {
    sshpass -p "$CMC_PASS" ssh -o StrictHostKeyChecking=no "$CMC_USER@$CMC_IP" "racadm $*" 2>&1 | grep -v "WARNING:"
}

# Get current VD information
echo "Verifying Virtual Disks..."
echo "--------------------------"
for vd_id in "${VD_IDS[@]}"; do
    vd_info=$(racadm_exec raid get vdisks:Disk.Virtual.$vd_id:$CONTROLLER -p Name,Size,MediaType 2>&1 | grep -E "(Name|Size|MediaType)" | sed 's/^   //' | tr '\n' ',' | sed 's/,$//')
    if [[ $vd_info == *"Error"* ]]; then
        echo -e "${RED}Error: VD $vd_id not found${NC}"
        exit 1
    fi
    echo "VD $vd_id: $vd_info"
done

echo ""
read -p "Proceed with assignment? (yes/no): " confirm
if [ "$confirm" != "yes" ]; then
    echo "Aborted."
    exit 1
fi

# Assign each VD to the blade
echo ""
echo "Assigning Virtual Disks..."
echo "-------------------------"
for vd_id in "${VD_IDS[@]}"; do
    echo -n "Assigning VD $vd_id to $BLADE_NAME... "
    result=$(racadm_exec raid assignvd:$CONTROLLER -vd Disk.Virtual.$vd_id:$CONTROLLER -b $BLADE_SLOT 2>&1)
    if [[ $result == *"successfully"* ]]; then
        echo -e "${GREEN}Success${NC}"
    else
        echo -e "${RED}Failed${NC}"
        echo "$result"
    fi
done

echo ""
echo -e "${GREEN}Virtual disk assignment completed!${NC}"
echo ""
echo "Next steps:"
echo "1. Reboot $BLADE_NAME to see the new disks"
echo "2. Verify disks appear in the OS with 'lsblk'"
echo "3. Configure Ceph to use the new storage layout"
echo ""
echo "To reboot the blade:"
echo "  talosctl reset --graceful=false --reboot --system-labels-to-wipe STATE --system-labels-to-wipe EPHEMERAL -n <NODE_IP>"