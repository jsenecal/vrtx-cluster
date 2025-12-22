#!/bin/bash
# Simple script to create RAID-0 VDs one by one
# This avoids the complexities of loops and SSH stdin issues

set -euo pipefail

# Configuration
CMC_IP="192.168.255.200"
CMC_USER="admin"
CMC_PASS="0235629xD!"
CONTROLLER="RAID.ChassisIntegrated.1-1"

# Parse arguments
AUTO_YES=false
for arg in "$@"; do
    case $arg in
        --yes)
            AUTO_YES=true
            ;;
    esac
done

echo "Dell VRTX RAID-0 Virtual Disk Creation Script (Simple Version)"
echo "============================================================="
echo ""

# Function to create a single VD
create_vd() {
    local bay=$1
    local enclosure=$2
    local vd_name="${enclosure}:0:${bay}"
    local disk_id="Disk.Bay.${bay}:Enclosure.Internal.${enclosure}-0:${CONTROLLER}"
    local media_type=$3
    local write_policy=$4
    local stripe_size=$5
    
    echo "Creating VD ${vd_name} on Bay ${bay} (${media_type})..."
    
    sshpass -p "${CMC_PASS}" ssh -o StrictHostKeyChecking=no "${CMC_USER}@${CMC_IP}" \
        "racadm raid createvd:${CONTROLLER} -rl r0 -wp ${write_policy} -rp nra -ss ${stripe_size} -dcp disabled -name ${vd_name} -pdkey:${disk_id}" 2>&1 | \
        grep -v "WARNING:" || true
    
    echo "Done."
    echo ""
}

# Show what we're going to create
echo "Will create the following VDs:"
echo "  0:0:5 - Bay 5 (SSD) - Write-Back, 64k stripe"
echo "  0:0:7 - Bay 7 (HDD) - Write-Through, 128k stripe"
echo "  0:0:8 - Bay 8 (HDD) - Write-Through, 128k stripe"
echo "  0:0:9 - Bay 9 (HDD) - Write-Through, 128k stripe"
echo ""

# Confirm
if [ "$AUTO_YES" != "true" ]; then
    read -p "Continue? (yes/no): " confirm
    if [ "$confirm" != "yes" ]; then
        echo "Aborted."
        exit 1
    fi
fi

# Create each VD
echo "Creating VDs..."
echo ""

# Create SSD
create_vd 5 0 "SSD" "wb" "64k"

# Create HDDs
create_vd 7 0 "HDD" "wt" "128k"
create_vd 8 0 "HDD" "wt" "128k"
create_vd 9 0 "HDD" "wt" "128k"

# Apply configuration
echo "Applying configuration..."
sshpass -p "${CMC_PASS}" ssh -o StrictHostKeyChecking=no "${CMC_USER}@${CMC_IP}" \
    "racadm jobqueue create ${CONTROLLER} -s TIME_NOW" 2>&1 | grep -v "WARNING:" || true

echo ""
echo "Configuration job submitted. The RAID controller will process the changes."
echo ""
echo "To check status, run:"
echo "  sshpass -p '${CMC_PASS}' ssh ${CMC_USER}@${CMC_IP} 'racadm jobqueue view'"
echo ""
echo "To see created VDs:"
echo "  sshpass -p '${CMC_PASS}' ssh ${CMC_USER}@${CMC_IP} 'racadm raid get vdisks -o -p Name'"