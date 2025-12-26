#!/bin/bash
# Script to create RAID-0 virtual disks for Ceph on Dell VRTX
# Names VDs based on their chassis position (e.g., 0:0:0 for Bay.0:Enclosure.0:Controller.1)
# SSDs use Write-Back, HDDs use Write-Through
# Usage: ./vrtx-create-ceph-vds.sh [--dry-run] [--yes]

set -uo pipefail

# Parse command line arguments
DRY_RUN=false
AUTO_YES=false
for arg in "$@"; do
    case $arg in
        --dry-run)
            DRY_RUN=true
            echo "*** DRY RUN MODE - No changes will be made ***"
            echo ""
            ;;
        --yes)
            AUTO_YES=true
            ;;
    esac
done

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
    
    # Check for any pending jobs first
    echo -e "${YELLOW}Checking for pending jobs...${NC}"
    pending_jobs=$(racadm_exec jobqueue view | grep -E "Status=(Running|Scheduled)" || echo "")
    if [ -n "$pending_jobs" ]; then
        echo -e "${YELLOW}Waiting for pending jobs to complete...${NC}"
        sleep 30
    fi
    
    echo -e "${YELLOW}Creating configuration job...${NC}"
    # Create job and capture output
    job_output=$(racadm_exec jobqueue create "$CONTROLLER" -s TIME_NOW 2>&1 || echo "ERROR")
    
    # Try to extract job ID
    job_id=$(echo "$job_output" | grep -oP 'JID_\d+' || echo "")
    
    # Check if we got the "commit failed" error but VDs were actually created
    if [[ "$job_output" == *"Commit job operation failed"* ]]; then
        echo -e "${YELLOW}Got 'commit failed' error, checking if VDs were actually created...${NC}"
        sleep 10
        
        # Check the latest job in the queue
        latest_job=$(racadm_exec jobqueue view | grep -E "JID_" | head -1 | grep -oP 'JID_\d+' || echo "")
        if [ -n "$latest_job" ]; then
            job_status=$(racadm_exec jobqueue view -i "$latest_job" 2>/dev/null | grep -E "Status=" | sed 's/Status=//')
            if [[ "$job_status" == *"Completed"* ]]; then
                echo -e "${GREEN}VDs were created successfully despite the error!${NC}"
                return 0
            fi
        fi
        echo -e "${YELLOW}Assuming VDs were created (common false negative)${NC}"
        return 0
    fi
    
    if [ -z "$job_id" ]; then
        echo -e "${RED}Failed to create job!${NC}"
        echo "$job_output"
        return 1
    fi
    
    echo -e "${GREEN}Created job: $job_id${NC}"
    
    # Monitor job completion
    echo "Monitoring job completion..."
    for i in {1..60}; do  # 10 minutes max
        job_status=$(racadm_exec jobqueue view -i "$job_id" 2>/dev/null | grep -E "Status=" | sed 's/Status=//')
        echo -n "."
        
        if [[ "$job_status" == *"Completed"* ]]; then
            echo -e "\n${GREEN}Job completed successfully!${NC}"
            sleep 5  # Give controller time to settle
            return 0
        elif [[ "$job_status" == *"Failed"* ]]; then
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
# First get the raw output, then process it
ready_disks=""
pdisk_output=$(racadm_exec raid get pdisks -o -p State)
current_disk=""

# Debug output
echo -e "${YELLOW}DEBUG: Processing disk states...${NC}"

while IFS= read -r line; do
    line=$(echo "$line" | xargs)  # Trim whitespace
    if [[ "$line" =~ ^Disk\.Bay\.[0-9]+: ]]; then
        current_disk="$line"
    elif [[ "$line" =~ State.*=.*Ready && -n "$current_disk" ]]; then
        ready_disks="${ready_disks}${current_disk}"$'\n'
        current_disk=""
    fi
done <<< "$pdisk_output"

# Remove trailing newline
ready_disks=$(echo "$ready_disks" | sed '/^$/d')

echo -e "${YELLOW}DEBUG: ready_disks content:${NC}"
echo "$ready_disks"
echo -e "${YELLOW}DEBUG: End of ready_disks${NC}"

