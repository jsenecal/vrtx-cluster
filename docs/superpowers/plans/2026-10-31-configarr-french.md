# Configarr + French Profiles Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deploy Configarr as a nightly CronJob that adds an opt-in `French` quality profile (plus the French custom formats it needs) to Sonarr and Radarr without touching anything existing.

**Architecture:** bjw-s app-template HelmRelease with a `cronjob` controller in `media-services`. `config.yml` ships as a ConfigMap (kustomize `configMapGenerator`); API keys come from an ExternalSecret reading the existing `sonarr` / `radarr` 1Password items and are referenced with `!env`. Configarr only manages what `config.yml` names.

**Tech Stack:** Flux, kustomize, bjw-s app-template, External Secrets (1Password), Configarr `1.38.0`, TRaSH Guides French custom formats.

**Spec:** `docs/superpowers/specs/2026-10-31-configarr-french-design.md`

## Global Constraints

- Image: `ghcr.io/raydak-labs/configarr:1.38.0@sha256:36d15adcc815557409a9437bc51468edfd1ac05ef6b46336dff650a56d2cc6a3`
- Sonarr: `http://sonarr.media-services.svc.cluster.local` (port 80), v4.0.14. Radarr: `http://radarr.media-services.svc.cluster.local` (port 80), v6.4.4.
- ClusterSecretStore name `onepassword-connect`; 1Password items `sonarr` (field `SONARR_API_KEY`) and `radarr` (field `RADARR_API_KEY`).
- `delete_unmanaged_custom_formats.enabled: false` and `delete_unmanaged_quality_profiles.enabled: false` on both instances. No `media_naming` key anywhere. `French` is the only entry under `quality_profiles`; every `assign_scores_to` targets only `French`.
- Do not use `renameQualityProfiles` or TRaSH quality-profile templates (`include` with a profile trash_id): the profile is defined directly as `French`.
- 2-space YAML, LF, trailing newline, no trailing whitespace. Validate with `kubeconform`. Commit messages without any Claude/AI attribution. Push to `main`; Flux reconciles.
- Pod security matches the other apps: `runAsNonRoot`, uid/gid/fsGroup 1000, `readOnlyRootFilesystem: true`, drop ALL caps; writable `emptyDir` at `/app/repos` (and `/tmp`).

## Review Focus

1. **Existing profiles altered** — Configarr adding new CFs must leave every existing profile's `formatItems` scores, cutoff, and qualities identical. Pinned by the before/after diff in Task 1 Step 7 and Task 2 Step 6.
2. **Existing CFs touched** — Sonarr's 14 HDR/DV CFs and Radarr's `DV (WEBDL)` must keep id and specifications. Same diff.
3. **Download storm** — after the sync, the Sonarr/Radarr queues must not grow and no "upgrade" grabs appear for titles on existing profiles. Pinned by Task 2 Step 7.
4. **Secret not injected** — a missing/renamed 1Password field makes `!env` resolve empty and Configarr fails auth; the Job must fail loudly (non-zero exit), not report success. Pinned by Task 1 Step 6 log check.
5. **Score ordering** — VOQ > VOF > VFQ > VFF and MULTi (Original + French) above any single-language French release must hold in the computed profile, and VO-only/VOSTFR must be ≤ -10000. Pinned by Task 2 Step 5.

---

### Task 1: Configarr CronJob that connects but manages nothing

**Files:**
- Create: `kubernetes/apps/media-services/configarr/ks.yaml`
- Create: `kubernetes/apps/media-services/configarr/app/kustomization.yaml`
- Create: `kubernetes/apps/media-services/configarr/app/externalsecret.yaml`
- Create: `kubernetes/apps/media-services/configarr/app/helmrelease.yaml`
- Create: `kubernetes/apps/media-services/configarr/app/config.yml`
- Modify: `kubernetes/apps/media-services/kustomization.yaml` (add `- ./configarr/ks.yaml` after `./prowlarr/ks.yaml`)

**Interfaces:**
- Produces: CronJob `configarr` in `media-services`; ConfigMap `configarr-config` (key `config.yml`, mounted at `/app/config/config.yml` via subPath); Secret `configarr-secret` with `SONARR_API_KEY`, `RADARR_API_KEY`; instance blocks `sonarr.main` and `radarr.main` in `config.yml` that Task 2 extends.

- [ ] **Step 1: Snapshot current state to the scratchpad**

