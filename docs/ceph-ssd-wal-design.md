# Ceph SSD WAL/DB Design for VRTX Cluster

## Overview
This document describes the SSD WAL/DB configuration for improving Ceph performance on the Dell VRTX cluster.

## Partition Scheme

### Per-Node Configuration
- **SSDs per node**: 2
- **HDDs per node**: 6
- **Partitions per SSD**: 3
- **Partition size**: 124GB each
- **Total WAL/DB capacity**: 744GB per node (2 SSDs × 372GB)

### Partition Layout

#### SSD 1 (VD 0:0:4) - 372GB usable
- **Partition 1** (124GB): WAL/DB for HDD1 (VD 0:0:6)
- **Partition 2** (124GB): WAL/DB for HDD2 (VD 0:0:7)
- **Partition 3** (124GB): WAL/DB for HDD3 (VD 0:0:8)

#### SSD 2 (VD 0:0:5) - 372GB usable
- **Partition 1** (124GB): WAL/DB for HDD4 (VD 0:0:9)
- **Partition 2** (124GB): WAL/DB for HDD5 (VD 0:0:10)
- **Partition 3** (124GB): WAL/DB for HDD6 (VD 0:0:11)

## RAID Configuration

### SSD Virtual Disks
- **RAID Level**: RAID-0 (no redundancy, maximum performance)
- **Write Policy**: Write-Back (wb)
- **Read Policy**: No Read Ahead (nra)
- **Stripe Size**: 64KB
- **Disk Cache Policy**: Disabled

### HDD Virtual Disks
- **RAID Level**: RAID-0 (no redundancy, maximum capacity)
- **Write Policy**: Write-Through (wt)
- **Read Policy**: No Read Ahead (nra)
- **Stripe Size**: 128KB
- **Disk Cache Policy**: Disabled

## Benefits

1. **Improved Write Performance**: WAL writes go to fast SSDs instead of slow HDDs
2. **Better Metadata Performance**: DB operations are accelerated by SSD storage
3. **Reduced HDD Wear**: Sequential writes to HDDs, random writes absorbed by SSDs
4. **Optimal Space Utilization**: 124GB per OSD is sufficient for WAL/DB with 4TB HDDs

## Implementation Steps

1. **Create RAID-0 VDs on Dell CMC** (completed)
   - Created 2 SSD VDs and 6 HDD VDs per node

2. **Assign VDs to blade servers**
   - Use `vrtx-assign-vds.sh` script

3. **Create SSD partitions**
   - Run `create-ssd-partitions.sh` on each node after reboot

4. **Update Ceph configuration**
   - Add nodes with metadataDevice configuration

5. **Deploy OSDs**
   - Rook-Ceph will create OSDs with dedicated WAL/DB devices

## Device Path Mapping

Due to dual PERC controllers, each device appears on two PCI paths:
- Controller 1: `pci-0000:09:00.0-scsi-0:2:X:0`
- Controller 2: `pci-0000:14:00.0-scsi-0:2:X:0`

Where X is the VD number (4-11 for vrtx-alpha).

## Monitoring

Key metrics to monitor after implementation:
- OSD write latency (should decrease)
- SSD utilization (WAL/DB usage)
- Overall cluster IOPS (should increase)
- Recovery/rebalancing speed (should improve)