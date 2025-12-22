#!/bin/bash
# Script to create RAID-0 virtual disks for Ceph on Dell VRTX
# Names VDs based on their chassis position (e.g., 0:0:0 for Bay.0:Enclosure.0:Controller.1)
# SSDs use Write-Back, HDDs use Write-Through
# Usage: ./vrtx-create-ceph-vds.sh [--dry-run]

set -euo pipefail

# Check for dry-run flag
DRY_RUN=false
if [[ "${1:-}" == "--dry-run" ]]; then
    DRY_RUN=true
    echo "*** DRY RUN MODE - No changes will be made ***"
    echo ""
fi

# Configuration
CMC_IP="192.168.255.200"
CMC_USER="admin"
CMC_PASS="0235629xD!"
CONTROLLER="RAID.ChassisIntegrated.1-1"

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to execute RACADM command via SSH
racadm_exec() {
    sshpass -p "$CMC_PASS" ssh -o StrictHostKeyChecking=no "$CMC_USER@$CMC_IP" "racadm $*" 2>&1 | grep -v "WARNING:"
}

# Function to extract position from disk ID
# Input: Disk.Bay.21:Enclosure.Internal.0-0:RAID.ChassisIntegrated.1-1
# Output: 0:0:21 (enclosure:0:slot)
get_position_name() {
    local disk_id=$1
    local bay=$(echo "$disk_id" | grep -oP 'Bay\.\K\d+')
    local enclosure=$(echo "$disk_id" | grep -oP 'Enclosure\.Internal\.\K\d+' | cut -d'-' -f1)
    # Controller is always 0 for VD naming
    echo "${enclosure}:0:${bay}"
}

# Function to create a RAID-0 VD
create_raid0_vd() {
    local disk_id=$1
    local media_type=$2
    local vd_name=$(get_position_name "$disk_id")
    
    echo -e "${YELLOW}Creating RAID-0 VD: $vd_name on $disk_id ($media_type)${NC}"
    
    # Set cache policy and stripe size based on media type
    if [ "$media_type" = "SSD" ]; then
        # SSDs: Write-Back for performance, 64K stripe size
        write_policy="wb"
        stripe_size="64k"
    else
        # HDDs: Write-Through for safety, 128K stripe size
        write_policy="wt"
        stripe_size="128k"
    fi
    
    # Create virtual disk with RAID-0
    # -rl r0: RAID-0
    # -wp: Write Policy (wb=Write Back, wt=Write Through)
    # -rp nra: No Read Ahead (recommended for Ceph)
    # -ss: Stripe size (64K for SSDs, 128K for HDDs)
    # -dcp disabled: Disable disk cache (let Ceph handle caching)
    if [ "$DRY_RUN" = true ]; then
        echo "  [DRY RUN] Would execute: racadm raid createvd:$CONTROLLER -rl r0 -wp $write_policy -rp nra -ss $stripe_size -dcp disabled -name $vd_name -pdkey:$disk_id"
    else
        racadm_exec raid createvd:"$CONTROLLER" -rl r0 -wp "$write_policy" -rp nra -ss $stripe_size -dcp disabled -name "$vd_name" -pdkey:"$disk_id"
    fi
}

# Function to create configuration job
apply_raid_config() {
    if [ "$DRY_RUN" = true ]; then
        echo -e "${YELLOW}[DRY RUN] Would create configuration job${NC}"
        return 0
    fi
    
    echo -e "${YELLOW}Creating configuration job...${NC}"
    job_output=$(racadm_exec raid jobqueue create "$CONTROLLER" -s TIME_NOW)
    job_id=$(echo "$job_output" | grep -oP 'JOB_\d+' || echo "")
    
    if [ -z "$job_id" ]; then
        echo -e "${RED}Failed to create job!${NC}"
        echo "$job_output"
        return 1
    fi
    
    echo -e "${GREEN}Created job: $job_id${NC}"
    
    # Monitor job completion
    echo "Monitoring job completion..."
    for i in {1..60}; do  # 10 minutes max
        status=$(racadm_exec jobqueue view -i "$job_id" | grep "Status" | awk '{print $3}')
        echo -n "."
        
        if [ "$status" = "Completed" ]; then
            echo -e "\n${GREEN}Job completed successfully!${NC}"
            return 0
        elif [ "$status" = "Failed" ]; then
            echo -e "\n${RED}Job failed!${NC}"
            racadm_exec jobqueue view -i "$job_id"
            return 1
        fi
        
        sleep 10
    done
    
    echo -e "\n${RED}Job timed out!${NC}"
    return 1
}

