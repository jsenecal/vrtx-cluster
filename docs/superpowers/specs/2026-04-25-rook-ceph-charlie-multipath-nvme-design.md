# Rook-Ceph: Multipath + NVMe WAL/DB Migration for vrtx-charlie

**Date:** 2026-04-25
**Scope:** `kubernetes/apps/rook-ceph/rook-ceph/`
**Cluster:** vrtx-cluster (3 ceph nodes: alpha, bravo, charlie)

## Background

The `vrtx-charlie` node currently runs its two Rook-Ceph OSDs on top of an LVM workaround (`/dev/ceph-osd-0/osd-data`, `/dev/ceph-osd-1/osd-data`) layered over multipath devices. This workaround was required because Rook ≤ v1.19.1 mishandled multipath devices when a `metadataDevice` was also configured: device discovery used kernel names (`/dev/dm-*`) rather than the mapper path, causing `ceph-volume lvm batch` to report "All data devices are unavailable." See [rook/rook#17057](https://github.com/rook/rook/issues/17057). PR [#17083](https://github.com/rook/rook/pull/17083) fixed it and was backported to release-1.19, shipping in **v1.19.2**.

Because the workaround used logical volumes, charlie also could not benefit from BlueStore WAL+DB on its Intel Optane NVMe — Rook does not support `metadataDevice` together with an LV-backed data device. Alpha and bravo, which see the same shared SAS disks via a single PCI path (no `multipathd`), were already configured with NVMe WAL/DB.

This spec covers two ordered changes:
1. Bump rook-ceph from `v1.19.1` to `v1.19.4` (current latest in the 1.19 line).
2. Reconfigure charlie's two OSDs onto direct multipath devices (`/dev/disk/by-id/dm-uuid-mpath-…`) with the Optane as `metadataDevice`.

Alpha and bravo are intentionally **out of scope** for this change; they will receive an analogous multipath migration in a follow-up after charlie is verified healthy.

## Hardware Inventory (verified via `talosctl get disks` and `talosctl ls /dev/disk/by-id/`)

| Node | OSD IDs | Data disks (current) | Data disks (target) | NVMe (Optane 480 GB) |
|---|---|---|---|---|
| vrtx-alpha (.201) | osd.4, osd.5 | `/dev/disk/by-path/pci-0000:09:00.0-scsi-0:2:4:0`, `…0:2:5:0` | unchanged | `nvme-INTEL_SSDPED1D480GAH_PHMB8332004S480JGN` |
| vrtx-bravo (.202) | osd.2, osd.3 | `/dev/disk/by-path/pci-0000:09:00.0-scsi-0:2:2:0`, `…0:2:3:0` | unchanged | `nvme-INTEL_SSDPED1D480GAH_PHMB833200KJ480JGN` |
| vrtx-charlie (.203) | osd.0, osd.1 | `/dev/ceph-osd-0/osd-data`, `/dev/ceph-osd-1/osd-data` (LV on mpathb/c) | `/dev/disk/by-id/dm-uuid-mpath-36c81f660f27c950030de385aaa882919`, `…36c81f660f27c950030de38bcb053e01c` | `nvme-INTEL_SSDPED1D480GAH_PHMB830200CB480JGN` (currently unused by ceph) |

Each shared HDD is ~4.8 TB. Pool replica size is 3 across hosts, so charlie holds one full replica (~250 GiB of objects today, capacity 8.7 TiB raw per host).

## Identifier Choice

For charlie's data devices, the spec uses `/dev/disk/by-id/dm-uuid-mpath-3<wwid>`. Rationale:

- `wwn-0x<wwid>` and `scsi-3<wwid>` symlinks resolve to one of the **underlying SCSI paths** (sdc / sde, or sdd / sdf), bypassing `multipathd`. With multipath active, writing through an underlying path can corrupt the dm device.
- `dm-name-mpathb` / `mpathc` are the same dm device but their letter assignment is derived from `multipath.conf` ordering and is less guaranteed to be stable across configuration changes than the WWID-based dm-uuid symlink.
- `dm-uuid-mpath-3<wwid>` embeds the same NAA WWN (`6c81f660…`) that the `wwn-0x` symlink uses; the leading `3` is the NAA type prefix that multipath prepends to form its WWID. It is the most stable mapper-side identifier.

For the NVMe metadata device, charlie uses `/dev/disk/by-id/nvme-INTEL_SSDPED1D480GAH_PHMB830200CB480JGN` (no `_1` namespace suffix), matching the convention already used for alpha and bravo at `cluster/helmrelease.yaml:83` and `:91`.

## Change 1 — Bump rook-ceph to v1.19.4

Files:
- `kubernetes/apps/rook-ceph/rook-ceph/app/helmrelease.yaml` line 13
- `kubernetes/apps/rook-ceph/rook-ceph/cluster/helmrelease.yaml` line 13

Both `tag: v1.19.1` → `tag: v1.19.4`.

This is a pure operator/cluster chart upgrade. No OSD-level changes happen because the existing charlie config still references `/dev/ceph-osd-X/osd-data`; the new code keeps using those LVs as-is until Change 2.

**Verification gate before proceeding to Change 2:**
- `flux get kustomizations -n rook-ceph` shows both kustomizations Ready
- All `rook-ceph-operator`, `rook-ceph-mon-*`, `rook-ceph-mgr-*`, `rook-ceph-osd-*`, and `csi-*` pods restart cleanly
- `ceph status` reports HEALTH_OK
- `ceph versions` shows the new daemon image where applicable

## Change 2 — Charlie storage reconfigure

### 2a. HelmRelease edit

Replace `cluster/helmrelease.yaml` lines 95–100 (the `vrtx-charlie` block including its workaround comment) with:

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

The "Using LVM on multipath devices…" comment on the existing lines 96–97 is removed (no longer relevant). The single-line comment above the `nodes:` block at line 77 covers all three hosts after this change.

This commit is **not pushed until step 2c (push)**. The operator must be scaled to zero and charlie's OSDs purged first, otherwise Rook will see the change while old OSDs still own the disks and refuse to act.

### 2b. Cluster-side preparation

All commands assume `kubectl` context is the vrtx cluster and the toolbox is deployed (`rook-ceph-tools` deployment).

**1. Mark charlie's OSDs out (toolbox):**
```bash
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd out osd.0 osd.1
```
Note on backfill: with `size: 3`, only 3 hosts in the cluster, and the default `host`-level failure domain, no backfill onto alpha/bravo is possible — the third replica has nowhere to go. PGs holding charlie's data transition to `active+undersized+degraded` and stay there until new OSDs come up on charlie. `min_size=2` (default) is preserved by alpha + bravo, so reads and writes continue.

**2. Confirm expected degraded state, then proceed:**
```bash
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph status
# Expect: HEALTH_WARN with `Degraded data redundancy: ... pgs undersized`,
# 0 objects misplaced (no backfill in progress), 4/6 osds up+in.
```
There is **no** wait-for-clean gate here — the cluster cannot become clean again until charlie's new OSDs are running. The point of `ceph osd out` is to stop directing client IO at the OSDs we're about to purge.

**3. Stop the operator and OSD pods:**
```bash
kubectl -n rook-ceph scale deploy rook-ceph-operator --replicas 0
kubectl -n rook-ceph scale deploy rook-ceph-osd-0 rook-ceph-osd-1 --replicas 0
```

**4. Purge OSDs from the cluster (toolbox):**
```bash
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd purge 0 --yes-i-really-mean-it
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd purge 1 --yes-i-really-mean-it
```

**5. Delete the OSD deployments and any leftover prepare job for charlie:**
```bash
kubectl -n rook-ceph delete deploy rook-ceph-osd-0 rook-ceph-osd-1
kubectl -n rook-ceph delete job -l app=rook-ceph-osd-prepare --field-selector spec.template.spec.nodeName=vrtx-charlie 2>/dev/null || true
```
The leftover-job cleanup is best-effort; when the operator is scaled back up in step 2c it will create a fresh prepare job for charlie regardless.

**6. Wipe charlie's storage** via a one-shot privileged Pod pinned to vrtx-charlie. The pod manifest is created locally (not committed to git) and applied with `kubectl apply -f`. It must:
- Run as `privileged: true`, `hostPID: true`, with the host's `/dev` and `/run/udev` mounted in.
- `nodeName: vrtx-charlie` so it lands on the right host.
- Image: any small Linux image with `lvm2`, `multipath-tools`, `util-linux`, `gdisk` available (e.g. `quay.io/ceph/ceph:v18` already has these; or `debian:stable-slim` with `apt install -y lvm2 multipath-tools gdisk`).
- Run command:
  ```bash
  set -euo pipefail
  lvremove -f /dev/ceph-osd-0/osd-data /dev/ceph-osd-1/osd-data || true
  vgremove -f ceph-osd-0 ceph-osd-1 || true
  pvremove -ff -y /dev/mapper/mpathb /dev/mapper/mpathc || true
  wipefs -af /dev/mapper/mpathb /dev/mapper/mpathc
  sgdisk --zap-all /dev/mapper/mpathb
  sgdisk --zap-all /dev/mapper/mpathc
  # NVMe is currently unused by ceph but be defensive against any leftover signatures
  wipefs -af /dev/disk/by-id/nvme-INTEL_SSDPED1D480GAH_PHMB830200CB480JGN
  sgdisk --zap-all /dev/disk/by-id/nvme-INTEL_SSDPED1D480GAH_PHMB830200CB480JGN
  partprobe || true
  ```
The `|| true` on the LV/VG/PV commands tolerates the case where Rook's purge already cleaned them up (`ceph-volume zap` on purge sometimes does this).

After the pod completes, delete it. Verify on the host:
```bash
talosctl ls -n 192.168.168.203 /dev/mapper/
# Expected: control, mpathb, mpathc (no ceph--osd--*)
talosctl ls -n 192.168.168.203 /dev/disk/by-id/ | grep -E 'mpath|nvme'
# Expected: dm-uuid-mpath-3<wwid> entries present, no LVM-* entries for ceph-osd-*
```

### 2c. Push and reconcile

1. Commit the helmrelease change from 2a and push.
2. Scale the operator back up:
   ```bash
   kubectl -n rook-ceph scale deploy rook-ceph-operator --replicas 1
   ```
3. Flux reconciles within the kustomization interval (or force with `flux reconcile kustomization rook-ceph-cluster -n rook-ceph --with-source`).
4. The operator runs OSD-prepare on charlie, sees the two clean multipath devices, and provisions two new OSDs with WAL+DB on the Optane. New OSD IDs will be the next available (likely `osd.6`, `osd.7` since 0 and 1 are tombstoned).

### 2d. Verification

- `ceph osd tree` — three hosts, two OSDs each, six total.
- `ceph osd metadata <new-id>` for each new OSD — confirm:
  - `bluestore_bdev_dev_node` lists the multipath device
  - `bluefs_db_dev_node` lists the NVMe path
  - `bluefs_dedicated_db: 1`
- `ceph osd df` — both new OSDs report ~4.4 TiB capacity, in line with alpha/bravo OSDs.
- `ceph status` — HEALTH_OK after backfill back onto charlie completes.
- Optionally: from inside an OSD pod, `ceph-volume lvm list` shows the data LV on the multipath PV and the db LV on the NVMe PV.

## Risks and Rollback

| Risk | Likelihood | Mitigation |
|---|---|---|
| Wipe pod fails to remove LVM because dm holders block it | Low | Operator is scaled to 0 and OSD pods deleted before wipe — no holders should remain. `dmsetup ls --tree` from inside the pod reveals stragglers; `dmsetup remove <name>` clears them. |
| New OSDs fail to come up after config push | Low | Cluster keeps serving on alpha+bravo (4 OSDs, 2 replicas of every PG online — degraded but available). Investigate prepare pod logs: `kubectl -n rook-ceph get pod -l app=rook-ceph-osd-prepare -o wide \| grep vrtx-charlie` then `kubectl -n rook-ceph logs <pod>`. |
| WWID changes (e.g. controller firmware update remaps NAA) | Very low | Re-run the talosctl identifier check; update the helmrelease accordingly. WWIDs are derived from device firmware and stable in practice. |
| v1.19.4 introduces a regression unrelated to this change | Low | Released for ~10 days as of this date; search rook issues if anything looks off. Rollback to v1.19.1 is a single revert. |

**Rollback paths:**
- **Before purge (step 4):** revert any helmrelease commits. OSDs remain intact and resume normally.
- **After purge but before successful 2d verification:** revert the helmrelease to the LVM workaround config; recreate the LVs manually on the multipath devices via the same privileged pod pattern (`pvcreate /dev/mapper/mpathb && vgcreate ceph-osd-0 /dev/mapper/mpathb && lvcreate -l 100%FREE -n osd-data ceph-osd-0`, repeat for mpathc/ceph-osd-1); restart operator. Old OSD data is gone — alpha+bravo serve all reads, and the recreated OSDs backfill from them.
- **After verification:** no rollback needed. To undo, repeat steps 1–6 with the prior config.

## Out of Scope (Follow-ups)

- Same migration applied to alpha and bravo (after charlie is verified). Requires enabling `multipathd` via Talos machine config on those nodes first, then a per-node version of steps 2b–2d.
- Any tuning of recovery throttling (`osd_recovery_max_active`, `osd_max_backfills`) — defaults are fine for this scale.
- Any change to pool size, compression, or CRUSH rules.
