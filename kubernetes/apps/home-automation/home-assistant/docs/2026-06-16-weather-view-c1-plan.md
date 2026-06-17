# C1 Weather View Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Weather view to the Maximalist YAML-mode dashboard showing current outdoor conditions, a thermal-comfort indicator, hourly/daily forecast charts, and a sun elevation chart.

**Architecture:** One new file (`lovelace/ui/views/view-weather.yaml`) registered via a single `!include` line appended to `lovelace-maximalist.yaml`. The view reuses the same outer grid-layout pattern as all other views (Kitchen, Living Room, etc.) and the three existing apexcharts templates (`weather_chart`, `weather_daily_chart`, `sun_elevation`). All work is in the `jsenecal/home-assistant-yaml` repo; HA picks up changes automatically via git-sync (30 s polling).

**Tech Stack:** Home Assistant YAML-mode Lovelace, custom:layout-card, custom:grid-layout, weather-forecast card, custom:apexcharts-card, card_mod, thermal_comfort integration (already configured: "Thermal Comfort Outdoor"), PirateWeather (`weather.weather`).

---

## Prerequisites (confirm before starting)

- `sensor.thermal_comfort_outdoor_humidex_perception` exists and is not `unavailable`
  — check: `ha_get_state(entity_id="sensor.thermal_comfort_outdoor_humidex_perception")`
- `sensor.thermal_comfort_outdoor_heat_index` exists
- `sensor.thermal_comfort_outdoor_dew_point` exists
- `weather.weather` (PirateWeather) is available

All four were confirmed live at plan-writing time (2026-06-16).

---

## File Structure

```
home-assistant-yaml/          ← git remote: origin/main, cloned at /home/jsenecal/Code/home-assistant-yaml
└── lovelace/
    ├── lovelace-maximalist.yaml          MODIFY: append one !include line (line 1629 is current EOF)
    └── ui/
        └── views/                        CREATE directory (does not exist)
            └── view-weather.yaml         CREATE: full view definition (~80 lines)
```

The `ui/shared/snippets/` and `ui/templates/apexcharts-card.yaml` files are **read-only** references — do not modify them.

---

## Task 1: View skeleton + registration

Creates a minimal "Weather" view with only the page title so the tab appears in the
dashboard and the include wiring can be verified before adding content.

**Files:**
- Create: `lovelace/ui/views/view-weather.yaml`
- Modify: `lovelace/lovelace-maximalist.yaml` (append 2 lines)

- [ ] **Step 1: Create the view skeleton file**

Create `/home/jsenecal/Code/home-assistant-yaml/lovelace/ui/views/view-weather.yaml`
with this exact content:

```yaml
title: Weather
path: weather
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
              # Weather
```

- [ ] **Step 2: Register the view in lovelace-maximalist.yaml**

Append these two lines to the end of
`/home/jsenecal/Code/home-assistant-yaml/lovelace/lovelace-maximalist.yaml`
(current EOF is line 1629):

```yaml

  - !include ui/views/view-weather.yaml
```

- [ ] **Step 3: Commit and push**

```bash
cd /home/jsenecal/Code/home-assistant-yaml
git add lovelace/ui/views/view-weather.yaml lovelace/lovelace-maximalist.yaml
git commit -m "feat(dashboard): add Weather view skeleton (C1)"
git push
```

Expected output: `main -> main` push succeeds.

- [ ] **Step 4: Verify the tab appears (wait ~35 s for git-sync)**

Open `https://haus.mstrsmth.io/maximalist/weather` in a browser (or navigate to the
Maximalist dashboard and look for the "Weather" tab). The page should load with only
the "# Weather" heading — no content cards yet.

If the page gives a 404 or the tab is missing, check HA logs:
`ha_get_logs(integration="lovelace")` — a YAML parse error will be shown there.

---

## Task 2: Current conditions row

Adds three side-by-side tiles: the native weather card (current state + hourly strip),
an extra-attributes markdown tile, and a thermal-comfort indicator tile.

**Files:**
- Modify: `lovelace/ui/views/view-weather.yaml` (append cards to the `cards:` list)

- [ ] **Step 1: Append the current conditions section**

Add the following block inside `view-weather.yaml`, after the page-title `layout-card`
block (i.e., as the next sibling item in the inner `cards:` list under the
`layout-page-columns` layout-card):

