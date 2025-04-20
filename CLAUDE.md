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

## External Secrets Configuration

When creating ExternalSecrets for this cluster:

1. **ClusterSecretStore Reference**: Always use the name `onepassword-connect` (not `onepassword`) in the secretStoreRef:
   ```yaml
   spec:
     secretStoreRef:
       kind: ClusterSecretStore
       name: onepassword-connect
   ```

2. **Required Fields**: External Secrets must include either `data` or `dataFrom` section:
   ```yaml
   # Using dataFrom with extract
   dataFrom:
     - extract:
         key: grafana  # This should match the item name in 1Password
   
   # Template usage example
   target:
     name: grafana-admin-secret
     template:
       data:
         admin-user: "{{ .GRAFANA_ADMIN_USERNAME }}"
         admin-password: "{{ .GRAFANA_ADMIN_PASSWORD }}"
   ```

3. **Store Structure**: 1Password items should contain fields with uppercase names that match template references.

## Gateway API Setup

To use Gateway API resources (HTTPRoute, etc.) in the cluster:

1. **CRDs Installation**: Gateway API CRDs are added to bootstrap-apps.sh:
   ```bash
   # renovate: datasource=github-releases depName=kubernetes-sigs/gateway-api
   https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.1/experimental-install.yaml
   ```

2. **Cilium Configuration**: Enable Gateway API support in Cilium:
   ```yaml
   # kubernetes/apps/kube-system/cilium/app/helm/values.yaml
   envoy:
     enabled: true
     rollOutPods: true
     prometheus:
       serviceMonitor:
         enabled: true
   gatewayAPI:
     enabled: true
     enableAlpn: true
   ```

3. **GatewayClass**: Create a GatewayClass for Cilium:
   ```yaml
   # kubernetes/apps/kube-system/cilium/gateway/gatewayclass.yaml
   apiVersion: gateway.networking.k8s.io/v1
   kind: GatewayClass
   metadata:
     name: cilium
   spec:
     controllerName: io.cilium/gateway-controller
   ```

4. **Gateway Resource**: Create an internal Gateway:
   ```yaml
   # kubernetes/apps/kube-system/cilium/gateway/internal.yaml
   apiVersion: gateway.networking.k8s.io/v1
   kind: Gateway
   metadata:
     name: internal
   spec:
     gatewayClassName: cilium
     listeners:
       - name: https
         protocol: HTTPS
         port: 443
         hostname: "*.k8s.${SECRET_DOMAIN}"
         allowedRoutes:
           namespaces:
             from: All
         tls:
           certificateRefs:
             - kind: Secret
               name: k8s-tls
               namespace: cert-manager
   ```

5. **HTTPRoute**: Reference the Gateway in HTTPRoute resources:
   ```yaml
   apiVersion: gateway.networking.k8s.io/v1
   kind: HTTPRoute
   metadata:
     name: example-route
   spec:
     hostnames: ["app.k8s.${SECRET_DOMAIN}"]
     parentRefs:
       - name: internal
         namespace: kube-system
         sectionName: https
     rules:
       - backendRefs:
           - name: my-service
             port: 8080
   ```

6. **Variable Substitution**: Ensure all kustomizations using these resources have:
   ```yaml
   postBuild:
     substituteFrom:
       - name: cluster-secrets
         kind: Secret
   ```
   
## Observability Stack

The observability stack consists of the following components:

1. **Kube-Prometheus-Stack**: Core monitoring system
   - Prometheus for metrics collection and alerting
   - Alert Manager for handling alerts
   - Node Exporter for hardware and OS metrics
   - Kube State Metrics for Kubernetes object metrics

2. **Grafana**: Visualization platform with pre-configured dashboards for:
   - Kubernetes resources
   - Node metrics
   - Ceph storage
   - VRTX hardware via SNMP
   - Network monitoring

3. **Loki & Promtail**: Log collection and aggregation
   - Promtail collects logs from all pods
   - Loki stores and indexes logs
   - Integrated with Grafana for log visualization

4. **Blackbox-Exporter**: Network monitoring
   - ICMP probes for cluster nodes and infrastructure
   - HTTP/HTTPS endpoint monitoring
   - DNS monitoring

5. **SNMP-Exporter**: Hardware monitoring for Dell VRTX chassis
   - Monitoring chassis and individual blade health
   - Temperature, power supply, and component status

All component configurations follow the GitOps model with Flux, and changes require commits to the repository to be applied to the cluster.