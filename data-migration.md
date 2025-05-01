# Media Services Data Migration Guide

This document outlines the steps to migrate all data from your existing home-k3s cluster to the new vrtx-cluster for media services applications.

## Overview

The goal is to transfer the complete application state including all configuration files, databases, and application data (excluding temporary cache and logs where appropriate).

## Prerequisite Steps

1. Create application resources in vrtx-cluster with suspended HelmReleases
2. Wait for PVCs to be created
3. Perform data migration
4. Unsuspend the HelmReleases

## Migration Approaches

### Method 1: Direct RSyncing (Recommended)

This method uses rsync with SSH to directly copy data from the source cluster's storage to the destination cluster's PVCs.

#### Step 1: Identify Source PV Locations

```bash
# Get source PV names and node
KUBECONFIG=/home/jsenecal/Code/home-k3s/kubeconfig kubectl get pvc -n media-services APP_NAME-config -o jsonpath='{.spec.volumeName}'
KUBECONFIG=/home/jsenecal/Code/home-k3s/kubeconfig kubectl get pvc -n media-services APP_NAME-cache -o jsonpath='{.spec.volumeName}' # If exists
KUBECONFIG=/home/jsenecal/Code/home-k3s/kubeconfig kubectl get nodes -o wide # To find node IP (192.168.168.5 for oxide)
```

#### Step 2: Create Migration Pod with RSyncing Capabilities

Create a pod manifest that mounts the destination PVCs:

```yaml
# overseerr-migration-rsync.yaml
apiVersion: v1
kind: Pod
metadata:
  name: overseerr-migration-rsync
  namespace: media-services
spec:
  containers:
  - name: rsync
    image: instrumentisto/rsync-ssh
    command:
    - sleep
    - "86400"  # Sleep for 24 hours to give time for rsync operations
    securityContext:
      runAsUser: 0  # Run as root to access all files
    volumeMounts:
    - mountPath: "/APP_NAME-config"
      name: APP_NAME-config
    - mountPath: "/APP_NAME-cache"  # If needed
      name: APP_NAME-cache
  volumes:
  - name: APP_NAME-config
    persistentVolumeClaim:
      claimName: APP_NAME  # Main PVC name
  - name: APP_NAME-cache  # If needed
    persistentVolumeClaim:
      claimName: APP_NAME-cache  # Cache PVC name if exists
```

Apply with:
```bash
kubectl apply -f overseerr-migration-rsync.yaml
```

#### Step 3: Set Up SSH Access

Copy your SSH private key to the migration pod:

```bash
# Create SSH directory
kubectl -n media-services exec overseerr-migration-rsync -- mkdir -p /root/.ssh

# Create SSH config to avoid host key verification
cat > /tmp/ssh-config << EOF
Host 192.168.168.5
  StrictHostKeyChecking no
  UserKnownHostsFile=/dev/null
EOF

# Copy SSH key and config to pod
kubectl -n media-services cp ~/.ssh/id_rsa overseerr-migration-rsync:/root/.ssh/id_rsa
kubectl -n media-services cp /tmp/ssh-config overseerr-migration-rsync:/root/.ssh/config

# Fix permissions and ownership
kubectl -n media-services exec overseerr-migration-rsync -- chmod 600 /root/.ssh/id_rsa /root/.ssh/config
kubectl -n media-services exec overseerr-migration-rsync -- chmod 700 /root/.ssh
kubectl -n media-services exec overseerr-migration-rsync -- chown -R root:root /root/.ssh
```

#### Step 4: Execute RSyncing

Run rsync to copy all data directly from the source node to the target PVCs:

```bash
# Config directory (excludes cache and logs)
kubectl -n media-services exec -it overseerr-migration-rsync -- rsync -avz \
  --exclude="Cache" --exclude="cache" \
  --exclude="Logs" --exclude="logs" \
  --progress \
  root@192.168.168.5:/var/openebs/local/SOURCE_CONFIG_PV/ /APP_NAME-config/

# Cache directory (if needed)
kubectl -n media-services exec -it overseerr-migration-rsync -- rsync -avz \
  --progress \
  root@192.168.168.5:/var/openebs/local/SOURCE_CACHE_PV/ /APP_NAME-cache/
```

### Method 2: Pod-to-Pod Transfer (Alternative)

This method uses temporary migration pods and tar archives to transfer all data.

#### Step 1: Create Migration Pod

For each application (replace `APP_NAME` with actual name like `plex`, `sonarr`, etc.):

```yaml
# /tmp/APP_NAME-migration-pod.yaml
apiVersion: v1
kind: Pod
metadata:
  name: APP_NAME-migration
  namespace: media-services
spec:
  containers:
  - name: migration
    image: busybox
    command: ["sleep", "3600"]
    volumeMounts:
    - name: config
      mountPath: /config
  volumes:
  - name: config
    persistentVolumeClaim:
      claimName: APP_NAME
```

Apply with:
```bash
kubectl apply -f /tmp/APP_NAME-migration-pod.yaml
```

#### Step 2: Transfer All Data

Create and run a migration script:

```bash
#!/bin/bash
set -euo pipefail

# Get source pod name
SOURCE_POD=$(KUBECONFIG=/home/jsenecal/Code/home-k3s/kubeconfig kubectl get pods -n media-services -l app.kubernetes.io/name=APP_NAME -o jsonpath='{.items[0].metadata.name}')

# Get target pod name
TARGET_POD="APP_NAME-migration"

echo "Creating tar archive of all APP_NAME data from home-k3s cluster..."
KUBECONFIG=/home/jsenecal/Code/home-k3s/kubeconfig kubectl exec -n media-services $SOURCE_POD -c app -- tar -cf - -C /config . --exclude="./Cache" --exclude="./cache" --exclude="./Logs" --exclude="./logs" > /tmp/APP_NAME-config.tar

echo "Extracting to target cluster..."
cat /tmp/APP_NAME-config.tar | kubectl exec -i -n media-services $TARGET_POD -- tar -xf - -C /config

echo "Migration complete!"
```

