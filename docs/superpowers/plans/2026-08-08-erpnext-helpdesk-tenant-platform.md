# ERPNext + Helpdesk Isolated Bench-Per-Tenant — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up an isolated, bench-per-tenant ERPNext + Frappe Helpdesk platform via the official `frappe/erpnext` Helm chart (8.0.71), generated from one kustomize base + a thin per-tenant overlay, with a CI-built custom image, per-tenant bundled MariaDB/Valkey, app-consistent VolSync backups, and Gateway-API ingress on `external-prod`.

**Architecture:** Each tenant is its own Flux `Kustomization` → `HelmRelease` `erpnext-‹tenant›` in namespace `frappe`, with its own `mariadb-sts` (ceph-block), Valkey, RWX sites volume (`persistence.worker` on ceph-filesystem), single site, and backup pipeline. Releases share one CI-built image `ghcr.io/<OWNER>/erpnext-helpdesk`. Resource names are parameterized with Flux `postBuild.substitute` (`${TENANT}`); hostnames use the secret domain token `${SECRET_DOMAIN_2}` from `cluster-secrets` (never a literal domain in Git).

**Tech Stack:** Flux (Kustomization + HelmRelease `valuesFrom`/`postRenderers`), Kustomize components (volsync), 1Password ExternalSecrets, Cilium Gateway API (HTTPRoute), Rook-Ceph (ceph-block RWO + ceph-filesystem RWX), GitHub Actions → GHCR, frappe_docker layered build.

**Spec:** `docs/superpowers/specs/2026-08-07-erpnext-helpdesk-helm-design.md`

**Secret hygiene:** Real domains are secrets in this repo. **Never write a literal domain** (the prod domain, or the tenant-2 domain) into any committed file — always use the `${SECRET_DOMAIN_2}` / `${SECRET_DOMAIN_3}` tokens, resolved by Flux from `cluster-secrets`. For local validation/verification, export the domain in your shell (see tasks) so it never lands in Git.

**Tenant model:**
- **Tenant 1 (build now)** — slug `loopnetworks`. Site (and `FRAPPE_SITE_NAME_HEADER`) = `erp.${SECRET_DOMAIN_2}`. Two hostnames: `erp.${SECRET_DOMAIN_2}` (ERPNext) and `helpdesk.${SECRET_DOMAIN_2}` (Helpdesk, via a `/` → `/helpdesk` redirect route). Both are `*.${SECRET_DOMAIN_2}` so existing gateway TLS + tunnel + wildcard DNS already cover them.
- **Tenant 2 (deferred)** — site `erp.${SECRET_DOMAIN_3}` on a **different domain** whose infra does not exist yet (needs a gateway listener + TLS cert + Cloudflare tunnel + a `SECRET_DOMAIN_3` entry in `cluster-secrets`). Do **not** build it now — see Phase D runbook.

**Verified facts (do not re-derive):**
- Chart: `erpnext` `8.0.71`, appVersion `v16.31.1`, repo `https://helm.erpnext.com`.
- Custom-image app branches: `erpnext` `version-16`, `helpdesk` `main` (its `pyproject.toml` pins `frappe>=16`), `telephony` `develop`; `FRAPPE_BRANCH=version-16`. Helpdesk `main` needs `python>=3.14`.
- Chart Service names (release `erpnext-‹tenant›`): HTTP entry **`erpnext-‹tenant›` :8080** (HTTPRoute backend), `erpnext-‹tenant›-mariadb-sts:3306`, `erpnext-‹tenant›-valkey-cache/queue:6379`, `erpnext-‹tenant›-gunicorn:8000`, `erpnext-‹tenant›-socketio:9000`.
- RWX sites volume = `persistence.worker` (`accessModes:[ReadWriteMany]`); chart **requires** `persistence.worker.storageClass`. Worker PVC is named `erpnext-‹tenant›-worker`.
- `mariadb-sts` has a `livenessProbe` (tcp 3306, ~60s to kill) and **no startupProbe** → add one via HelmRelease `postRenderers`.
- Credentials: `mariadb-sts.rootPassword` (inject via Flux `valuesFrom.targetPath`); `jobs.createSite.adminExistingSecret` + `adminExistingSecretKey` for the Administrator password.
- Fixed `nginx.envVars: FRAPPE_SITE_NAME_HEADER=erp.${SECRET_DOMAIN_2}` makes the bench serve its one site for any Host — so both hostnames work without `bench add-domain`.

