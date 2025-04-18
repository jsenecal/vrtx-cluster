# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

- `task init` - Initialize configuration files
- `task configure` - Render and validate configuration files
- `task bootstrap:talos` - Bootstrap Talos cluster
- `task bootstrap:apps` - Bootstrap apps into the cluster
- `task reconcile` - Force Flux to pull changes from Git
- `task template:tidy` - Archive template related files
- `task talos:reset` - Reset cluster nodes
- `task talos:generate-config` - Generate Talos configuration files
- `talosctl reset --graceful=false --reboot --system-labels-to-wipe STATE --system-labels-to-wipe EPHEMERAL -n <NODE_IP>` - Reset a single Talos node and wipe both ephemeral and state partitions
- `kubectl -n <namespace> get pods` - List pods in a namespace
- `kubectl -n <namespace> logs <pod-name> -f` - View logs for a pod

## Style Guidelines

- Indentation: 2 spaces for most files, tabs (4 spaces) for .cue files, 4 spaces for .md and .sh files
- Line endings: LF
- Encoding: UTF-8
- Trim trailing whitespace
- Insert final newline
- YAML formatting should follow Kubernetes style conventions
- Shell scripts should use bash with `set -euo pipefail`
- Use declarative Kubernetes manifests with proper annotations
- Kustomize patches should be minimal and focused
- Always validate Kubernetes manifests with `kubeconform` before applying

## Network Bonding Configuration

This repository implements network bonding for Talos Linux with several configuration options:

1. **Interface Names Method** (recommended):
   ```yaml
   bond: true
   bond_interface_names:
     - "eno1"
     - "eno2"
   mtu: 1500    # Applied to both bond0 and underlying interfaces
   ```

2. **MAC Addresses Method**:
   ```yaml
   bond: true
   bond_use_selectors: false
   bond_interfaces:
     - "00:11:22:33:44:55"
     - "00:11:22:33:44:56"
   mtu: 1500    # Applied to both bond0 and underlying interfaces
   ```

3. **Device Selectors Method**:
   ```yaml
   bond: true
   bond_use_selectors: true
   bond_interfaces:
     - "00:50:56:*"    # MAC address pattern
   bond_bus_paths:
     - "01:00.*"       # PCI bus path
   bond_pci_ids:
     - "8086:10fb"     # Vendor:Device ID
   mtu: 1500           # Applied to all interfaces
   ```

### MTU Configuration

The configuration ensures that MTU is properly set on all levels in the bonding chain:
- Each underlying physical interface
- The bond0 interface itself 
- The VLAN interface (if used)

This prevents "netlink error stating that the MTU value results in numerical result out of range" by ensuring all interfaces in the bonding chain have consistent MTU settings.