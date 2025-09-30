#!/bin/bash
set -euo pipefail

# First extract all needed files
cd /home/jsenecal/Code/vrtx-cluster
mkdir -p tmp-z2m-backup
unzip -o /home/jsenecal/Downloads/z2m-backup.2.6.1.2025-09-27-19-13-38.zip configuration.yaml database.db coordinator_backup.json state.json -d tmp-z2m-backup/

# Base64 encode them
cd tmp-z2m-backup
base64 -w0 configuration.yaml > configuration.yaml.b64
base64 -w0 database.db > database.db.b64
base64 -w0 coordinator_backup.json > coordinator_backup.json.b64
base64 -w0 state.json > state.json.b64
cd ..

# Create ConfigMap
cat > kubernetes/apps/home-automation/zigbee2mqtt/basement/configmap-backup.yaml <<EOF
---
# yaml-language-server: \$schema=https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/v1-configmap.json
apiVersion: v1
kind: ConfigMap
metadata:
  name: z2m-b-backup-data
  annotations:
    kustomize.toolkit.fluxcd.io/substitute: disabled
data:
  configuration.yaml.b64: |
EOF

# Append configuration.yaml.b64 with proper indentation
cat tmp-z2m-backup/configuration.yaml.b64 | sed 's/^/    /' >> kubernetes/apps/home-automation/zigbee2mqtt/basement/configmap-backup.yaml

# Add database.db.b64
echo "  database.db.b64: |" >> kubernetes/apps/home-automation/zigbee2mqtt/basement/configmap-backup.yaml
cat tmp-z2m-backup/database.db.b64 | sed 's/^/    /' >> kubernetes/apps/home-automation/zigbee2mqtt/basement/configmap-backup.yaml

# Add coordinator_backup.json.b64
echo "  coordinator_backup.json.b64: |" >> kubernetes/apps/home-automation/zigbee2mqtt/basement/configmap-backup.yaml
cat tmp-z2m-backup/coordinator_backup.json.b64 | sed 's/^/    /' >> kubernetes/apps/home-automation/zigbee2mqtt/basement/configmap-backup.yaml

# Add state.json.b64
echo "  state.json.b64: |" >> kubernetes/apps/home-automation/zigbee2mqtt/basement/configmap-backup.yaml
cat tmp-z2m-backup/state.json.b64 | sed 's/^/    /' >> kubernetes/apps/home-automation/zigbee2mqtt/basement/configmap-backup.yaml

echo "ConfigMap with configuration.yaml created successfully!"