> Replace `<OWNER>` with the GitHub owner/org for GHCR (e.g. `jsenecal`) consistently. Flux does **single-pass** substitution, so the base uses `erp.${SECRET_DOMAIN_2}` directly (one token, resolved once) — do not introduce an intermediate token that itself contains `${...}`.

---

## Phase A — Shared prerequisites (chart repo + custom image)

### Task 1: Register the ERPNext HelmRepository

**Files:**
- Create: `kubernetes/flux/meta/repos/erpnext.yaml`
- Modify: `kubernetes/flux/meta/repos/kustomization.yaml`

- [ ] **Step 1: Create the HelmRepository**

`kubernetes/flux/meta/repos/erpnext.yaml`:
```yaml
---
# yaml-language-server: $schema=https://raw.githubusercontent.com/fluxcd-community/flux2-schemas/main/helmrepository-source-v1.json
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: erpnext
  namespace: flux-system
spec:
  interval: 1h
  url: https://helm.erpnext.com
```

- [ ] **Step 2: Add it to the repos kustomization**

Edit `kubernetes/flux/meta/repos/kustomization.yaml` — add `./erpnext.yaml` to `resources` (sorted with the existing entries).

- [ ] **Step 3: Validate**

Run: `kustomize build kubernetes/flux/meta/repos | kubeconform -strict -ignore-missing-schemas`
Expected: exits 0; output includes the `erpnext` HelmRepository.

- [ ] **Step 4: Commit**

```bash
git add kubernetes/flux/meta/repos/erpnext.yaml kubernetes/flux/meta/repos/kustomization.yaml
git commit -m "feat(frappe): add erpnext HelmRepository"
```

---

### Task 2: Custom image build context (apps.json)

The image is built by CI (Task 3) from **frappe_docker's own** `images/layered/Containerfile`, so this repo needs only `apps.json`.

**Files:**
- Create: `docker/erpnext-helpdesk/apps.json`

- [ ] **Step 1: Create `apps.json`**

`docker/erpnext-helpdesk/apps.json`:
```json
[
  { "url": "https://github.com/frappe/erpnext", "branch": "version-16" },
  { "url": "https://github.com/frappe/helpdesk", "branch": "main" },
  { "url": "https://github.com/frappe/telephony", "branch": "develop" }
]
```

- [ ] **Step 2: Validate JSON**

Run: `python3 -c "import json; json.load(open('docker/erpnext-helpdesk/apps.json'))"`
Expected: no output, exit 0.

- [ ] **Step 3: Commit**

```bash
git add docker/erpnext-helpdesk/apps.json
git commit -m "feat(frappe): custom erpnext+helpdesk+telephony image apps.json"
```

---

### Task 3: GitHub Actions workflow → GHCR

**Files:**
- Create: `.github/workflows/build-erpnext-helpdesk.yaml`

- [ ] **Step 1: Create the workflow**

`.github/workflows/build-erpnext-helpdesk.yaml`:
```yaml
---
name: Build ERPNext+Helpdesk image
on:
  push:
    branches: [main]
    paths:
      - docker/erpnext-helpdesk/apps.json
      - .github/workflows/build-erpnext-helpdesk.yaml
  workflow_dispatch: {}
permissions:
  contents: read
  packages: write
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout frappe_docker
        uses: actions/checkout@v4
        with:
          repository: frappe/frappe_docker
          ref: main
          path: frappe_docker
      - name: Checkout this repo (for apps.json)
        uses: actions/checkout@v4
        with:
          path: self
      - name: Compute APPS_JSON_BASE64
        run: echo "APPS_JSON_BASE64=$(base64 -w0 self/docker/erpnext-helpdesk/apps.json)" >> "$GITHUB_ENV"
      - name: Log in to GHCR
        uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}
      - name: Build and push
        uses: docker/build-push-action@v6
        with:
          context: frappe_docker
          file: frappe_docker/images/layered/Containerfile
          push: true
          tags: ghcr.io/<OWNER>/erpnext-helpdesk:v16.31.1
          build-args: |
            FRAPPE_PATH=https://github.com/frappe/frappe
            FRAPPE_BRANCH=version-16
            APPS_JSON_BASE64=${{ env.APPS_JSON_BASE64 }}
```

