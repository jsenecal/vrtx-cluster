# C2 Environment View Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an Environment view to the Maximalist dashboard displaying a live psychrometric chart with indicator dots for outdoor, office, living room, and bedroom zones.

**Architecture:** SVG and CSS assets are committed to vrtx-cluster as a ConfigMap, mounted at `/config/www/` so HA serves them at `/local/`. The `custom:floorplan-card` overlays live indicator dots using JavaScript coordinate math in floorplan rules. Two new `thermal_comfort` config entries provide `absolute_humidity` for the new zones.

**Tech Stack:** Home Assistant YAML-mode Lovelace, custom:floorplan-card (ha-floorplan HACS card), thermal_comfort integration, kustomize configMapGenerator, Flux GitOps.

---

## Prerequisites (confirm before starting)

- `ha-floorplan` is installed in HACS (confirmed by user)
- Two new thermal_comfort entries will be created in Task 2

---

## File Structure

```
vrtx-cluster/
└── kubernetes/apps/home-automation/home-assistant/app/
    ├── www/
    │   ├── psychrometry-chart.svg    CREATE: 140 KB SVG from Madelena's repo
    │   └── psychrometry-chart.css    CREATE: 756 B CSS from Madelena's repo
    ├── kustomization.yaml            MODIFY: add home-assistant-psychrometry-assets to configMapGenerator
    └── helmrelease.yaml              MODIFY: add psychrometry-assets persistence entry

home-assistant-yaml/
└── lovelace/
    ├── lovelace-maximalist.yaml          MODIFY: append !include (current EOF: line 1631)
    └── ui/views/
        └── view-environment.yaml         CREATE: full view definition
```

---

## Task 1: Download SVG/CSS and wire up K8s assets

Downloads the psychrometric chart assets from Madelena's pinned commit and registers
them as a ConfigMap in vrtx-cluster, mounted into `/config/www/` so HA serves them
at `/local/psychrometry-chart.svg` and `/local/psychrometry-chart.css`.

**Files:**
- Create: `kubernetes/apps/home-automation/home-assistant/app/www/psychrometry-chart.svg`
- Create: `kubernetes/apps/home-automation/home-assistant/app/www/psychrometry-chart.css`
- Modify: `kubernetes/apps/home-automation/home-assistant/app/kustomization.yaml`
- Modify: `kubernetes/apps/home-automation/home-assistant/app/helmrelease.yaml`

- [ ] **Step 1: Download SVG and CSS from Madelena's pinned commit**

```bash
cd /home/jsenecal/Code/vrtx-cluster
mkdir -p kubernetes/apps/home-automation/home-assistant/app/www

gh api "repos/Madelena/hass-config-public/contents/www/psychrometry-chart.svg?ref=a34865410ae96c4f5d26938d45115e88b8032bc6" \
  --jq '.content' | base64 -d \
  > kubernetes/apps/home-automation/home-assistant/app/www/psychrometry-chart.svg

gh api "repos/Madelena/hass-config-public/contents/www/psychrometry-chart.css?ref=a34865410ae96c4f5d26938d45115e88b8032bc6" \
  --jq '.content' | base64 -d \
  > kubernetes/apps/home-automation/home-assistant/app/www/psychrometry-chart.css
```

Verify sizes:
```bash
wc -c kubernetes/apps/home-automation/home-assistant/app/www/psychrometry-chart.svg
wc -c kubernetes/apps/home-automation/home-assistant/app/www/psychrometry-chart.css
```

Expected: SVG ≈ 139 806 bytes, CSS ≈ 756 bytes.

- [ ] **Step 2: Add psychrometry-assets to configMapGenerator in kustomization.yaml**

File: `kubernetes/apps/home-automation/home-assistant/app/kustomization.yaml`

The existing `configMapGenerator` array has one entry. Add a second entry for the
psychrometry assets. The global `generatorOptions` (already present) applies
`disableNameSuffixHash: true` and the Flux no-substitute annotation to all entries.

Change from:
```yaml
configMapGenerator:
  - name: home-assistant-lovelace-maximalist
    files:
      - lovelace_maximalist.yaml=./resources/lovelace_maximalist.yaml
```

Change to:
```yaml
configMapGenerator:
  - name: home-assistant-lovelace-maximalist
    files:
      - lovelace_maximalist.yaml=./resources/lovelace_maximalist.yaml
  - name: home-assistant-psychrometry-assets
    files:
      - psychrometry-chart.svg=./www/psychrometry-chart.svg
      - psychrometry-chart.css=./www/psychrometry-chart.css
```

- [ ] **Step 3: Add psychrometry-assets persistence entry to helmrelease.yaml**