For each app, save `GET /api/v3/qualityprofile` and `GET /api/v3/customformat` (API key from `/config/config.xml` inside the pod, `curl localhost:80`) to `$SCRATCH/before-{sonarr,radarr}-{qualityprofile,customformat}.json`, plus queue totals (`/api/v3/queue?pageSize=1 | .totalRecords`).
Expected: 4 JSON files; Sonarr has 7 profiles / 14 CFs, Radarr 6 profiles / 1 CF.

- [ ] **Step 2: Write `ks.yaml`**

Copy the shape of `kubernetes/apps/media-services/sonarr/ks.yaml`: name `&app configarr`, namespace `media-services`, path `./kubernetes/apps/media-services/configarr/app`, no components, `dependsOn` `sonarr` and `radarr` (namespace `media-services`) and `onepassword-connect` (namespace `external-secrets`), `postBuild.substituteFrom` cluster-secrets, `wait: false`.

- [ ] **Step 3: Write `externalsecret.yaml`**

Target `configarr-secret`; template data `SONARR_API_KEY: "{{ .SONARR_API_KEY }}"`, `RADARR_API_KEY: "{{ .RADARR_API_KEY }}"`; `dataFrom` extracts from keys `sonarr` and `radarr`.

- [ ] **Step 4: Write `helmrelease.yaml` and `kustomization.yaml`**

Model on `kubernetes/apps/media-services/plex/tools/off-deck/helmrelease.yaml`: controller `configarr`, `type: cronjob`, schedule `0 4 * * *`, `concurrencyPolicy: Forbid`, `backoffLimit: 0`, history 1/1, `ttlSecondsAfterFinished: 86400`, `restartPolicy: Never`, `TZ: America/Toronto`, `envFrom` secret `configarr-secret`, security context per Global Constraints, `annotations: reloader.stakater.com/auto: "true"`. Persistence: `config` (configMap `configarr-config`, `/app/config/config.yml` subPath `config.yml`, readOnly), `repos` emptyDir `/app/repos`, `tmp` emptyDir `/tmp`.
`kustomization.yaml`: resources externalsecret + helmrelease; `configMapGenerator` `configarr-config` from `config.yml`; `generatorOptions` `disableNameSuffixHash: true` with annotation `kustomize.toolkit.fluxcd.io/substitute: disabled` (as in `overseerr/app/kustomization.yaml`).

Initial `config.yml`:

```yaml
---
sonarr:
  main:
    base_url: http://sonarr.media-services.svc.cluster.local
    api_key: !env SONARR_API_KEY
    delete_unmanaged_custom_formats:
      enabled: false
    delete_unmanaged_quality_profiles:
      enabled: false
radarr:
  main:
    base_url: http://radarr.media-services.svc.cluster.local
    api_key: !env RADARR_API_KEY
    delete_unmanaged_custom_formats:
      enabled: false
    delete_unmanaged_quality_profiles:
      enabled: false
```

- [ ] **Step 5: Validate locally**

Run: `kustomize build kubernetes/apps/media-services/configarr/app | kubeconform -strict -ignore-missing-schemas -summary` and the same for `kubernetes/apps/media-services`.
Expected: 0 invalid, 0 errors; rendered ConfigMap contains `!env SONARR_API_KEY` verbatim.

- [ ] **Step 6: Commit, push, run once**

```bash
git add kubernetes/apps/media-services/configarr kubernetes/apps/media-services/kustomization.yaml
git commit -m "feat(configarr): add configarr cronjob for sonarr and radarr"
git push
```
Wait for `flux -n media-services get ks configarr` Ready, then `kubectl -n media-services create job --from=cronjob/configarr configarr-manual-1` and read its logs.
Expected: Job `Complete`; logs show successful connection to both instances and nothing created. If the pod fails on a read-only path, add an emptyDir for that path rather than relaxing `readOnlyRootFilesystem`.

- [ ] **Step 7: Diff against snapshot**

Re-export the four JSON files to `$SCRATCH/after1-*` and `diff <(jq -S . before-X) <(jq -S . after1-X)` each.
Expected: no differences.

### Task 2: `French` profile and custom formats

**Files:**
- Modify: `kubernetes/apps/media-services/configarr/app/config.yml`

**Interfaces:**
- Consumes: `sonarr.main` / `radarr.main` blocks from Task 1.
- Produces: quality profile `French` in each app.

- [ ] **Step 1: Add the profile to both instances**

