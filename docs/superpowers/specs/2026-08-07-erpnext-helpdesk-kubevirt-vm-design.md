# ERPNext + Helpdesk on a KubeVirt VM — Design

**Date:** 2026-08-07
**Status:** ⚠️ NOT the chosen path for ERPNext — retained as a **reusable KubeVirt VM pattern reference**.
**Namespace:** `kubevirt`

> **Why this is kept:** During brainstorming we established that the previous ERPNext
> pain was **Galera + mariadb-operator + k8s probe-kills** — not MariaDB the engine, not
> containers per se. With that understood, ERPNext + Helpdesk is being deployed via the
> **official `frappe/helm` chart** (single standalone `mariadb-sts`, Valkey, Gateway-API
> httproute) — see the companion spec `2026-08-07-erpnext-helpdesk-helm-design.md`.
>
> This document is retained because the KubeVirt VM patterns it works out are genuinely
> reusable for a *future* stateful VM workload:
> - **Three-source cloud-init** (inline userData + ConfigMap disk + SOPS Secret disk)
> - **virtiofs-shared filesystem PVC → existing VolSync component** for app-consistent backups
> - **CDI `http` import** of an Ubuntu LTS cloud image to a `ceph-block` DataVolume
> - **VM ingress** via masquerade pod-network → Service → HTTPRoute on the prod gateway
> - **KubeVirt virtiofs feature-gate** enablement
>
> Read it as "how to run a stateful app in a VM on this cluster," with ERPNext as the worked example.

## Goal

Run ERPNext (latest, v16) plus Frappe Helpdesk on the cluster using the **official
`frappe_docker` production stack**, hosted inside a **KubeVirt VirtualMachine** rather
than the previous (removed) containerized Helm deployment. The VM is fully declarative
(rebuildable from Git via cloud-init); application data lives on a separate persistent
disk; app-consistent backups flow through the cluster's existing VolSync pipeline.

Exposed at:

- `erp.${SECRET_DOMAIN_2}` — ERPNext desk/app
- `support.${SECRET_DOMAIN_2}` — Frappe Helpdesk portal (alias of the same site, `/` → `/helpdesk`)

## Context / Constraints

- KubeVirt **v1.9.0** + CDI are deployed and healthy (`kubernetes/apps/kubevirt/`). No VMs exist yet — this is the first.
- The containerized ERPNext/Frappe deployment was fully removed from Git; **no data to migrate — fresh install**.
- Storage classes: `ceph-block` (default, RWO), `ceph-filesystem`, `openebs-hostpath`.
- Snapshot class: `csi-ceph-blockpool`.
- Gateway `external-prod` (`kube-system`) already serves `*.${SECRET_DOMAIN_2}` with TLS; Cloudflare tunnel (prod) fronts it. `SECRET_DOMAIN_2` = `${SECRET_DOMAIN_2}`.
- SOPS is wired: `.sops.yaml` encrypts `^(data|stringData)$`; Flux Kustomizations decrypt via `secretRef: sops-age`.
- VolSync component at `kubernetes/components/volsync` (local variant) does filesystem restic → NFS repo, snapshot copyMethod on `ceph-block`, retention hourly:24/daily:7. PVC is created by the component with a `dataSourceRef` restore pattern.
- Multus NADs exist but are **not** used here — VM uses pod network (masquerade) + Service + HTTPRoute, matching the rest of the cluster's ingress model.

## Architecture

```
Cloudflare tunnel (prod)
   └─ external-prod gateway (*.${SECRET_DOMAIN_2}, TLS, kube-system)
        ├─ HTTPRoute erp.${SECRET_DOMAIN_2}       ──┐
        └─ HTTPRoute support.${SECRET_DOMAIN_2}   ──┤  (/ → /helpdesk redirect)
                                                  ▼
                               Service erpnext (ClusterIP) :8080
                                                  ▼
                     VirtualMachine "erpnext" (pod network, masquerade)
                     Ubuntu 26.04 LTS cloud image + Docker + frappe_docker compose
                     ┌───────────────────────────────────────────────┐
                     │ frontend(nginx:8080) backend queue-* scheduler  │
                     │ websocket  mariadb  redis-cache  redis-queue    │
                     │ image: erpnext-helpdesk:local                   │
                     │        (frappe + erpnext + helpdesk)            │
                     └───────────────────────────────────────────────┘
   disks / volumes:
     • rootdisk  40Gi ceph-block (block)  — CDI-imported Ubuntu 26.04 LTS, OS+Docker; cattle
     • datadisk  60Gi ceph-block (block)  — ext4 → /mnt/erpnext-data (mariadb/redis/sites bind mounts)
     • backups   20Gi ceph-block (fs)     — virtiofs → /mnt/erpnext-backups → VolSync → NFS
     • configdisk  ConfigMap erpnext-config (iso)  — compose.yaml, apps.json, bootstrap.sh, backup.sh
     • credsdisk   Secret erpnext-creds (iso, SOPS) — creds.env
     • cloudinitdisk  cloudInitNoCloud.userData (inline) — mounts the two disks, runs bootstrap
```

## Components

