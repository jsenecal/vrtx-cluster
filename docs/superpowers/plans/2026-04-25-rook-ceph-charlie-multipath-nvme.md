# Rook-Ceph: Multipath + NVMe WAL/DB Migration for vrtx-charlie

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move vrtx-charlie's two Rook-Ceph OSDs off the LVM-on-multipath workaround and onto direct multipath devices with the Intel Optane NVMe as BlueStore WAL+DB, after upgrading rook-ceph from v1.19.1 to v1.19.4 (the multipath fix landed in v1.19.2).

**Architecture:** Two phases gated on cluster health. Phase 1 is a chart version bump only (no OSD churn). Phase 2 drains and purges charlie's two existing OSDs, wipes the multipath block devices, then pushes a HelmRelease change so the operator re-prepares OSDs on the same physical hardware with the new layout. Cluster stays available throughout because alpha+bravo retain 2/3 replicas of every PG.

**Tech Stack:** Rook v1.19.4 chart, Ceph v18 (Reef), Flux v2 (Kustomize+HelmRelease), Talos Linux (no host shell — privileged k8s Pod for disk wiping), `kubectl` + `talosctl` + `ceph` toolbox for cluster operations.

**Spec:** [docs/superpowers/specs/2026-04-25-rook-ceph-charlie-multipath-nvme-design.md](../specs/2026-04-25-rook-ceph-charlie-multipath-nvme-design.md)

---

## File Map

**Modified files (committed to git):**
- `kubernetes/apps/rook-ceph/rook-ceph/app/helmrelease.yaml` — operator chart tag bump (Phase 1)
- `kubernetes/apps/rook-ceph/rook-ceph/cluster/helmrelease.yaml` — cluster chart tag bump (Phase 1) + charlie storage block (Phase 2)

**Local-only files (not committed):**
- `/tmp/charlie-wipe-pod.yaml` — one-shot privileged Pod manifest used only for the wipe step

**No new directories or test files** — this is an infrastructure migration, not application code. "Verification" steps act as the test gates.

---

# Phase 1 — Chart upgrade

### Task 1: Bump rook-ceph operator and cluster charts to v1.19.4

**Files:**
- Modify: `kubernetes/apps/rook-ceph/rook-ceph/app/helmrelease.yaml:13`
- Modify: `kubernetes/apps/rook-ceph/rook-ceph/cluster/helmrelease.yaml:13`

- [ ] **Step 1: Confirm current cluster is HEALTH_OK before changing anything**

Run:
```bash
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph status
```

Expected: `health: HEALTH_OK`, `6 osds: 6 up, 6 in`, `pgs: NN active+clean` (no degraded or backfilling state). If the cluster is not HEALTH_OK, stop and investigate before proceeding.

- [ ] **Step 2: Edit the operator chart tag**

In `kubernetes/apps/rook-ceph/rook-ceph/app/helmrelease.yaml`, change line 13:
```yaml
    tag: v1.19.1
```
to:
```yaml
    tag: v1.19.4
```

- [ ] **Step 3: Edit the cluster chart tag**

In `kubernetes/apps/rook-ceph/rook-ceph/cluster/helmrelease.yaml`, change line 13:
```yaml
    tag: v1.19.1
```
to:
```yaml
    tag: v1.19.4
```

- [ ] **Step 4: Commit and push**

Run:
```bash
git add kubernetes/apps/rook-ceph/rook-ceph/app/helmrelease.yaml kubernetes/apps/rook-ceph/rook-ceph/cluster/helmrelease.yaml
git commit -m "feat(rook-ceph): bump chart from v1.19.1 to v1.19.4

Brings in PR #17083 (multipath fix) backported in v1.19.2."
git push
```

- [ ] **Step 5: Force Flux reconciliation (optional, the webhook usually triggers within seconds)**

Run:
```bash
flux reconcile source git -n flux-system flux-system
flux reconcile source oci -n rook-ceph rook-ceph
flux reconcile source oci -n rook-ceph rook-ceph-cluster
flux reconcile kustomization -n rook-ceph rook-ceph
flux reconcile kustomization -n rook-ceph rook-ceph-cluster
```

Expected: each command returns within a few seconds with `... reconciliation finished`. Note the OCIRepositories live in the `rook-ceph` namespace (not `flux-system`); the GitRepository is in `flux-system`.

- [ ] **Step 6: Verify both kustomizations are Ready**

Run:
```bash
flux get kustomizations -n rook-ceph
```

