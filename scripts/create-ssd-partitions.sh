#!/bin/bash
# Script to create SSD partitions for Ceph WAL/DB on vrtx-alpha
# This script should be run after the VDs are assigned and the node is rebooted

set -euo pipefail

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Configuration
PARTITION_SIZE="124G"
NODE_NAME="vrtx-alpha"

# Expected SSD devices (will be verified)
SSD1="/dev/sde"
SSD2="/dev/sdf"

echo "SSD Partition Creation for Ceph WAL/DB"
echo "======================================"
echo ""
echo "Node: $NODE_NAME"
echo "Partition size: $PARTITION_SIZE per partition"
echo "SSDs: $SSD1, $SSD2"
echo ""

# Function to check if device exists
check_device() {
    local device=$1
    if [ ! -b "$device" ]; then
        echo -e "${RED}Error: Device $device not found${NC}"
        return 1
    fi
    return 0
}

# Verify both SSDs exist
echo "Verifying SSD devices..."
if ! check_device "$SSD1" || ! check_device "$SSD2"; then
    echo -e "${RED}Missing SSD devices. Please ensure VDs are assigned and node is rebooted.${NC}"
    exit 1
fi

# Show current device information
echo ""
echo "Current device information:"
echo "---------------------------"
for dev in $SSD1 $SSD2; do
    echo "Device: $dev"
    lsblk "$dev" 2>/dev/null || echo "  No partition table"
    echo ""
done

# Confirm before proceeding
echo -e "${YELLOW}WARNING: This will destroy all data on $SSD1 and $SSD2${NC}"
read -p "Proceed with partition creation? (yes/no): " confirm
if [ "$confirm" != "yes" ]; then
    echo "Aborted."
    exit 1
fi

# Wipe existing partition tables
echo ""
echo "Wiping existing partition tables..."
for dev in $SSD1 $SSD2; do
    echo -n "Wiping $dev... "
    if sgdisk --zap-all "$dev" >/dev/null 2>&1; then
        echo -e "${GREEN}Done${NC}"
    else
        echo -e "${RED}Failed${NC}"
        exit 1
    fi
done

# Create partitions on first SSD
echo ""
echo "Creating partitions on $SSD1..."
echo "--------------------------------"
sgdisk -n 1:0:+$PARTITION_SIZE -c 1:"ceph-db-hdd1" -t 1:8300 "$SSD1"
sgdisk -n 2:0:+$PARTITION_SIZE -c 2:"ceph-db-hdd2" -t 2:8300 "$SSD1"
sgdisk -n 3:0:+$PARTITION_SIZE -c 3:"ceph-db-hdd3" -t 3:8300 "$SSD1"

# Create partitions on second SSD
echo ""
echo "Creating partitions on $SSD2..."
echo "--------------------------------"
sgdisk -n 1:0:+$PARTITION_SIZE -c 1:"ceph-db-hdd4" -t 1:8300 "$SSD2"
sgdisk -n 2:0:+$PARTITION_SIZE -c 2:"ceph-db-hdd5" -t 2:8300 "$SSD2"
sgdisk -n 3:0:+$PARTITION_SIZE -c 3:"ceph-db-hdd6" -t 3:8300 "$SSD2"

# Reload partition tables
echo ""
echo "Reloading partition tables..."
partprobe $SSD1 $SSD2

# Wait for devices to settle
sleep 2

# Verify partitions were created
echo ""
echo "Verifying partition creation..."
echo "-------------------------------"
echo ""
echo "SSD1 ($SSD1) partitions:"
sgdisk -p "$SSD1" | grep -E "^   [0-9]"
echo ""
echo "SSD2 ($SSD2) partitions:"
sgdisk -p "$SSD2" | grep -E "^   [0-9]"

# Show final layout
echo ""
echo -e "${GREEN}Partition creation completed!${NC}"
echo ""
echo "Final partition layout:"
echo "----------------------"
lsblk $SSD1 $SSD2

# Generate partition mapping
echo ""
echo "Partition mapping for Ceph OSDs:"
echo "--------------------------------"
echo "HDD1 (VD 0:0:6)  -> WAL/DB: ${SSD1}1"
echo "HDD2 (VD 0:0:7)  -> WAL/DB: ${SSD1}2"
echo "HDD3 (VD 0:0:8)  -> WAL/DB: ${SSD1}3"
echo "HDD4 (VD 0:0:9)  -> WAL/DB: ${SSD2}1"
echo "HDD5 (VD 0:0:10) -> WAL/DB: ${SSD2}2"
echo "HDD6 (VD 0:0:11) -> WAL/DB: ${SSD2}3"

echo ""
echo "Next steps:"
echo "1. Update Ceph configuration to use these devices"
echo "2. Add vrtx-alpha to the Ceph cluster storage configuration"
echo "3. Deploy OSDs with dedicated WAL/DB devices"