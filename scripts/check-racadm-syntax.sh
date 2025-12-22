#!/bin/bash
# Script to check RACADM syntax and current configuration

CMC_IP="192.168.255.200"
CMC_USER="admin"
CMC_PASS="0235629xD!"

echo "Testing different RACADM command syntaxes..."
echo ""

# Test 1: Try without colon after createvd
echo "Test 1: racadm raid createvd -controller RAID.ChassisIntegrated.1-1 ..."
sshpass -p "$CMC_PASS" ssh -o StrictHostKeyChecking=no "$CMC_USER@$CMC_IP" \
    "racadm raid help createvd" 2>&1 | head -20

echo ""
echo "Test 2: Check existing VD details to understand format"
sshpass -p "$CMC_PASS" ssh -o StrictHostKeyChecking=no "$CMC_USER@$CMC_IP" \
    "racadm raid get vdisks -o" 2>&1 | grep -A10 "0:0:0" | head -20

echo ""
echo "Test 3: Get help on raid command"
sshpass -p "$CMC_PASS" ssh -o StrictHostKeyChecking=no "$CMC_USER@$CMC_IP" \
    "racadm help raid" 2>&1 | grep -A10 "createvd"