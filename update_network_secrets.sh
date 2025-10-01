#!/bin/bash

# Extract values from configuration
NETWORK_KEY='[0x59,0xD6,0x1F,0xDE,0xF5,0x1F,0x8B,0xA6,0x69,0x64,0x55,0xE1,0xDC,0x7A,0x90,0x22]'
PAN_ID='43090'
EXT_PAN_ID='[0x87,0x4A,0x0B,0xD1,0xB5,0x46,0xE7,0x6F]'

# Base64 encode the values
NETWORK_KEY_B64=$(echo -n "$NETWORK_KEY" | base64 -w0)
PAN_ID_B64=$(echo -n "$PAN_ID" | base64 -w0)
EXT_PAN_ID_B64=$(echo -n "$EXT_PAN_ID" | base64 -w0)

# Update the secret
kubectl -n home-automation patch secret z2m-b-secrets --type='json' -p='[
  {"op": "add", "path": "/data/zigbee_network_key", "value": "'$NETWORK_KEY_B64'"},
  {"op": "add", "path": "/data/zigbee_pan_id", "value": "'$PAN_ID_B64'"},
  {"op": "add", "path": "/data/zigbee_ext_pan_id", "value": "'$EXT_PAN_ID_B64'"}
]'