- [ ] **Step 2: Commit**

```bash
git add .github/workflows/build-erpnext-helpdesk.yaml
git commit -m "ci(frappe): build erpnext+helpdesk image to GHCR"
```

- [ ] **Step 3: Push and run the build**

```bash
git push
gh workflow run build-erpnext-helpdesk.yaml
gh run watch "$(gh run list --workflow=build-erpnext-helpdesk.yaml --limit 1 --json databaseId --jq '.[0].databaseId')"
```
Expected: run succeeds. Confirm the image pulls and note visibility:
```bash
docker pull ghcr.io/<OWNER>/erpnext-helpdesk:v16.31.1
gh api "user/packages/container/erpnext-helpdesk" --jq '.visibility' 2>/dev/null || echo "check org packages"
```
If `private`, either make it public in GHCR settings or plan `imagePullSecrets` (Task 5 note).

---

## Phase B — Namespace + tenant base

### Task 4: Create the `frappe` namespace kustomization

**Files:**
- Create: `kubernetes/apps/frappe/kustomization.yaml`

- [ ] **Step 1: Create it (mirrors `kubernetes/apps/productivity/kustomization.yaml`)**

`kubernetes/apps/frappe/kustomization.yaml`:
```yaml
---
# yaml-language-server: $schema=https://json.schemastore.org/kustomization
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: frappe
components:
  - ../../components/common
resources:
  - ./tenants/loopnetworks/ks.yaml
```
> Commit deferred to Task 9 (references files created next).

---

### Task 5: Tenant base — HelmRelease

**Files:**
- Create: `kubernetes/apps/frappe/tenant-base/helmrelease.yaml`

- [ ] **Step 1: Create the HelmRelease**

`kubernetes/apps/frappe/tenant-base/helmrelease.yaml`:
```yaml
---
# yaml-language-server: $schema=https://kubernetes-schemas.pages.dev/helm.toolkit.fluxcd.io/helmrelease_v2.json
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: erpnext-${TENANT}
spec:
  interval: 30m
  chart:
    spec:
      chart: erpnext
      version: "8.0.71"
      sourceRef:
        kind: HelmRepository
        name: erpnext
        namespace: flux-system
  maxHistory: 2
  install:
    remediation:
      retries: 3
  upgrade:
    cleanupOnFail: true
    remediation:
      strategy: rollback
      retries: 3
  # Inject the MariaDB root password from the ExternalSecret without plaintext in Git.
  valuesFrom:
    - kind: Secret
      name: erpnext-${TENANT}-secret
      valuesKey: mariadb-root-password
      targetPath: mariadb-sts.rootPassword
  # mariadb-sts ships a livenessProbe but no startupProbe; add a generous one so
  # InnoDB crash recovery cannot trigger a liveness-kill loop.
  postRenderers:
    - kustomize:
        patches:
          - target:
              kind: StatefulSet
              name: ".*-mariadb-sts"
            patch: |
              - op: add
                path: /spec/template/spec/containers/0/startupProbe
                value:
                  tcpSocket:
                    port: 3306
                  periodSeconds: 10
                  failureThreshold: 60
  values:
    image:
      repository: ghcr.io/<OWNER>/erpnext-helpdesk
      tag: v16.31.1
      pullPolicy: IfNotPresent
    nginx:
      # Fixed site header: serve this bench's single site for any incoming Host,
      # so both erp.* and helpdesk.* hostnames map to it.
      envVars:
        - name: FRAPPE_SITE_NAME_HEADER
          value: erp.${SECRET_DOMAIN_2}
    persistence:
      worker:
        enabled: true
        size: 20Gi
        storageClass: ceph-filesystem
        accessModes:
          - ReadWriteMany
      logs:
        enabled: false
    ingress:
      enabled: false
    httproute:
      enabled: false
    mariadb-sts:
      enabled: true
      persistence:
        storageClass: ceph-block
        size: 20Gi
      myCnf: |
        [mysqld]
        skip-character-set-client-handshake
        skip-innodb-read-only-compressed
        character-set-server=utf8mb4
        collation-server=utf8mb4_unicode_ci
        innodb_flush_log_at_trx_commit=2
        innodb_buffer_pool_size=1G
    jobs:
      createSite:
        enabled: true
        siteName: erp.${SECRET_DOMAIN_2}
        adminExistingSecret: erpnext-${TENANT}-secret
        adminExistingSecretKey: admin-password
        installApps:
          - erpnext
          - helpdesk
          - telephony
        dbType: mariadb
      createMultipleSites:
        enabled: false
```
> If Task 3 found the image private: add `imagePullSecrets: [{ name: ghcr-pull }]` under `spec.values` and create that Secret via an ExternalSecret. Default assumption: public image.
> Tenant 2 (different domain) overrides the two `${SECRET_DOMAIN_2}` host references via a kustomize patch in its overlay (Phase D).

