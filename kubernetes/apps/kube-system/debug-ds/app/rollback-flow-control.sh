#!/bin/bash
# Script to rollback flow control changes on all nodes

# Function to rollback flow control settings on a specific node
rollback_node() {
  local pod_name=$1
  echo "Rolling back flow control settings on node for pod $pod_name..."
  
  # Get the list of interfaces
  interfaces=$(kubectl -n kube-system exec -it $pod_name -- bash -c "cd /host && ip link | grep -E 'eno[0-9]+' | awk -F: '{print \$2}' | tr -d ' ' | cut -d'<' -f1")
  
  for iface in $interfaces; do
    echo "  Restoring auto-negotiation for $iface..."
    kubectl -n kube-system exec -it $pod_name -- bash -c "cd /host && ethtool -A $iface autoneg on"
  done
}

# Get all debug pods
echo "Getting debug pods..."
pods=$(kubectl -n kube-system get pods -l app=debug-node -o=custom-columns=NAME:.metadata.name --no-headers)

# Rollback flow control on each node
for pod in $pods; do
  rollback_node $pod
done

echo "Flow control settings rolled back to auto-negotiation on all nodes."
echo "To verify, run: kubectl -n kube-system exec -it <pod-name> -- bash -c \"cd /host && ethtool -a eno1\""