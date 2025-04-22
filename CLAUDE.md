# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## GitOps Workflow

This repository follows a GitOps workflow using Flux:

- All changes MUST be committed and pushed to the Git repository to take effect on the cluster
- After pushing changes to Git, Flux automatically reconciles the changes through a GitHub webhook
- `task reconcile` is only needed if you want to manually force immediate reconciliation (not typically required)

## Commands

- `task init` - Initialize configuration files
- `task configure` - Render and validate configuration files
- `task bootstrap:talos` - Bootstrap Talos cluster
- `task bootstrap:apps` - Bootstrap apps into the cluster
- `task reconcile` - Force Flux to pull changes from Git (only if automatic reconciliation isn't working)
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

4. **Kustomization Structure**: The external-secrets component has a specific kustomization structure:
   - The ClusterSecretStore resources are defined in `/kubernetes/apps/external-secrets/external-secrets/stores/`
   - This stores directory MUST be included in the main kustomization at `/kubernetes/apps/external-secrets/external-secrets/app/kustomization.yaml`:
     ```yaml
     resources:
       - ./helmrelease.yaml
       - ../stores
     ```
   - The stores directory has its own kustomization that includes the onepassword subdirectory:
     ```yaml
     # kubernetes/apps/external-secrets/external-secrets/stores/kustomization.yaml
     resources:
       - ./onepassword
     ```

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
               name: k8s-${SECRET_DOMAIN/./-}-production-tls
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

## Troubleshooting

### ExternalSecrets Issues

If external secrets are not getting populated:

1. **Check the ExternalSecret resource status**:
   ```bash
   kubectl -n <namespace> get externalsecrets
   kubectl -n <namespace> describe externalsecret <name>
   ```
   Look for status conditions like "SecretSyncedError" which indicate sync failures.

2. **Verify the ClusterSecretStore exists and is valid**:
   ```bash
   kubectl get clustersecretstores
   kubectl describe clustersecretstore onepassword-connect
   ```
   Ensure the store is in a "Valid" state.

3. **Check OnePassword Connect is working**:
   ```bash
   kubectl -n external-secrets get pods
   kubectl -n external-secrets logs -l app.kubernetes.io/name=onepassword-connect
   ```
   
4. **Validate kustomization includes the stores directory**:
   If the ClusterSecretStore is missing, verify that `/kubernetes/apps/external-secrets/external-secrets/app/kustomization.yaml` 
   includes the `../stores` directory in the resources list.

### Grafana Access Issues

If "no healthy upstream" errors occur when accessing Grafana:

1. **Check Grafana pod status**:
   ```bash
   kubectl -n observability get pods -l app.kubernetes.io/name=grafana
   kubectl -n observability describe pod -l app.kubernetes.io/name=grafana
   ```
   Look for issues with container startup or missing secrets.

2. **Verify admin credentials secret exists**:
   ```bash
   kubectl -n observability get secret grafana-admin-secret
   ```
   This secret should be created by the ExternalSecret.

3. **Check HTTPRoute configuration**:
   ```bash
   kubectl -n observability get httproute -l app.kubernetes.io/name=grafana
   ```
   Ensure the route is properly configured with correct hostnames and backend references.

4. **Verify Gateway status**:
   ```bash
   kubectl -n kube-system get gateway internal
   ```
   Ensure the gateway is properly configured and has a "Ready" status.
