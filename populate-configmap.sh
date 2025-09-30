#!/bin/bash
set -e

# Working directory
cd /home/jsenecal/Code/vrtx-cluster

# Create temporary file
cp kubernetes/apps/home-automation/zigbee2mqtt/basement/configmap-backup.yaml /tmp/configmap.yaml

# Read each base64 file and replace placeholders
CONFIG_B64=$(cat tmp-z2m-backup/configuration.yaml.b64 | fold -w 76 | sed 's/^/    /')
DB_B64=$(cat tmp-z2m-backup/database.db.b64 | fold -w 76 | sed 's/^/    /')
COORD_B64=$(cat tmp-z2m-backup/coordinator_backup.json.b64 | fold -w 76 | sed 's/^/    /')
STATE_B64=$(cat tmp-z2m-backup/state.json.b64 | fold -w 76 | sed 's/^/    /')

# Use awk to replace placeholders
awk -v config="$CONFIG_B64" -v db="$DB_B64" -v coord="$COORD_B64" -v state="$STATE_B64" '
/PLACEHOLDER_CONFIG/ {print config; next}
/PLACEHOLDER_DB/ {print db; next}
/PLACEHOLDER_COORD/ {print coord; next}
/PLACEHOLDER_STATE/ {print state; next}
{print}
' /tmp/configmap.yaml > kubernetes/apps/home-automation/zigbee2mqtt/basement/configmap-backup.yaml

echo "ConfigMap created successfully"