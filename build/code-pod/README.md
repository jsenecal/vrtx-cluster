# code-pod

Container image for the Tailscale-attached Arch dev pod under `kubernetes/apps/default/code-pod/`.

## Build

```bash
cd build/code-pod
docker buildx build --load -f Containerfile -t code-pod:dev .
```

Build args:
- `USERNAME` (default `jsenecal`) — also set as `ENV`, used at runtime by the entrypoint.
- `UID` / `GID` (default `1000` / `1000`) — must match VolSync `moverSecurityContext` for ownership compatibility.

## Smoke test

```bash
docker run -d --name code-pod-test -p 12222:22 code-pod:dev
docker exec -u jsenecal code-pod-test fish -c 'claude --version; gh --version; yay --version'
docker rm -f code-pod-test
```

To ssh in, drop a pubkey into `/etc/code-pod/ssh/authorized_keys` (sshd reads `AuthorizedKeysFile` from there, not from `~/.ssh`). In the cluster this path is the read-only `ssh-seed` Secret mount synced from 1Password; for a local `docker run` smoke test, bind-mount a file over that path instead.

## What's in the image

Stage 1 (`aur-build`) builds `yay-bin` from AUR with a disposable `builder` user. Only the resulting `.pkg.tar.zst` crosses into stage 2.

Stage 2 (`final`) installs the pacman package set, copies the AUR yay package and `pacman -U`s it, drops in `rootfs/`, creates `${USERNAME}` (UID `${UID}`, in `wheel`, shell `/usr/bin/fish`), `npm install -g @anthropic-ai/claude-code`, runs the Oh My Fish installer non-interactively as the user, sets the entrypoint.

Runtime (`code-pod-entrypoint.sh`) generates sshd host keys into `/etc/ssh` (an emptyDir at deploy time), runs a first-run home-PVC sentinel to set ownership and create `~/.ssh`, then `exec`s `sshd -D -e`.

## CI

`.github/workflows/code-pod-image.yaml` builds on PRs (no push) and pushes + cosigns on `main`. Trigger manual rebuilds with the workflow's `workflow_dispatch`.
