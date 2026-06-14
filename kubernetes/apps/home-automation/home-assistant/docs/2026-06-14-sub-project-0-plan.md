# Sub-project 0: Shared Template Library — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Port Madelena's shared button-card / decluttering-card / layout-card template
library into a new `lovelace/` tree in `jsenecal/home-assistant-yaml`, deliver it to the
`home-assistant` pod via a `git-sync` sidecar, register it as a new YAML-mode
"Maximalist" dashboard via a package ConfigMap, install the HACS frontend resources the
templates depend on, and prove the whole pipeline with a Kitchen pilot view.

**Architecture:** A new `lovelace/` directory tree is added to the existing (dormant)
`jsenecal/home-assistant-yaml` repo, mirroring Madelena's `ui/templates/` and
`ui/shared/snippets/` layout. The `home-assistant` HelmRelease
(`kubernetes/apps/home-automation/home-assistant/app/helmrelease.yaml`) gains a
`git-sync` sidecar that clones that repo into a shared `emptyDir`, mounted read-only at
`/config/hass-config-src` in the `app` container. A small single-file ConfigMap
(`lovelace_maximalist.yaml`) registers the new dashboard via HA's `packages:` mechanism.
One-time manual bootstrap enables `packages:` in `configuration.yaml` and installs 4
HACS frontend resources.

**Tech Stack:** Flux/Kustomize, bjw-s app-template HelmRelease, `registry.k8s.io/git-sync/git-sync` v4
sidecar, Home Assistant YAML-mode Lovelace dashboards + `packages:`, HACS (button-card,
card-mod, lovelace-layout-card, decluttering-card, lovelace-card-tools, apexcharts-card).

---

## File Structure

### Repo: `jsenecal/home-assistant-yaml` (already cloned at `/home/jsenecal/Code/home-assistant-yaml`, branch `main`)

- Create: `lovelace/.gitignore`
- Create: `lovelace/ui/templates/button-card/base.yaml` (51 lines, verbatim port)
- Create: `lovelace/ui/templates/button-card/live-tiles.yaml` (941 lines, verbatim port)
- Create: `lovelace/ui/templates/button-card/rows.yaml` (146 lines, verbatim port)
- Create: `lovelace/ui/templates/button-card/rail-rows.yaml` (334 lines, verbatim port)
- Create: `lovelace/ui/templates/button-card/header-cards.yaml` (143 lines, verbatim port)
- Create: `lovelace/ui/templates/decluttering-card.yaml` (427 lines, verbatim port)
- Create: `lovelace/ui/templates/apexcharts-card.yaml` (289 lines, verbatim port)
- Create: `lovelace/ui/shared/snippets/layout-live-tile-mini.yaml` (2 lines, verbatim port)
- Create: `lovelace/ui/shared/snippets/layout-live-tile.yaml` (2 lines, verbatim port)
- Create: `lovelace/ui/shared/snippets/layout-page-columns-one.yaml` (6 lines, verbatim port)
- Create: `lovelace/ui/shared/snippets/layout-page-columns.yaml` (6 lines, verbatim port)
- Create: `lovelace/ui/shared/snippets/layout-page-margin.yaml` (9 lines, verbatim port)
- Create: `lovelace/ui/shared/snippets/layout-page-title-with-2-badges.yaml` (9 lines, verbatim port)
- Create: `lovelace/ui/shared/snippets/layout-page-title.yaml` (9 lines, verbatim port)
- Create: `lovelace/ui/shared/snippets/parameters-page-title-swipe-card.yaml` (12 lines, verbatim port)
- Create: `lovelace/ui/shared/snippets/style-markdown-page-title.yaml` (11 lines, verbatim port)
- Create: `lovelace/ui/shared/snippets/style-page-title-swipe-card-tile.yaml` (4 lines, verbatim port)
- Create: `lovelace/ui/shared/snippets/style-page-title-swipe-card.yaml` (6 lines, verbatim port)
- Create: `lovelace/lovelace-maximalist.yaml` (new dashboard entrypoint + Kitchen pilot view)

All "verbatim port" files are fetched from
`Madelena/hass-config-public` at the pinned commit `a34865410ae96c4f5d26938d45115e88b8032bc6`
so the port is reproducible regardless of upstream changes.

### Repo: `vrtx-cluster` (this repo)

- Modify: `kubernetes/apps/home-automation/home-assistant/app/helmrelease.yaml`
- Modify: `kubernetes/apps/home-automation/home-assistant/app/kustomization.yaml`
- Create: `kubernetes/apps/home-automation/home-assistant/app/resources/lovelace_maximalist.yaml`

### Live HA instance (manual, one-time, via `kubectl exec` / MCP tools)

- `/config/configuration.yaml` — add a new top-level `homeassistant:` block enabling
  `packages: !include_dir_named packages` (no `homeassistant:` key exists today).
- HACS resources: `lovelace-layout-card`, `decluttering-card`, `lovelace-card-tools`,
  `apexcharts-card` — downloaded via HACS and registered as dashboard resources.

---

## Important implementation notes

### Note A: git-sync path has an extra `repo/` segment

The approved design doc says the dashboard entrypoint will live at
`/config/hass-config-src/lovelace/lovelace-maximalist.yaml`. In practice, git-sync v4
performs an atomic symlink swap: it clones into `$GITSYNC_ROOT/<rev-hash>` and points
the symlink `$GITSYNC_ROOT/$GITSYNC_LINK` at it. With `GITSYNC_ROOT=/git` and
`GITSYNC_LINK=repo`, the repo's content is reachable at `/git/repo/...`. Since the same
`emptyDir` is mounted at `/config/hass-config-src` in the `app` container, the real
path is:

```
/config/hass-config-src/repo/lovelace/lovelace-maximalist.yaml
```

This plan uses that corrected path everywhere (Task 7's package ConfigMap). The design
doc will be updated to match once this plan is approved/executed.

### Note B: sub-project 0 scope re: `button-card/sensors/`

The design doc's "Dropped/deferred" section mentions `ui/templates/button-card/sensors/*.yaml`
(sun/plant/plex/WAQI templates "kept", NYC-specific ones dropped). This plan does **not**
port any `sensors/` directory — sub-project 0 is scoped to exactly the 18 files listed
in File Structure above (the layout/theme mechanics needed to render *any* view). The
`sensors/` template directory is deferred to sub-project A, where it can be split
file-by-file into "kept" vs "needs a local replacement" without blocking this
foundational work.

### Note C: `!include` paths are relative to the including file's directory

Home Assistant resolves `!include` (and `!include_dir_*`) paths relative to the
directory of the file containing the tag — not relative to `/config`. Because
`lovelace-maximalist.yaml` lives at `lovelace/lovelace-maximalist.yaml` and the ported
templates live under `lovelace/ui/...`, every `!include` in Task 5 below uses paths
like `ui/templates/...` and `ui/shared/snippets/...` (relative to `lovelace/`) — exactly
mirroring Madelena's original repo, where `ui/ui-lovelace.yaml` includes
`templates/...` relative to `ui/`.

The `lovelace.dashboards.maximalist.filename` key (Task 7) is the one exception: it is
always relative to `/config`, hence the full `hass-config-src/repo/lovelace/...` path
from Note A.

---

## Task 1: Scaffold the `lovelace/` directory tree

**Files:**
- Create: `/home/jsenecal/Code/home-assistant-yaml/lovelace/.gitignore`

- [ ] **Step 1: Create the directory structure**

```bash
mkdir -p /home/jsenecal/Code/home-assistant-yaml/lovelace/ui/templates/button-card
mkdir -p /home/jsenecal/Code/home-assistant-yaml/lovelace/ui/shared/snippets
```

- [ ] **Step 2: Write `.gitignore`**

File content for `/home/jsenecal/Code/home-assistant-yaml/lovelace/.gitignore`:

```
secrets.yaml
```

- [ ] **Step 3: Commit and push**

```bash
cd /home/jsenecal/Code/home-assistant-yaml
git add lovelace/.gitignore
git commit -m "feat(lovelace): scaffold directory tree for Maximalist dashboard"
git push origin main
```

Expected: push succeeds, `git status` shows the `lovelace/` directories present
(empty dirs aren't tracked by git, but `lovelace/.gitignore` is committed).

---

## Task 2: Port button-card template files (5 files)

**Files:**
- Create: `/home/jsenecal/Code/home-assistant-yaml/lovelace/ui/templates/button-card/base.yaml`
- Create: `/home/jsenecal/Code/home-assistant-yaml/lovelace/ui/templates/button-card/live-tiles.yaml`
- Create: `/home/jsenecal/Code/home-assistant-yaml/lovelace/ui/templates/button-card/rows.yaml`
- Create: `/home/jsenecal/Code/home-assistant-yaml/lovelace/ui/templates/button-card/rail-rows.yaml`
- Create: `/home/jsenecal/Code/home-assistant-yaml/lovelace/ui/templates/button-card/header-cards.yaml`

- [ ] **Step 1: Download all 5 files from the pinned commit**

```bash
cd /home/jsenecal/Code/home-assistant-yaml/lovelace/ui/templates/button-card
SHA=a34865410ae96c4f5d26938d45115e88b8032bc6
BASE="https://raw.githubusercontent.com/Madelena/hass-config-public/$SHA/ui/templates/button-card"
curl -sL "$BASE/base.yaml" -o base.yaml
curl -sL "$BASE/live-tiles.yaml" -o live-tiles.yaml
curl -sL "$BASE/rows.yaml" -o rows.yaml
curl -sL "$BASE/rail-rows.yaml" -o rail-rows.yaml
curl -sL "$BASE/header-cards.yaml" -o header-cards.yaml
```

- [ ] **Step 2: Verify line counts**

```bash
wc -l base.yaml live-tiles.yaml rows.yaml rail-rows.yaml header-cards.yaml
```

Expected:
```
   51 base.yaml
  941 live-tiles.yaml
  146 rows.yaml
  334 rail-rows.yaml
  143 header-cards.yaml
 1615 total
```

- [ ] **Step 3: Commit and push**

```bash
cd /home/jsenecal/Code/home-assistant-yaml
git add lovelace/ui/templates/button-card/base.yaml \
        lovelace/ui/templates/button-card/live-tiles.yaml \
        lovelace/ui/templates/button-card/rows.yaml \
        lovelace/ui/templates/button-card/rail-rows.yaml \
        lovelace/ui/templates/button-card/header-cards.yaml
git commit -m "feat(lovelace): port button-card templates from hass-config-public"
git push origin main
```

---

## Task 3: Port decluttering-card and apexcharts-card templates

**Files:**
- Create: `/home/jsenecal/Code/home-assistant-yaml/lovelace/ui/templates/decluttering-card.yaml`
- Create: `/home/jsenecal/Code/home-assistant-yaml/lovelace/ui/templates/apexcharts-card.yaml`

- [ ] **Step 1: Download both files from the pinned commit**

```bash
cd /home/jsenecal/Code/home-assistant-yaml/lovelace/ui/templates
SHA=a34865410ae96c4f5d26938d45115e88b8032bc6
BASE="https://raw.githubusercontent.com/Madelena/hass-config-public/$SHA/ui/templates"
curl -sL "$BASE/decluttering-card.yaml" -o decluttering-card.yaml
curl -sL "$BASE/apexcharts-card.yaml" -o apexcharts-card.yaml
```

- [ ] **Step 2: Verify line counts**

```bash
wc -l decluttering-card.yaml apexcharts-card.yaml
```

Expected:
```
 427 decluttering-card.yaml
 289 apexcharts-card.yaml
 716 total
```

- [ ] **Step 3: Commit and push**

```bash
cd /home/jsenecal/Code/home-assistant-yaml
git add lovelace/ui/templates/decluttering-card.yaml \
        lovelace/ui/templates/apexcharts-card.yaml
git commit -m "feat(lovelace): port decluttering-card and apexcharts-card templates"
git push origin main
```

---

## Task 4: Port shared layout/style snippets (11 files)

**Files:**
- Create: `/home/jsenecal/Code/home-assistant-yaml/lovelace/ui/shared/snippets/layout-live-tile-mini.yaml`
- Create: `/home/jsenecal/Code/home-assistant-yaml/lovelace/ui/shared/snippets/layout-live-tile.yaml`
- Create: `/home/jsenecal/Code/home-assistant-yaml/lovelace/ui/shared/snippets/layout-page-columns-one.yaml`
- Create: `/home/jsenecal/Code/home-assistant-yaml/lovelace/ui/shared/snippets/layout-page-columns.yaml`
- Create: `/home/jsenecal/Code/home-assistant-yaml/lovelace/ui/shared/snippets/layout-page-margin.yaml`
- Create: `/home/jsenecal/Code/home-assistant-yaml/lovelace/ui/shared/snippets/layout-page-title-with-2-badges.yaml`
- Create: `/home/jsenecal/Code/home-assistant-yaml/lovelace/ui/shared/snippets/layout-page-title.yaml`
- Create: `/home/jsenecal/Code/home-assistant-yaml/lovelace/ui/shared/snippets/parameters-page-title-swipe-card.yaml`
- Create: `/home/jsenecal/Code/home-assistant-yaml/lovelace/ui/shared/snippets/style-markdown-page-title.yaml`
- Create: `/home/jsenecal/Code/home-assistant-yaml/lovelace/ui/shared/snippets/style-page-title-swipe-card-tile.yaml`
- Create: `/home/jsenecal/Code/home-assistant-yaml/lovelace/ui/shared/snippets/style-page-title-swipe-card.yaml`

- [ ] **Step 1: Download all 11 files from the pinned commit**

```bash
cd /home/jsenecal/Code/home-assistant-yaml/lovelace/ui/shared/snippets
SHA=a34865410ae96c4f5d26938d45115e88b8032bc6
BASE="https://raw.githubusercontent.com/Madelena/hass-config-public/$SHA/ui/shared/snippets"
curl -sL "$BASE/layout-live-tile-mini.yaml" -o layout-live-tile-mini.yaml
curl -sL "$BASE/layout-live-tile.yaml" -o layout-live-tile.yaml
curl -sL "$BASE/layout-page-columns-one.yaml" -o layout-page-columns-one.yaml
curl -sL "$BASE/layout-page-columns.yaml" -o layout-page-columns.yaml
curl -sL "$BASE/layout-page-margin.yaml" -o layout-page-margin.yaml
curl -sL "$BASE/layout-page-title-with-2-badges.yaml" -o layout-page-title-with-2-badges.yaml
curl -sL "$BASE/layout-page-title.yaml" -o layout-page-title.yaml
curl -sL "$BASE/parameters-page-title-swipe-card.yaml" -o parameters-page-title-swipe-card.yaml
curl -sL "$BASE/style-markdown-page-title.yaml" -o style-markdown-page-title.yaml
curl -sL "$BASE/style-page-title-swipe-card-tile.yaml" -o style-page-title-swipe-card-tile.yaml
curl -sL "$BASE/style-page-title-swipe-card.yaml" -o style-page-title-swipe-card.yaml
```

- [ ] **Step 2: Verify line counts**

```bash
wc -l layout-live-tile-mini.yaml layout-live-tile.yaml layout-page-columns-one.yaml \
      layout-page-columns.yaml layout-page-margin.yaml layout-page-title-with-2-badges.yaml \
      layout-page-title.yaml parameters-page-title-swipe-card.yaml \
      style-markdown-page-title.yaml style-page-title-swipe-card-tile.yaml \
      style-page-title-swipe-card.yaml
```

Expected:
```
   2 layout-live-tile-mini.yaml
   2 layout-live-tile.yaml
   6 layout-page-columns-one.yaml
   6 layout-page-columns.yaml
   9 layout-page-margin.yaml
   9 layout-page-title-with-2-badges.yaml
   9 layout-page-title.yaml
  12 parameters-page-title-swipe-card.yaml
  11 style-markdown-page-title.yaml
   4 style-page-title-swipe-card-tile.yaml
   6 style-page-title-swipe-card.yaml
  76 total
```

- [ ] **Step 3: Commit and push**

```bash
cd /home/jsenecal/Code/home-assistant-yaml
git add lovelace/ui/shared/snippets/
git commit -m "feat(lovelace): port shared layout and style snippets"
git push origin main
```

---

## Task 5: Write the Maximalist dashboard entrypoint + Kitchen pilot view

**Files:**
- Create: `/home/jsenecal/Code/home-assistant-yaml/lovelace/lovelace-maximalist.yaml`

This is new content (not a port). It declares the three shared template dictionaries
(`button_card_templates`, `decluttering_templates`, `apexcharts_card_templates`) the
same way Madelena's `ui/ui-lovelace.yaml` does, sets the Metrology theme, and adds one
view ("Kitchen") built from the ported `layout-page-margin` / `layout-page-columns` /
`layout-page-title` / `layout-live-tile` snippets and 11 live tiles against real Kitchen
entities (verified live against the HA instance):

- `light.kitchen_dimmer_2`, `light.kitchen_island_dimmer`,
  `light.kitchen_countertop_dimmer` — individual dimmer lights (`light_button_card`)
- `light.kitchen_dimmers_grp` — light group (`light_button_card_group`)
- `scene.kitchen_energize`, `scene.kitchen_concentrate`, `scene.kitchen_nightlight` —
  Hue dynamic scenes (`hue_scene_card`, calls `hue.activate_scene`)
- `binary_sensor.kitchen_dimmer_2_occupancy`, `binary_sensor.refrigerator_running` —
  occupancy/appliance binary sensors (`live_tile`)
- `sensor.aude_s_plant_sensor_temperature`, `sensor.aude_s_plant_sensor_moisture` —
  plant sensor readings (`live_tile_with_unit`)

The view structure (outer `custom:grid-layout` + nested `custom:layout-card`
`grid-layout` sections) follows the exact pattern used in Madelena's own
`ui/views/rooms/kitchen.yaml` and `ui/views/rooms/workspace.yaml`.

- [ ] **Step 1: Write the file**

File content for `/home/jsenecal/Code/home-assistant-yaml/lovelace/lovelace-maximalist.yaml`:

```yaml
# Maximalist Dashboard
# Template library ported from https://github.com/Madelena/hass-config-public
# (Madelena Mak, 2022) and adapted for jsenecal/Metrology-for-Hass.

title: Maximalist
theme: Metro Slate

button_card_templates: !include_dir_merge_named ui/templates/button-card
decluttering_templates: !include ui/templates/decluttering-card.yaml
apexcharts_card_templates: !include ui/templates/apexcharts-card.yaml

views:
  - title: Kitchen
    path: kitchen
    icon: mdi:fridge-outline
    type: 'custom:grid-layout'
    layout: !include ui/shared/snippets/layout-page-margin.yaml
    cards:
      - type: 'custom:layout-card'
        layout_type: 'custom:grid-layout'
        layout: !include ui/shared/snippets/layout-page-columns.yaml
        view_layout:
          grid-area: cc
        cards:

          # [Header] Page title

          - type: 'custom:layout-card'
            layout_type: 'custom:grid-layout'
            layout: !include ui/shared/snippets/layout-page-title.yaml
            view_layout:
              grid-column: 1/-1
            cards:
              - type: markdown
                style: !include ui/shared/snippets/style-markdown-page-title.yaml
                content: >
                  # Kitchen

          # [Section] Live tiles (pilot)

          - type: 'custom:layout-card'
            layout_type: 'custom:grid-layout'
            layout: !include ui/shared/snippets/layout-live-tile.yaml
            view_layout:
              grid-column: 1/-1
            cards:

              - type: 'custom:button-card'
                template: header_card_no_link
                variables:
                  name: LIGHTS
                view_layout:
                  grid-column: 1/-1

              - type: 'custom:button-card'
                template: light_button_card
                entity: light.kitchen_dimmer_2
                name: Dimmer 2

              - type: 'custom:button-card'
                template: light_button_card
                entity: light.kitchen_island_dimmer
                name: Island

              - type: 'custom:button-card'
                template: light_button_card
                entity: light.kitchen_countertop_dimmer
                name: Countertop

              - type: 'custom:button-card'
                template: light_button_card_group
                entity: light.kitchen_dimmers_grp
                name: All Lights

              - type: 'custom:button-card'
                template: hue_scene_card
                entity: scene.kitchen_energize
                variables:
                  name: Energize

              - type: 'custom:button-card'
                template: hue_scene_card
                entity: scene.kitchen_concentrate
                variables:
                  name: Concentrate

              - type: 'custom:button-card'
                template: hue_scene_card
                entity: scene.kitchen_nightlight
                variables:
                  name: Nightlight

              - type: 'custom:button-card'
                template: header_card_no_link
                variables:
                  name: SENSORS
                view_layout:
                  grid-column: 1/-1

              - type: 'custom:button-card'
                template: live_tile
                entity: binary_sensor.kitchen_dimmer_2_occupancy
                name: Occupancy

              - type: 'custom:button-card'
                template: live_tile
                entity: binary_sensor.refrigerator_running
                name: Fridge Running

              - type: 'custom:button-card'
                template: live_tile_with_unit
                entity: sensor.aude_s_plant_sensor_temperature
                name: Plant Temp

              - type: 'custom:button-card'
                template: live_tile_with_unit
                entity: sensor.aude_s_plant_sensor_moisture
                name: Plant Moisture
```

> **Theme note:** `theme: Metro Slate` is a best-effort pick from the theme names
> defined in `jsenecal/Metrology-for-Hass`'s `themes/metro.yaml` (`Metro Red`,
> `Fluent Red`, `Metro Blue`, `Fluent Blue`, `Metro Green`, `Fluent Green`,
> `Metro Neon Green`, `Fluent Neon Green`, `Metro Orange`, `Fluent Orange`,
> `Metro Purple`, `Fluent Purple`, `Metro Slate`, `Fluent Slate`). Task 10 verifies this
> theme actually renders and corrects it if not.

- [ ] **Step 2: Commit and push**

```bash
cd /home/jsenecal/Code/home-assistant-yaml
git add lovelace/lovelace-maximalist.yaml
git commit -m "feat(lovelace): add Maximalist dashboard entrypoint with Kitchen pilot view"
git push origin main
```

---

## Task 6: Add the git-sync sidecar to the home-assistant HelmRelease

**Files:**
- Modify: `kubernetes/apps/home-automation/home-assistant/app/helmrelease.yaml`

This task adds a `git-sync` container that clones `jsenecal/home-assistant-yaml` into a
new `hass-config-src` `emptyDir`, mounted read-only at `/config/hass-config-src` in the
`app` container (per Note A, the synced repo content lands at
`/config/hass-config-src/repo/...`). `readOnlyRootFilesystem: true` on the new
container means git-sync needs a writable `$HOME` for its internal `git config --global`
calls, so it also gets a `/tmp` mount via the existing `tmpfs` emptyDir.

- [ ] **Step 1: Add the `git-sync` container**

In `kubernetes/apps/home-automation/home-assistant/app/helmrelease.yaml`, the
`containers` map currently ends with the `code-server` container (lines 63-89):

```yaml
          code-server:
            image:
              repository: ghcr.io/coder/code-server
              tag: 4.123.0@sha256:6d46b83ea0687ab1826ec029b6d0e6342bbd55cc5c29b98258463e7faee16d1e
            securityContext:
              runAsUser: 1000
              runAsGroup: 1000
            args:
              - --auth
              - none
              - --disable-telemetry
              - --disable-update-check
              - --user-data-dir
              - /config/.code-server
              - --extensions-dir
              - /config/.code-server
              - --port
              - "12321"
              - /config
            env:
              HASS_SERVER: http://localhost:8123
            resources:
              requests:
                cpu: 10m
                memory: 512Mi
              limits:
                memory: 8Gi
```

Add a new `git-sync` container immediately after it (before the blank line and
`service:` section):

```yaml
          code-server:
            image:
              repository: ghcr.io/coder/code-server
              tag: 4.123.0@sha256:6d46b83ea0687ab1826ec029b6d0e6342bbd55cc5c29b98258463e7faee16d1e
            securityContext:
              runAsUser: 1000
              runAsGroup: 1000
            args:
              - --auth
              - none
              - --disable-telemetry
              - --disable-update-check
              - --user-data-dir
              - /config/.code-server
              - --extensions-dir
              - /config/.code-server
              - --port
              - "12321"
              - /config
            env:
              HASS_SERVER: http://localhost:8123
            resources:
              requests:
                cpu: 10m
                memory: 512Mi
              limits:
                memory: 8Gi

          git-sync:
            image:
              # renovate: datasource=docker depName=registry.k8s.io/git-sync/git-sync
              repository: registry.k8s.io/git-sync/git-sync
              tag: v4.7.0@sha256:d232fd13474ba1b46dba431af2b1411b9d9afacda55ae644d2a32e43975128dd
            env:
              GITSYNC_REPO: https://github.com/jsenecal/home-assistant-yaml
              GITSYNC_REF: main
              GITSYNC_ROOT: /git
              GITSYNC_LINK: repo
              GITSYNC_PERIOD: 30s
              HOME: /tmp
            resources:
              requests:
                cpu: 5m
                memory: 32Mi
              limits:
                memory: 64Mi
            securityContext:
              allowPrivilegeEscalation: false
              readOnlyRootFilesystem: true
              capabilities:
                drop:
                  - ALL
```

- [ ] **Step 2: Add the `hass-config-src` emptyDir volume**

In the same file, the `persistence` block currently has (lines 101-129):

```yaml
    persistence:
      config:
        existingClaim: home-assistant
        advancedMounts:
          home-assistant:
            app:
              - path: /config
            code-server:
              - path: /config
      hass-cache:
        existingClaim: hass-cache
        advancedMounts:
          home-assistant:
            app:
              - path: /venv
                subPath: hass-venv
      tmpfs:
        type: emptyDir
        advancedMounts:
          home-assistant:
            app:
              - path: /tmp
                subPath: hass-tmp
            code-server:
              - path: /tmp
                subPath: code-server-tmp
              - path: /nonexistent
                subPath: nonexistent
```

Replace it with (adds `hass-config-src` after `hass-cache`, and adds a `git-sync` mount
to the existing `tmpfs` volume):

```yaml
    persistence:
      config:
        existingClaim: home-assistant
        advancedMounts:
          home-assistant:
            app:
              - path: /config
            code-server:
              - path: /config
      hass-cache:
        existingClaim: hass-cache
        advancedMounts:
          home-assistant:
            app:
              - path: /venv
                subPath: hass-venv
      hass-config-src:
        type: emptyDir
        advancedMounts:
          home-assistant:
            git-sync:
              - path: /git
            app:
              - path: /config/hass-config-src
                readOnly: true
      tmpfs:
        type: emptyDir
        advancedMounts:
          home-assistant:
            app:
              - path: /tmp
                subPath: hass-tmp
            code-server:
              - path: /tmp
                subPath: code-server-tmp
              - path: /nonexistent
                subPath: nonexistent
            git-sync:
              - path: /tmp
                subPath: git-sync-tmp
```

- [ ] **Step 3: Validate the kustomization builds**

```bash
cd /home/jsenecal/Code/vrtx-cluster
kubectl kustomize kubernetes/apps/home-automation/home-assistant/app | head -1
```

Expected: no errors (the `head -1` just confirms output was produced — full output
contains `${SECRET_DOMAIN}` etc. unsubstituted, which is expected since
`postBuild.substituteFrom` is a Flux-side step).

- [ ] **Step 4: Commit and push**

```bash
cd /home/jsenecal/Code/vrtx-cluster
git add kubernetes/apps/home-automation/home-assistant/app/helmrelease.yaml
git commit -m "feat(home-assistant): add git-sync sidecar for lovelace dashboard source"
git push origin main
```

- [ ] **Step 5: Wait for Flux reconciliation and verify**

```bash
flux reconcile kustomization home-assistant -n home-automation --with-source
kubectl -n home-automation get pods -l app.kubernetes.io/name=home-assistant
```

Expected: the `home-assistant` pod shows `4/4` containers ready (`app`, `code-server`,
`git-sync`, plus the istio/network sidecars already present — exact count may vary, but
`git-sync` should appear in `kubectl -n home-automation describe pod <pod>`'s container
list).

```bash
kubectl -n home-automation exec deploy/home-assistant -c app -- ls /config/hass-config-src/repo/lovelace/
```

Expected output includes `lovelace-maximalist.yaml` and `ui`.

---

## Task 7: Register the Maximalist dashboard via a packages ConfigMap

**Files:**
- Create: `kubernetes/apps/home-automation/home-assistant/app/resources/lovelace_maximalist.yaml`
- Modify: `kubernetes/apps/home-automation/home-assistant/app/kustomization.yaml`
- Modify: `kubernetes/apps/home-automation/home-assistant/app/helmrelease.yaml`

- [ ] **Step 1: Create the package ConfigMap source file**

```bash
mkdir -p /home/jsenecal/Code/vrtx-cluster/kubernetes/apps/home-automation/home-assistant/app/resources
```

File content for
`kubernetes/apps/home-automation/home-assistant/app/resources/lovelace_maximalist.yaml`:

```yaml
lovelace:
  dashboards:
    maximalist:
      mode: yaml
      title: Maximalist
      icon: mdi:view-dashboard-variant
      filename: hass-config-src/repo/lovelace/lovelace-maximalist.yaml
      show_in_sidebar: true
      require_admin: false
```

- [ ] **Step 2: Add the `configMapGenerator` to the kustomization**

`kubernetes/apps/home-automation/home-assistant/app/kustomization.yaml` currently reads:

```yaml
---
# yaml-language-server: $schema=https://json.schemastore.org/kustomization
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ./helmrelease.yaml
  - ./pvc.yaml
postBuild:
  substituteFrom:
    - kind: Secret
      name: cluster-secrets
```

Replace it with:

```yaml
---
# yaml-language-server: $schema=https://json.schemastore.org/kustomization
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ./helmrelease.yaml
  - ./pvc.yaml
configMapGenerator:
  - name: home-assistant-lovelace-maximalist
    files:
      - lovelace_maximalist.yaml=./resources/lovelace_maximalist.yaml
generatorOptions:
  disableNameSuffixHash: true
  annotations:
    kustomize.toolkit.fluxcd.io/substitute: disabled
postBuild:
  substituteFrom:
    - kind: Secret
      name: cluster-secrets
```

- [ ] **Step 3: Mount the ConfigMap into `/config/packages/`**

In `kubernetes/apps/home-automation/home-assistant/app/helmrelease.yaml`, the
`persistence` block now ends with the `tmpfs` entry added in Task 6 (ending with the
`git-sync` mount). Add a new `lovelace-maximalist` entry after `hass-config-src` and
before `tmpfs`:

```yaml
      hass-config-src:
        type: emptyDir
        advancedMounts:
          home-assistant:
            git-sync:
              - path: /git
            app:
              - path: /config/hass-config-src
                readOnly: true
      lovelace-maximalist:
        type: configMap
        name: home-assistant-lovelace-maximalist
        advancedMounts:
          home-assistant:
            app:
              - path: /config/packages/lovelace_maximalist.yaml
                subPath: lovelace_maximalist.yaml
                readOnly: true
      tmpfs:
        type: emptyDir
        advancedMounts:
          home-assistant:
            app:
              - path: /tmp
                subPath: hass-tmp
            code-server:
              - path: /tmp
                subPath: code-server-tmp
              - path: /nonexistent
                subPath: nonexistent
            git-sync:
              - path: /tmp
                subPath: git-sync-tmp
```

- [ ] **Step 4: Validate the kustomization builds and the ConfigMap is generated**

```bash
cd /home/jsenecal/Code/vrtx-cluster
kubectl kustomize kubernetes/apps/home-automation/home-assistant/app | \
  yq 'select(.kind == "ConfigMap" and .metadata.name == "home-assistant-lovelace-maximalist")'
```

Expected: prints a ConfigMap manifest with `data."lovelace_maximalist.yaml"` containing
the `lovelace: dashboards: maximalist: ...` content from Step 1.

- [ ] **Step 5: Commit and push**

```bash
cd /home/jsenecal/Code/vrtx-cluster
git add kubernetes/apps/home-automation/home-assistant/app/resources/lovelace_maximalist.yaml \
        kubernetes/apps/home-automation/home-assistant/app/kustomization.yaml \
        kubernetes/apps/home-automation/home-assistant/app/helmrelease.yaml
git commit -m "feat(home-assistant): register Maximalist dashboard via packages ConfigMap"
git push origin main
```

- [ ] **Step 6: Wait for Flux reconciliation and verify the mount**

```bash
flux reconcile kustomization home-assistant -n home-automation --with-source
kubectl -n home-automation exec deploy/home-assistant -c app -- cat /config/packages/lovelace_maximalist.yaml
```

Expected: prints the `lovelace: dashboards: maximalist: ...` YAML from Step 1. At this
point the file exists on disk but HA does not load it yet — `packages:` isn't enabled
in `configuration.yaml` until Task 8.

---

## Task 8: Bootstrap `configuration.yaml` to enable `packages:`

**Live instance change** (manual, one-time — not GitOps, `configuration.yaml` lives on
the PVC).

Current `/config/configuration.yaml` (read via `kubectl exec`) has no `homeassistant:`
top-level key:

```yaml
# Loads default set of integrations. Do not remove.
default_config:

# Load frontend themes from the themes folder
frontend:
  themes: !include_dir_merge_named themes
  extra_module_url:
    - /hacsfiles/lovelace-card-mod/card-mod.js

automation: !include automations.yaml
script: !include scripts.yaml
scene: !include scenes.yaml

http:
  use_x_forwarded_for: true
  cors_allowed_origins:
    - https://haus.k8s.mstrsmth.io
  trusted_proxies:
    - 10.42.0.0/16      # Pod network
    - 192.168.168.0/24  # Gateway network
```

- [ ] **Step 1: Create `/config/packages/` and append the `homeassistant:` block**

```bash
kubectl -n home-automation exec deploy/home-assistant -c app -- sh -c \
  'mkdir -p /config/packages && printf "\nhomeassistant:\n  packages: !include_dir_named packages\n" >> /config/configuration.yaml'
```

- [ ] **Step 2: Verify the file**

```bash
kubectl -n home-automation exec deploy/home-assistant -c app -- tail -5 /config/configuration.yaml
```

Expected:
```

homeassistant:
  packages: !include_dir_named packages
```

- [ ] **Step 3: Check the config is valid**

Use the `ha_check_config` MCP tool. Expected: `result: valid` (no errors). If it
reports an error referencing `lovelace_maximalist.yaml` or `packages`, re-check Step 1's
output and Task 7's ConfigMap content for YAML syntax issues before continuing.

- [ ] **Step 4: Restart Home Assistant**

`packages:` is evaluated at startup, so a full restart (not just a config reload) is
required. Use the `ha_restart` MCP tool, then wait for the instance to come back:

```bash
kubectl -n home-automation get pods -l app.kubernetes.io/name=home-assistant -w
```

Expected: pod cycles through `Running` → ready `1/1` (app container) again within ~1-2
minutes. Press Ctrl-C once ready.

- [ ] **Step 5: Confirm the Maximalist dashboard is registered**

Use the `ha_get_overview` MCP tool (or check the sidebar in the frontend). Expected: a
new "Maximalist" entry with icon `mdi:view-dashboard-variant` appears alongside the
existing "Overview"/"Areas"/"Map" dashboards.

---

## Task 9: Install required HACS frontend resources

**Live instance change** (manual, one-time, via MCP tools).

Four custom cards are needed by the ported templates and the Kitchen pilot view:

| HACS repository | Installed JS asset | Lovelace resource URL |
|---|---|---|
| `thomasloven/lovelace-layout-card` | `layout-card.js` | `/hacsfiles/lovelace-layout-card/layout-card.js` |
| `custom-cards/decluttering-card` | `decluttering-card.js` | `/hacsfiles/decluttering-card/decluttering-card.js` |
| `thomasloven/lovelace-card-tools` | `card-tools.js` | `/hacsfiles/lovelace-card-tools/card-tools.js` |
| `RomRider/apexcharts-card` | `apexcharts-card.js` | `/hacsfiles/apexcharts-card/apexcharts-card.js` |

`button-card`, `card-mod`, and `mini-graph-card` are already installed/registered (see
existing `ha_config_list_dashboard_resources` output) — only these 4 are new.

- [ ] **Step 1: Download each repository via HACS**

Call `ha_hacs_download` once per repository, with `category="lovelace"`:

```
ha_hacs_download(repository="thomasloven/lovelace-layout-card", category="lovelace")
ha_hacs_download(repository="custom-cards/decluttering-card", category="lovelace")
ha_hacs_download(repository="thomasloven/lovelace-card-tools", category="lovelace")
ha_hacs_download(repository="RomRider/apexcharts-card", category="lovelace")
```

Expected: each call reports success and the repository is now listed as a HACS
"Installed" repository.

> **Fallback:** if `ha_hacs_download` reports the repository is unknown to HACS (HACS
> WebSocket calls were unreliable earlier in this project — see the design history),
> first call `ha_hacs_add_repository(repository="<owner>/<repo>", category="lovelace")`
> for the failing repo, then retry `ha_hacs_download`. If MCP HACS calls keep failing,
> install manually via the HACS panel in the frontend (Settings → HACS → Frontend →
> "+ Explore & Download Repositories", search for each repo name, install, then add the
> resource as in Step 2).

- [ ] **Step 2: Register each as a Lovelace dashboard resource**

Call `ha_config_set_dashboard_resource` once per file, with `resource_type="module"`:

```
ha_config_set_dashboard_resource(url="/hacsfiles/lovelace-layout-card/layout-card.js", resource_type="module")
ha_config_set_dashboard_resource(url="/hacsfiles/decluttering-card/decluttering-card.js", resource_type="module")
ha_config_set_dashboard_resource(url="/hacsfiles/lovelace-card-tools/card-tools.js", resource_type="module")
ha_config_set_dashboard_resource(url="/hacsfiles/apexcharts-card/apexcharts-card.js", resource_type="module")
```

- [ ] **Step 3: Verify resources are registered**

Use `ha_config_list_dashboard_resources`. Expected: the 4 new URLs above appear in
addition to the 7 existing entries (11 total `module`/`css` resources).

No restart is required — Lovelace resources are picked up on the next full browser
page load.

---

## Task 10: Verify the Kitchen pilot view renders

- [ ] **Step 1: Confirm the `Metro Slate` theme name**

```bash
kubectl -n home-automation exec deploy/home-assistant -c app -- cat /config/themes/metro/metro.yaml | grep -E '^[A-Za-z].*:$'
```

Expected: includes a line `Metro Slate:`. If `theme: Metro Slate` does not visually
apply in Step 3 below (e.g. the dashboard falls back to the default theme), check the
HA logs for `Unable to find theme` warnings — this likely means
`!include_dir_merge_named themes` (in `configuration.yaml`) does not recurse into the
HACS-installed `/config/themes/metro/` subdirectory. If so, as a sub-project-0-scoped
fix, remove the `theme:` line from `lovelace-maximalist.yaml` (commit + push) and file
the theme-loading issue as a follow-up — it's a pre-existing HACS/theme config issue,
not something this plan's infrastructure changes can fix safely.

- [ ] **Step 2: Reload the frontend and navigate to the new dashboard**

Using the Playwright MCP tools, navigate to:

```
https://haus.k8s.mstrsmth.io/maximalist/kitchen
```

- [ ] **Step 3: Take a screenshot and check the browser console**

Use `mcp__plugin_playwright_playwright__browser_take_screenshot` to capture the
rendered view, and `mcp__plugin_playwright_playwright__browser_console_messages` to
check for JS errors.

Expected:
- Page title "Kitchen" renders via the `header_card_no_link` / markdown title card.
- A "LIGHTS" section header followed by 4 tiles: "Dimmer 2", "Island", "Countertop",
  "All Lights" (showing on/off state per the live entity states queried during
  planning — `light.kitchen_dimmer_2` and `light.kitchen_dimmers_grp` were `on`,
  `light.kitchen_island_dimmer` and `light.kitchen_countertop_dimmer` were `off`).
- 3 Hue scene tiles ("Energize", "Concentrate", "Nightlight") with their colorDict
  background colors.
- A "SENSORS" section header followed by 4 tiles: "Occupancy" (on), "Fridge Running"
  (off), "Plant Temp" (~23.2°C), "Plant Moisture" (~35%).
- No `Custom element doesn't exist` errors in the console (this would indicate a
  missing/misregistered HACS resource from Task 9).

- [ ] **Step 4: Troubleshooting common errors**

- `Custom element doesn't exist: layout-card` / `grid-layout` → re-check Task 9 Step 2
  registered `/hacsfiles/lovelace-layout-card/layout-card.js` and the browser did a hard
  refresh.
- A tile renders as a raw error card mentioning a missing template (e.g.
  `Unknown button_card_template`) → re-check `button_card_templates:
  !include_dir_merge_named ui/templates/button-card` resolved — run:
  ```bash
  kubectl -n home-automation exec deploy/home-assistant -c app -- ls /config/hass-config-src/repo/lovelace/ui/templates/button-card/
  ```
  Expected: `base.yaml  header-cards.yaml  live-tiles.yaml  rail-rows.yaml  rows.yaml`.
- Hue scene tiles show no background color → `hue.activate_scene` and the colorDict
  match on `variables.name.toLowerCase()` (`energize`, `concentrate`, `nightlight`),
  which matches the `scene.kitchen_*` `original_name` values (`Energize`, `Nightlight`,
  etc. — confirmed via `ha_get_entity`). If tapping a scene tile does nothing, confirm
  the entity's `platform` is `hue` (`ha_get_entity`) — `hue.activate_scene` only works
  for Hue-platform scene entities.

---

## Self-review

- **Spec coverage:** every "Sub-project 0 deliverable" in the design doc
  (`2026-06-14-dashboard-adaptation-design.md`) maps to a task: ported templates
  (Tasks 2-4), git-sync infrastructure (Task 6), dashboard registration via packages
  (Tasks 7-8), HACS resources (Task 9), pilot view (Task 5 + Task 10). The
  `secrets.yaml` SOPS wiring is explicitly **not** included — the design doc says it's
  "not required for sub-project 0 itself"; Task 1's `.gitignore` leaves the door open
  for sub-project C/D to add it without restructuring.
- **Placeholder scan:** all file contents, commands, entity IDs, image digests, HACS
  repo/asset names, and line-count expectations were verified against the live HA
  instance, the pinned upstream commit, and GitHub API responses during planning — no
  `TBD`/`adapt as needed` remain.
- **Path/type consistency:** `hass-config-src` (emptyDir name), `git-sync` (container
  name), and `home-assistant-lovelace-maximalist` (ConfigMap name) are used identically
  across Tasks 6/7. The `/config/hass-config-src/repo/...` vs. design-doc's
  `/config/hass-config-src/...` discrepancy is called out in Note A and used
  consistently in Tasks 5, 7, and 10.
- **Design doc correction:** after this plan is executed, update
  `2026-06-14-dashboard-adaptation-design.md`'s git-sync section to reflect the
  `.../repo/...` path from Note A, so the doc matches the as-built system.

---

## Execution choice

Plan complete and saved to
`kubernetes/apps/home-automation/home-assistant/docs/2026-06-14-sub-project-0-plan.md`.
Two execution options:

1. **Subagent-Driven (recommended)** — dispatch a fresh subagent per task, review
   between tasks, fast iteration.
2. **Inline Execution** — execute tasks in this session using `executing-plans`, batch
   execution with checkpoints for review.

Which approach?