Expected: both `rook-ceph` and `rook-ceph-cluster` show `READY: True` and a recent `LAST APPLIED REVISION`.

- [ ] **Step 7: Verify operator restarted on the new image**

Run:
```bash
kubectl -n rook-ceph get deploy rook-ceph-operator -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
kubectl -n rook-ceph rollout status deploy/rook-ceph-operator --timeout=5m
```

Expected: image string contains `v1.19.4`; rollout reports `successfully rolled out`.

- [ ] **Step 8: Verify cluster is HEALTH_OK after the upgrade**

Run:
```bash
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph status
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph versions
```

Expected: `health: HEALTH_OK`; `ceph versions` shows mon/mgr/osd daemons all on the same version (chart-bundled Ceph image). Wait until `ceph status` is fully clean before proceeding to Phase 2 — there should be no rolling restarts in flight.

- [ ] **Step 9: Sanity-check the OSD layout is unchanged**

Run:
```bash
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd tree
```

Expected: same six OSDs as before, same hosts, all `up` and `1.00000` reweight. If anything moved, stop and investigate.

---

# Phase 2 — Charlie storage migration

### Task 2: Mark charlie's OSDs out

**Files:** none (live cluster operation only)

- [ ] **Step 1: Note the OSD IDs to drain**

The two OSDs on `vrtx-charlie` are `osd.0` and `osd.1`. Confirm:
```bash
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd tree | grep -A2 vrtx-charlie
```

Expected: lines listing `osd.0` and `osd.1` under host `vrtx-charlie`. If the IDs differ, use the IDs you observe in every subsequent step.

- [ ] **Step 2: Mark them out**

Run:
```bash
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd out osd.0 osd.1
```

Expected: `marked out osd.0. marked out osd.1.`

- [ ] **Step 3: Confirm the cluster is in the expected degraded state**

Run:
```bash
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph status
```

Expected: `health: HEALTH_WARN` with messages like `Degraded data redundancy: ... pgs undersized`, plus `osd: 6 osds: 6 up (...), 4 in`. **No** `backfill_wait`, `backfilling`, or `recovery` activity should appear — the third replica has nowhere to go (only 3 hosts, host failure domain), so PGs go undersized rather than backfilling. `min_size: 2` is still met by alpha+bravo, so client IO continues.

If you see active backfill, stop and investigate — the failure domain may have been changed.

---

### Task 3: Stop the operator and charlie's OSD pods

**Files:** none.

- [ ] **Step 1: Scale the operator to zero**

Run:
```bash
kubectl -n rook-ceph scale deploy rook-ceph-operator --replicas=0
kubectl -n rook-ceph rollout status deploy/rook-ceph-operator --timeout=2m
```

Expected: `deployment.apps/rook-ceph-operator scaled` and `... successfully rolled out` (with 0/0 replicas).

- [ ] **Step 2: Scale charlie's OSD deployments to zero**

Run:
```bash
kubectl -n rook-ceph scale deploy rook-ceph-osd-0 rook-ceph-osd-1 --replicas=0
kubectl -n rook-ceph wait --for=delete pod -l ceph-osd-id=0 --timeout=2m
kubectl -n rook-ceph wait --for=delete pod -l ceph-osd-id=1 --timeout=2m
```

Expected: deployments scale to 0; pods terminate within ~30s. The `wait --for=delete` returns success either when the pod is gone or immediately if it never existed.

- [ ] **Step 3: Verify no charlie OSD pod is running**

Run:
```bash
kubectl -n rook-ceph get pod -o wide | grep vrtx-charlie | grep -E 'osd|prepare' || echo "no charlie osd/prepare pods"
```

Expected: prints `no charlie osd/prepare pods`. If a pod is still present and Running, wait for termination before proceeding.

---

### Task 4: Purge OSDs 0 and 1 from the cluster

**Files:** none.

- [ ] **Step 1: Purge osd.0**

Run:
```bash
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd purge 0 --yes-i-really-mean-it
```

Expected: `purged osd.0`.

- [ ] **Step 2: Purge osd.1**

Run:
```bash
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd purge 1 --yes-i-really-mean-it
```

Expected: `purged osd.1`.

- [ ] **Step 3: Verify they are gone from `osd tree`**

Run:
```bash
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd tree
```

Expected: only 4 OSDs listed (`osd.2`/`osd.3` on bravo, `osd.4`/`osd.5` on alpha). The `vrtx-charlie` host entry may still appear with weight 0 — that is fine; it will get a new entry when new OSDs come up.

---