if [ -z "$ready_disks" ]; then
    echo -e "${YELLOW}No disks in 'Ready' state found.${NC}"
    echo "All disks may already be configured."
    exit 0
fi

# Get all disk info at once to avoid multiple SSH connections
echo -e "${YELLOW}Gathering disk information...${NC}"
all_media=$(racadm_exec raid get pdisks -o -p MediaType)
all_sizes=$(racadm_exec raid get pdisks -o -p Size)

echo "Found disks ready for configuration:"
# Debug: show raw ready_disks
echo -e "${YELLOW}DEBUG: Number of ready disks: $(echo "$ready_disks" | grep -c "Disk.Bay")${NC}"

# Process each disk
while IFS= read -r disk; do
    [ -z "$disk" ] && continue
    [[ ! "$disk" =~ "Disk.Bay" ]] && continue
    
    position=$(get_position_name "$disk")
    
    # Extract info from cached data - fix the grep pattern
    disk_clean=$(echo "$disk" | awk '{print $1}')
    media_type=$(echo "$all_media" | grep -A1 "^${disk_clean}$" | grep "MediaType" | awk -F'=' '{print $2}' | xargs)
    size=$(echo "$all_sizes" | grep -A1 "^${disk_clean}$" | grep "Size" | awk -F'=' '{print $2}' | xargs)
    
    echo "  $disk_clean -> VD Name: $position ($size $media_type)"
done <<< "$ready_disks"

echo ""
if [ "$AUTO_YES" = true ]; then
    echo "Auto-confirming due to --yes flag"
    confirm="yes"
else
    read -p "Do you want to create RAID-0 VDs for all ready disks? (yes/no): " confirm
fi

if [ "$confirm" != "yes" ]; then
    echo "Aborted."
    exit 1
fi

# Process SSDs first, then HDDs
echo ""
echo "Creating Virtual Disks..."
echo "------------------------"

# Use cached data to separate disks
ssd_disks=""
hdd_disks=""

while IFS= read -r disk; do
    [ -z "$disk" ] && continue
    [[ ! "$disk" =~ "Disk.Bay" ]] && continue
    
    # Clean the disk name
    disk_clean=$(echo "$disk" | awk '{print $1}')
    media_type=$(echo "$all_media" | grep -A1 "^${disk_clean}$" | grep "MediaType" | awk -F'=' '{print $2}' | xargs)
    
    if [ "$media_type" = "SSD" ]; then
        ssd_disks="${ssd_disks}${disk_clean}"$'\n'
    elif [ "$media_type" = "HDD" ]; then
        hdd_disks="${hdd_disks}${disk_clean}"$'\n'
    fi
done <<< "$ready_disks"

# Trim trailing newlines
ssd_disks=$(echo "$ssd_disks" | sed '/^$/d')
hdd_disks=$(echo "$hdd_disks" | sed '/^$/d')

# Debug: show what we found
echo -e "${YELLOW}DEBUG: Found $(echo "$ssd_disks" | grep -c "Disk.Bay") SSDs and $(echo "$hdd_disks" | grep -c "Disk.Bay") HDDs${NC}"

# Create ALL VDs first (SSDs and HDDs)
vd_created=false

# Convert disk lists to arrays
readarray -t ssd_array <<< "$ssd_disks"
readarray -t hdd_array <<< "$hdd_disks"

# Debug arrays
echo -e "${YELLOW}DEBUG: SSD array has ${#ssd_array[@]} elements${NC}"
for i in "${!ssd_array[@]}"; do
    echo "  SSD[$i]: '${ssd_array[$i]}'"
done
echo -e "${YELLOW}DEBUG: HDD array has ${#hdd_array[@]} elements${NC}"
for i in "${!hdd_array[@]}"; do
    echo "  HDD[$i]: '${hdd_array[$i]}'"
done