File: `kubernetes/apps/home-automation/home-assistant/app/helmrelease.yaml`

Add the new persistence entry between `lovelace-maximalist` and `tmpfs`. The
`lovelace-maximalist` entry ends at line 166 (after `readOnly: true`). Insert:

```yaml
      psychrometry-assets:
        type: configMap
        name: home-assistant-psychrometry-assets
        advancedMounts:
          home-assistant:
            app:
              - path: /config/www/psychrometry-chart.svg
                subPath: psychrometry-chart.svg
                readOnly: true
              - path: /config/www/psychrometry-chart.css
                subPath: psychrometry-chart.css
                readOnly: true
```

The full persistence section after the change (lovelace-maximalist through tmpfs):
```yaml
      lovelace-maximalist:
        type: configMap
        name: home-assistant-lovelace-maximalist
        advancedMounts:
          home-assistant:
            app:
              - path: /config/packages/lovelace_maximalist.yaml
                subPath: lovelace_maximalist.yaml
                readOnly: true
      psychrometry-assets:
        type: configMap
        name: home-assistant-psychrometry-assets
        advancedMounts:
          home-assistant:
            app:
              - path: /config/www/psychrometry-chart.svg
                subPath: psychrometry-chart.svg
                readOnly: true
              - path: /config/www/psychrometry-chart.css
                subPath: psychrometry-chart.css
                readOnly: true
      tmpfs:
        type: emptyDir
        ...
```

- [ ] **Step 4: Commit and push vrtx-cluster**

```bash
cd /home/jsenecal/Code/vrtx-cluster
git add kubernetes/apps/home-automation/home-assistant/app/www/ \
        kubernetes/apps/home-automation/home-assistant/app/kustomization.yaml \
        kubernetes/apps/home-automation/home-assistant/app/helmrelease.yaml
git commit -m "feat(home-assistant): mount psychrometry chart assets via ConfigMap"
git push
```

Expected: `main -> main` push succeeds.

- [ ] **Step 5: Verify assets are served (wait ~60 s for Flux + HA pod restart)**

Flux will reconcile and update the ConfigMap. The HelmRelease has
`reloader.stakater.com/auto: "true"`, so the HA pod restarts automatically when the
ConfigMap is created.

Check that the SVG is accessible:
```
Open in browser: https://haus.mstrsmth.io/local/psychrometry-chart.svg
```

Expected: SVG renders in the browser as a psychrometric diagram with comfort zone
shading (blues, greens) and gridlines. If it returns 404, check HA pod logs for
startup errors.

---

## Task 2: HA prerequisites — thermal_comfort entries and ha-floorplan resource

Creates two new thermal_comfort config entries (Living Room and Bedroom) and registers
ha-floorplan as a Lovelace dashboard resource.

**Note:** The `thermal_comfort` integration cannot be created via the MCP config-flow
tool. Use browser automation to navigate to the HA integrations page and complete the
config flow UI for each entry — the same flow used in C1 for "Thermal Comfort Outdoor".

- [ ] **Step 1: Create "Thermal Comfort Living Room" via HA UI**

Navigate to: `https://haus.mstrsmth.io/config/integrations/add?domain=thermal_comfort`

Fill in the form:
- Name: `Thermal Comfort Living Room`
- Temperature sensor: `sensor.living_room_ths_temperature`
- Humidity sensor: `sensor.living_room_ths_humidity`
- Poll: off (toggle disabled)
- Scan interval: 30
- Custom icons: off

Submit. Expected: integration entry appears in the list.

- [ ] **Step 2: Create "Thermal Comfort Bedroom" via HA UI**

Navigate to: `https://haus.mstrsmth.io/config/integrations/add?domain=thermal_comfort`

Fill in the form:
- Name: `Thermal Comfort Bedroom`
- Temperature sensor: `sensor.aude_s_bedroom_ths_temperature`
- Humidity sensor: `sensor.aude_s_bedroom_ths_humidity`
- Poll: off (toggle disabled)
- Scan interval: 30
- Custom icons: off

Submit. Expected: integration entry appears in the list.

- [ ] **Step 3: Verify the four absolute_humidity entities exist and have numeric states**

```
ha_get_state(entity_id=[
  "sensor.thermal_comfort_outdoor_absolute_humidity",
  "sensor.thermal_comfort_office_absolute_humidity",
  "sensor.thermal_comfort_living_room_absolute_humidity",
  "sensor.thermal_comfort_bedroom_absolute_humidity"
])
```

Expected: all four return numeric states (e.g. 10.0, 12.2, 10.5, 11.8). If any return
`unknown` or `unavailable`, check that the correct temperature and humidity sensor
entity IDs were entered in the config flow.