### Task 5: Delete charlie's OSD deployments and any leftover prepare jobs

**Files:** none.

- [ ] **Step 1: Delete the OSD deployments**

Run:
```bash
kubectl -n rook-ceph delete deploy rook-ceph-osd-0 rook-ceph-osd-1
```

Expected: `deployment.apps "rook-ceph-osd-0" deleted` and `deployment.apps "rook-ceph-osd-1" deleted`.

- [ ] **Step 2: Delete any leftover OSD prepare jobs/pods on charlie (best-effort)**

Run:
```bash
kubectl -n rook-ceph get job -o json | jq -r '.items[] | select(.spec.template.spec.nodeName=="vrtx-charlie" and (.metadata.labels.app=="rook-ceph-osd-prepare")) | .metadata.name' | xargs -r -n1 kubectl -n rook-ceph delete job
kubectl -n rook-ceph get pod -o wide | awk '/vrtx-charlie/ && /prepare/ {print $1}' | xargs -r -n1 kubectl -n rook-ceph delete pod
```

Expected: either deletes any matching jobs/pods, or does nothing if none exist (the `xargs -r` is a no-op on empty input). Both outcomes are fine.

---

### Task 6: Wipe charlie's block devices via a privileged Pod

**Files:**
- Create (local, do not commit): `/tmp/charlie-wipe-pod.yaml`

- [ ] **Step 1: Write the wipe Pod manifest to a local file**

Create `/tmp/charlie-wipe-pod.yaml` with this content:
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: charlie-wipe
  namespace: rook-ceph
spec:
  restartPolicy: Never
  nodeName: vrtx-charlie
  hostPID: true
  hostNetwork: true
  containers:
    - name: wipe
      image: quay.io/ceph/ceph:v18
      securityContext:
        privileged: true
      command:
        - /bin/bash
        - -c
        - |
          set -euo pipefail
          echo "== before =="
          dmsetup ls --tree || true
          ls -l /dev/mapper/ /dev/disk/by-id/ | grep -E 'mpath|nvme|ceph-osd' || true
          echo "== removing LVs =="
          lvremove -f /dev/ceph-osd-0/osd-data /dev/ceph-osd-1/osd-data || true
          vgremove -f ceph-osd-0 ceph-osd-1 || true
          pvremove -ff -y /dev/mapper/mpathb /dev/mapper/mpathc || true
          echo "== wiping mpath devices =="
          wipefs -af /dev/mapper/mpathb /dev/mapper/mpathc
          sgdisk --zap-all /dev/mapper/mpathb
          sgdisk --zap-all /dev/mapper/mpathc
          echo "== wiping NVMe =="
          wipefs -af /dev/disk/by-id/nvme-INTEL_SSDPED1D480GAH_PHMB830200CB480JGN
          sgdisk --zap-all /dev/disk/by-id/nvme-INTEL_SSDPED1D480GAH_PHMB830200CB480JGN
          partprobe || true
          echo "== after =="
          dmsetup ls --tree || true
          ls -l /dev/mapper/ | grep -E 'mpath|ceph-osd' || true
          echo "== done =="
      volumeMounts:
        - { name: dev, mountPath: /dev }
        - { name: udev, mountPath: /run/udev }
        - { name: lvm, mountPath: /run/lvm }
  volumes:
    - { name: dev, hostPath: { path: /dev } }
    - { name: udev, hostPath: { path: /run/udev } }
    - { name: lvm, hostPath: { path: /run/lvm } }
  tolerations:
    - operator: Exists