# Main execution
echo "Dell VRTX Ceph RAID-0 Virtual Disk Creation Script"
echo "=================================================="
echo ""

# Show current disk status
echo "Current Physical Disks (Ready state):"
echo "------------------------------------"
racadm_exec raid get pdisks -o -p MediaType,Size,State | grep -B1 -A2 "Ready" | grep -E "(Disk.Bay|MediaType|Size|State)" | awk 'NR%4==1{print ""} {print}'

echo ""
echo "Current Virtual Disks:"
echo "---------------------"
racadm_exec raid get vdisks -o -p Name,Size,Layout | grep -E "(Disk.Virtual|Name|Size|Layout)" | awk 'NR%4==1{print ""} {print}'

echo ""
echo -e "${YELLOW}Configuration Settings:${NC}"
echo "- VD Naming: Enclosure:Controller:Slot (e.g., 0:0:21 for slot 21)"
echo "- SSDs: Write-Back cache policy"
echo "- HDDs: Write-Through cache policy"
echo "- Read Policy: No Read Ahead (Ceph optimized)"
echo "- Stripe Size: 64K for SSDs, 128K for HDDs"
echo "- Disk Cache: Disabled"
echo ""

# Get all disks in Ready state
ready_disks=$(racadm_exec raid get pdisks -o -p State | grep -B1 "Ready" | grep "Disk.Bay" | cut -d' ' -f1)

if [ -z "$ready_disks" ]; then
    echo -e "${YELLOW}No disks in 'Ready' state found.${NC}"
    echo "All disks may already be configured."
    exit 0
fi

echo "Found disks ready for configuration:"
while IFS= read -r disk; do
    position=$(get_position_name "$disk")
    disk_info=$(racadm_exec raid get pdisks -o -p MediaType,Size | grep -A2 "$disk" | grep -E "(MediaType|Size)" | awk '{print $3}' | tr '\n' ' ')
    echo "  $disk -> VD Name: $position ($disk_info)"
done <<< "$ready_disks"

echo ""
read -p "Do you want to create RAID-0 VDs for all ready disks? (yes/no): " confirm

if [ "$confirm" != "yes" ]; then
    echo "Aborted."
    exit 1
fi

# Process SSDs first, then HDDs
echo ""
echo "Creating Virtual Disks..."
echo "------------------------"

# Separate SSDs and HDDs
ssd_disks=""
hdd_disks=""

while IFS= read -r disk; do
    media_type=$(racadm_exec raid get pdisks -o -p MediaType | grep -A1 "$disk" | grep "MediaType" | awk '{print $3}')
    if [ "$media_type" = "SSD" ]; then
        ssd_disks+="$disk"$'\n'
    else
        hdd_disks+="$disk"$'\n'
    fi
done <<< "$ready_disks"

# Create SSDs first
if [ -n "$ssd_disks" ]; then
    echo -e "${YELLOW}Creating SSD Virtual Disks (Write-Back):${NC}"
    while IFS= read -r disk; do
        [ -z "$disk" ] && continue
        create_raid0_vd "$disk" "SSD"
    done <<< "$ssd_disks"
    
    if apply_raid_config; then
        echo -e "${GREEN}SSD configuration completed!${NC}"
    else
        echo -e "${RED}SSD configuration failed!${NC}"
        exit 1
    fi
fi

# Create HDDs
if [ -n "$hdd_disks" ]; then
    echo ""
    echo -e "${YELLOW}Creating HDD Virtual Disks (Write-Through):${NC}"
    while IFS= read -r disk; do
        [ -z "$disk" ] && continue
        create_raid0_vd "$disk" "HDD"
    done <<< "$hdd_disks"
    
    if apply_raid_config; then
        echo -e "${GREEN}HDD configuration completed!${NC}"
    else
        echo -e "${RED}HDD configuration failed!${NC}"
        exit 1
    fi
fi

echo ""
echo -e "${GREEN}Virtual disk creation completed!${NC}"
echo ""
echo "Created VDs Summary:"
racadm_exec raid get vdisks -o -p Name,MediaType,WritePolicy,ReadPolicy | grep -E "(Disk.Virtual|Name|MediaType|WritePolicy|ReadPolicy)"
echo ""
echo "Next steps:"
echo "1. Run the VD assignment script to assign disks to blade servers"
echo "2. Reboot the blade servers to see the new disks"
echo "3. Partition the SSDs for Ceph WAL/DB usage"
echo "4. Configure Rook-Ceph to use the new storage layout"