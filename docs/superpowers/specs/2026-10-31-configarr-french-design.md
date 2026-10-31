# Configarr + opt-in French profiles — design

## Intent

The library is overwhelmingly English-original (Sonarr: 284 series, Radarr: 878
movies) and English is the preferred default. Every now and then the owner wants
to deliberately pick French for a title, or grab a French-only show, and have it
handled properly: French/MULTi releases recognized and ranked sensibly, and not
renamed to an English title on disk.

C411 (French private tracker) was just made available through Prowlarr's built-in
definition, which is what brings MULTi/VFF/VFQ releases into the picture.

Configarr is added so custom formats and the new profiles live in Git instead of
being clicked together in the UI.

## Goals

- Deploy Configarr in `media-services`, GitOps-managed, syncing Sonarr and Radarr.
- One new opt-in quality profile per app, named **`French`**:
  - qualities 1080p through 2160p (same range as Sonarr's existing
    "HD / Ultra-HD"), upgrades allowed
  - requires French audio; MULTi (original + French) ranked first, French-only
    second
  - French variant ranking: VOQ (original Québec production) highest, then
    VOF (original France production), then VFQ (Québec dub), then VFF (France
    dub); other variants (VQ, VFI, VF2, ...) keep TRaSH's default scores
  - rejects VOSTFR, French fansub/LQ releases
  - built from TRaSH Guides French custom formats (`french-*`, `multi`), with
    scores taken from TRaSH's `[French MULTi.VF]` profiles
    (`docs/json/sonarr/quality-profiles/french-multi-vf-bluray-web-*.json`,
    `docs/json/radarr/quality-profiles/french-multi-vf-*-bluray-web.json`)
- Custom formats synced to the apps so MULTi releases are recognized.

## Prerequisite (manual, not managed by Configarr)

- On each French-capable indexer in Sonarr/Radarr (C411, Torrent9), set
  "Multi Languages" to Original + French so MULTi releases parse as both
  languages.

## Non-goals

- Changing any existing quality profile. The ~1,160 titles on existing profiles
  must behave exactly as today (no mass upgrades/downgrades/re-downloads).
- Managing media naming. Naming schemes stay as they are; Configarr must not set
  `media_naming`.
- Plex display titles.
- Lidarr, Prowlarr settings.

## Anti-goals (failure even if it "works")

- Any existing title starts re-downloading or gets upgraded/downgraded because of
  Configarr.
- Existing custom formats (Sonarr HDR/DV set, Radarr `DV (WEBDL)`) or their
  scores on existing profiles get deleted or altered.
- API keys committed in plaintext.

## Constraints

- Follow repo conventions (onedr0p/home-ops layout): `kubernetes/apps/media-services/configarr/{ks.yaml,app/}`,
  bjw-s app-template HelmRelease, add `./configarr/ks.yaml` to
  `kubernetes/apps/media-services/kustomization.yaml`.
- Secrets via ExternalSecret, `ClusterSecretStore` `onepassword-connect`, reusing
  existing 1Password items `sonarr` (`SONARR_API_KEY`) and `radarr`
  (`RADARR_API_KEY`). No new 1Password item needed.
- Runs as a scheduled job (app-template `type: cronjob`), nightly. Existing
  example of a cronjob app: `kubernetes/apps/media-services/plex/tools/off-deck/helmrelease.yaml`.
- Services: Sonarr and Radarr both listen on port **80**
  (`http://sonarr.media-services.svc.cluster.local`, `http://radarr...`).
- Versions: Sonarr 4.0.14 (develop), Radarr 6.4.4.
- Validate manifests with kubeconform; commit + push (Flux reconciles). No Claude
  attribution in commits.
- Configarr safety settings: `delete_unmanaged_custom_formats` and
  `delete_unmanaged_quality_profiles` disabled; only the `French` profile listed
  under `quality_profiles`; `assign_scores_to` targets only `French`.

## Decided by the owner

- English is the default; French is opt-in per title by choosing the `French`
  profile.
- Folder names for French titles are set manually (Sonarr/Radarr Edit → Path).
  Episode filenames keep the existing scheme; the owner renames manually if
  bothered.
- Configarr is the tool (not Recyclarr).
- VOQ is the top pick for French content; for dubs, VFQ is preferred over VFF.

## Builder's calls (made during design, open to review)

- Single combined 1080p–2160p `French` profile instead of TRaSH's separate
  1080p/2160p profiles; cutoff at the top 2160p quality, scores copied from the
  TRaSH MULTi.VF profiles.
- Profile language set so French is enforced by custom formats (TRaSH approach),
  not by Radarr's profile language field.
- Schedule: once nightly, plus it runs on every deploy/change.
- C411's Prowlarr "Replace MULTi" option stays off; MULTi is handled by the
  custom formats.

## Left to the builder

- Configarr image tag/digest (`ghcr.io/raydak-labs/configarr`), config delivery
  (ConfigMap mounted at the documented config path), env var names
  (`CONFIG_LOCATION`, `SECRETS_LOCATION` / `!env`).
- Whether TRaSH's French CFs need any `customFormatDefinitions` overrides for
  Sonarr 4.0.14 / Radarr 6.
- Writable cache path (emptyDir) for the TRaSH/Recyclarr repo clones, security
  context matching the other apps (uid 1000, read-only root FS).
- Verification: run the job once, confirm the `French` profile exists in both
  apps, existing profiles' JSON unchanged (diff before/after), no new queue items.