---

### Task 6: Tenant base — ExternalSecret (credentials)

**Files:**
- Create: `kubernetes/apps/frappe/tenant-base/externalsecret.yaml`

- [ ] **Step 1: Create the ExternalSecret**

`kubernetes/apps/frappe/tenant-base/externalsecret.yaml`:
```yaml
---
# yaml-language-server: $schema=https://kubernetes-schemas.pages.dev/external-secrets.io/externalsecret_v1.json
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: erpnext-${TENANT}
spec:
  secretStoreRef:
    kind: ClusterSecretStore
    name: onepassword-connect
  target:
    name: erpnext-${TENANT}-secret
    template:
      data:
        mariadb-root-password: "{{ .MARIADB_ROOT_PASSWORD }}"
        admin-password: "{{ .ADMIN_PASSWORD }}"
  dataFrom:
    - extract:
        key: erpnext-${TENANT}
```
> 1Password item `erpnext-‹tenant›` must contain fields `MARIADB_ROOT_PASSWORD` and `ADMIN_PASSWORD` (uppercase), each `openssl rand -base64 24`.

---

### Task 7: Tenant base — HTTPRoutes (erp + helpdesk)

**Files:**
- Create: `kubernetes/apps/frappe/tenant-base/httproute.yaml`

- [ ] **Step 1: Create both HTTPRoutes**

`kubernetes/apps/frappe/tenant-base/httproute.yaml`:
```yaml
---
# yaml-language-server: $schema=https://kubernetes-schemas.pages.dev/gateway.networking.k8s.io/httproute_v1.json
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: erpnext-${TENANT}
spec:
  parentRefs:
    - name: external-prod
      namespace: kube-system
      sectionName: https
  hostnames:
    - erp.${SECRET_DOMAIN_2}
  rules:
    - backendRefs:
        - name: erpnext-${TENANT}
          port: 8080
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: erpnext-${TENANT}-helpdesk
spec:
  parentRefs:
    - name: external-prod
      namespace: kube-system
      sectionName: https
  hostnames:
    - helpdesk.${SECRET_DOMAIN_2}
  rules:
    # Exact "/" redirects to the Helpdesk portal; all other paths pass through
    # (so /helpdesk, /helpdesk/*, /api/*, /assets/* reach the backend).
    - matches:
        - path:
            type: Exact
            value: /
      filters:
        - type: RequestRedirect
          requestRedirect:
            path:
              type: ReplaceFullPath
              replaceFullPath: /helpdesk
            statusCode: 302
    - backendRefs:
        - name: erpnext-${TENANT}
          port: 8080
```
> Confirm Cilium supports the `RequestRedirect` filter with `ReplaceFullPath` during Task 11; if not, fall back to a `URLRewrite` on the passthrough plus a landing redirect.

---

### Task 8: Tenant base — backup CronJob + kustomization

**Files:**
- Create: `kubernetes/apps/frappe/tenant-base/cronjob-backup.yaml`
- Create: `kubernetes/apps/frappe/tenant-base/kustomization.yaml`

