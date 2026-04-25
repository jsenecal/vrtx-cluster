# Code-Pod: Tailscale-attached Arch dev pod with Claude Code and volsynced home

**Date:** 2026-04-25
**Scope:** new image at `build/code-pod/`, new app at `kubernetes/apps/default/code-pod/`, new workflow `.github/workflows/code-pod-image.yaml`
**Cluster:** vrtx-cluster

## Background

We want a long-lived in-cluster shell environment that:

- Is reachable from anywhere on the tailnet over SSH (no Cloudflare tunnel, no in-cluster Service).
- Has Claude Code, the GitHub CLI, fish + Oh My Fish, and a sensible Arch toolchain (including yay for AUR) preinstalled.
- Persists `$HOME` and a separate `~/Code` workspace across pod restarts and cluster rebuilds via VolSync (restic on NFS, same pattern as every other stateful app in this repo).
- Does not run with a privileged in-cluster identity by default — kubectl access is bring-your-own-kubeconfig.

This pod replaces ad-hoc `kubectl debug` flows and the empty `kubernetes/apps/development/code-server/` slot, but lives in the `default` namespace per request.

## Decisions

The brainstorming session resolved the following design choices. Each is load-bearing for one or more sections below.

| Decision | Choice |
|---|---|
| SSH transport | OpenSSH server **inside** the pod; Tailscale sidecar acts purely as the network transport (no `tailscale ssh`). |
| Image source | Built in this repo under `build/code-pod/`, pushed to `ghcr.io`, pinned by digest in the HelmRelease. |
| Image base | `archlinux:base-devel`, multi-stage so the final layer has no makepkg builder user / build cache. |
| AUR support | yay (from `aur/yay-bin`) built in stage 1, installed via `pacman -U` in stage 2. |
| Claude auth | Both env (`ANTHROPIC_API_KEY`) and OAuth login paths supported; in practice the user logs in once with `claude /login` and the token persists in `~/.claude/`. |
| Tailscale auth | OAuth client → ephemeral nodes (one-shot auth-key minted at startup). No long-lived auth-key at rest. Tags: `tag:k8s`. |
| Tailnet hostname | `vrtx-pod`. |
| Persistent storage | Two volsynced PVCs: `code-pod` (10 GiB `$HOME`, hourly) and `code-pod-workspace` (100 GiB `~/Code`, daily). |
| kubectl from inside | No ServiceAccount mounted. User scp's their own kubeconfig to `~/.kube/config` post-bootstrap. |
| Authorized-keys seeding | initContainer reads from a Kubernetes Secret and writes `~/.ssh/authorized_keys` only if missing on the home PVC. After first seed the file is owned by the volume; the secret is no longer consulted. |
| Username | Build arg `USERNAME`, default `jsenecal`. Hardcoded as a literal in the HelmRelease mount paths (`/home/jsenecal`, `/home/jsenecal/Code`). One-time coupling acknowledged. |
| Image rebuild cadence | On change only (PR build, push to main pushes the image). No scheduled rebuilds — the user can `sudo pacman -Syu` live. |
| In-cluster Service | None. The pod is reachable only via the tailnet. |

## Repo Layout

```
build/code-pod/
  Containerfile
  rootfs/
    etc/ssh/sshd_config.d/code-pod.conf
    etc/sudoers.d/wheel-pacman
    etc/fish/conf.d/code-pod.fish
    etc/profile.d/code-pod.sh
    usr/local/bin/code-pod-entrypoint.sh
  README.md

.github/workflows/
  code-pod-image.yaml

kubernetes/apps/default/code-pod/
  ks.yaml
  app/
    helmrelease.yaml
    externalsecret-tailscale.yaml
    externalsecret-ssh.yaml
    externalsecret-anthropic.yaml
    workspace/
      pvc.yaml
      replicationsource.yaml
      replicationdestination.yaml
      externalsecret.yaml
    kustomization.yaml
```

The `default` namespace already exists; no new Namespace resource is created here.

## Container Image (`build/code-pod/`)

### Stage 1 — `aur-build`