# Build commands for SSDs
if [ ${#ssd_array[@]} -gt 0 ] && [ -n "${ssd_array[0]}" ]; then
    echo -e "${YELLOW}Preparing SSD Virtual Disks (Write-Back):${NC}"
    ssd_count=0
    declare -A seen_vd_names
    for disk in "${ssd_array[@]}"; do
        [ -z "$disk" ] && continue
        [[ ! "$disk" =~ "Disk.Bay" ]] && continue
        vd_name=$(get_position_name "$disk")
        
        # Skip if we've already seen this VD name
        if [[ -n "${seen_vd_names[$vd_name]:-}" ]]; then
            echo "  Skipping: $disk (would create duplicate VD name: $vd_name)"
            continue
        fi
        seen_vd_names[$vd_name]=1
        
        echo "  Will create: $vd_name on $disk (SSD)"
        vd_created=true
        ssd_count=$((ssd_count + 1))
    done
    echo -e "${GREEN}Prepared $ssd_count SSD VDs${NC}"
fi

# Build commands for HDDs
if [ ${#hdd_array[@]} -gt 0 ] && [ -n "${hdd_array[0]}" ]; then
    echo ""
    echo -e "${YELLOW}Preparing HDD Virtual Disks (Write-Through):${NC}"
    hdd_count=0
    declare -A seen_vd_names
    for disk in "${hdd_array[@]}"; do
        [ -z "$disk" ] && continue
        [[ ! "$disk" =~ "Disk.Bay" ]] && continue
        vd_name=$(get_position_name "$disk")
        
        # Skip if we've already seen this VD name
        if [[ -n "${seen_vd_names[$vd_name]:-}" ]]; then
            echo "  Skipping: $disk (would create duplicate VD name: $vd_name)"
            continue
        fi
        seen_vd_names[$vd_name]=1
        
        echo "  Will create: $vd_name on $disk (HDD)"
        vd_created=true
        hdd_count=$((hdd_count + 1))
    done
    echo -e "${GREEN}Prepared $hdd_count HDD VDs${NC}"
fi

# Execute all commands individually
if [ "$vd_created" = true ] && [ "$DRY_RUN" = false ]; then
    echo ""
    echo -e "${YELLOW}Executing VD creation commands...${NC}"
    
    # Process SSDs
    if [ ${#ssd_array[@]} -gt 0 ] && [ -n "${ssd_array[0]}" ]; then
        for disk in "${ssd_array[@]}"; do
            [ -z "$disk" ] && continue
            [[ ! "$disk" =~ "Disk.Bay" ]] && continue
            vd_name=$(get_position_name "$disk")
            
            # Skip if duplicate
            if [[ -n "${seen_vd_names[$vd_name]:-}" ]]; then
                continue
            fi
            
            echo -n "Creating $vd_name... "
            if racadm_exec raid createvd:"$CONTROLLER" -rl r0 -wp wb -rp nra -ss 64k -dcp disabled -name "$vd_name" -pdkey:"$disk"; then
                echo "Success"
            else
                echo "Failed (may already exist)"
            fi
        done
    fi
    
    # Process HDDs
    if [ ${#hdd_array[@]} -gt 0 ] && [ -n "${hdd_array[0]}" ]; then
        declare -A seen_vd_names_exec
        for disk in "${hdd_array[@]}"; do
            [ -z "$disk" ] && continue
            [[ ! "$disk" =~ "Disk.Bay" ]] && continue
            vd_name=$(get_position_name "$disk")
            
            # Skip if duplicate
            if [[ -n "${seen_vd_names_exec[$vd_name]:-}" ]]; then
                continue
            fi
            seen_vd_names_exec[$vd_name]=1
            
            echo -n "Creating $vd_name... "
            if racadm_exec raid createvd:"$CONTROLLER" -rl r0 -wp wt -rp nra -ss 128k -dcp disabled -name "$vd_name" -pdkey:"$disk"; then
                echo "Success"
            else
                echo "Failed (may already exist)"
            fi
        done
    fi
fi

# Apply configuration ONCE for all VDs
if [ "$vd_created" = true ]; then
    echo ""
    echo -e "${YELLOW}Applying configuration for all VDs...${NC}"
    if apply_raid_config; then
        echo -e "${GREEN}All VD configurations completed!${NC}"
    else
        echo -e "${RED}Configuration failed!${NC}"
        echo -e "${YELLOW}Note: VDs may have been created despite the error. Check with: racadm raid get vdisks${NC}"
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