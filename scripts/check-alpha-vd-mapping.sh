#!/bin/bash
# Check VD to device mapping on vrtx-alpha

NODE_IP="192.168.168.201"

echo "Checking VD mapping on vrtx-alpha..."
echo ""

# List all VDs we see
echo "=== VDs seen in PCI paths ==="
talosctl -n $NODE_IP ls /dev/disk/by-path/ | grep -E "pci-0000:(09|14):00.0-scsi-0:2:[0-9]+:0$" | awk -F: '{print $4}' | sort -nu | while read vd; do
    echo "VD $vd"
done

echo ""
echo "=== Checking device sizes by VD ==="
# For each VD, try to find its size
for vd in 3 4 5 7 8 13 14 15; do
    # Find a device that maps to this VD
    device=$(talosctl -n $NODE_IP ls -l /dev/disk/by-path/pci-0000:09:00.0-scsi-0:2:${vd}:0 2>/dev/null | awk '{print $11}' | grep -o 'sd[a-z]*')
    if [ -n "$device" ]; then
        size=$(talosctl -n $NODE_IP get disks | grep "^$NODE_IP.*Disk.*$device " | awk '{print $6, $7}')
        echo "VD $vd -> /dev/$device -> $size"
    fi
done

echo ""
echo "=== Device count by size ==="
echo "399 GB devices: $(talosctl -n $NODE_IP get disks | grep "399 GB" | grep "Shared PERC8" | wc -l)"
echo "1.2 TB devices: $(talosctl -n $NODE_IP get disks | grep "1.2 TB" | wc -l)"