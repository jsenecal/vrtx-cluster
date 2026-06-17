# C2: Environment View Design

**Sub-project**: C2 of the Maximalist dashboard adaptation
**Parent design doc**: `2026-06-14-dashboard-adaptation-design.md`
**Dashboard repo**: `jsenecal/home-assistant-yaml`
**Date**: 2026-06-17

---

## Goal

Add an **Environment** view to the Maximalist YAML-mode dashboard displaying a live
psychrometric chart (Mollier diagram) with indicator dots for four zones — outdoor,
office, living room, and bedroom — positioned from real temperature and absolute
humidity readings. A summary table below the chart shows the humidex perception label
for each zone.

---

## Architecture

```
vrtx-cluster (K8s):
  ConfigMap: home-assistant-psychrometry-assets
    ├── psychrometry-chart.svg   (140 KB, from Madelena/hass-config-public pinned commit)
    └── psychrometry-chart.css
  HelmRelease persistence entries:
    /config/www/psychrometry-chart.svg   ← browser fetches as /local/psychrometry-chart.svg
    /config/www/psychrometry-chart.css   ← browser fetches as /local/psychrometry-chart.css

home-assistant-yaml:
  lovelace-maximalist.yaml          MODIFY: append one !include line
  lovelace/ui/views/view-environment.yaml  CREATE: full view definition
    └── custom:floorplan-card
          ├── image: /local/psychrometry-chart.svg
          ├── stylesheet: /local/psychrometry-chart.css
          └── rules: 4 indicator rules (outdoor, office, living room, bedroom)

HA (manual prerequisite — must be done before implementation):
  New thermal_comfort config entries via Settings → Devices & Services:
    "Thermal Comfort Living Room"  temp: sensor.living_room_ths_temperature
                                   humidity: sensor.living_room_ths_humidity
    "Thermal Comfort Bedroom"      temp: sensor.aude_s_bedroom_ths_temperature
                                   humidity: sensor.aude_s_bedroom_ths_humidity
```

All `!include` paths in `view-environment.yaml` resolve relative to
`/config/hass-config-src/repo/lovelace/` (how git-sync mounts the repo).

---

## Prerequisites

### Manual steps required before implementation

**1. Create two new Thermal Comfort config entries (HA UI):**

> **Settings → Devices & Services → Add Integration → "Thermal Comfort"**

Entry 1:
- Name: `Thermal Comfort Living Room`
- Temperature sensor: `sensor.living_room_ths_temperature`
- Humidity sensor: `sensor.living_room_ths_humidity`
- Poll: off | Scan interval: 30 | Custom icons: off

Entry 2:
- Name: `Thermal Comfort Bedroom`
- Temperature sensor: `sensor.aude_s_bedroom_ths_temperature`
- Humidity sensor: `sensor.aude_s_bedroom_ths_humidity`
- Poll: off | Scan interval: 30 | Custom icons: off

**2. Register ha-floorplan as a Lovelace resource (if not already done):**

The `ha-floorplan` HACS card must be registered as a dashboard resource. Find the
`hacstag` from the installed HACS entry and register via:
```
ha_config_set_dashboard_resource(url="/hacsfiles/ha-floorplan/ha-floorplan.js", type="module")
```

### Expected entities after prerequisites

| Entity | Source |
|---|---|
| `sensor.thermal_comfort_living_room_absolute_humidity` | new entry |
| `sensor.thermal_comfort_living_room_humidex_perception` | new entry |
| `sensor.thermal_comfort_bedroom_absolute_humidity` | new entry |
| `sensor.thermal_comfort_bedroom_humidex_perception` | new entry |

### Existing entities (confirmed live)

| Entity | State |
|---|---|
| `sensor.outdoor_temperature` | 17.3 °C |
| `sensor.thermal_comfort_outdoor_absolute_humidity` | 10.01 g/m³ |
| `sensor.thermal_comfort_outdoor_humidex_perception` | comfortable |
| `sensor.office_ths_temperature` | 22.56 °C |
| `sensor.thermal_comfort_office_absolute_humidity` | 12.21 g/m³ |
| `sensor.thermal_comfort_office_humidex_perception` | comfortable |
| `sensor.living_room_ths_temperature` | 23.5 °C |
| `sensor.living_room_ths_humidity` | 62 % |
| `sensor.aude_s_bedroom_ths_temperature` | 22.5 °C |
| `sensor.aude_s_bedroom_ths_humidity` | 66 % |

---

## File Layout

```
vrtx-cluster/
└── kubernetes/apps/home-automation/home-assistant/
    └── app/
        ├── helmrelease.yaml          MODIFY: add psychrometry-assets persistence entry
        ├── kustomization.yaml        MODIFY: add configMapGenerator
        └── www/
            ├── psychrometry-chart.svg   CREATE (downloaded from Madelena pinned commit)
            └── psychrometry-chart.css   CREATE (downloaded from Madelena pinned commit)

home-assistant-yaml/
└── lovelace/
    ├── lovelace-maximalist.yaml          MODIFY: append one !include line
    └── ui/views/
        └── view-environment.yaml         CREATE: full view definition
```

