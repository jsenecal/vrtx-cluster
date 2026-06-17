# C1: Weather View Design

**Sub-project**: C1 of the Maximalist dashboard adaptation  
**Parent design doc**: `2026-06-14-dashboard-adaptation-design.md`  
**Dashboard repo**: `jsenecal/home-assistant-yaml`  
**Date**: 2026-06-16

---

## Goal

Add a **Weather** view to the Maximalist YAML-mode dashboard that shows current outdoor
conditions, a comfort/perception indicator derived from `thermal_comfort`, hourly and daily
forecast charts (via PirateWeather / `weather.weather`), and the sun elevation chart — all
using the established Metro/Maximalist card-mod styling already in place from sub-project 0.

---

## Architecture

The view follows the exact same pattern as every other Maximalist view (e.g. Kitchen):

```
lovelace-maximalist.yaml
  └── !include ui/views/view-weather.yaml
        └── custom:grid-layout  (layout-page-margin.yaml)
              └── custom:layout-card  (layout-page-columns.yaml, grid-area: cc)
                    ├── page-title block  ("# Weather")
                    ├── current-conditions row
                    │     ├── weather-forecast card (current state only)
                    │     ├── extra-attributes tile (apparent temp, wind gust, UV, ozone)
                    │     └── comfort-indicator tile (thermal perception text + heat index)
                    ├── hourly forecast chart  (reuse: weather_chart template)
                    ├── daily forecast chart   (reuse: weather_daily_chart template)
                    └── sun elevation chart    (reuse: sun_elevation template)
```

All `!include` paths in `view-weather.yaml` resolve relative to
`/config/hass-config-src/repo/lovelace/` (how git-sync mounts the repo into HA).

---

## Prerequisites

### Manual step required before implementation

The `thermal_comfort` config entry for outdoor sensors cannot be created via MCP
(the integration is not in the supported config-flow tool types). Before implementing
the dashboard view, the user must create it via the UI:

> **Settings → Devices & Services → Add Integration → "Thermal Comfort"**
> - Name: `Thermal Comfort Outdoor`
> - Temperature sensor: `sensor.outdoor_temperature`
> - Humidity sensor: `sensor.outdoor_humidity`
> - Poll: off  |  Scan interval: 30  |  Custom icons: off

The two bridge sensors (`sensor.outdoor_temperature`, `sensor.outdoor_humidity`) were
already created as template helpers via MCP (entry IDs `01KV9DC27ZT9Q42JD8EAA11AGZ` /
`01KV9DC4JJ91A0NKA59A5MY34E`) and are live.

### Entities created by the Thermal Comfort Outdoor entry

Expected entity IDs (pattern mirrors "Thermal Comfort Office"):

| Sensor | Entity ID | Used in view |
|---|---|---|
| Thermal Perception | `sensor.thermal_comfort_outdoor_thermal_perception` | comfort tile (main text) |
| Heat Index | `sensor.thermal_comfort_outdoor_heat_index` | comfort tile (value) |
| Dew Point | `sensor.thermal_comfort_outdoor_dew_point` | extra-attributes tile |
| Absolute Humidity | `sensor.thermal_comfort_outdoor_absolute_humidity` | not shown |
| Simmer Zone | `sensor.thermal_comfort_outdoor_simmer_zone` | not shown |

> **Note**: confirm actual entity IDs after creating the entry — thermal_comfort slugifies
> the config `name` field, so "Thermal Comfort Outdoor" → `thermal_comfort_outdoor_*`.

---

## Data Sources

| Entity | Platform | Used for |
|---|---|---|
| `weather.weather` | PirateWeather | Current conditions + hourly/daily forecasts |
| `sun.sun` | Sun | Sun elevation chart |
| `sensor.outdoor_temperature` | template | Bridge to thermal_comfort (not displayed) |
| `sensor.outdoor_humidity` | template | Bridge to thermal_comfort (not displayed) |
| `sensor.thermal_comfort_outdoor_thermal_perception` | thermal_comfort | Comfort label |
| `sensor.thermal_comfort_outdoor_heat_index` | thermal_comfort | Feels-like value |
| `sensor.thermal_comfort_outdoor_dew_point` | thermal_comfort | Dew point in extra-attrs tile |

Current `weather.weather` attributes available (confirmed via live HA):
`apparent_temperature`, `wind_gust_speed`, `ozone`, `uv_index`, `temperature`,
`humidity`, `wind_speed`, `wind_bearing`, `pressure`, `visibility`, `cloud_coverage`.

Daily forecast fields (confirmed via `weather.get_forecasts`):
`datetime`, `condition`, `precipitation_probability`, `cloud_coverage`, `wind_bearing`,
`uv_index`, `temperature`, `templow`, `dew_point`, `pressure`, `wind_gust_speed`,
`wind_speed`, `precipitation`, `humidity`.

---

## File Layout

```
home-assistant-yaml/
└── lovelace/
    ├── lovelace-maximalist.yaml          ← add !include for new view
    └── ui/
        ├── views/
        │   └── view-weather.yaml         ← NEW: full view definition
        └── templates/
            └── apexcharts-card.yaml      ← existing (no changes): sun_elevation,
                                             weather_chart, weather_daily_chart
```

The `ui/views/` directory does not exist yet and must be created.

