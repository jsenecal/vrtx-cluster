# Dashboard Adaptation — Sub-project 0: Shared Template Library

## Background

[Madelena/hass-config-public](https://github.com/Madelena/hass-config-public) provides two
Lovelace dashboard "products" sharing one template library:

- A **maximalist control-center dashboard**: dense, per-room views (lights, energy,
  climate, scenes) plus specialty data-viz pages (axonometric floor plan, energy
  Sankey, psychrometry chart, network rail map, weather charts).
- An **ambient smart-display dashboard**: a slideshow + app-hub UI for wall-mounted
  tablets, showing one thing at a time.

Both are built on a shared button-card / decluttering-card / layout template library
and the [Metrology theme](https://github.com/Madelena/Metrology-for-Hass), which we
already maintain a fork of as
[jsenecal/Metrology-for-Hass](https://github.com/jsenecal/Metrology-for-Hass)
(installed via HACS).

Adapting the rest of Madelena's config is too large for a single design. This document
covers **sub-project 0 only**: porting the shared template/snippet library and standing
up the infrastructure to deliver it, designed so that the remaining sub-projects can
build on it without re-architecting:

- **A** — Maximalist control-center dashboard, room-by-room
- **B** — Ambient smart-display dashboard (wall tablets)
- **C** — Specialty data-viz pages (floor plan, energy Sankey, psychrometry, etc.)
- **D** — Location-specific sensor swaps (NYC-bound integrations → local equivalents
  or dropped)

A lot of Madelena's *content* is New York-specific (subway map, NYC311, GasBuddy,
traffic cameras) and is explicitly out of scope here.

## Architecture

### Repository: `jsenecal/home-assistant-yaml`

A dormant public repo already exists for Home Assistant YAML
(`blueprints/`, `scripts/`). It gains a new top-level `lovelace/` directory that
mirrors Madelena's layout:

```
lovelace/
├── lovelace-maximalist.yaml      # new dashboard entrypoint, !includes the below
├── secrets.yaml                  # NOT committed — provided via mounted Secret
└── ui/
    ├── templates/
    │   ├── button-card/
    │   │   ├── base.yaml
    │   │   ├── live-tiles.yaml
    │   │   ├── rows.yaml
    │   │   ├── rail-rows.yaml
    │   │   └── header-cards.yaml
    │   ├── decluttering-card.yaml
    │   └── apexcharts-card.yaml   # registered now, consumed starting in sub-project C
    └── shared/
        └── snippets/
            └── *.yaml             # layout-page-columns, live-tile, page-title, etc.
```

Sensitive values (none expected in sub-project 0, but anticipated for C/D — e.g.
weather API keys) are referenced via HA's native `!secret <key>` mechanism.

### git-sync sidecar

The `home-assistant` HelmRelease
(`kubernetes/apps/home-automation/home-assistant/app/helmrelease.yaml`) gains a new
`git-sync` container alongside the existing `app` and `code-server` containers,
sharing a new `emptyDir` volume:

- git-sync clones/pulls `jsenecal/home-assistant-yaml` (public, no credentials needed)
  into the shared volume, mounted at `/config/hass-config-src`.
- The `app` container mounts the same volume read-only at the same path.
- The dashboard entrypoint and its `!include`s are referenced as
  `/config/hass-config-src/lovelace/...`.

This follows the existing `persistence` / `advancedMounts` pattern already used for
the `tmpfs` mount in `helmrelease.yaml`.

### Dashboard registration (HA packages)

`lovelace.dashboards` entries live in `configuration.yaml`, which is on the PVC (not
git). Rather than editing `configuration.yaml` directly, a small single-file ConfigMap
(`lovelace_maximalist.yaml`) is mounted via `advancedMounts`/subPath at
`/config/packages/lovelace_maximalist.yaml`:

```yaml
lovelace:
  dashboards:
    maximalist:
      mode: yaml
      title: Maximalist
      icon: mdi:view-dashboard-variant
      filename: hass-config-src/lovelace/lovelace-maximalist.yaml
      show_in_sidebar: true
      require_admin: false
```

This relies on `homeassistant: packages: !include_dir_named packages` being enabled
(see Bootstrap below). Being a single file, this ConfigMap has none of the
key-collision or size issues a multi-file `configMapGenerator` would have.

### Secrets

A SOPS-encrypted `secret.sops.yaml` (same pattern as
`kubernetes/apps/rook-ceph/rook-ceph/app/secret.sops.yaml`) is decrypted by Flux into a
Kubernetes Secret, then mounted via subPath at
`/config/hass-config-src/lovelace/secrets.yaml` — overlaying a single file into the
git-synced directory tree, scoped to that dashboard's `!include`s. This doesn't touch
HA's main `/config/secrets.yaml`.

## Sub-project 0 deliverables

### Ported (near-as-is)

From `ui/templates/` and `ui/shared/snippets/`:

- `button-card/{base,live-tiles,rows,rail-rows,header-cards}.yaml` — layout/theme
  mechanics, not content-specific.
- `decluttering-card.yaml` — generic reusable template declarations.
- `apexcharts-card.yaml` — chart templates, registered now for sub-project C.
- All of `shared/snippets/` — page-column layouts, live-tile layouts, page titles,
  markdown styling snippets.

### Dropped / deferred

The `ui/templates/button-card/sensors/*.yaml` templates tied to NYC services
(`goodservice-io` subway status, NWS alerts — NWS doesn't cover Canada and may get an
Environment Canada equivalent under sub-project D). Generic ones (sun, plant, plex,
WAQI air quality) are kept.

### New HACS resources

Installed via the `ha_hacs_*` MCP tools and registered with
`ha_config_set_dashboard_resource`:

- `lovelace-layout-card`
- `decluttering-card`
- `lovelace-card-tools`
- `apexcharts-card`

### Pilot / smoke-test view

A single view in the new `maximalist` dashboard, using the live-tile/column templates
against real entities in the **Kitchen** area (largest area by entity count, good
mix of lights/scenes/sensors), to prove the ported library renders correctly
end-to-end. The Metrology theme is set as this dashboard's theme.

## Bootstrap steps (one-time, manual)

1. If `homeassistant: packages: !include_dir_named packages` is not already present in
   `configuration.yaml`, add it via code-server. Everything after this is GitOps.
2. Populate `lovelace/secrets.yaml` content (if/when needed) via the SOPS-encrypted
   secret — not required for sub-project 0 itself.

## Out of scope (future sub-projects)

- **A** — room-by-room maximalist views for the remaining 16 areas.
- **B** — ambient smart-display dashboard for the Family Room/Office/Kitchen wall
  displays.
- **C** — specialty data-viz pages (floor plan, energy Sankey, psychrometry,
  network map, weather charts), building on `apexcharts-card.yaml` and additional
  HACS resources (`ha-sankey-chart`, `ha-floorplan`, etc.).
- **D** — replace NYC-bound sensors (multiscrape traffic/transit/311, GasBuddy) with
  local equivalents or drop them; revisit NWS-alert templates with an Environment
  Canada source.

## Open questions / risks

- YAML-mode dashboards don't auto-reload on file change the way storage-mode ones do;
  a `lovelace.reload` (or full restart, for the `packages` change) may be needed after
  each git-sync pull during active development.
- git-sync poll interval needs picking (favor a short interval during active
  development of sub-projects A–D, can lengthen once stable).
