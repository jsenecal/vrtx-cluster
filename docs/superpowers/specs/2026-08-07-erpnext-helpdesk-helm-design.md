# ERPNext + Helpdesk (isolated bench-per-tenant) via the official Helm chart — Design

**Date:** 2026-08-07
**Status:** Approved design, pending implementation plan
**Namespace:** `frappe`
**Companion:** `2026-08-07-erpnext-helpdesk-kubevirt-vm-design.md` (rejected VM approach, retained as a reusable KubeVirt VM pattern reference)

## Goal

Deploy an **isolated bench-per-tenant** ERPNext + **Frappe Helpdesk** platform using the
official `frappe/erpnext` Helm chart (8.x): **each tenant is its own HelmRelease** — its own
bundled MariaDB, Valkey, single site, sites volume, and backups — sharing only a single
CI-built custom image. Releases are generated from **one kustomize base + a thin per-tenant
overlay**, so tenant #2 is a small overlay, not a copy. Exposed via Gateway-API HTTPRoutes
on the prod gateway.

- **Tenant 1** (build now): site `erp.${SECRET_DOMAIN_2}`; ERPNext at `erp.${SECRET_DOMAIN_2}`, Helpdesk at its **own hostname** `helpdesk.${SECRET_DOMAIN_2}`.
- **Tenant 2** (deferred, infra not ready): site `erp.${SECRET_DOMAIN_3}` — a **different domain**, so it additionally needs a gateway listener + TLS + Cloudflare tunnel for `${SECRET_DOMAIN_3}` before an overlay can be added.
- **Helpdesk on its own host:** each bench serves one site, so pin `FRAPPE_SITE_NAME_HEADER` to the fixed site name; the helpdesk hostname is a second HTTPRoute that redirects `/` → `/helpdesk`. No `bench add-domain` needed.
- Provisioning: **declarative per-tenant overlay in Git**; parameterized by `TENANT` (k8s slug), `SITE_NAME` (= erp host = fixed site header), `HELPDESK_HOST`.
- **Isolation: physical** — separate MariaDB *instance* per tenant (not just separate DBs on a shared server).
- **Scale: one tenant now, a second later.** The ~2× footprint is modest and buys full blast-radius containment.

## Why bench-per-tenant (isolation model)

The user requires **physical DB isolation**: a DB-level problem (crash, bad upgrade, restore,
connection exhaustion) in one tenant must not touch another. Logical isolation (separate
databases on one shared `mysqld`) does not provide this — the instance is shared. So each
tenant gets its **own bundled `mariadb-sts` instance** inside its **own HelmRelease**.

Benefits at this scale: complete blast-radius containment, **independent upgrade/restore/backup
per tenant**, and — directly addressing this repo's history — a MariaDB problem can never span
tenants. Each release is also *simpler* than a multisite bench: plain **single-site**
(`jobs.createSite`), one hostname, one HTTPRoute. Cost: ~N× footprint (N MariaDBs, N Valkey
pairs, N app-pod sets), acceptable at N≈2.

**Rejected alternatives:** multisite single bench (logical isolation only — shared instance);
per-site separate DB servers under one bench (not cleanly supported by the chart, non-standard
`site_config` db_host wiring).

## Why this deployment shape (lesson from the previous deployment)

Previously this repo ran the same chart (`b483f0dd`, Sep 2025, `7.0.126`) with
**`mariadb.enabled: false` + `redis-*.enabled: false`**, pointing at an **external
mariadb-operator/Galera cluster and external Redis**. Galera synchronous replication +
operator churn + k8s liveness probes killing a slow-recovering DB + a shared Redis whose
version drift produced the `frappe.types.frappedict` pickle 500s = the pain. Removed.

**Root cause:** Galera + operator + probe-kills + shared Redis — *not* MariaDB the engine,
*not* containers, *not* Ceph replication. Postgres rejected (experimental for ERPNext+Helpdesk).
KubeVirt VM designed and rejected (bespoke ops).

**Therefore per tenant:** chart-bundled **standalone MariaDB** (`mariadb-sts`, one instance,
no operator/Galera) + chart-bundled **Valkey**, with a **generous `startupProbe`** so InnoDB
crash recovery never triggers a liveness-kill loop.

## Context / Constraints