```yaml

      # [Section] Current conditions

      - type: weather-forecast
        entity: weather.weather
        forecast_type: hourly
        show_forecast: true

      - type: markdown
        content: >
          **Feels like** {{ state_attr('weather.weather', 'apparent_temperature') | round(1) }} °C

          **Wind** {{ state_attr('weather.weather', 'wind_speed') | round(0) }} km/h
          *(gusts {{ state_attr('weather.weather', 'wind_gust_speed') | round(0) }} km/h)*

          **UV Index** {{ state_attr('weather.weather', 'uv_index') }}

          **Dew point** {{ states('sensor.thermal_comfort_outdoor_dew_point') | round(1) }} °C

          **Ozone** {{ state_attr('weather.weather', 'ozone') }}

      - type: markdown
        content: >
          ## {{ states('sensor.thermal_comfort_outdoor_humidex_perception') | title }}

          Feels like **{{ states('sensor.thermal_comfort_outdoor_heat_index') | round(1) }} °C**
```

The complete `view-weather.yaml` should now look like this (full file):

```yaml
title: Weather
path: weather
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
              # Weather

      # [Section] Current conditions

      - type: weather-forecast
        entity: weather.weather
        forecast_type: hourly
        show_forecast: true

      - type: markdown
        content: >
          **Feels like** {{ state_attr('weather.weather', 'apparent_temperature') | round(1) }} °C

          **Wind** {{ state_attr('weather.weather', 'wind_speed') | round(0) }} km/h
          *(gusts {{ state_attr('weather.weather', 'wind_gust_speed') | round(0) }} km/h)*

          **UV Index** {{ state_attr('weather.weather', 'uv_index') }}

          **Dew point** {{ states('sensor.thermal_comfort_outdoor_dew_point') | round(1) }} °C

          **Ozone** {{ state_attr('weather.weather', 'ozone') }}

      - type: markdown
        content: >
          ## {{ states('sensor.thermal_comfort_outdoor_humidex_perception') | title }}

          Feels like **{{ states('sensor.thermal_comfort_outdoor_heat_index') | round(1) }} °C**
```

- [ ] **Step 2: Commit and push**

```bash
cd /home/jsenecal/Code/home-assistant-yaml
git add lovelace/ui/views/view-weather.yaml
git commit -m "feat(dashboard): add current conditions row to Weather view"
git push
```

- [ ] **Step 3: Verify current conditions (wait ~35 s)**

Navigate to `https://haus.mstrsmth.io/maximalist/weather`.

Check each tile:
- **Weather card**: shows condition icon, current temperature, compact hourly strip
- **Extra-attrs tile**: shows apparent temperature, wind speed + gusts, UV index, dew point, ozone — all with real numeric values (not `None` or `unknown`)
- **Comfort tile**: shows a perception label ("Comfortable", "Slightly cool", etc.) as an `##` heading, and a "Feels like X °C" line below

If any value shows `unknown`: run `ha_get_state` on that entity to confirm it exists and has a non-null state.

---

## Task 3: Forecast and sun charts

Adds three full-width charts beneath the conditions row: hourly temperature + precipitation,
5-day high/low + precipitation, and today's sun elevation arc.

**Files:**
- Modify: `lovelace/ui/views/view-weather.yaml` (append three chart cards)

- [ ] **Step 1: Append the chart section**

Add the following block to `view-weather.yaml` after the three conditions tiles
(i.e., after the comfort-indicator markdown card, still inside the inner `cards:` list):

```yaml

      # [Section] Charts

      - type: 'custom:apexcharts-card'
        template: weather_chart
        view_layout:
          grid-column: 1/-1
        header:
          title: Hourly Forecast
          show: true
          show_states: false
        yaxis:
          - id: temp
            show: true
            decimals: 0
            apex_config:
              labels:
                offsetX: 24
          - id: precip
            opposite: true
            min: 0
            max: 100
            show: true
            decimals: 0
        series:
          - entity: weather.weather
            name: Temperature
            yaxis_id: temp
            forecast:
              type: hourly
              attribute: temperature
            unit: '°C'
          - entity: weather.weather
            name: Rain %
            yaxis_id: precip
            type: column
            opacity: 0.3
            stroke_width: 0
            forecast:
              type: hourly
              attribute: precipitation_probability
            unit: '%'

      - type: 'custom:apexcharts-card'
        template: weather_daily_chart
        view_layout:
          grid-column: 1/-1
        header:
          title: 5-Day Forecast
          show: true
          show_states: false
        yaxis:
          - id: temp
            show: true
            decimals: 0
          - id: precip
            opposite: true
            min: 0
            max: 100
            show: false
        series:
          - entity: weather.weather
            name: High
            type: column
            yaxis_id: temp
            forecast:
              type: daily
              attribute: temperature
            unit: '°C'
          - entity: weather.weather
            name: Low
            type: column
            yaxis_id: temp
            forecast:
              type: daily
              attribute: templow
            unit: '°C'
          - entity: weather.weather
            name: Rain %
            type: column
            yaxis_id: precip
            opacity: 0.3
            stroke_width: 0
            forecast:
              type: daily
              attribute: precipitation_probability
            unit: '%'

      - type: 'custom:apexcharts-card'
        template: sun_elevation
        view_layout:
          grid-column: 1/-1
```