```

- [ ] **Step 2: Apply the Pod**

Run:
```bash
kubectl apply -f /tmp/charlie-wipe-pod.yaml
kubectl -n rook-ceph wait --for=condition=Ready pod/charlie-wipe --timeout=2m
```

Expected: `pod/charlie-wipe created` then `pod/charlie-wipe condition met`.

- [ ] **Step 3: Watch the wipe complete**

Run:
```bash
kubectl -n rook-ceph logs -f pod/charlie-wipe
```

Expected: log shows `== before ==`, `== removing LVs ==`, `== wiping mpath devices ==`, `== wiping NVMe ==`, `== after ==`, `== done ==`. Some `lvremove`/`vgremove`/`pvremove` commands may print warnings if the LVs were already cleaned by `ceph osd purge` — that is expected (the `|| true` catches the failure). The `wipefs` and `sgdisk` commands should succeed cleanly.

After `== done ==`, the pod transitions to `Completed`.

- [ ] **Step 4: Confirm the Pod completed successfully**

Run:
```bash
kubectl -n rook-ceph get pod charlie-wipe
```

Expected: `STATUS: Completed`, `RESTARTS: 0`. If it shows `Error`, read the logs and resolve before proceeding.

- [ ] **Step 5: Verify the LVs and VGs are gone from the host**

Run:
```bash
talosctl ls -n 192.168.168.203 /dev/mapper/
```

Expected: only `control`, `mpathb`, `mpathc` (no `ceph--osd--*-osd--data` entries).

Run:
```bash
talosctl ls -n 192.168.168.203 /dev/disk/by-id/ | grep -E 'mpath|nvme|LVM'
```

Expected: `dm-uuid-mpath-3...` entries for both mpath devices, the `nvme-INTEL_SSDPED1D480GAH_PHMB830200CB480JGN` entry, **no** `dm-uuid-LVM-...` entries for `ceph-osd-0` or `ceph-osd-1`.

- [ ] **Step 6: Delete the wipe Pod**

Run:
```bash
kubectl -n rook-ceph delete pod charlie-wipe
rm /tmp/charlie-wipe-pod.yaml
```

Expected: `pod "charlie-wipe" deleted`. The local file is removed because we don't keep it in git.

---

### Task 7: Update the cluster HelmRelease to use multipath devices + NVMe metadata

**Files:**
- Modify: `kubernetes/apps/rook-ceph/rook-ceph/cluster/helmrelease.yaml:95-100`

- [ ] **Step 1: Replace the `vrtx-charlie` storage block**

Current content (lines 95–100):
```yaml
          - name: vrtx-charlie
            # Using LVM on multipath devices - ceph-volume doesn't work with dm-* kernel paths directly
            # Note: LV + metadataDevice not supported by Rook, so NVMe WAL/DB not available for charlie
            devices:
              - name: /dev/ceph-osd-0/osd-data
              - name: /dev/ceph-osd-1/osd-data
```

Replace with:
```yaml
          - name: vrtx-charlie
            devices:
              - name: /dev/disk/by-id/dm-uuid-mpath-36c81f660f27c950030de385aaa882919
                config:
                  metadataDevice: /dev/disk/by-id/nvme-INTEL_SSDPED1D480GAH_PHMB830200CB480JGN
              - name: /dev/disk/by-id/dm-uuid-mpath-36c81f660f27c950030de38bcb053e01c
                config:
                  metadataDevice: /dev/disk/by-id/nvme-INTEL_SSDPED1D480GAH_PHMB830200CB480JGN
```

- [ ] **Step 2: Update the comment above the `nodes:` block (optional cleanup)**

The existing comment at line 77 reads:
```yaml
        # Using by-path identifiers (avoids multipath duplication) with NVMe WAL/DB acceleration
```

Update it to reflect that charlie now uses multipath:
```yaml
        # Using by-path identifiers on alpha/bravo and multipath dm-uuid on charlie, with NVMe WAL/DB on all nodes
```

- [ ] **Step 3: Commit and push**

Run:
```bash
git add kubernetes/apps/rook-ceph/rook-ceph/cluster/helmrelease.yaml
git commit -m "feat(rook-ceph): move charlie OSDs to multipath devices with NVMe WAL/DB