---

## Component Design

### 1. SVG Assets (ConfigMap)

Source: `Madelena/hass-config-public` at commit `a34865410ae96c4f5d26938d45115e88b8032bc6`
- `www/psychrometry-chart.svg` — 140 KB Inkscape SVG with pre-drawn comfort zones,
  gridlines, and six named indicator elements
- `www/psychrometry-chart.css` — 756 bytes; applies Metrology theme variables
  (`--primary-text-color`, `--dark-mode-filter`, `--font-stack`)

`kustomization.yaml` already has a `configMapGenerator` array and global
`generatorOptions: disableNameSuffixHash: true`. Add the new entry to that array:

```yaml
# Add inside the existing configMapGenerator array:
  - name: home-assistant-psychrometry-assets
    files:
      - psychrometry-chart.svg=./www/psychrometry-chart.svg
      - psychrometry-chart.css=./www/psychrometry-chart.css
```

The global `generatorOptions` (already present) handles `disableNameSuffixHash` and
the `kustomize.toolkit.fluxcd.io/substitute: disabled` annotation for all generators.

`helmrelease.yaml` persistence section gains:

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

### 2. Floorplan Card — Coordinate System

The SVG coordinate space is 1007 × 665 pixels (viewBox `5 40 1007 720`).

**Axes:**
- X: dry-bulb temperature, range −20 °C to +45 °C (span = 65 °C → 1007 px)
- Y: absolute humidity, range 0–35 g/m³, drawn bottom-to-top

**Position formula:**
```javascript
x = (temperature_°C + 20) / 65 * 1007 - x_offset
y = 665 - (absolute_humidity / 35 * 665) - y_offset
```

**Indicator mapping:**

| SVG element | Zone | x_offset | y_offset | Temperature entity | Abs. humidity entity |
|---|---|---|---|---|---|
| `indicator-outdoor` | Outdoor | 229 | 155 | `sensor.outdoor_temperature` | `sensor.thermal_comfort_outdoor_absolute_humidity` |
| `indicator-workspace` | Office | 256 | 10 | `sensor.office_ths_temperature` | `sensor.thermal_comfort_office_absolute_humidity` |
| `indicator-livingroom` | Living Room | 11 | 10 | `sensor.living_room_ths_temperature` | `sensor.thermal_comfort_living_room_absolute_humidity` |
| `indicator-bedroom` | Bedroom | 237 | 155 | `sensor.aude_s_bedroom_ths_temperature` | `sensor.thermal_comfort_bedroom_absolute_humidity` |

The offsets correct for each indicator element's initial position in the SVG.

### 3. Floorplan Card YAML

```yaml
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
```

### 4. Perception Summary Table

A `type: markdown` card full-width below the chart, using `<table>` HTML:

```yaml
- type: markdown
  view_layout:
    grid-column: 1/-1
  content: |
    | Zone | Comfort |
    |---|---|
    | Outdoor | {{ states('sensor.thermal_comfort_outdoor_humidex_perception') | regex_replace('_', ' ') | title }} |
    | Office | {{ states('sensor.thermal_comfort_office_humidex_perception') | regex_replace('_', ' ') | title }} |
    | Living Room | {{ states('sensor.thermal_comfort_living_room_humidex_perception') | regex_replace('_', ' ') | title }} |
    | Bedroom | {{ states('sensor.thermal_comfort_bedroom_humidex_perception') | regex_replace('_', ' ') | title }} |
```

### 5. view-environment.yaml Structure

Follows the exact same outer pattern as `view-weather.yaml`:

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

      - type: 'custom:layout-card'    # page title
        ...
        cards:
          - type: markdown
            content: '# Environment'

      - type: 'custom:floorplan-card' # psychrometry chart (full-width)
        ...

      - type: markdown                # perception table (full-width)
        ...
```

---

## Integration with lovelace-maximalist.yaml

Append one line after the Weather view include:

```yaml
  - !include ui/views/view-environment.yaml
```

---

## Verification

After implementation:

1. "Environment" tab appears in Maximalist dashboard navigation
2. Psychrometry chart loads — comfort zone shading and gridlines visible (dark-mode filter applies)
3. Four indicator dots appear at positions corresponding to current readings:
   - Indoor zones (office, living room, bedroom) cluster in the 20–25 °C / 8–14 g/m³ region
   - Outdoor dot moves with PirateWeather temperature
4. Hovering an indicator shows the entity's more-info popup
5. Summary table below the chart shows non-`unknown` perception labels for all four zones
6. No browser console errors for missing entities or floorplan elements

---

## Out of Scope

- Albert's bedroom: no THS sensor available; can be added later if a sensor is installed
- Additional rooms (bathroom, lobby, dining room, server rack): sensors exist but no thermal_comfort entries; add in a future pass if desired
- C3 — Floor plan view (ha-floorplan with home SVG layout)