```yaml
    quality_profiles:
      - name: French
        score_set: french-multi-vf
        reset_unmatched_scores:
          enabled: true
        upgrade:
          allowed: true
          until_quality: Bluray|WEB 2160p
          until_score: 10000
        min_format_score: 0
        quality_sort: top
        qualities:
          - name: Bluray|WEB 2160p
            qualities: [Bluray-2160p, WEBDL-2160p, WEBRip-2160p]
          - name: Bluray|WEB 1080p
            qualities: [Bluray-1080p, WEBDL-1080p, WEBRip-1080p]
```
Radarr only: add `language: Any` (French is enforced by custom formats).

- [ ] **Step 2: Add language custom formats with explicit scores (both apps, `assign_scores_to: [{name: French, score: N}]`)**

| CF | Sonarr trash_id | Radarr trash_id | Score |
|----|-----------------|-----------------|-------|
| VOQ | 802dd70b856c423a9b0cb7f34ac42be1 | f7caa1942be5cc547c266bd3dbc2cda9 | 400 |
| VOF | 7ae924ee9b2f39df3283c6c0beb8a2aa | 4cafa20d5584f6ba1871d1b8941aa3cb | 300 |
| VFQ | 7a7f4e4f58bd1058440236d033a90b67 | b6ace47331a1d3b77942fc18156f6df6 | 200 |
| VFF | 2c29a39a4fdfd6d258799bc4c09731b9 | 404c08fd0bd67f39b4d8e5709319094e | 100 |
| Language: Original + French | 10e77b96ae4770a7de645a91a53ce29a | 0542a48746585dc4444bbbb8a6bdf6ea | 1000 |
| MULTi | 7ba05c6e0e14e793538174c679126996 | 4b900e171accbfb172729b63323ea8ca | 0 |
| Language: Not French | 322fca6f8f3694acc1401ddb530fd33d | 533f782474f0819643c2ec0c1eeeb0ac | -10000 |
| Language: Not Original | ae575f95ab639ba5d15f663bf019e3e8 | d6e9318c875905d6cfb5bee961afcea9 | 0 |
| VOSTFR | 07a32f77690263bb9fda1842db7e273f | 9172b2f683f6223e3a1846427b417a3d | -10000 |
| FR LQ | 3ba797e5dc13af4b8d9bb25e83d90de2 | 48f031e76111f17ea94898f4cdc34fdc | -10000 |

Original + French at 1000 keeps any MULTi release above the best single-language French one (VOQ 400). VQ/VFI/VF2/VFB are added with score 0 (tags only, matching TRaSH).

- [ ] **Step 3: Add release-quality custom formats with TRaSH `french-multi-vf` scores**

Take every remaining `formatItems` trash_id from TRaSH's `docs/json/sonarr/quality-profiles/french-multi-vf-bluray-web-2160p.json` and `docs/json/radarr/quality-profiles/french-multi-vf-uhd-bluray-web.json` (tiers, FR tiers, Repack/Proper, streaming boosts, AUViO/MyCANAL/SALTO, FastSUB) and assign them to `French` without a `score`, so the score set / TRaSH default applies.

- [ ] **Step 4: Validate, commit, push, run**

Same validation as Task 1 Step 5. Commit `feat(configarr): add opt-in French quality profile`, push, wait for Ready, `kubectl create job --from=cronjob/configarr configarr-manual-2`.
Expected: Job `Complete`; logs show profile `French` created in both apps.

- [ ] **Step 5: Verify the computed profile**

Fetch the `French` profile from each app and map `formatItems` to `{name: score}`.
Expected: VOQ 400 > VOF 300 > VFQ 200 > VFF 100; `Language: Original + French` 1000; `Language: Not French`, `VOSTFR`, `FR LQ` = -10000; at least one tier CF (e.g. `WEB Tier 01`) is non-zero. If tier CFs are all 0, `score_set` didn't apply: give those CFs explicit scores from the TRaSH CF JSON's `trash_scores.default`, then repeat Step 4.

- [ ] **Step 6: Diff existing profiles and CFs against the Task 1 snapshot**

Diff each existing profile (exclude `French`) after removing `formatItems` entries whose CF did not exist before and have score 0. Diff pre-existing CFs by id.
Expected: no differences.

- [ ] **Step 7: Check for a download storm**

Compare queue `totalRecords` with the Step 1 snapshot and check `/api/v3/history?eventType=1&pageSize=20` for grabs since the sync.
Expected: no new grabs for titles on existing profiles.