---

## Component Design

### 1. Page Title Block

Standard pattern (identical to all other views):

```yaml
- type: 'custom:layout-card'
  layout_type: 'custom:grid-layout'
  layout: !include ui/shared/snippets/layout-page-title.yaml
  cards:
    - type: markdown
      content: '# Weather'
      card_mod:
        style: !include ui/shared/snippets/style-markdown-page-title.yaml
```

### 2. Current Conditions Row

Three tiles side-by-side inside a horizontal `custom:layout-card`:

#### 2a. Weather state card
`type: weather-forecast` pointing at `weather.weather`, `forecast_type: hourly`,
`show_forecast: true`. This card provides the native HA weather card with the
condition icon, current temperature, and a compact hourly strip.

#### 2b. Extra attributes tile
`type: markdown` showing:
- Apparent temperature: `{{ state_attr('weather.weather','apparent_temperature') }} °C`
- Wind: `{{ states('weather.weather') }}` direction + `{{ state_attr('weather.weather','wind_speed') }} km/h` gusts `{{ state_attr('weather.weather','wind_gust_speed') }}`
- UV Index: `{{ state_attr('weather.weather','uv_index') }}`
- Dew point: `{{ states('sensor.thermal_comfort_outdoor_dew_point') }} °C`
- Ozone: `{{ state_attr('weather.weather','ozone') }}`

Styled with Metro card-mod theme (card background, primary-text font stack).

#### 2c. Comfort indicator tile
`type: markdown` showing:
- Primary text: `{{ states('sensor.thermal_comfort_outdoor_thermal_perception') }}`
- Secondary: `Feels like {{ states('sensor.thermal_comfort_outdoor_heat_index') }} °C`

The thermal_perception state is a human-readable string like "Comfortable", "Warm",
"Slightly warm" — display it large (h2-level) with the heat index below as a subtitle.

### 3. Hourly Forecast Chart

Reuse existing `weather_chart` apexcharts template (already in `ui/templates/apexcharts-card.yaml`).
That template is a 24-hour span at 160px height with Metro card-mod styling.

```yaml
- type: 'custom:apexcharts-card'
  template: weather_chart
  header:
    title: Hourly
    show: true
  series:
    - entity: weather.weather
      name: Temperature
      forecast:
        type: hourly
        attribute: temperature
      unit: '°C'
    - entity: weather.weather
      name: Precipitation %
      forecast:
        type: hourly
        attribute: precipitation_probability
      unit: '%'
      y_axis_id: right
```

Exact series config to be finalized in the plan — the template defines span/height/styling,
the view only provides `series` and `header`.

### 4. Daily Forecast Chart

Reuse existing `weather_daily_chart` template (5-day span, day-grid, Metro styling).

```yaml
- type: 'custom:apexcharts-card'
  template: weather_daily_chart
  header:
    title: 5-Day Forecast
    show: true
  series:
    - entity: weather.weather
      name: High
      forecast:
        type: daily
        attribute: temperature
      unit: '°C'
    - entity: weather.weather
      name: Low
      forecast:
        type: daily
        attribute: templow
      unit: '°C'
    - entity: weather.weather
      name: Rain %
      forecast:
        type: daily
        attribute: precipitation_probability
      unit: '%'
      y_axis_id: right
```

### 5. Sun Elevation Chart

Reuse existing `sun_elevation` template unchanged:

```yaml
- type: 'custom:apexcharts-card'
  template: sun_elevation
```

No series overrides needed — the template is self-contained.

---

## Integration with lovelace-maximalist.yaml

Add one line to the `views:` list in `lovelace-maximalist.yaml`, after the existing
room views and before any utility views:

```yaml
  - !include ui/views/view-weather.yaml
```

The `!include` path resolves from the `lovelace/` root (same as all other includes in
the file).

---

## Apexcharts Template Contract

The three reused templates are in `lovelace/ui/templates/apexcharts-card.yaml`.
Relevant contracts (do not override these in the view):

| Template | Span | Height | Card-mod |
|---|---|---|---|
| `sun_elevation` | 24h | auto | Metro dark-mode filter |
| `weather_chart` | 24h | 160px | Metro dark-mode filter |
| `weather_daily_chart` | 126h (~5 days) | 160px | Metro dark-mode + day grid |

The view may override `header`, `series`, and `apex_config.yaxis` only.

---

## Verification

After implementation:

1. Reload the Maximalist dashboard in HA — "Weather" tab appears in navigation
2. Current conditions row: weather card shows condition + current temp; extra-attrs tile
   shows apparent temp, wind, UV, dew point, ozone; comfort tile shows perception label
   and feels-like temperature
3. Hourly chart: 24 data points visible, temperature + precipitation % series
4. Daily chart: 5 bars/days visible, high/low/rain series
5. Sun elevation chart: renders today's arc
6. No `Entity not available` errors in browser console (thermal_comfort entry must be
   created first)
7. Dark-mode filter applies correctly on charts (verify by switching HA theme)

---

## Out of Scope (future phases)

- **C2 — Psychrometry chart**: `ha-floorplan` card overlaying `psychrometry-chart.svg`
  with thermal_comfort-derived comfort zone marker positions
- **C3 — Floor plan**: `ha-floorplan` card with user-provided SVG of home layout