- Base: `archlinux:base-devel`.
- `pacman -Syu --noconfirm git`.
- Create disposable `builder` user (UID/GID irrelevant — never reaches stage 2). Add NOPASSWD sudoers entry for makepkg's pacman calls.
- `git clone https://aur.archlinux.org/yay-bin.git`, `makepkg --noconfirm -s` as `builder`.
- The single artifact `yay-bin-*.pkg.tar.zst` is what crosses into stage 2; nothing else.

### Stage 2 — `final`

- Base: `archlinux:base-devel`.
- Build args (defaults shown):
  ```
  ARG USERNAME=jsenecal
  ARG UID=1000
  ARG GID=1000
  ```
- `pacman -Syu --noconfirm` plus install:
  ```
  openssh git base-devel sudo fish curl wget unzip jq less
  ripgrep fd bat eza htop rsync tmux nodejs npm github-cli
  python python-pip ca-certificates tzdata
  ```
- Copy yay artifact from `aur-build`, `pacman -U --noconfirm /tmp/yay-bin-*.pkg.tar.zst`, remove the artifact.
- Create `${USERNAME}` (UID/GID `${UID}/${GID}`, primary group of same name added to `wheel`, default shell `/usr/bin/fish`, home `/home/${USERNAME}`).
- Drop `/etc/sudoers.d/wheel-pacman`:
  ```
  %wheel ALL=(ALL:ALL) NOPASSWD: /usr/bin/pacman, /usr/bin/yay
  ```
- Drop `/etc/ssh/sshd_config.d/code-pod.conf`:
  ```
  PasswordAuthentication no
  PermitRootLogin no
  AllowGroups wheel
  AuthorizedKeysFile .ssh/authorized_keys
  PrintMotd no
  ```
- npm prefix at `/usr/local`, then `npm install -g @anthropic-ai/claude-code`.
- As `${USERNAME}` (`USER ${USERNAME}` block): clone Oh My Fish into `~/.local/share/omf` and run its install script with the upstream-documented non-interactive flags. The README in `build/code-pod/` will pin the exact incantation; spec assumes the framework lands at `~/.local/share/omf`.
- Reset to `USER root` for the final layers.
- After `ARG USERNAME`, also set `ENV USERNAME=${USERNAME}` so the entrypoint can reference it at runtime — `USERNAME` stays a real variable end-to-end.
- Drop the entrypoint at `/usr/local/bin/code-pod-entrypoint.sh`:
  ```sh
  #!/usr/bin/env bash
  set -euo pipefail

  # Generate sshd host keys if missing (host keys live on emptyDir, not the home PVC).
  ssh-keygen -A

  # First-run home setup sentinel.
  home="/home/${USERNAME}"
  if [ ! -e "${home}/.code-pod-initialised" ]; then
    install -d -o "${USERNAME}" -g "${USERNAME}" -m 0700 "${home}/.ssh"
    chown -R "${USERNAME}:${USERNAME}" "${home}"
    touch "${home}/.code-pod-initialised"
    chown "${USERNAME}:${USERNAME}" "${home}/.code-pod-initialised"
  fi

  exec /usr/sbin/sshd -D -e
  ```
- `EXPOSE 22`.
- `ENTRYPOINT ["/usr/local/bin/code-pod-entrypoint.sh"]`.

### Image labels

Set `org.opencontainers.image.source`, `…revision`, `…created` from CI-injected build args, so ghcr surfaces them on the package page.

## Workload (`kubernetes/apps/default/code-pod/`)

### `ks.yaml`

Flux Kustomization in the `default` namespace, including the standard volsync component for the `$HOME` PVC. Substitutions match other apps:

```yaml
postBuild:
  substitute:
    APP: code-pod
    VOLSYNC_CAPACITY: 10Gi
  substituteFrom:
    - name: cluster-secrets
      kind: Secret
components:
  - ../../../../components/volsync
dependsOn:
  - name: rook-ceph-cluster
    namespace: rook-ceph
  - name: onepassword-connect
    namespace: external-secrets
```

The hand-written `workspace/` directory carries its own ReplicationSource / ReplicationDestination / PVC / ExternalSecret with `code-pod-workspace` as the literal name (it does not use the component, because Flux Components key off a single `${APP}` substitution per Kustomization).