### 1. VirtualMachine (`virtualmachine.yaml`)

- `kubevirt.io/v1` VirtualMachine, `running: true`, `runStrategy` acceptable too.
- Domain: `cpu.cores: 4`, `memory.guest: 8Gi`, machine `q35`.
- **Networking:** default pod network with `masquerade: {}`. Guest port 8080 reachable via the Service.
- **rootdisk:** DataVolume (CDI), `http` import of Ubuntu 26.04 LTS server cloud image (resolute), 40Gi, `ceph-block`, `volumeMode: Block`, bus virtio.
- **datadisk:** DataVolume, blank, 60Gi, `ceph-block`, `volumeMode: Block`, bus virtio. Formatted ext4 + mounted `/mnt/erpnext-data` by cloud-init (idempotent: only format if no filesystem).
- **backups (virtiofs):** references PVC `erpnext-backups` (created by the VolSync component, Filesystem mode) via `domain.devices.filesystems` (virtiofs), shared into guest and mounted `/mnt/erpnext-backups`.
- **cloudinitdisk:** `cloudInitNoCloud.userData` inline (readable base cloud-config).
- **configdisk:** volume `configMap: { name: erpnext-config }` → guest disk labeled `config`.
- **credsdisk:** volume `secret: { secretName: erpnext-creds }` → guest disk labeled `creds`.

**Three-source cloud-init split:**
- Inline `userData` (readable, in VM manifest): create user + SSH key, install `qemu-guest-agent` + Docker, mount config/creds disks, format+mount datadisk, mount virtiofs backups, copy files into place, source `creds.env`, run `bootstrap.sh`, install the systemd backup timer.
- `configMap erpnext-config` (readable plain files via `configMapGenerator files:`): `compose.yaml`, `apps.json`, `bootstrap.sh`, `backup.sh`.
- `secret erpnext-creds` (SOPS-encrypted `stringData`): `creds.env` with `DB_ROOT_PASSWORD` + `ADMIN_PASSWORD`.

### 2. Custom image (`files/apps.json` + `files/bootstrap.sh`)

Built **on the VM at first boot** using frappe_docker's layered build:

`apps.json`:
```json
[
  { "url": "https://github.com/frappe/erpnext",  "branch": "version-16" },
  { "url": "https://github.com/frappe/helpdesk", "branch": "<v16-compatible>" }
]
```
(frappe framework pinned via `FRAPPE_BRANCH=version-16`; helpdesk branch/tag verified compatible at implementation.)

`bootstrap.sh` (runs once, guarded by a sentinel file on the data disk):
1. `git clone https://github.com/frappe/frappe_docker` (pinned ref).
2. `docker build` the layered `Containerfile` with `APPS_JSON_BASE64=$(base64 -w0 apps.json)` and `FRAPPE_BRANCH=version-16`, tag `erpnext-helpdesk:local`.
3. `docker compose -f compose.yaml up -d` (env from generated `.env`, `pull_policy: never`).
4. Wait for MariaDB, then `bench new-site erp.${SECRET_DOMAIN_2} --admin-password "$ADMIN_PASSWORD" --db-root-password "$DB_ROOT_PASSWORD" --install-app erpnext --install-app helpdesk`.
5. `bench --site erp.${SECRET_DOMAIN_2} add-domain support.${SECRET_DOMAIN_2}` and set as production.
6. `bench --site erp.${SECRET_DOMAIN_2} set-config host_name ...` / enable scheduler; write sentinel.

### 3. frappe_docker compose (`files/compose.yaml`)

Adapted from upstream `pwd.yml`:
- All services use `image: erpnext-helpdesk:local`, `pull_policy: never`.
- Named volumes redirected to **bind mounts under `/mnt/erpnext-data`**: `sites`, MariaDB data, redis-queue data (redis-cache may stay ephemeral).
- `frontend` (nginx) publishes container port to host **8080**.
- `.env` generated at boot from `creds.env` (`DB_PASSWORD`, admin password consumed by bootstrap, `FRAPPE_SITE_NAME_HEADER`, ports).

### 4. Backups (`files/backup.sh` + systemd timer)

- Daily systemd timer runs `docker compose exec -T backend bench --site erp.${SECRET_DOMAIN_2} backup --with-files`.
- Copies the newest `*.sql.gz` + files tarballs from the site's `private/backups` into `/mnt/erpnext-backups`, pruning to the last N locally (VolSync handles long-term retention).
- **Existing VolSync component** (`APP=erpnext-backups`, `VOLSYNC_CAPACITY=20Gi`) snapshots the PVC → restic → NFS. 1Password `volsync-template` item supplies `RESTIC_PASSWORD` (shared pattern). Repo path `/repository/erpnext-backups`.
- **Restore:** fresh VM → new empty site → `bench restore <dump> --with-private-files <tar>` from a dump synced back via VolSync.

### 5. Ingress

