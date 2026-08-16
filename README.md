# Radar — Environment Canada radar widget for the Omarchy bar

An [Omarchy](https://omarchy.org/) shell bar widget that shows an animated
weather radar loop from Environment and Climate Change Canada, centred on
Toronto by default. A 󰐷 pill sits in the status bar; clicking it opens a
panel with the last ~72 minutes of precipitation radar animated over a
Government of Canada basemap.

![Radar panel showing the Greater Toronto Area](docs/screenshot.png)

## Features

- **Animated loop** — 12 frames at Environment Canada's native 6-minute
  cadence (~72 minutes of history), with a hold on the newest frame before
  the loop rewinds.
- **Real basemap** — NRCan's CBMT cartographic basemap under the radar
  layer, pixel-aligned via matching WMS bounding boxes, with a marker at
  the configured location.
- **Always warm** — the widget prefetches frames at shell startup and
  refreshes in the background every 30 minutes, so the panel opens
  instantly. Opening it also triggers an immediate refresh, so what you
  see is never staler than the radar's own publishing lag. Overlapping
  frames are served from Qt's pixmap cache; only genuinely new timestamps
  are downloaded.
- **Dark basemap** — on a dark desktop the bright CBMT paper map is run
  through an invert + 180° hue-rotate shader, so opening the panel doesn't
  flash white. Water stays blue, roads stay yellow, and the radar returns
  above it are left untouched. Follows the desktop's light/dark setting
  live; see `darkMap` below.
- **Graceful degradation** — on fetch failure the last loop stays visible
  with an "Offline" note; partial frame failures are counted in the
  footer.

## Interactions

| Input | Action |
|---|---|
| Left-click pill | Toggle panel |
| Middle-click pill / `R` | Refresh now |
| Click map / Space / Enter | Play & pause |
| `←` / `→` | Step frames (auto-pauses) |
| Esc | Close panel |
| Tab / Shift-Tab | Switch to adjacent bar panels |

## Install

The directory name must match the plugin id (`andrew.radar`):

```bash
git clone <this repo> ~/.config/omarchy/plugins/andrew.radar
omarchy plugin enable andrew.radar --section center --after omarchy.weather
```

The Omarchy shell hot-reloads plugins; no restart needed. Adjust the
placement flags to taste (see `omarchy plugin enable --help`).

## Configuration

Settings go on the widget's layout entry in `~/.config/omarchy/shell.json`.
All keys are optional; defaults shown:

```json
{
  "id": "andrew.radar",
  "latitude": 43.65,
  "longitude": -79.38,
  "spanKm": 280,
  "locationName": "Toronto",
  "frames": 12,
  "frameMs": 250,
  "holdMs": 1000,
  "pollMinutes": 30,
  "darkMap": "auto"
}
```

- `latitude` / `longitude` / `locationName` — map centre and header label.
  Works anywhere with Canadian radar coverage.
- `spanKm` — east–west width of the map in kilometres.
- `frames` — loop length (6 minutes of history per frame, up to the 3-hour
  window GeoMet serves).
- `frameMs` / `holdMs` — animation speed and newest-frame hold.
- `pollMinutes` — background refresh cadence while the panel is closed.
- `darkMap` — `auto` (follow the desktop), `on`, or `off`. Unknown values
  fall back to `auto`.

Dark mode is detected from Qt's `Application.styleHints.colorScheme`, which
the platform theme (gtk3) feeds from the same
`org.gnome.desktop.interface color-scheme` key omarchy sets when you switch
themes — so the map flips as soon as the theme does, without a restart. If
no platform theme answers, the widget falls back to the luminance of the
shell theme's background colour, using the same `R+G+B > 382` rule as
`omarchy-theme-color`.

## How it works

Two WMS services, no API keys:

- **Radar**: [MSC GeoMet](https://eccc-msc.github.io/open-data/msc-geomet/readme_en/)
  layer `RADAR_1KM_RRAI` (1 km rain-rate composite). The available time
  window is discovered from `GetCapabilities`, then one transparent PNG is
  fetched per 6-minute timestamp.
- **Basemap**: NRCan's
  [CBMT](https://www.nrcan.gc.ca/earth-sciences/geography/topographic-information/web-services/9110)
  WMS, requested with the same `EPSG:4326` bounding box so the layers
  stack exactly.

The dark basemap is a small `ShaderEffect` applied as the basemap `Image`'s
`layer.effect` (only when it is actually on — in light mode the layer is
disabled and the render path is unchanged). Qt needs shaders precompiled, so
`shaders/darkmap.frag.qsb` is committed alongside its GLSL source; rebuild it
with `shaders/build.sh` (needs `qt6-shadertools`) after editing the `.frag`.

The panel is a Quickshell/QML component following the Omarchy shell's
`bar-widget` plugin contract (`manifest.json` + `BarWidget.qml` +
`Panel.qml`, modelled on the built-in `omarchy.weather` plugin). All
fetches are asynchronous — QML's `XMLHttpRequest` for capabilities and
network-sourced `Image` elements (decoded off the main thread) for frames
— so the bar never blocks.

Radar data: [Environment and Climate Change Canada](https://weather.gc.ca/).
Basemap: Natural Resources Canada. This project is not affiliated with
either.