- [ ] **Step 1: Create the backup CronJob**

`kubernetes/apps/frappe/tenant-base/cronjob-backup.yaml`:
```yaml
---
apiVersion: batch/v1
kind: CronJob
metadata:
  name: erpnext-${TENANT}-backup
spec:
  schedule: "0 3 * * *"
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 1
  failedJobsHistoryLimit: 3
  jobTemplate:
    spec:
      backoffLimit: 1
      template:
        spec:
          restartPolicy: Never
          securityContext:
            runAsUser: 1000
            runAsGroup: 1000
            fsGroup: 1000
          containers:
            - name: backup
              image: ghcr.io/<OWNER>/erpnext-helpdesk:v16.31.1
              command: ["/bin/bash", "-c"]
              args:
                - |
                  set -euo pipefail
                  cd /home/frappe/frappe-bench
                  SITE="erp.${SECRET_DOMAIN_2}"
                  bench --site "$SITE" backup --with-files
                  mkdir -p /backups
                  cp -f sites/"$SITE"/private/backups/*-database.sql.gz      /backups/ || true
                  cp -f sites/"$SITE"/private/backups/*-files.tar            /backups/ || true
                  cp -f sites/"$SITE"/private/backups/*-private-files.tar    /backups/ || true
                  ls -1t /backups | tail -n +13 | while read -r f; do rm -f "/backups/$f"; done
              volumeMounts:
                - name: sites
                  mountPath: /home/frappe/frappe-bench/sites
                - name: backups
                  mountPath: /backups
          volumes:
            - name: sites
              persistentVolumeClaim:
                claimName: erpnext-${TENANT}-worker
            - name: backups
              persistentVolumeClaim:
                claimName: erpnext-${TENANT}-backups
```
> `${SECRET_DOMAIN_2}` is resolved by Flux at apply time (the value never appears in Git). Confirm the worker PVC name (`erpnext-‹tenant›-worker`) in Task 9 Step 4.

- [ ] **Step 2: Create the base kustomization**

`kubernetes/apps/frappe/tenant-base/kustomization.yaml`:
```yaml
---
# yaml-language-server: $schema=https://json.schemastore.org/kustomization
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ./helmrelease.yaml
  - ./externalsecret.yaml
  - ./httproute.yaml
  - ./cronjob-backup.yaml
```

---

## Phase C — Tenant 1 (`loopnetworks`) + live bring-up

### Task 9: Tenant 1 overlay + validate the tree offline

**Files:**
- Create: `kubernetes/apps/frappe/tenants/loopnetworks/kustomization.yaml`
- Create: `kubernetes/apps/frappe/tenants/loopnetworks/ks.yaml`

- [ ] **Step 1: Create the overlay kustomization**

`kubernetes/apps/frappe/tenants/loopnetworks/kustomization.yaml`:
```yaml
---
# yaml-language-server: $schema=https://json.schemastore.org/kustomization
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ../../tenant-base
```

- [ ] **Step 2: Create the tenant Flux Kustomization**

`kubernetes/apps/frappe/tenants/loopnetworks/ks.yaml`:
```yaml
---
# yaml-language-server: $schema=https://raw.githubusercontent.com/fluxcd-community/flux2-schemas/main/kustomization-kustomize-v1.json
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: &app erpnext-loopnetworks
  namespace: flux-system
spec:
  targetNamespace: frappe
  commonMetadata:
    labels:
      app.kubernetes.io/name: *app
  dependsOn:
    - name: volsync
      namespace: volsync-system
  path: ./kubernetes/apps/frappe/tenants/loopnetworks
  prune: true
  sourceRef:
    kind: GitRepository
    name: flux-system
    namespace: flux-system
  wait: false
  interval: 30m
  retryInterval: 1m
  timeout: 15m
  components:
    - ../../../../components/volsync
  postBuild:
    substitute:
      TENANT: loopnetworks
      APP: erpnext-loopnetworks-backups
      VOLSYNC_CAPACITY: 20Gi
    substituteFrom:
      - kind: Secret
        name: cluster-secrets
```
> `${SECRET_DOMAIN_2}` comes from `cluster-secrets`. The volsync component provides PVC/ReplicationSource/restic-ExternalSecret keyed on `APP`.

