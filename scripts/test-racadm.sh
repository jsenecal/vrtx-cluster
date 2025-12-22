#!/bin/bash
# Test RACADM connectivity and gather VRTX information

# Configuration
CMC_IP="192.168.255.200"
CMC_USER="admin"
CMC_PASS="0235629xD!"

echo "Testing RACADM connectivity to VRTX CMC..."
echo ""

# Test basic connection
echo "1. Testing basic connection:"
racadm -r "$CMC_IP" -u "$CMC_USER" -p "$CMC_PASS" getsysinfo

# If that fails, try with certificate bypass
if [ $? -ne 0 ]; then
    echo ""
    echo "2. Trying with --nocertwarn:"
    racadm -r "$CMC_IP" -u "$CMC_USER" -p "$CMC_PASS" --nocertwarn getsysinfo
fi

# Once connected, gather information
echo ""
echo "3. Getting RAID controller information:"
racadm -r "$CMC_IP" -u "$CMC_USER" -p "$CMC_PASS" --nocertwarn raid get controllers

echo ""
echo "4. Getting physical disk information:"
racadm -r "$CMC_IP" -u "$CMC_USER" -p "$CMC_PASS" --nocertwarn raid get pdisks

echo ""
echo "5. Getting virtual disk information:"
racadm -r "$CMC_IP" -u "$CMC_USER" -p "$CMC_PASS" --nocertwarn raid get vdisks

echo ""
echo "6. Getting blade information:"
racadm -r "$CMC_IP" -u "$CMC_USER" -p "$CMC_PASS" --nocertwarn getslotname