The complete final `view-weather.yaml` (full file for reference):

```yaml
title: Weather
path: weather
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
              # Weather

      # [Section] Current conditions

      - type: weather-forecast
        entity: weather.weather
        forecast_type: hourly
        show_forecast: true

      - type: markdown
        content: >
          **Feels like** {{ state_attr('weather.weather', 'apparent_temperature') | round(1) }} °C

          **Wind** {{ state_attr('weather.weather', 'wind_speed') | round(0) }} km/h
          *(gusts {{ state_attr('weather.weather', 'wind_gust_speed') | round(0) }} km/h)*

          **UV Index** {{ state_attr('weather.weather', 'uv_index') }}

          **Dew point** {{ states('sensor.thermal_comfort_outdoor_dew_point') | round(1) }} °C

          **Ozone** {{ state_attr('weather.weather', 'ozone') }}

      - type: markdown
        content: >
          ## {{ states('sensor.thermal_comfort_outdoor_humidex_perception') | title }}

          Feels like **{{ states('sensor.thermal_comfort_outdoor_heat_index') | round(1) }} °C**

      # [Section] Charts

      - type: 'custom:apexcharts-card'
        template: weather_chart
        view_layout:
          grid-column: 1/-1
        header:
          title: Hourly Forecast
          show: true
          show_states: false
        yaxis:
          - id: temp
            show: true
            decimals: 0
            apex_config:
              labels:
                offsetX: 24
          - id: precip
            opposite: true
            min: 0
            max: 100
            show: true
            decimals: 0
        series:
          - entity: weather.weather
            name: Temperature
            yaxis_id: temp
            forecast:
              type: hourly
              attribute: temperature
            unit: '°C'
          - entity: weather.weather
            name: Rain %
            yaxis_id: precip
            type: column
            opacity: 0.3
            stroke_width: 0
            forecast:
              type: hourly
              attribute: precipitation_probability
            unit: '%'

      - type: 'custom:apexcharts-card'
        template: weather_daily_chart
        view_layout:
          grid-column: 1/-1
        header:
          title: 5-Day Forecast
          show: true
          show_states: false
        yaxis:
          - id: temp
            show: true
            decimals: 0
          - id: precip
            opposite: true
            min: 0
            max: 100
            show: false
        series:
          - entity: weather.weather
            name: High
            type: column
            yaxis_id: temp
            forecast:
              type: daily
              attribute: temperature
            unit: '°C'
          - entity: weather.weather
            name: Low
            type: column
            yaxis_id: temp
            forecast:
              type: daily
              attribute: templow
            unit: '°C'
          - entity: weather.weather
            name: Rain %
            type: column
            yaxis_id: precip
            opacity: 0.3
            stroke_width: 0
            forecast:
              type: daily
              attribute: precipitation_probability
            unit: '%'

      - type: 'custom:apexcharts-card'
        template: sun_elevation
        view_layout:
          grid-column: 1/-1
```

- [ ] **Step 2: Commit and push**

```bash
cd /home/jsenecal/Code/home-assistant-yaml
git add lovelace/ui/views/view-weather.yaml
git commit -m "feat(dashboard): add forecast and sun charts to Weather view"
git push
```

- [ ] **Step 3: Verify all charts (wait ~35 s)**

Navigate to `https://haus.mstrsmth.io/maximalist/weather`.

Check each chart:
- **Hourly chart**: two series visible — a smooth temperature line + semi-transparent
  precipitation columns. Chart spans 24 h with past left of now-line and forecast right.
- **Daily chart**: column bars for 5 days, high and low temperature visible as grouped
  or overlapping columns. Day labels (MON, TUE, etc.) on x-axis.
- **Sun elevation chart**: today's arc of `sensor.sun_elevation` visible; the baseline
  zero-line divides the chart into above/below horizon.
- Metro card-mod styling (dark background, `var(--font-stack)` labels) applies to all
  three charts.

If a chart shows "No data" or spinner: run `ha_get_state(entity_id="weather.weather")`
to confirm the entity is responsive, and check that `apexcharts-card` HACS custom card
is installed.

If chart series are blank but no error: the `forecast` key in apexcharts-card requires
apexcharts-card ≥ 2.9.0. Check the installed version in HACS.

---

## Spec Discrepancy Note

The design spec (`2026-06-16-weather-view-c1-design.md`) referenced
`sensor.thermal_comfort_outdoor_thermal_perception` as the comfort label entity.
That entity does not exist. The Thermal Comfort integration creates
`sensor.thermal_comfort_outdoor_humidex_perception` (and `dew_point_perception`) as
the human-readable comfort labels. This plan uses `humidex_perception` which was
confirmed live at 2026-06-16 with state "comfortable".