- [ ] **Step 3: Validate the built tree offline** (export the real domain locally so it is never committed)

```bash
export TENANT=loopnetworks
export SECRET_DOMAIN_2=<prod-domain>   # from cluster-secrets; shell-only, do not commit
kustomize build kubernetes/apps/frappe/tenants/loopnetworks \
  | envsubst '${TENANT} ${SECRET_DOMAIN_2}' \
  | kubeconform -strict -ignore-missing-schemas
```
Expected: exits 0.

- [ ] **Step 4: Confirm the worker PVC name**

```bash
helm template erpnext-loopnetworks erpnext/erpnext --version 8.0.71 \
  --set mariadb-sts.enabled=true --set mariadb-sts.persistence.storageClass=ceph-block \
  --set persistence.worker.storageClass=ceph-filesystem \
  | grep -A2 'kind: PersistentVolumeClaim' | grep 'name:'
```
Expected: `erpnext-loopnetworks-worker`. If different, fix `claimName` in `cronjob-backup.yaml`.

- [ ] **Step 5: Ensure the namespace kustomization lists the tenant**

Confirm `kubernetes/apps/frappe/kustomization.yaml` `resources` includes `./tenants/loopnetworks/ks.yaml` (Task 4).

- [ ] **Step 6: Commit the whole frappe tree**

```bash
git add kubernetes/apps/frappe
git commit -m "feat(frappe): isolated bench-per-tenant base + loopnetworks tenant (ERPNext+Helpdesk)"
```

---

### Task 10: Create the 1Password item for tenant 1

- [ ] **Step 1: Create the item**

Create a 1Password item `erpnext-loopnetworks` in the `onepassword-connect` vault with fields:
- `MARIADB_ROOT_PASSWORD` = `openssl rand -base64 24`
- `ADMIN_PASSWORD` = `openssl rand -base64 24`

---

### Task 11: Deploy tenant 1 and verify live

> GitOps: effect only after push + Flux reconcile.

- [ ] **Step 1: Push**

```bash
git push
```

- [ ] **Step 2: Reconcile + watch**

```bash
flux reconcile source git flux-system
flux -n flux-system get kustomization erpnext-loopnetworks
flux -n frappe get helmrelease erpnext-loopnetworks
```
Expected: Kustomization Ready; HelmRelease reconciles (minutes for image pull + site creation).

- [ ] **Step 3: Verify credentials materialized**

```bash
kubectl -n frappe get externalsecret erpnext-loopnetworks
kubectl -n frappe get secret erpnext-loopnetworks-secret -o jsonpath='{.data.admin-password}' | base64 -d | head -c 4; echo " …(present)"
```
Expected: `SecretSynced`; secret has `mariadb-root-password` + `admin-password`.

- [ ] **Step 4: Verify pods, PVCs, site creation**

```bash
kubectl -n frappe get pods
kubectl -n frappe get pvc
kubectl -n frappe logs -l job-name --tail=40 | tail -40
```
Expected: mariadb-sts + valkey + nginx/gunicorn/workers Running; PVCs `erpnext-loopnetworks-worker` (RWX cephfs), `erpnext-loopnetworks-mariadb-sts` (ceph-block), `erpnext-loopnetworks-backups` Bound; create-site job Completed with erpnext + helpdesk + telephony installed.

- [ ] **Step 5: Verify the startupProbe patch applied**

```bash
kubectl -n frappe get statefulset erpnext-loopnetworks-mariadb-sts -o jsonpath='{.spec.template.spec.containers[0].startupProbe}'; echo
```
Expected: shows the `tcpSocket:3306 failureThreshold:60` startupProbe.

- [ ] **Step 6: Verify ingress end-to-end** (domain from shell env, not committed)

```bash
export SECRET_DOMAIN_2=<prod-domain>
curl -sSI "https://erp.$SECRET_DOMAIN_2" | head -1
curl -sSI "https://helpdesk.$SECRET_DOMAIN_2" | head -1
curl -sSI "https://helpdesk.$SECRET_DOMAIN_2/helpdesk" | head -1
```
Expected: `erp.` → 200/302 (ERPNext); `helpdesk.` → 302 to `/helpdesk`; `/helpdesk` → 200 (Helpdesk portal). If 503, check `kubectl get gateway -n kube-system external-prod` attachedRoutes and restart `cilium-operator` per CLAUDE.md.

