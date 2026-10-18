---
name: code-pod-mcp-secrets
description: Use when adding an MCP server or a 1Password-backed secret/env var to the code-pod dev pod in this repo, when a HelmRelease-declared env var isn't showing up in a code-pod SSH session, or when a `uvx --from=...` tool invocation hangs for minutes instead of starting.
---

# Code Pod MCP & Secrets Setup

## Overview

`code-pod` (`kubernetes/apps/dev/code-pod/`) is the dev pod Claude Code sessions in this repo run inside, built from `build/code-pod/`. Adding an MCP server backed by a 1Password secret touches two layers that are easy to conflate: the GitOps-managed k8s side, and the pod-local Claude Code config that git knows nothing about.

## The two layers

| Layer | Where | GitOps-tracked? |
|---|---|---|
| Secret → env var | ExternalSecret + `envFrom` in `kubernetes/apps/dev/code-pod/app/helmrelease.yaml` | Yes |
| MCP server registration | `~/.claude.json` (or `claude mcp add`) inside the pod | **No** |

The home PVC (`existingClaim: code-pod`, mounted at `/home/jsenecal`, where `~/.claude.json` lives) has **no PVC manifest in this repo and no VolSync backup** — unlike `workspace` (`code-pod-workspace`, which has `replicationsource`/`replicationdestination`). Lose that PVC and MCP registrations, memory, everything under `$HOME` goes with it, with nothing to restore from.

## Wiring a new secret into code-pod's env

Follow the existing `code-pod-anthropic` / `code-pod-ha-mcp` pattern:

1. New `kubernetes/apps/dev/code-pod/app/externalsecret-<name>.yaml`:
   ```yaml
   apiVersion: external-secrets.io/v1
   kind: ExternalSecret
   metadata:
     name: code-pod-<name>
   spec:
     secretStoreRef:
       kind: ClusterSecretStore
       name: onepassword-connect
     dataFrom:
       - extract:
           key: <1Password item name>
     target:
       name: code-pod-<name>-secret
       creationPolicy: Owner
   ```
2. Register it in `kubernetes/apps/dev/code-pod/app/kustomization.yaml`.
3. Add to the `app` container's `envFrom` in `helmrelease.yaml`, with `optional: true` so a missing/rotated secret doesn't crash the pod.
4. Commit, push. `reloader.stakater.com/auto: "true"` + `strategy: Recreate` on the controller means **code-pod gets recreated** — this kills any live Claude Code session running inside it, including the one making this change. Warn before pushing.
5. Container env now reaches SSH login shells automatically: `build/code-pod/rootfs/usr/local/bin/code-pod-entrypoint.sh` writes a filtered copy of the container env to `~/.ssh/environment` on every start, and `sshd_config.d/code-pod.conf` sets `PermitUserEnvironment yes`. If a var doesn't show up in a shell, check the entrypoint's exclusion list — it drops `KUBERNETES_*`, anything containing `_PORT` or `_SERVICE_HOST`, and shell-reserved names (`HOME`, `PATH`, etc.); a colliding name gets silently dropped.

## Registering the MCP server itself

Not in git. Either edit the project's entry in `~/.claude.json` (`projects["<repo-path>"].mcpServers`), or use `claude mcp add --scope <user|local> -- <command> <args...>`. For a stdio server needing a secret, set `env` explicitly:

```json
"my-server": {
  "type": "stdio",
  "command": "uvx",
  "args": ["--from=my-mcp@latest", "my-mcp"],
  "env": { "MY_TOKEN": "${MY_TOKEN}" }
}
```

Takes effect on the *next* Claude Code startup only — not the current session.

## Gotcha: `uvx` hangs for minutes "compiling"

`.mise.toml` pins a very new Python (`python = "3.15.0"` as of writing). PyPI often has no prebuilt wheel yet for brand-new CPython versions, so `uv`/`uvx` silently falls back to building native extensions from source — e.g. `pydantic-monty` pulls in a Rust crate and takes 5–15+ minutes via `cargo`/`rustc` with no progress output beyond "Building X". It looks hung; it isn't — `ps aux | grep -E "rustc|cargo|maturin"` will show a process pegged near 100% CPU.

Fix: pin the invocation to a Python version with prebuilt wheels, independent of the pod's default:

```
uvx --python 3.13 --from=my-mcp@latest my-mcp
```

`uv`/`uvx` comes from `.mise.toml`'s `[tools]` (`uv = "latest"`), **not** the Containerfile's pacman package list — don't add `uv` as a pacman package, it's redundant.

## Gotcha: code-pod image CI build fails with a package 404

```
error: failed retrieving file '<pkg>-<version>-x86_64.pkg.tar.zst' from fastly.mirror.pkgbuild.com : 404
error: failed retrieving file '<pkg>-<version>-x86_64.pkg.tar.zst' from geo.mirror.pkgbuild.com : 404
```

`.github/workflows/code-pod-image.yaml` uses a persistent `type=gha` BuildKit cache (`scope=code-pod`, keyed by instruction content, not time). The early `pacman -Syu` layer's synced package database gets reused forever as long as that Containerfile line hasn't changed — but Arch's rolling-release mirrors prune old builds, so a stale cached layer can reference a version no longer upstream. A plain re-run hits the same stale cache and fails identically.

Fix — clear the cache, then rebuild:
```
gh cache delete --all --ref refs/heads/main --succeed-on-no-caches
gh workflow run code-pod-image.yaml --ref main
```
Then update `helmrelease.yaml`'s pinned `tag: main@sha256:...` from the `Push & Sign` job's `containerimage.digest`:
```
gh run view --job=<push-job-id> --log | grep containerimage.digest
```

## Common mistakes

- Assuming MCP registration is tracked by git — it isn't; a fresh pod/clone won't have it.
- Pushing a code-pod HelmRelease/image change without warning it recreates the pod (kills the current session if running inside it).
- Adding `uv` to the Containerfile's pacman list instead of using the existing mise-managed install.
- Re-running a failed CI build without clearing the GHA cache first, when the failure is a mirror 404 rather than an actual Containerfile problem.
- Assuming `~/.claude.json`/home PVC is backed up — it isn't (no VolSync, no PVC manifest in git).