### `helmrelease.yaml`

bjw-s `app-template`. One controller (`code-pod`), `strategy: Recreate` (RWO PVCs), single replica.

**Containers:**

- `app`:
  - Image: `ghcr.io/jsenecal/code-pod@sha256:…` (digest pinned, Renovate-managed).
  - `runAsUser: 0` (sshd needs root to drop into the user). All other containers run unprivileged.
  - `envFrom`:
    - `code-pod-anthropic-secret` (optional). If `ANTHROPIC_API_KEY` is unset/empty, Claude Code falls back to OAuth via `~/.claude/`.
  - Volume mounts:
    - `code-pod` PVC at `/home/jsenecal`
    - `code-pod-workspace` PVC at `/home/jsenecal/Code`
    - `ssh-host-keys` emptyDir at `/etc/ssh`
    - `cache` emptyDir at `/home/jsenecal/.cache` (excludes node_modules-ish junk from backups)
  - Probes: `exec: pgrep -x sshd` for liveness and readiness.
  - Capabilities: drop ALL, add `SETUID`, `SETGID`, `CHOWN`, `DAC_OVERRIDE` (sshd minimum).
  - `reloader.stakater.com/auto: "true"` annotation so secret rotation triggers a restart.

- `tailscale` sidecar:
  - Image: `ghcr.io/tailscale/tailscale:<pinned>` (digest pinned, Renovate-managed).
  - Env (from `code-pod-tailscale-secret`):
    - `TS_AUTHKEY` — value rendered from OAuth client id+secret using the Tailscale-documented format `tskey-client-<id>-<secret>?ephemeral=true&preauthorized=true&tags=tag:k8s`. The ExternalSecret template does this composition.
    - `TS_HOSTNAME=vrtx-pod`
    - `TS_USERSPACE=false`
    - `TS_STATE_DIR=/var/lib/tailscale`
  - Volume mounts:
    - `tailscale-state` emptyDir at `/var/lib/tailscale`
  - Capabilities: `NET_ADMIN`, `NET_RAW`.
  - Probe: `exec: tailscale status --json` checking for `BackendState: Running`.

**initContainers:**

- `seed-authorized-keys`:
  - Image: same as `app` (already has shell + chown).
  - Mounts the home PVC at `/home/jsenecal`, plus the `code-pod-ssh-secret` at `/etc/code-pod/ssh/` (read-only).
  - Logic:
    ```sh
    set -euo pipefail
    target=/home/jsenecal/.ssh/authorized_keys
    if [ ! -s "$target" ]; then
      install -d -o jsenecal -g jsenecal -m 0700 /home/jsenecal/.ssh
      install -o jsenecal -g jsenecal -m 0600 \
        /etc/code-pod/ssh/authorized_keys "$target"
    fi
    ```

**Pod spec:**

- `defaultPodOptions.securityContext.fsGroup: 1000` so the home PVC is owned by `jsenecal`.
- No Service. No HTTPRoute. No Gatus check.

### `externalsecret-tailscale.yaml`

```yaml
spec:
  secretStoreRef: { kind: ClusterSecretStore, name: onepassword-connect }
  target:
    name: code-pod-tailscale-secret
    template:
      data:
        TS_AUTHKEY: "tskey-client-{{ .TS_OAUTH_CLIENT_ID }}-{{ .TS_OAUTH_CLIENT_SECRET }}?ephemeral=true&preauthorized=true&tags=tag:k8s"
  dataFrom:
    - extract: { key: code-pod }
```

1Password item `code-pod` provides `TS_OAUTH_CLIENT_ID`, `TS_OAUTH_CLIENT_SECRET`.

### `externalsecret-ssh.yaml`

Pulls `AUTHORIZED_KEYS` from 1Password item `code-pod-ssh`, renders into key `authorized_keys` of secret `code-pod-ssh-secret`, mounted by the seed initContainer.

### `externalsecret-anthropic.yaml`