- Storage: `ceph-block` (RWO), **`ceph-filesystem` (cephfs, RWX)**, `openebs-hostpath`. Snapshot class `csi-ceph-blockpool`.
- Gateway `external-prod` (`kube-system`) serves `*.${SECRET_DOMAIN_2}` with TLS; Cloudflare tunnel (prod) fronts `*.${SECRET_DOMAIN_2}`. `SECRET_DOMAIN_2` = `${SECRET_DOMAIN_2}`.
- **`*.${SECRET_DOMAIN_2}` is a shared prod domain** (`app.${SECRET_DOMAIN_2}` already routes there) → no wildcard route; each tenant hostname is explicit. Wildcard **DNS** already resolves to the tunnel → no per-tenant DNS record.
- VolSync component (`kubernetes/components/volsync`, local): filesystem restic → NFS, snapshot copyMethod on `ceph-block`; component PVC uses `dataSourceRef` restore; 1Password `volsync-template` supplies `RESTIC_PASSWORD`; parameterized by `${APP}`.
- ExternalSecrets: `ClusterSecretStore` `onepassword-connect`.
- Chart facts (from `frappe/helm`): `image.repository/tag`; `mariadb-sts` standalone (no Galera); Valkey cache+queue default; `jobs.createSite` (single site) with `installApps`; native `httproute`; `ingress` off by default. Multi-pod chart needs an **RWX** `sites` volume even for a single site.

## Architecture

```
Cloudflare tunnel (prod, *.${SECRET_DOMAIN_2}) → external-prod gateway (TLS)
   ├─ HTTPRoute erpnext-t1  host: t1.${SECRET_DOMAIN_2} ─┐
   └─ HTTPRoute erpnext-t2  host: t2.${SECRET_DOMAIN_2} ─┼─ (per tenant)
                                                       ▼
   ┌──────────────────── namespace: frappe ─────────────────────────────┐
   │ shared: image ghcr.io/<you>/erpnext-helpdesk:<tag> (CI-built, v16)  │
   │                                                                     │
   │  HelmRelease erpnext-t1            HelmRelease erpnext-t2            │
   │  ├─ nginx/backend/queue/sched/ws   ├─ nginx/backend/queue/sched/ws  │
   │  ├─ sites vol PVC (cephfs RWX)     ├─ sites vol PVC (cephfs RWX)     │
   │  ├─ mariadb-sts (own, ceph-block)  ├─ mariadb-sts (own, ceph-block) │  ← physical DB isolation
   │  ├─ valkey-cache / valkey-queue    ├─ valkey-cache / valkey-queue   │
   │  └─ jobs.createSite t1.loop…       └─ jobs.createSite t2.loop…      │
   │  CronJob backup-t1 → VolSync       CronJob backup-t2 → VolSync      │
   │  ExternalSecret erpnext-t1-secrets ExternalSecret erpnext-t2-secrets│
   └─────────────────────────────────────────────────────────────────────┘
   generated from: tenant-base (kustomize) + overlays/{t1,t2}
```

## Components

