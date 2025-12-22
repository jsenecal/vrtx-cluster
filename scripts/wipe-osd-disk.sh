#!/bin/bash
# Script to wipe Ceph OSD disk

set -euo pipefail

NODE_IP=$1
DEVICE=$2

echo "Wiping Ceph OSD disk $DEVICE on node $NODE_IP"
echo "WARNING: This will destroy all data on $DEVICE!"
read -p "Are you sure? (yes/no): " confirm

if [ "$confirm" != "yes" ]; then
    echo "Aborted."
    exit 1
fi

echo "Wiping disk $DEVICE..."

# Use dd to wipe the first and last 10MB of the disk
# This removes partition tables and Ceph signatures
talosctl -n $NODE_IP dmesg --follow=false | tail -1
talosctl -n $NODE_IP ls /dev/$DEVICE || { echo "Device $DEVICE not found"; exit 1; }

echo "Wiping beginning of disk..."
talosctl -n $NODE_IP dd if=/dev/zero of=/dev/$DEVICE bs=1M count=10 2>/dev/null || true

# Get disk size to wipe the end
DISK_SIZE=$(talosctl -n $NODE_IP cat /sys/block/$DEVICE/size)
SECTOR_SIZE=512
SIZE_MB=$((DISK_SIZE * SECTOR_SIZE / 1024 / 1024))
SEEK_MB=$((SIZE_MB - 10))

echo "Wiping end of disk (seek=$SEEK_MB MB)..."
talosctl -n $NODE_IP dd if=/dev/zero of=/dev/$DEVICE bs=1M count=10 seek=$SEEK_MB 2>/dev/null || true

echo "Disk $DEVICE has been wiped."