#!/usr/bin/env python3
import yaml

# Read the configuration file
with open('/home/jsenecal/Code/vrtx-cluster/tmp-z2m-backup/configuration.yaml', 'r') as f:
    config = yaml.safe_load(f)

# Extract network configuration
network_key = config['advanced']['network_key']
pan_id = config['advanced']['pan_id']
ext_pan_id = config['advanced']['ext_pan_id']

# Convert network_key array to hex string
network_key_hex = '[' + ','.join([f'0x{k:02X}' for k in network_key]) + ']'

# Convert ext_pan_id array to hex string
ext_pan_id_hex = '[' + ','.join([f'0x{k:02X}' for k in ext_pan_id]) + ']'

print(f"Network Key: {network_key_hex}")
print(f"PAN ID: {pan_id}")
print(f"Extended PAN ID: {ext_pan_id_hex}")

# Create patch commands
print("\nKubectl patch commands:")
print(f"kubectl -n home-automation patch secret z2m-b-secrets --type='json' -p='[{{\"op\": \"replace\", \"path\": \"/data/zigbee_network_key\", \"value\": \"{network_key_hex.encode().hex()}\"}}]'")
print(f"kubectl -n home-automation patch secret z2m-b-secrets --type='json' -p='[{{\"op\": \"replace\", \"path\": \"/data/zigbee_pan_id\", \"value\": \"{str(pan_id).encode().hex()}\"}}]'")
print(f"kubectl -n home-automation patch secret z2m-b-secrets --type='json' -p='[{{\"op\": \"replace\", \"path\": \"/data/zigbee_ext_pan_id\", \"value\": \"{ext_pan_id_hex.encode().hex()}\"}}]'")