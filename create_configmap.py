#!/usr/bin/env python3
import os
import base64
import zipfile

# Extract and base64 encode the backup files
backup_zip = "/home/jsenecal/Downloads/z2m-backup.2.6.1.2025-09-27-19-13-38.zip"
files_to_include = [
    "configuration.yaml",
    "database.db", 
    "coordinator_backup.json",
    "state.json"
]

# Start building the ConfigMap
configmap = """---
apiVersion: v1
kind: ConfigMap
metadata:
  name: z2m-b-backup-data
  namespace: home-automation
data:
"""

# Extract and process each file from the zip
with zipfile.ZipFile(backup_zip, 'r') as zip_file:
    for filename in files_to_include:
        # Read the file from zip
        with zip_file.open(filename) as f:
            content = f.read()
        
        # Base64 encode
        b64_content = base64.b64encode(content).decode('utf-8')
        
        # Format for YAML - split into 76 char lines and indent
        lines = []
        for i in range(0, len(b64_content), 76):
            lines.append("    " + b64_content[i:i+76])
        
        # Add to configmap
        field_name = filename + ".b64"
        configmap += f"  {field_name}: |\n"
        configmap += "\n".join(lines)
        configmap += "\n"

# Write the ConfigMap
output_path = "/home/jsenecal/Code/vrtx-cluster/kubernetes/apps/home-automation/zigbee2mqtt/basement/configmap-backup.yaml"
with open(output_path, 'w') as f:
    f.write(configmap)

print(f"ConfigMap created successfully at {output_path}")