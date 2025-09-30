#!/bin/bash
set -euo pipefail

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
  database.db.b64: |
EOF

# Append database.db.b64 with proper indentation
cat tmp-z2m-backup/database.db.b64 | sed 's/^/    /' >> kubernetes/apps/home-automation/zigbee2mqtt/basement/configmap-backup.yaml

# Add coordinator_backup.json.b64
echo "  coordinator_backup.json.b64: |" >> kubernetes/apps/home-automation/zigbee2mqtt/basement/configmap-backup.yaml
cat tmp-z2m-backup/coordinator_backup.json.b64 | sed 's/^/    /' >> kubernetes/apps/home-automation/zigbee2mqtt/basement/configmap-backup.yaml

# Add state.json.b64
echo "  state.json.b64: |" >> kubernetes/apps/home-automation/zigbee2mqtt/basement/configmap-backup.yaml
cat tmp-z2m-backup/state.json.b64 | sed 's/^/    /' >> kubernetes/apps/home-automation/zigbee2mqtt/basement/configmap-backup.yaml

echo "ConfigMap created successfully!"