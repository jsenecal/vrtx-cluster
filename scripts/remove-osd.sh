#!/bin/bash
# Script to safely remove an OSD from the Ceph cluster

set -euo pipefail

OSD_ID="${1:-}"

if [ -z "$OSD_ID" ]; then
    echo "Usage: $0 <osd-id>"
    echo "Example: $0 1"
    exit 1
fi

echo "=== Removing OSD.$OSD_ID from Ceph Cluster ==="
echo ""

# Step 1: Mark OSD out
echo "1. Marking OSD.$OSD_ID as out..."
kubectl -n rook-ceph exec -it deploy/rook-ceph-tools -- ceph osd out $OSD_ID

# Step 2: Wait for data to be moved off the OSD
echo ""
echo "2. Waiting for data to be moved off OSD.$OSD_ID..."
echo "(Note: With <3 OSDs and 3x replication, some objects will remain misplaced)"
while true; do
    # Check if OSD has any data
    osd_used=$(kubectl -n rook-ceph exec -it deploy/rook-ceph-tools -- ceph osd df 2>/dev/null | grep "^ *$OSD_ID " | awk '{print $5}')
    
    if [[ "$osd_used" == "0" || "$osd_used" == "0B" ]]; then
        echo "OSD.$OSD_ID has no data, safe to proceed!"
        break
    fi
    
    echo "OSD.$OSD_ID still has data: $osd_used"
    sleep 10
done

# Step 3: Check if safe to destroy
echo ""
echo "3. Checking if OSD.$OSD_ID is safe to destroy..."
if kubectl -n rook-ceph exec -it deploy/rook-ceph-tools -- ceph osd safe-to-destroy $OSD_ID 2>/dev/null; then
    echo "OSD.$OSD_ID is safe to destroy"
else
    echo "Warning: OSD.$OSD_ID still has PGs mapped, but since it has no data, proceeding..."
fi

# Step 4: Stop the OSD pod
echo ""
echo "4. Scaling down OSD.$OSD_ID deployment..."
kubectl -n rook-ceph scale deployment rook-ceph-osd-$OSD_ID --replicas=0

# Wait for pod to terminate
echo "Waiting for OSD pod to terminate..."
kubectl -n rook-ceph wait --for=delete pod -l ceph-osd-id=$OSD_ID --timeout=60s || true

# Step 5: Purge OSD from cluster
echo ""
echo "5. Purging OSD.$OSD_ID from cluster..."
kubectl -n rook-ceph exec -it deploy/rook-ceph-tools -- ceph osd purge $OSD_ID --yes-i-really-mean-it

# Step 6: Delete the deployment
echo ""
echo "6. Deleting OSD deployment..."
kubectl -n rook-ceph delete deployment rook-ceph-osd-$OSD_ID

echo ""
echo "OSD.$OSD_ID has been removed from the cluster!"
echo ""
echo "Next steps:"
echo "- Remove the PVC if it exists: kubectl -n rook-ceph delete pvc <pvc-name>"
echo "- Clean up the disk on the node if needed"