- [ ] **Step 4: Find the ha-floorplan HACS resource URL**

```
ha_hacs_search(query="floorplan", category="lovelace", installed_only=True)
```

Look for the `ha-floorplan` entry and note its `frontend_path`. The resource URL will
be `/hacsfiles/<frontend_path>/ha-floorplan.js`. If HACS WebSocket fails, the URL is
most likely `/hacsfiles/ha-floorplan/ha-floorplan.js`.

- [ ] **Step 5: Register ha-floorplan as a dashboard resource**

```
ha_config_set_dashboard_resource(
  url="/hacsfiles/ha-floorplan/ha-floorplan.js",
  type="module"
)
```

(Replace the path if Step 4 returned a different frontend_path.)

- [ ] **Step 6: Verify ha-floorplan is in the resources list**

```
ha_config_list_dashboard_resources()
```

Expected: one entry with URL matching `/hacsfiles/ha-floorplan/ha-floorplan.js`.

---

## Task 3: View skeleton + registration

Creates a minimal "Environment" view with only the page title so the tab appears in
the dashboard and the include wiring can be verified before adding the chart.

**Files:**
- Create: `lovelace/ui/views/view-environment.yaml`
- Modify: `lovelace/lovelace-maximalist.yaml` (append 2 lines at current EOF line 1631)

- [ ] **Step 1: Create the view skeleton file**

Create `/home/jsenecal/Code/home-assistant-yaml/lovelace/ui/views/view-environment.yaml`
with this exact content:

```yaml
title: Environment
path: environment
type: 'custom:grid-layout'
layout: !include ui/shared/snippets/layout-page-margin.yaml
cards:
  - type: 'custom:layout-card'
    layout_type: 'custom:grid-layout'
    layout: !include ui/shared/snippets/layout-page-columns.yaml
    view_layout:
      grid-area: cc
    cards:

      - type: 'custom:layout-card'
        layout_type: 'custom:grid-layout'
        layout: !include ui/shared/snippets/layout-page-title.yaml
        view_layout:
          grid-column: 1/-1
        cards:
          - type: markdown
            style: !include ui/shared/snippets/style-markdown-page-title.yaml
            content: >
              # Environment
```

- [ ] **Step 2: Register the view in lovelace-maximalist.yaml**

Append these two lines to the end of
`/home/jsenecal/Code/home-assistant-yaml/lovelace/lovelace-maximalist.yaml`
(current EOF is line 1631):

```yaml

  - !include ui/views/view-environment.yaml
```

- [ ] **Step 3: Commit and push**

```bash
cd /home/jsenecal/Code/home-assistant-yaml
git add lovelace/ui/views/view-environment.yaml lovelace/lovelace-maximalist.yaml
git commit -m "feat(dashboard): add Environment view skeleton (C2)"
git push
```

Expected: `main -> main` push succeeds.

- [ ] **Step 4: Verify the tab appears (wait ~35 s for git-sync)**

Open `https://haus.mstrsmth.io/maximalist/environment` in a browser. The page should
load with only the "# Environment" heading — no chart yet.

If the page gives a 404 or the tab is missing, check HA logs:
`ha_get_logs(integration="lovelace")` — a YAML parse error will be shown there.

---

## Task 4: Full view — floorplan card and perception table

Adds the psychrometric chart floorplan card and the zone perception summary table to
the Environment view.

**Files:**
- Modify: `lovelace/ui/views/view-environment.yaml` (replace skeleton with full content)

- [ ] **Step 1: Write the full view-environment.yaml**

Replace `/home/jsenecal/Code/home-assistant-yaml/lovelace/ui/views/view-environment.yaml`
with this exact content:

```yaml
title: Environment
path: environment
type: 'custom:grid-layout'
layout: !include ui/shared/snippets/layout-page-margin.yaml
cards:
  - type: 'custom:layout-card'
    layout_type: 'custom:grid-layout'
    layout: !include ui/shared/snippets/layout-page-columns.yaml
    view_layout:
      grid-area: cc
    cards:

      - type: 'custom:layout-card'
        layout_type: 'custom:grid-layout'
        layout: !include ui/shared/snippets/layout-page-title.yaml
        view_layout:
          grid-column: 1/-1
        cards:
          - type: markdown
            style: !include ui/shared/snippets/style-markdown-page-title.yaml
            content: >
              # Environment

      # [Section] Psychrometry chart

      - type: 'custom:floorplan-card'
        view_layout:
          grid-column: 1/-1
        config:
          image:
            location: /local/psychrometry-chart.svg
            cache: false
          stylesheet: /local/psychrometry-chart.css
          defaults:
            hover_action: hover-info
            tap_action: more-info
          rules:
            - entity: sensor.outdoor_temperature
              state_action:
                action: call-service
                service: floorplan.style_set
                service_data:
                  element: indicator-outdoor
                  style: |
                    >
                    var x = (parseFloat(entity.state) + 20) / 65 * 1007 - 229;
                    var y = 665 - (parseFloat(states['sensor.thermal_comfort_outdoor_absolute_humidity'].state) / 35 * 665) - 155;
                    return `transform: translate(${x}px, ${y}px);`;

            - entity: sensor.office_ths_temperature
              state_action:
                action: call-service
                service: floorplan.style_set
                service_data:
                  element: indicator-workspace
                  style: |
                    >
                    var x = (parseFloat(entity.state) + 20) / 65 * 1007 - 256;
                    var y = 665 - (parseFloat(states['sensor.thermal_comfort_office_absolute_humidity'].state) / 35 * 665) - 10;
                    return `transform: translate(${x}px, ${y}px);`;

            - entity: sensor.living_room_ths_temperature
              state_action:
                action: call-service
                service: floorplan.style_set
                service_data:
                  element: indicator-livingroom
                  style: |
                    >
                    var x = (parseFloat(entity.state) + 20) / 65 * 1007 - 11;
                    var y = 665 - (parseFloat(states['sensor.thermal_comfort_living_room_absolute_humidity'].state) / 35 * 665) - 10;
                    return `transform: translate(${x}px, ${y}px);`;

            - entity: sensor.aude_s_bedroom_ths_temperature
              state_action:
                action: call-service
                service: floorplan.style_set
                service_data:
                  element: indicator-bedroom
                  style: |
                    >
                    var x = (parseFloat(entity.state) + 20) / 65 * 1007 - 237;
                    var y = 665 - (parseFloat(states['sensor.thermal_comfort_bedroom_absolute_humidity'].state) / 35 * 665) - 155;
                    return `transform: translate(${x}px, ${y}px);`;

      # [Section] Zone perception summary

      - type: markdown
        view_layout:
          grid-column: 1/-1
        content: |
          | Zone | Comfort |
          |---|---|
          | Outdoor | {{ states('sensor.thermal_comfort_outdoor_humidex_perception') | regex_replace(find='_', replace=' ') | title }} |
          | Office | {{ states('sensor.thermal_comfort_office_humidex_perception') | regex_replace(find='_', replace=' ') | title }} |
          | Living Room | {{ states('sensor.thermal_comfort_living_room_humidex_perception') | regex_replace(find='_', replace=' ') | title }} |
          | Bedroom | {{ states('sensor.thermal_comfort_bedroom_humidex_perception') | regex_replace(find='_', replace=' ') | title }} |
```

- [ ] **Step 2: Commit and push**

```bash
cd /home/jsenecal/Code/home-assistant-yaml
git add lovelace/ui/views/view-environment.yaml
git commit -m "feat(dashboard): add psychrometry chart and perception table to Environment view"
git push
```

Expected: `main -> main` push succeeds.

- [ ] **Step 3: Verify the chart renders (wait ~35 s for git-sync)**

Navigate to `https://haus.mstrsmth.io/maximalist/environment`.

Check each element:
- **Chart**: psychrometric diagram loads — comfort zone shading (blues/greens),
  temperature gridlines on X axis, humidity gridlines on Y axis
- **Indicator dots**: four dots appear at reasonable positions. Indoor zones
  (office, living room, bedroom) should cluster in the ~20–25 °C / 8–14 g/m³ region.
  Outdoor dot reflects current outdoor temperature.
- **Perception table**: four rows with non-`unknown` comfort labels (e.g. "Comfortable",
  "Very Comfortable", etc.)
- **Dark-mode filter**: Metrology theme's filter applies to the chart colours

If indicators do not appear: open browser devtools → Console and look for errors from
`ha-floorplan`. A common cause is the ha-floorplan resource not being registered; verify
with `ha_config_list_dashboard_resources()`.

If `indicator-bedroom` or `indicator-livingroom` show `unknown` in the perception table:
the thermal_comfort entries from Task 2 may not have finished initialising — wait 30 s
and reload.

---

## Spec Discrepancy Note

The thermal_comfort entry named "Thermal Comfort Bedroom" will produce entities with
prefix `sensor.thermal_comfort_bedroom_*`. If Aude's bedroom later gets a sibling sensor
(Albert's bedroom), a second entry named "Thermal Comfort Albert Bedroom" can be added
and wired to the unused `indicator-indoor` or `indicator-bathroom` SVG elements.