Now that v1.19.2+ supports multipath devices alongside metadataDevice
(rook/rook#17083), drop the LVM workaround and put BlueStore WAL+DB
on the Intel Optane like alpha and bravo."
git push
```

---

### Task 8: Reconcile and bring the operator back

**Files:** none.

- [ ] **Step 1: Force Flux to reconcile the cluster HelmRelease (optional, webhook usually does it)**

Run:
```bash
flux reconcile source git -n flux-system flux-system
flux reconcile source oci -n rook-ceph rook-ceph-cluster
flux reconcile kustomization -n rook-ceph rook-ceph-cluster
```

Expected: each reports `... reconciliation finished`.

- [ ] **Step 2: Verify the CephCluster CR reflects the new charlie spec before scaling the operator up**

Run:
```bash
kubectl -n rook-ceph get cephcluster rook-ceph -o yaml | yq '.spec.storage.nodes[] | select(.name=="vrtx-charlie")'
```

Expected output:
```yaml
name: vrtx-charlie
devices:
  - name: /dev/disk/by-id/dm-uuid-mpath-36c81f660f27c950030de385aaa882919
    config:
      metadataDevice: /dev/disk/by-id/nvme-INTEL_SSDPED1D480GAH_PHMB830200CB480JGN
  - name: /dev/disk/by-id/dm-uuid-mpath-36c81f660f27c950030de38bcb053e01c
    config:
      metadataDevice: /dev/disk/by-id/nvme-INTEL_SSDPED1D480GAH_PHMB830200CB480JGN
```

If `yq` is not available locally, omit the filter and grep for `vrtx-charlie` in the full YAML. **Do not proceed until the CR shows the new device paths** — scaling the operator up against the old spec would re-prepare OSDs with the wrong device paths.

- [ ] **Step 3: Scale the operator back to 1**

Run:
```bash
kubectl -n rook-ceph scale deploy rook-ceph-operator --replicas=1
kubectl -n rook-ceph rollout status deploy/rook-ceph-operator --timeout=3m
```

Expected: operator pod becomes `Running` and `Ready`.

---

### Task 9: Wait for new OSDs on charlie and verify NVMe WAL/DB

**Files:** none.

- [ ] **Step 1: Watch the OSD prepare job for charlie**

Run:
```bash
kubectl -n rook-ceph get pod -o wide -w | grep -E 'osd-prepare|osd-[0-9]+'
```

Expected: within 1–2 minutes, an `rook-ceph-osd-prepare-vrtx-charlie-...` pod appears, runs to `Completed`. Press Ctrl-C once you see it finish, or use a one-shot wait:

```bash
kubectl -n rook-ceph wait --for=condition=Complete \
  job -l app=rook-ceph-osd-prepare \
  --field-selector spec.template.spec.nodeName=vrtx-charlie \
  --timeout=10m
```

Expected: `condition met`. If the prepare job fails, dump its logs:
```bash
kubectl -n rook-ceph logs -l app=rook-ceph-osd-prepare --tail=200 | grep -A3 -B1 -i 'error\|fail'
```

- [ ] **Step 2: Confirm two new OSD deployments appear**

Run:
```bash
kubectl -n rook-ceph get deploy | grep rook-ceph-osd-
```

Expected: four pre-existing deployments (`rook-ceph-osd-2/3/4/5`) plus two new ones (likely `rook-ceph-osd-6` and `rook-ceph-osd-7`, since 0/1 are tombstoned). Both new deployments should reach `1/1` Ready within a couple of minutes.

- [ ] **Step 3: Confirm the new OSDs joined the cluster**

Run:
```bash
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd tree
```

Expected: 6 OSDs total, two new ones listed under `vrtx-charlie`, all `up` and `in` with reweight `1.00000`.

- [ ] **Step 4: Verify NVMe WAL/DB is in use on each new OSD**

For each new OSD ID (substitute `<NEW_ID>`):
```bash
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- \
  ceph osd metadata <NEW_ID> | grep -E 'bluefs|bluestore_bdev_dev_node|hostname'
```

Expected fields:
- `"hostname": "vrtx-charlie"`
- `"bluestore_bdev_dev_node"`: contains the multipath device (e.g. `/dev/dm-...` or a mapper path)
- `"bluefs_dedicated_db": "1"`
- `"bluefs_db_dev_node"`: contains an NVMe-related path (resolves to the Optane)

If `bluefs_dedicated_db` is `0`, the metadataDevice was not honored — investigate the prepare logs.

- [ ] **Step 5: Confirm OSD capacity is full-disk**

Run:
```bash
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd df tree
```

Expected: each new OSD reports ~4.4 TiB (4400000 MB range), comparable to alpha/bravo OSDs. If significantly smaller, the LVs were created on a partition rather than the full multipath device — investigate.

---

### Task 10: Wait for backfill to charlie and final verification

**Files:** none.

- [ ] **Step 1: Watch backfill progress**

Run:
```bash
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph status
```

Expected: cluster shows `recovery: ... objects/s` and a shrinking `degraded` / `misplaced` count. With ~250 GiB of data and gigabit-class storage networking, expect 30–90 minutes to clean.

To poll, repeat every minute or so until clean.

- [ ] **Step 2: Verify HEALTH_OK and all PGs active+clean**

Run:
```bash
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph status
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph pg ls | tail -5
```

Expected:
- `health: HEALTH_OK`
- `osd: 6 osds: 6 up, 6 in`
- All PGs `active+clean` (no `degraded`, `undersized`, `recovering`, or `backfilling`)
- `0 objects misplaced`

- [ ] **Step 3: Spot-check that the operator did not scale charlie's OSDs back to a different device set**

Run:
```bash
kubectl -n rook-ceph get cephcluster rook-ceph -o yaml | yq '.status.storage.deviceSet // .status' | head -50
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd tree
```

Expected: charlie shows two OSDs with the standard 4.36429 weight, identical to alpha and bravo.

- [ ] **Step 4: Smoke-test client IO**

Pick any RBD-backed app (e.g. an existing PVC) and confirm it can read/write. A quick way:
```bash
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- rados -p ceph-blockpool bench 30 write --no-cleanup -b 4194304 -t 16
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- rados -p ceph-blockpool bench 10 seq -t 16
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- rados -p ceph-blockpool cleanup
```

Expected: writes complete without errors; sustained throughput should be visibly higher than before the migration (NVMe-backed metadata reduces write latency on small ops). No requirement on a specific number — the point is to confirm IO works and the new OSDs are participating.

- [ ] **Step 5: Final sanity check**

Run:
```bash
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph status
flux get kustomizations -n rook-ceph
```

Expected: `HEALTH_OK`, both kustomizations Ready. Migration complete.

---

## Rollback notes (reference, not numbered tasks)

- **Anywhere before Task 6 (wipe):** revert the latest commit(s) on `main` with `git revert`, push, scale the operator back to 1 if it was scaled down. Old OSDs come back with their existing data; nothing has been destroyed yet.
- **Between Task 6 (wipe) and a successful Task 9 (new OSDs up):** the original LV-on-multipath layout can be recreated from inside the same wipe-style Pod:
  ```bash
  pvcreate /dev/mapper/mpathb /dev/mapper/mpathc
  vgcreate ceph-osd-0 /dev/mapper/mpathb
  vgcreate ceph-osd-1 /dev/mapper/mpathc
  lvcreate -l 100%FREE -n osd-data ceph-osd-0
  lvcreate -l 100%FREE -n osd-data ceph-osd-1
  ```
  Then revert the Task 7 commit, push, and bring the operator back. New OSDs will be created fresh and backfill from alpha+bravo (the data on the wiped LVs is gone, but two replicas remain).
- **After successful Task 10:** no rollback needed. To revert deliberately, repeat Tasks 2–9 with the prior LVM config — wasteful but doable.

## Out-of-scope follow-ups

- Apply the same migration recipe to alpha and bravo (after confirming charlie has been stable for a few days). That will require enabling `multipathd` on those nodes via Talos machine config first, then a per-node version of Tasks 2–10.
- Tuning recovery throttles (`osd_max_backfills`, `osd_recovery_max_active`) — defaults are fine at this scale.

---

## Self-Review

**Spec coverage check (every requirement in the spec maps to at least one task):**
- "Bump rook-ceph from v1.19.1 to v1.19.4" → Task 1 ✓
- "Reconfigure charlie's two OSDs onto direct multipath devices with the Optane as metadataDevice" → Tasks 7, 9 ✓
- "Drain charlie's OSDs" → Task 2 ✓
- "Confirm expected degraded state, then proceed" → Task 2 step 3 ✓
- "Stop the operator and OSD pods" → Task 3 ✓
- "Purge OSDs from the cluster" → Task 4 ✓
- "Delete the OSD deployments and any leftover prepare job for charlie" → Task 5 ✓
- "Wipe charlie's storage via a one-shot privileged Pod" → Task 6 ✓
- "Push and reconcile" → Tasks 7, 8 ✓
- "Verification" (osd tree, osd metadata, osd df, ceph status, ceph-volume lvm list) → Tasks 9, 10 ✓
- "Rollback paths" → Rollback notes section ✓
- "Out of scope (alpha/bravo migration)" → Out-of-scope follow-ups section ✓

**Placeholder scan:** No "TBD", "TODO", "implement later", or "similar to Task N" patterns. Every step has explicit commands and expected output.

**Consistency check:**
- Charlie's two OSD IDs referred to as `osd.0` and `osd.1` in Tasks 2, 3, 4, 5, 9 — consistent with the spec and with `ceph osd tree` output captured during brainstorming.
- Multipath WWIDs `…2919` and `…e01c` consistent across spec, plan Tasks 6 and 7.
- NVMe symlink `nvme-INTEL_SSDPED1D480GAH_PHMB830200CB480JGN` (no `_1` suffix) consistent across spec and Tasks 6 and 7.
- Phase 1 commit affects both `app/helmrelease.yaml:13` and `cluster/helmrelease.yaml:13`; Phase 2 commit affects only `cluster/helmrelease.yaml:95-100` (and the line 77 comment) — no double-edits or contradictions.