Pulls `ANTHROPIC_API_KEY` from 1Password item `code-pod-anthropic` — created with the field empty on day one to keep the wiring intact. Rendered into secret `code-pod-anthropic-secret`. Consumed via `envFrom: { secretRef: { name: code-pod-anthropic-secret, optional: true } }` so an empty/missing key cleanly falls through to OAuth.

## Storage & VolSync

### `code-pod` (home, 10 GiB, hourly)

Provisioned by `components/volsync`. The component supplies:

- `PersistentVolumeClaim` named `code-pod` with `dataSourceRef` → `code-pod-dst` (ReplicationDestination), capacity 10 GiB on `ceph-block`.
- `ReplicationSource` named `code-pod` with the default hourly schedule.
- `ReplicationDestination` named `code-pod-dst` with `manual: restore-once` (no-op on first boot, restores from restic on cluster rebuild).
- `ExternalSecret` deriving restic creds from `volsync-template` 1Password item, repository path `/repository/code-pod`.

`moverSecurityContext` defaults (`runAsUser/Group/fsGroup: 1000`) match the `jsenecal` user; ownership is correct out of the box.

### `code-pod-workspace` (Code, 100 GiB, daily)

Hand-written sibling resources in `kubernetes/apps/default/code-pod/app/workspace/`. Same shapes as the component, but with `code-pod-workspace` as a literal:

- `pvc.yaml`: `code-pod-workspace`, 100 GiB, `ceph-block`, `dataSourceRef` → `code-pod-workspace-dst`.
- `replicationsource.yaml`: `sourcePVC: code-pod-workspace`, `schedule: "0 4 * * *"`, retain `daily: 7, weekly: 4`, `cacheCapacity: 5Gi`.
- `replicationdestination.yaml`: `code-pod-workspace-dst`, `manual: restore-once`.
- `externalsecret.yaml`: target `code-pod-workspace-volsync-secret`, repository `/repository/code-pod-workspace`, password from `volsync-template`.

### What is NOT on a backed-up volume

- Tailscale daemon state (`/var/lib/tailscale`, sidecar emptyDir) — by design, ephemeral nodes re-auth fresh.
- sshd host keys (`/etc/ssh`, app-container emptyDir) — regenerated on each pod start. Clients see a "host key changed" warning only if they previously connected to a stale instance; for Tailscale-only access this matters less because the tailnet identity is what authenticates the host.
- `~/.cache` (app-container emptyDir mounted over `/home/jsenecal/.cache`) — keeps backup snapshots from picking up build/install caches.

## Secrets and 1Password Items

| 1Password item | Fields | Used by |
|---|---|---|
| `code-pod` (new) | `TS_OAUTH_CLIENT_ID`, `TS_OAUTH_CLIENT_SECRET` | `code-pod-tailscale-secret` |
| `code-pod-ssh` (new) | `AUTHORIZED_KEYS` | `code-pod-ssh-secret` (seed initContainer) |
| `code-pod-anthropic` (new, optional content) | `ANTHROPIC_API_KEY` (may be empty) | `code-pod-anthropic-secret` (`envFrom optional: true`) |
| `volsync-template` (existing) | `RESTIC_PASSWORD` | both volsync ExternalSecrets |

No SSH host-key secret: host keys are pod-ephemeral.
No kubeconfig secret: BYO via `scp`.
No Claude OAuth token secret: file lives on the volsynced home PVC.

## CI Workflow (`.github/workflows/code-pod-image.yaml`)

Mirrors the project's existing workflow style (`bjw-s-labs/action-changed-files` filter, pinned actions, ubuntu-latest builders).

**Triggers:**
- `pull_request` on `main` for paths `build/code-pod/**` and `.github/workflows/code-pod-image.yaml`.
- `push` to `main` on the same paths.
- `workflow_dispatch`.

**Jobs:**

1. `filter` — emit `changed-files` outputs (skipped on workflow_dispatch path filter, always-run on dispatch).
2. `build` (`if: changed-files != '[]' || event == 'workflow_dispatch'`):
   - Checkout, set up Buildx, build the image to a local OCI tarball.
   - Run `hadolint build/code-pod/Containerfile`.
   - Run `aquasecurity/trivy-action` against the built image (severity `HIGH,CRITICAL`, fail on findings; allow temporary suppressions via `.trivyignore` in `build/code-pod/`).