---

## Phase D — (Deferred) Runbook: add tenant 2 on a new domain

> **Do not execute now.** Tenant 2 (`erp.${SECRET_DOMAIN_3}`) is on a different domain with no infra yet.

**Prerequisites (infra) before an overlay is possible:**
1. Add `SECRET_DOMAIN_3` (the tenant-2 domain) to `cluster-secrets` (SOPS).
2. Add an `https` listener + TLS cert for `*.${SECRET_DOMAIN_3}` on a prod gateway (or a new gateway), mirroring `external-prod`.
3. Create a Cloudflare tunnel + wildcard DNS for `*.${SECRET_DOMAIN_3}`.

**Then, to onboard tenant 2 (slug e.g. `mtlnog`):**
1. Create `kubernetes/apps/frappe/tenants/mtlnog/kustomization.yaml` referencing `../../tenant-base`, **plus a kustomize patch** that overrides the two domain references (they default to `${SECRET_DOMAIN_2}` in the base): `nginx.envVars` `FRAPPE_SITE_NAME_HEADER`, `jobs.createSite.siteName`, the CronJob `SITE`, and the two HTTPRoute `hostnames` → use `${SECRET_DOMAIN_3}`.
2. Create `kubernetes/apps/frappe/tenants/mtlnog/ks.yaml` (copy of tenant 1's, every `loopnetworks` → `mtlnog`, `APP: erpnext-mtlnog-backups`).
3. Add `./tenants/mtlnog/ks.yaml` to `kubernetes/apps/frappe/kustomization.yaml`.
4. Create 1Password item `erpnext-mtlnog` (`MARIADB_ROOT_PASSWORD`, `ADMIN_PASSWORD`).
5. Validate, commit, push, verify (mirror Tasks 9–11). Confirm the fully-isolated second stack (own `erpnext-mtlnog-mariadb-sts`) does not disturb tenant 1.

> Consider generalizing the base to a `${TENANT_DOMAIN_KEY}`-driven pattern only once a second domain is real; premature generalization risks nested-substitution bugs (Flux is single-pass).

---

## Phase E — Backup verification (tenant 1)

### Task 12: Verify per-tenant backups reach VolSync/NFS

- [ ] **Step 1: Trigger the backup CronJob manually**

```bash
kubectl -n frappe create job erpnext-loopnetworks-backup-manual --from=cronjob/erpnext-loopnetworks-backup
kubectl -n frappe wait --for=condition=complete job/erpnext-loopnetworks-backup-manual --timeout=600s
kubectl -n frappe logs job/erpnext-loopnetworks-backup-manual --tail=20
```
Expected: `bench backup` succeeds; dump + files copied to `/backups`.

- [ ] **Step 2: Trigger a VolSync sync and confirm a snapshot**

```bash
kubectl -n frappe annotate replicationsource erpnext-loopnetworks-backups \
  volsync.backube/trigger-sync="$(date -Iseconds)" --overwrite
kubectl -n frappe get replicationsource erpnext-loopnetworks-backups \
  -o custom-columns="NAME:.metadata.name,LAST_SYNC:.status.lastSyncTime"
```
Expected: `lastSyncTime` updates; a snapshot exists in the restic repo `/repository/erpnext-loopnetworks-backups`.

- [ ] **Step 3: Clean up**

```bash
kubectl -n frappe delete job erpnext-loopnetworks-backup-manual
```

---

## Follow-ups (out of scope for this plan)

- Gatus monitoring per tenant (the `components/gatus/public` component hardcodes `${SECRET_DOMAIN}`, not `${SECRET_DOMAIN_2}`; needs a custom endpoint with the full host).
- Renovate config for `ghcr.io/<OWNER>/erpnext-helpdesk` tag + chart `8.0.71`.
- Automated restore runbook (currently manual `bench restore`).
- `imagePullSecrets` wiring if the GHCR image stays private.
```
