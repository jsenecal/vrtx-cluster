#!/bin/bash

# Create a clean ConfigMap with all backup files
cat > /home/jsenecal/Code/vrtx-cluster/kubernetes/apps/home-automation/zigbee2mqtt/basement/configmap-backup.yaml <<'EOF'
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: z2m-b-backup-data
  namespace: home-automation
data:
EOF

# Add configuration.yaml.b64
echo "  configuration.yaml.b64: |" >> /home/jsenecal/Code/vrtx-cluster/kubernetes/apps/home-automation/zigbee2mqtt/basement/configmap-backup.yaml
cat /home/jsenecal/Code/vrtx-cluster/tmp-z2m-backup/configuration.yaml.b64 | fold -w 76 | sed 's/^/    /' >> /home/jsenecal/Code/vrtx-cluster/kubernetes/apps/home-automation/zigbee2mqtt/basement/configmap-backup.yaml

# Add database.db.b64
echo "  database.db.b64: |" >> /home/jsenecal/Code/vrtx-cluster/kubernetes/apps/home-automation/zigbee2mqtt/basement/configmap-backup.yaml
cat /home/jsenecal/Code/vrtx-cluster/tmp-z2m-backup/database.db.b64 | fold -w 76 | sed 's/^/    /' >> /home/jsenecal/Code/vrtx-cluster/kubernetes/apps/home-automation/zigbee2mqtt/basement/configmap-backup.yaml

# Add coordinator_backup.json.b64
echo "  coordinator_backup.json.b64: |" >> /home/jsenecal/Code/vrtx-cluster/kubernetes/apps/home-automation/zigbee2mqtt/basement/configmap-backup.yaml
cat /home/jsenecal/Code/vrtx-cluster/tmp-z2m-backup/coordinator_backup.json.b64 | fold -w 76 | sed 's/^/    /' >> /home/jsenecal/Code/vrtx-cluster/kubernetes/apps/home-automation/zigbee2mqtt/basement/configmap-backup.yaml

# Add state.json.b64
echo "  state.json.b64: |" >> /home/jsenecal/Code/vrtx-cluster/kubernetes/apps/home-automation/zigbee2mqtt/basement/configmap-backup.yaml
cat /home/jsenecal/Code/vrtx-cluster/tmp-z2m-backup/state.json.b64 | fold -w 76 | sed 's/^/    /' >> /home/jsenecal/Code/vrtx-cluster/kubernetes/apps/home-automation/zigbee2mqtt/basement/configmap-backup.yaml