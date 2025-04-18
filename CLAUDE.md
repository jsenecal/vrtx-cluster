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