### 1. Shared: chart source + custom image
- `HelmRepository` `erpnext` (`flux-system`), URL **`https://helm.erpnext.com`** (verified), chart **`erpnext` 8.0.71** (appVersion v16.31.1; pin + Renovate-track), in `kubernetes/flux/meta/repos/`.
- **Custom image** (shared by all tenants), build context `docker/erpnext-helpdesk/`: `apps.json` = `erpnext` (branch `version-16`) + `helpdesk` (branch **`main`**) + `telephony` (branch **`develop`**), **`FRAPPE_BRANCH=version-16`**, frappe_docker layered `Containerfile`. Built by **GitHub Actions → `ghcr.io/<you>/erpnext-helpdesk:<version>`**, Renovate-tracked.
  - **App-branch facts (verified):** helpdesk does *not* use `version-NN` branches — its `main` `pyproject.toml` pins `frappe = ">=16.0.0-dev,<18.0.0"`, i.e. it **requires frappe ≥16**, so `main` is the correct pairing with frappe/erpnext `version-16` (the official image's `FRAPPE_BRANCH=version-15` is stale CI). `telephony` has only `develop`. `telephony` matches the official Helpdesk image and backs Helpdesk's call features.
  - **Build gotcha:** helpdesk `main` needs `python >=3.14`; confirm the frappe_docker `version-16` base image provides it at build time.

### 2. Per-tenant HelmRelease (the base)
Each tenant = one `HelmRelease` `erpnext-‹tenant›` with:
- `image.repository/tag` → the shared GHCR image.
- `mariadb-sts.enabled: true` — **own single instance**, `ceph-block`, ~10–20Gi; **generous `startupProbe`** (≈`failureThreshold: 60`, `periodSeconds: 5`) + InnoDB tuning (`innodb_flush_log_at_trx_commit=2`, sane `innodb_io_capacity`/`buffer_pool_size`, `utf8mb4`).
- `valkey-cache` + `valkey-queue` — own instances.
- **Sites volume:** own PVC on **`ceph-filesystem` (RWX)** (multi-pod chart needs RWX even single-site).
- `jobs.createSite`: `siteName: ${SITE_NAME}` (the erp host, e.g. `erp.${SECRET_DOMAIN_2}`), `installApps: [erpnext, helpdesk, telephony]`, admin password from the tenant ExternalSecret, `dbType: mariadb`.
- **Fixed site header:** set `nginx.envVars: [{name: FRAPPE_SITE_NAME_HEADER, value: ${SITE_NAME}}]` so the bench serves its single site regardless of the incoming Host — lets multiple hostnames (erp + helpdesk) map to it.
- Chart ingress/httproute disabled (own HTTPRoutes below).

### 3. Per-tenant ingress (two hostnames)
- `HTTPRoute` `erpnext-‹tenant›`: `hostnames: [${SITE_NAME}]` (the erp host), parentRef `external-prod`/`https`, backend the tenant nginx Service `erpnext-‹tenant›:8080`. Serves ERPNext at `/`.
- `HTTPRoute` `erpnext-‹tenant›-helpdesk`: `hostnames: [${HELPDESK_HOST}]`, same parentRef/backend, with a `RequestRedirect` rule sending exact path `/` → `/helpdesk` (other paths pass through). Lands users on the Helpdesk portal at `${HELPDESK_HOST}/helpdesk`.

### 4. Per-tenant backups
- `CronJob` `erpnext-‹tenant›-backup` (nightly): `bench --site ‹tenant›.${SECRET_DOMAIN_2} backup --with-files`, copies newest dump+files into the tenant backup PVC.
- **VolSync component** with `APP=erpnext-‹tenant›-backups` → restic → NFS. Restore is per-tenant/independent.

### 5. Per-tenant secrets
- `ExternalSecret` `erpnext-‹tenant›-secrets` (store `onepassword-connect`, own 1Password item) → DB root/app + Administrator password for that tenant; referenced by its `mariadb-sts` + `createSite`.

### 6. Base + overlay structure (DRY)
- **`tenant-base/`** — kustomize base holding the common HelmRelease, ExternalSecret, HTTPRoute, backup CronJob, and volsync component wiring, with tenant-specific fields as placeholders.
- **`tenants/‹tenant›/`** — thin overlay + its own **Flux `Kustomization` (`ks.yaml`)** that: kustomize-builds `tenant-base` with the tenant's patches (release name, `siteName`, hostname, secret item, `APP`), includes the volsync component, and sets `postBuild.substitute` for the tenant identity + `substituteFrom` cluster-secrets.
- Onboarding a tenant = add a `tenants/‹tenant›/` overlay (name, host, 1Password item) + register its `ks.yaml`. (Exact DRY mechanism — kustomize patches vs Flux `postBuild.substitute` for `${TENANT}`/`${TENANT_HOST}` — decided at implementation; both are viable, substitution keeps the base fully generic.)

## GitOps file layout

```
kubernetes/flux/meta/repos/erpnext.yaml            # shared HelmRepository

kubernetes/apps/frappe/
  kustomization.yaml                               # namespace frappe, common component; lists tenant ks.yamls
  tenant-base/
    kustomization.yaml
    helmrelease.yaml                               # ${TENANT}/${TENANT_HOST} placeholders; mariadb-sts, valkey,
                                                   #   sites vol (RWX), createSite, image(GHCR), probes/tuning
    externalsecret.yaml                            # erpnext-${TENANT}-secrets
    httproute.yaml                                 # host ${TENANT_HOST}
    cronjob-backup.yaml                            # bench --site ${TENANT_HOST} backup --with-files
  tenants/
    <t1>/
      ks.yaml                                      # Flux KS: path tenants/<t1>, component volsync (APP=erpnext-<t1>-backups),
                                                   #   postBuild substitute TENANT/TENANT_HOST + substituteFrom cluster-secrets
      kustomization.yaml                           # ../../tenant-base (+ any patches)
    <t2>/
      ks.yaml
      kustomization.yaml

docker/erpnext-helpdesk/{apps.json, Containerfile}
.github/workflows/build-erpnext-helpdesk.yaml      # shared CI → GHCR
```

## Data flow

1. CI builds/pushes the shared erpnext+helpdesk(+telephony) image to GHCR.
2. Flux reconciles each tenant KS → its HelmRelease → own mariadb-sts + valkey + app pods (own RWX sites vol) + `createSite` (creates the tenant site, installs apps) + own VolSync backup PVC.
3. Traffic: tunnel → `external-prod` → tenant HTTPRoute (host match) → tenant nginx → gunicorn.
4. Nightly: per-tenant CronJob `bench backup --with-files` → tenant backup PVC → VolSync → NFS.

## Error handling / edge cases

- **DB crash-loop (old failure):** prevented per tenant by standalone DB + generous `startupProbe`; and contained — cannot span tenants.
- **Shared-Redis pickle bug:** cannot recur (each release's own Valkey).
- **RWX sites volume:** cephfs handles Frappe's many small files; each tenant's own PVC.
- **Upgrades/migrations:** bump the shared image/chart, roll tenants **independently**; each runs `bench --site ‹host› migrate`. A tenant can lag or be rolled back alone.
- **Footprint growth:** each new tenant adds a full stack; fine at ~2, revisit the model if tenant count grows large (multisite would trade isolation for density).
- **Base/overlay drift:** keep tenant-specific values *only* in overlays; everything else in the base so upgrades touch one place.
- **Backup consistency:** logical `bench backup` per site is app-consistent.

## Testing / verification

- Per tenant: `flux -n frappe get hr erpnext-‹tenant›` Ready; pods Running; `createSite` Completed; `bench --site ‹host› list-apps` shows erpnext + helpdesk (+ telephony).
- `https://${SITE_NAME}` → ERPNext login; `https://${HELPDESK_HOST}` → redirects to `/helpdesk` (Helpdesk portal) — for each tenant.
- `kubectl -n frappe get replicationsource` shows `erpnext-‹tenant›-backups` syncing; a restic snapshot per tenant lands in NFS after the first CronJob run.
- Isolation check: disrupt one tenant's mariadb pod → the other tenant is unaffected; the disrupted one recovers within its startupProbe window.
- Onboarding check: adding a `tenants/‹t2›/` overlay brings up a second fully-isolated stack with no change to `‹t1›`.

## Open items to confirm during implementation

1. ~~chart repo URL + version~~ — **verified: `https://helm.erpnext.com`, chart `erpnext` 8.0.71 (appVersion v16.31.1).**
2. ~~helpdesk/telephony v16 branches~~ — **verified: helpdesk `main` (requires frappe ≥16), telephony `develop`, `FRAPPE_BRANCH=version-16`.** Remaining: confirm the v16 base image ships `python ≥3.14` (helpdesk main requirement).
3. Chart keys for: the **RWX sites volume**, `mariadb-sts` `startupProbe` + custom `my.cnf`, and credential wiring (chart-generated Secret vs our ExternalSecret).
4. `createSite` schema: admin password wiring; whether `telephony` must be in `installApps` or is pulled by helpdesk.
5. Chart nginx Service name/port for the HTTPRoute backendRef.
6. DRY mechanism for base+overlay: kustomize patches vs Flux `postBuild.substitute` (`${TENANT}`/`${TENANT_HOST}`) — pick one; ensure resource names, PVCs, secrets, and `APP` all parameterize cleanly.
7. GHCR image visibility (public vs pull-secret) + Renovate datasource.
8. Backup CronJob mechanics (reaching the tenant's sites vol + DB).

## Out of scope (YAGNI for v1)

- Multisite single-bench / logical-only isolation (rejected — user wants physical isolation).
- Dynamic/ad-hoc tenant onboarding (tenants are declarative overlays).
- Custom per-tenant domains (start with `‹tenant›.${SECRET_DOMAIN_2}`).
- HA MariaDB / Galera (deliberately avoided); Postgres (rejected); KubeVirt VM (rejected — companion doc).
- Automated restore (runbook only).
```
