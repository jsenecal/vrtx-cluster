# cross-seed Design

**Date:** 2026-09-16
**Namespace:** `media-services`
**Status:** Approved

## Goal

Run cross-seed as a daemon in the cluster so torrents already seeding in the NAS
Transmission instance are matched against tagged Prowlarr indexers and injected
back into Transmission as hardlinked cross-seeds.

## Verified environment

Every fact below was confirmed against the live cluster before the design was fixed.

| Fact | Value | How verified |
|---|---|---|
| Torrent client | Transmission 4.0.6, RPC v17 | `session-get` via RPC from a `media-services` pod |
| Client endpoint | `192.168.168.4:30096`, urlBase `/transmission/` | Sonarr download-client config |
| Client download dir | `/downloads/complete` (incomplete: `/downloads/incomplete`) | `session-get` |
| Torrent count | 3421 total, 3262 seeding | `torrent-get` |
| Torrent layout | `/downloads/complete/{Sonarr,Radarr,Lidarr,movies,games}` | `torrent-get` |
| NAS export (downloads) | `192.168.168.4:/mnt/zpool/shares/downloads`, 84T | `df` inside the Sonarr pod |
| NAS export (media) | `192.168.168.4:/mnt/zpool/shares/media`, 76T | `df` inside the Sonarr pod |
| Sonarr remote path map | `/downloads/` -> `/data/downloads/torrents/` | Sonarr `remotepathmapping` API |
| Prowlarr indexers | 1 IPTorrents, 2 upload.cx (both enabled); no tags defined | Prowlarr `indexer` / `tag/detail` API |
| *arr `AllowedHosts` | `<app>` and `<app>.k8s.<domain>` only | HelmRelease env; FQDN request returns HTTP 400, short name returns 200 |
| cross-seed image | `node` v20.20.2, `curl` at `/usr/bin/curl` | run inside `ghcr.io/cross-seed/cross-seed:6.13.7` |

Derived: Transmission's `/downloads` is the NAS path
`/mnt/zpool/shares/downloads/torrents`.

## Key constraint: downloads and media are separate NFS exports

`downloads` and `media` are distinct exports backed by distinct datasets, so a
hardlink cannot span them. cross-seed selects a linkDir by matching `stat.st_dev`
between the source data and the candidate link directory, which makes this a hard
boundary rather than a preference.

Consequence: searchees are limited to **client torrents only**. All of them live
under `/downloads/complete`, so a single linkDir inside the same export serves
every match. Adding Sonarr/Radarr library files as searchees would require a
second linkDir on the media export *and* a corresponding mount inside Transmission
on the NAS; that is explicitly out of scope.

## Path alignment

cross-seed injects by handing Transmission a `download-dir` path, so cross-seed
must see the filesystem at the same paths Transmission does.

The pod mounts NFS `192.168.168.4:/mnt/zpool/shares/downloads/torrents` at
**`/downloads`**. Pod paths are then byte-identical to Transmission's:

```
NAS   /mnt/zpool/shares/downloads/torrents/complete
pod   /downloads/complete            <- searchee data
xmit  /downloads/complete            <- same string, resolves natively

NAS   /mnt/zpool/shares/downloads/torrents/cross-seed
pod   /downloads/cross-seed          <- linkDir, same export as complete/
```

No remote path mapping and no NAS-side configuration change is required.

`useClientTorrents` reads searchees from Transmission over **RPC**, not from disk.
Transmission's `torrent-get` reports `torrentFile` as
`/config/torrents/<hash>.torrent`, but that on-disk path is only consumed by the
legacy `torrentDir` option. Transmission's config directory is therefore *not*
mounted.

## Components

Standard repo app layout, mirroring `sonarr`/`prowlarr`:

```
kubernetes/apps/media-services/cross-seed/
  ks.yaml
  app/
    externalsecret.yaml
    helmrelease.yaml
    kustomization.yaml
```

Registered in `kubernetes/apps/media-services/kustomization.yaml`.

- **Chart:** app-template `3.7.3` via the shared `chartRef` from `components/common/repos`.
- **Components:** `gatus/internal`, `volsync`.
- **dependsOn:** `rook-ceph-cluster` (rook-ceph), `onepassword-connect` (external-secrets).
- **Workload:** Deployment, image `ghcr.io/cross-seed/cross-seed:6.13.7` (digest-pinned), args `["daemon"]`,
  `CROSS_SEED_PORT: 80`, `TZ: America/Toronto`.
- **Probes:** liveness/readiness on `/api/ping` (unauthenticated).
- **Security:** `runAsNonRoot`, uid/gid/fsGroup 1000, `readOnlyRootFilesystem: true`,
  all capabilities dropped, `emptyDir` at `/tmp`.
- **Storage:** volsync component, 5Gi `/config` PVC, schedule `18 * * * *`
  (minute verified unused; schedules in this repo are staggered one app per minute).
- **Route:** internal gateway, `cross-seed.k8s.${SECRET_DOMAIN}`.
- **Gatus:** `GATUS_PATH: /api/ping`.

## Configuration

`config.js` is rendered by the ExternalSecret and mounted at `/config/config.js`.