3. `push` (`if: github.event_name != 'pull_request' && needs.build.result == 'success'`):
   - Login to ghcr with `GITHUB_TOKEN`.
   - Push to `ghcr.io/${{ github.repository_owner }}/code-pod` with tags `:main`, `:sha-<short>`, `:latest`.
   - Sign with `cosign sign --yes ghcr.io/${{ github.repository_owner }}/code-pod@<digest>` using GitHub OIDC (`id-token: write`).
4. `success` aggregator (matches `image-pull.yaml` pattern).

**Permissions:**
- Top-level: `contents: read`.
- `push` job only: `packages: write`, `id-token: write`.

PR builds get neither `packages: write` nor `id-token: write`, so a malicious PR cannot push or sign.

**Renovate:**
A small entry is added to the existing Renovate config so `ghcr.io/${{ github.repository_owner }}/code-pod` is pinned to digest in the HelmRelease and bumps via PR like every other image in the cluster.

## Bootstrap (first-time)

**Pre-merge (one-time):**

1. Tailscale admin → OAuth clients → new client, scope `auth_keys` (write), allowed tag `tag:k8s`. Copy ID + Secret.
2. 1Password: create item `code-pod` with `TS_OAUTH_CLIENT_ID`, `TS_OAUTH_CLIENT_SECRET`.
3. 1Password: create item `code-pod-ssh` with `AUTHORIZED_KEYS` (laptop pubkey, newline-separated for multiple).
4. (Optional) 1Password: create item `code-pod-anthropic` with `ANTHROPIC_API_KEY` empty for now.
5. (Existing) `volsync-template` is reused.
6. Tailscale ACLs: confirm `tag:k8s` is reachable on `tcp:22` from your user.

**Post-merge (automatic):**

7. ExternalSecrets resolve.
8. `ReplicationDestination`s create empty PVCs at requested capacity (no restore, first time).
9. PVCs `code-pod` and `code-pod-workspace` bind via `dataSourceRef`.
10. Pod starts. seed-initContainer copies `authorized_keys` onto the home PVC. sshd starts. Tailscale sidecar joins tailnet as `vrtx-pod`.
11. Hourly / daily ReplicationSources begin running.

**Post-deploy (manual, one time):**

12. `ssh jsenecal@vrtx-pod`.
13. `claude /login` → browser flow → token in `~/.claude/`.
14. (Optional) `gh auth login`.
15. (Optional) `scp ~/.kube/config jsenecal@vrtx-pod:.kube/config` for BYO kubectl.

## Disaster Recovery

On cluster rebuild, the same flow runs except `manual: restore-once` triggers restic to pull the most recent snapshots. PVCs come up populated. `seed-authorized-keys` sees the file already exists and is a no-op. `~/.claude/`, `~/.config/gh/`, `~/.kube/`, fish history, and `~/Code` are all already in place. The first SSH login just works.

A new ephemeral Tailscale node joins with the same `vrtx-pod` hostname; MagicDNS continues to point at "the current node".

## Day-2

- **Add an SSH key:** `ssh-copy-id` from a tailnet host or append to `~/.ssh/authorized_keys` while logged in. The 1Password `code-pod-ssh` item is no longer consulted.
- **Rotate Tailscale OAuth:** create a new client in admin, update 1Password item `code-pod`, restart the pod (`kubectl -n default rollout restart deploy/code-pod`).
- **Update Arch userland:** `sudo pacman -Syu` inside the pod (changes survive until the next image pull). Or push a Containerfile commit / `workflow_dispatch` to rebuild and let Renovate pin the new digest.
- **Resize a PVC:** edit `VOLSYNC_CAPACITY` (home) or `pvc.yaml` capacity (workspace); `ceph-block` is online-resizable.

## Out of Scope

- Cosign verification policy in Kyverno (described as optional; can be added later as a separate change).
- Multiple users / multi-tenant SSH (single-user pod by design).
- A dedicated namespace for code-pod (using `default` per request; can be moved later if it grows).
- A second pod / replica for HA (single-replica is intentional; the pod is a personal workstation, not a service).