- `service.yaml`: ClusterIP Service selecting the VMI (`kubevirt.io/vm: erpnext` via `spec.selector`), port 8080 → targetPort 8080.
- `httproute-erp.yaml`: hostname `erp.${SECRET_DOMAIN_2}`, parentRef `external-prod`/`https`, backendRef the Service:8080.
- `httproute-support.yaml`: hostname `support.${SECRET_DOMAIN_2}`, parentRef `external-prod`/`https`; a `RequestRedirect`/`URLRewrite` filter sends `/` → `/helpdesk`, backendRef the Service:8080. Domain must also be registered in Frappe (`add-domain`) so nginx accepts the Host header.

### 6. Cluster change — KubeVirt virtiofs feature gate

Sharing a Filesystem PVC into the VM via virtiofs requires the virtiofs feature gate in the KubeVirt CR (`kubernetes/apps/kubevirt/kubevirt/app/kubevirt-cr.yaml`). Exact gate name for v1.9.0 verified at implementation (candidates: `VirtIOFS` / `ExperimentalVirtiofsSupport`); added to `configuration.developerConfiguration.featureGates` alongside existing `LiveMigration`.

## GitOps file layout

```
kubernetes/apps/kubevirt/erpnext/
  ks.yaml                     # Flux Kustomization: ns kubevirt, dependsOn kubevirt + cdi,
                              #   decryption sops-age, postBuild substituteFrom cluster-secrets,
                              #   component ../../components/volsync (APP=erpnext-backups)
  app/
    kustomization.yaml        # resources + configMapGenerator(files: files/*) + volsync component vars
    virtualmachine.yaml       # VM + rootdisk/datadisk DataVolumes + 5 volumes
    secret.sops.yaml          # erpnext-creds (stringData.creds.env), SOPS-encrypted
    service.yaml
    httproute-erp.yaml
    httproute-support.yaml
    files/
      compose.yaml
      apps.json
      bootstrap.sh
      backup.sh
```

Register `- ./erpnext/ks.yaml` in `kubernetes/apps/kubevirt/kustomization.yaml`.

The VolSync backup PVC/ReplicationSource/ExternalSecret come from the component via
`postBuild` substitutions (`APP=erpnext-backups`, `VOLSYNC_CAPACITY=20Gi`, defaults otherwise).

## Data flow

1. Flux reconciles `erpnext` Kustomization → CDI imports Ubuntu to rootdisk; blank datadisk; VolSync creates empty `erpnext-backups` PVC; ConfigMap + decrypted Secret materialize; VM starts.
2. First boot: cloud-init installs Docker, mounts disks, builds custom image, brings up compose stack, creates site + installs helpdesk + adds support domain.
3. Traffic: Cloudflare tunnel → `external-prod` → HTTPRoute → Service:8080 → VM nginx → frappe.
4. Nightly: backup timer → `bench backup --with-files` → `/mnt/erpnext-backups`; VolSync snapshots that PVC → restic → NFS.

## Error handling / edge cases

- **Idempotent first boot:** bootstrap guarded by a sentinel on the data disk; datadisk formatted only if no filesystem present. VM restart ≠ rebuild.
- **Rebuild (root cattle):** new root + fresh datadisk → bootstrap runs; site restored via `bench restore` from VolSync-synced dump (documented runbook, not automated in v1).
- **virtiofs unavailable / gate wrong:** fallback documented — make backups a second block disk and run restic from inside the VM to NFS (deviates from reusing the VolSync component); avoided unless the feature gate proves unworkable.
- **Image build failure on boot:** stack won't come up; diagnose via `virtctl console` / `docker logs`. Build ref pinned for reproducibility.
- **Host header:** support domain must be added in Frappe or nginx returns 404/redirect loops.

## Testing / verification

- `kubectl -n kubevirt get vm,vmi` → Running with an IP.
- `virtctl console erpnext` → cloud-init finished, `docker compose ps` all healthy.
- `curl -H 'Host: erp.${SECRET_DOMAIN_2}' http://<svc-clusterip>:8080` → ERPNext login.
- External: `https://erp.${SECRET_DOMAIN_2}` and `https://support.${SECRET_DOMAIN_2}` (lands on `/helpdesk`).
- `kubectl -n kubevirt get replicationsource erpnext-backups` → syncing; a restic snapshot lands in NFS after the first timer run (or a manual trigger).
- Restore rehearsal (optional): spin a throwaway site and `bench restore` a dump.

## Open items to confirm during implementation

1. Exact virtiofs feature-gate name for KubeVirt v1.9.0.
2. Ubuntu 26.04 LTS (resolute) cloud image URL (`cloud-images.ubuntu.com/releases/26.04/release/`) + CDI `http`/`registry` import source and checksum handling.
3. Helpdesk branch/tag compatible with ERPNext/Frappe version-16.
4. frappe_docker pinned ref + precise `pwd.yml` → `compose.yaml` adaptation (bind mounts, port 8080, env).
5. Service→VMI selector labels KubeVirt sets on the launcher pod.
6. Whether `redis-cache` stays ephemeral vs. on the data disk.

## Out of scope (YAGNI for v1)

- Automated restore-on-rebuild (runbook only).
- Live migration tuning / multi-VM HA.
- Multus/LAN IP.
- CI-built custom image (build-on-boot instead).
- Renovate tracking of frappe app git branches.
```