| Option | Value | Rationale |
|---|---|---|
| `action` | `inject` | add matches straight to Transmission |
| `linkType` | `hardlink` | linkDir shares the export with the data |
| `linkDirs` | `["/downloads/cross-seed"]` | single export, see constraint above |
| `useClientTorrents` | `true` | RPC searchees, no torrentDir mount |
| `torrentDir` | `null` | explicitly unused in v6 |
| `torrentClients` | `transmission:http://<user>:<pass>@192.168.168.4:30096/transmission/rpc` | credentials injected from 1Password |
| `sonarr` / `radarr` | in-cluster service URLs with API keys | metadata lookup only (TVDB/IMDb id resolution to improve match quality); does **not** add media-export searchees |
| `torznab` | Prowlarr indexers tagged `cross-seed` | opt-in controlled from the Prowlarr UI, no redeploy |
| `matchMode` | `partial` | tolerate incomplete season packs |
| `skipRecheck` | `true` | trust the hardlinked data |
| `searchCadence` | unset | see cadence decision |
| `rssCadence` | `30 minutes` | cheap, catches new uploads |
| `excludeOlder` | `2 weeks` | bounds any manually triggered search |
| `excludeRecentSearch` | `3 days` | avoids re-querying the same searchee |

### *arr URLs must use short service names

Sonarr, Radarr, and Prowlarr all set `ALLOWEDHOSTS` to `<app>.k8s.<domain>,<app>`.
A request whose `Host` header is the in-cluster FQDN
(`prowlarr.media-services.svc.cluster.local`) is rejected with **HTTP 400**;
the short name `prowlarr` returns 200. This was confirmed by direct request.

cross-seed therefore addresses the *arr services as `http://sonarr`,
`http://radarr`, and `http://prowlarr`, which resolve because cross-seed runs in
the same namespace. The onedr0p reference configuration uses FQDNs and would fail
here, because that cluster does not set `AllowedHosts`.

### Indexer discovery

`config.js` queries the Prowlarr API at render time for indexers carrying the
`cross-seed` tag, following the onedr0p pattern. Because this manifest path is
subject to Flux `postBuild` substitution, every JavaScript template literal must
escape its `$` as `$$` or Flux will consume it.

The `cross-seed` tag does not exist yet; it is created and applied to indexers 1
and 2 as part of this work. Without the tag cross-seed starts with zero indexers.

### Search cadence

With 3262 seeding torrents and only two indexers, an automatic full search pass is
the dominant operational risk: at cross-seed's default 30s inter-search delay a
single pass runs well over a day of continuous querying, which IPTorrents may treat
as abuse.

The daemon therefore ships with `searchCadence` unset, so it performs no periodic
mass search. It responds to RSS and to injection on completion. A deliberate
backfill can be started later with `POST /api/job?name=search` once the deployment
has been observed behaving.

## Secrets

All items live in the `Automation` vault, which already holds the *arr items and
`volsync-template`.

Only one new item is created, `cross-seed`, holding a single generated field:

| Field | Used for |
|---|---|
| `CROSS_SEED_API_KEY` | cross-seed's own API auth |

The Transmission credentials are **not** duplicated. A `transmission` item already
exists in the same vault carrying `TRANSMISSION_USERNAME`, `TRANSMISSION_PASSWORD`
and `TRANSMISSION_URL`, so the ExternalSecret extracts it directly. This keeps one
source of truth: rotating the Transmission password in 1Password updates both the
*arr download clients and cross-seed, with no second copy to drift.

`config.js` assembles the RPC endpoint from `TRANSMISSION_URL` rather than
hardcoding the host, normalising the trailing slash and using the `URL` username
and password setters so credentials are percent-encoded correctly.

The ExternalSecret also extracts the existing `prowlarr`, `radarr`, and `sonarr`
items for their API keys. Field names were confirmed from the existing
ExternalSecrets: `PROWLARR_API_KEY`, `RADARR_API_KEY`, `SONARR_API_KEY`.

No credential is committed to the repository.

## Failure modes

| Symptom | Likely cause |
|---|---|
| Pod CrashLoop on start | 1Password `cross-seed` item missing or incomplete; ExternalSecret has not synced |
| Log shows `Loaded 0 indexers from Prowlarr` | `cross-seed` tag missing or not applied to any indexer |
| `fetchIndexers` throws at startup | Prowlarr unreachable from the pod |
| `fetchIndexers` throws with an HTTP 400 body | an *arr URL was written as an FQDN instead of a short service name |
| Injection fails with an unresolvable path | `/downloads` mount does not line up with Transmission's `download-dir` |
| Hardlink fails, falls back or errors | link target resolved onto a different export |

## Pre-deployment verification performed

- `config.js` rendered through a simulation of Flux `postBuild` substitution;
  no unescaped `${...}` remained and no variable went unsubstituted.
- The rendered config passed `node --check` **inside the cross-seed image itself**.
- `fetchIndexers` was executed in that image against the live Prowlarr service and
  returned `Loaded 2 indexers from Prowlarr`.
- `kustomize build` succeeded for both the app directory and the namespace.
- `kubeconform -strict` validated all three resources.

## Out of scope

- Sonarr/Radarr library files as searchees (blocked by the export boundary).
- Reviving the disabled qBittorrent download client.
- An automatic full-library backfill pass.