### Method 3: Direct Volume Access

For clusters where you have direct access to the storage volumes:

#### Step 1: Identify PV Locations

```bash
# Source cluster PVC/PV
KUBECONFIG=/home/jsenecal/Code/home-k3s/kubeconfig kubectl get pvc -n media-services APP_NAME -o jsonpath='{.spec.volumeName}'
SOURCE_PV=$(KUBECONFIG=/home/jsenecal/Code/home-k3s/kubeconfig kubectl get pvc -n media-services APP_NAME -o jsonpath='{.spec.volumeName}')

# For OpenEBS Local PV, find the data at:
# /var/openebs/local/SOURCE_PV/

# Target cluster PVC/PV
TARGET_PV=$(kubectl get pvc -n media-services APP_NAME -o jsonpath='{.spec.volumeName}')
```

#### Step 2: Copy Data Directly

SSH to the storage nodes and copy data:

```bash
# On source node
ssh user@source-node

# For OpenEBS volumes, data is at:
cd /var/openebs/local/SOURCE_PV/

# Use rsync to copy to temporary location
rsync -avz --exclude="cache" --exclude="Cache" --exclude="logs" --exclude="Logs" /var/openebs/local/SOURCE_PV/ /tmp/transfer/

# Then copy from temporary location to destination volume
rsync -avz /tmp/transfer/ /path/to/destination/volume/
```

## Application-Specific Considerations

While we want to transfer all data, here are some application-specific considerations:

### Plex

- Transfer the entire `/config` directory excluding Cache and Logs
- Key locations: `/config/Library/Application Support/Plex Media Server/`
- For rsync method with Plex:
  ```bash
  # Identify source PVs
  KUBECONFIG=/home/jsenecal/Code/home-k3s/kubeconfig kubectl get pvc -n media-services plex-config -o jsonpath='{.spec.volumeName}'
  # pvc-7ebcfdca-030e-4451-8bab-1dc510f114f5

  KUBECONFIG=/home/jsenecal/Code/home-k3s/kubeconfig kubectl get pvc -n media-services plex-cache -o jsonpath='{.spec.volumeName}'
  # pvc-762e4caf-b0cd-4df4-95cc-4b24f9cb9610

  # Create migration pod manifest
  kubectl apply -f kubernetes/apps/media-services/plex/app/migration-pod-rsync.yaml

  # Set up SSH access
  kubectl -n media-services exec plex-migration-rsync -- mkdir -p /root/.ssh
  kubectl -n media-services cp ~/.ssh/id_rsa plex-migration-rsync:/root/.ssh/id_rsa
  kubectl -n media-services cp /tmp/ssh-config plex-migration-rsync:/root/.ssh/config
  kubectl -n media-services exec plex-migration-rsync -- chmod 600 /root/.ssh/id_rsa /root/.ssh/config
  kubectl -n media-services exec plex-migration-rsync -- chmod 700 /root/.ssh
  kubectl -n media-services exec plex-migration-rsync -- chown -R root:root /root/.ssh

  # Execute rsync
  kubectl -n media-services exec -it plex-migration-rsync -- rsync -avz --exclude="Cache" --exclude="Library/Application Support/Plex Media Server/Cache" --exclude="Logs" --exclude="Library/Application Support/Plex Media Server/Logs" --progress root@192.168.168.5:/var/openebs/local/pvc-7ebcfdca-030e-4451-8bab-1dc510f114f5/ /plex-config/

  kubectl -n media-services exec -it plex-migration-rsync -- rsync -avz --progress root@192.168.168.5:/var/openebs/local/pvc-762e4caf-b0cd-4df4-95cc-4b24f9cb9610/ /plex-cache/
  ```

### Sonarr/Radarr/Prowlarr

- Transfer entire `/config` excluding logs and temporary media cover caches
- Databases contain all the critical configuration

### Overseerr

- Ensure the `/app/config` directory is fully transferred
- The SQLite database in `/app/config/db/` contains user data and requests

### Tautulli

- Full transfer of the `/config` directory preserves all history and settings

## Post-Migration Verification

Before enabling the applications, verify data was transferred correctly:

```bash
# Check file ownership and permissions
kubectl exec -n media-services APP_NAME-migration -- ls -la /config

# Check database files exist
kubectl exec -n media-services APP_NAME-migration -- find /config -name "*.db"

# Check config files exist
kubectl exec -n media-services APP_NAME-migration -- find /config -name "*.xml"
```

## Enabling Applications

Once data migration is complete:

1. Remove the migration pods:
```bash
kubectl delete pod -n media-services APP_NAME-migration
```

2. Edit the HelmRelease to remove the suspend flag:
```yaml
spec:
  # Remove or comment out this line
  # suspend: true
```

3. Commit and push changes to apply with GitOps:
```bash
git add kubernetes/apps/media-services/APP_NAME/app/helmrelease.yaml
git commit -m "Enable APP_NAME after data migration"
git push
```

## Troubleshooting

If issues arise after migration:

1. Check container logs:
```bash
kubectl logs -n media-services -l app.kubernetes.io/name=APP_NAME
```

2. Verify permissions are correct:
```bash
kubectl exec -n media-services POD_NAME -- ls -la /config
```

3. For database issues, consider repairing:
```bash
kubectl exec -it -n media-services POD_NAME -- bash
# Then use appropriate database tools
```
