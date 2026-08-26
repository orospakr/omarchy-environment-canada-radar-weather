# Radar — Environment Canada radar widget for the Omarchy bar

An [Omarchy](https://omarchy.org/) shell bar widget that shows an animated
weather radar loop from Environment and Climate Change Canada. A 󰐷 pill
sits in the status bar; clicking it opens a panel with the last ~72 minutes
of precipitation radar animated over a Government of Canada basemap, with
location tabs along the top: **Auto** (geoip-detected) plus any cities you
add from Environment Canada's official site list.

![Radar panel showing the Greater Toronto Area](docs/screenshot.png)

## Features

- **Location tabs** — a segmented control across the top of the panel.
  **Auto** locates you through [BeaconDB](https://beacondb.net/)'s geoip
  fallback (a coarse ~25 km fix — exactly the granularity a 280 km radar
  view needs, with no Geoclue/portal dependency) and names the fix after
  the nearest Environment Canada site. Further tabs are cities you pick;
  **+** opens a searchable list of all ~855 citypage sites.
- **Star to manage** — in the "+" search popup every row carries a star:
  starred cities are your tabs. Toggle the star (click, or `s` on the
  highlighted row) to add/remove without leaving the popup; activating a
  row body adds the city and switches straight to it. Right-clicking a
  city tab offers **Remove**.
- **Animated loop** — 12 frames at Environment Canada's native 6-minute
  cadence (~72 minutes of history), with a hold on the newest frame before
  the loop rewinds.
- **Real basemap** — NRCan's CBMT cartographic basemap under the radar
  layer, pixel-aligned via matching WMS bounding boxes, with a marker at
  the active location (for Auto: the geoip fix itself).
- **Always warm** — the widget prefetches frames at shell startup and
  refreshes in the background every 30 minutes, so the panel opens
  instantly. Opening it also triggers an immediate refresh, so what you
  see is never staler than the radar's own publishing lag. Frames are
  served from Qt's pixmap cache, so switching back to an already-viewed
  tab costs no downloads.
- **Dark basemap** — on a dark desktop the bright CBMT paper map is run
  through an invert + 180° hue-rotate shader, so opening the panel doesn't
  flash white. Water stays blue, roads stay yellow, and the radar returns
  above it are left untouched. Follows the desktop's light/dark setting
  live; see `darkMap` below.
- **Graceful degradation** — on fetch failure the last loop stays visible
  with an "Offline" note; partial frame failures are counted in the
  footer. The last good geoip fix is cached, so Auto works offline too.

## Interactions

| Input | Action |
|---|---|
| Left-click pill | Toggle panel |
| Middle-click pill / `R` | Refresh now (radar + geoip fix) |
| Click a tab | Switch location |
| `1`–`9` | Jump to tab (1 = Auto) |
| Right-click a city tab / `x` | Remove that city (via context menu) |
| Drag a city tab | Reorder your cities |
| `+` tab / `a` | Search & manage cities (star = keep as tab) |
| Click map / Space / Enter | Play & pause |
| `←` / `→` | Step frames (auto-pauses) |
| Esc | Close panel (or the open popup) |
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

Locations are managed from the panel itself and persisted by the shell onto
the widget's layout entry in `~/.config/omarchy/shell.json`:

```json
{
  "id": "andrew.radar",
  "locations": [
    { "siteCode": "s0000623", "name": "Ottawa (Kanata - Orléans)", "province": "ON",
      "latitude": 45.42, "longitude": -75.69 }
  ],
  "active": "auto",
  "autoFix": { "latitude": 45.03, "longitude": -79.32, "accuracy": 25000, "at": 1755820000000 }
}
```

- `locations` / `active` — the city tabs and the selected one (`"auto"` or
  a `siteCode`). Written by the panel; hand-editing works too and
  hot-reloads.
- `autoFix` — cached result of the last BeaconDB lookup (refreshed at most
  hourly), so the Auto tab renders immediately after a shell restart.

Entries from older versions that set `latitude` / `longitude` /
`locationName` directly are migrated automatically into a single saved
city on first load.

The remaining tuning keys are optional; defaults shown:

```json
{
  "spanKm": 280,
  "frames": 12,
  "frameMs": 250,
  "holdMs": 1000,
  "pollMinutes": 30,
  "darkMap": "auto"
}
```

- `spanKm` — east–west width of the map in kilometres (applies to every
  tab).
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

Three services, no API keys:

- **Radar**: [MSC GeoMet](https://eccc-msc.github.io/open-data/msc-geomet/readme_en/)
  layer `RADAR_1KM_RRAI` (1 km rain-rate composite). The available time
  window is discovered from `GetCapabilities` — it is global to the layer,
  so switching tabs never re-asks — then one transparent PNG is fetched
  per 6-minute timestamp for the active bbox.
- **Basemap**: NRCan's
  [CBMT](https://www.nrcan.gc.ca/earth-sciences/geography/topographic-information/web-services/9110)
  WMS, requested with the same `EPSG:4326` bounding box so the layers
  stack exactly.
- **Auto location**: [BeaconDB](https://beacondb.net/)'s
  `/v1/geolocate` fallback (an MLS-compatible endpoint; an empty request
  body means "locate by IP"). City search uses the
  [citypage site list](https://dd.weather.gc.ca/today/citypage_weather/docs/)
  — a snapshot is bundled in `data/` for offline use and a copy in
  `~/.cache/omarchy/andrew.radar/` is refreshed monthly.

The dark basemap is a small `ShaderEffect` applied as the basemap `Image`'s
`layer.effect` (only when it is actually on — in light mode the layer is
disabled and the render path is unchanged). Qt needs shaders precompiled, so
`shaders/darkmap.frag.qsb` is committed alongside its GLSL source; rebuild it
with `shaders/build.sh` (needs `qt6-shadertools`) after editing the `.frag`.

The panel is a Quickshell/QML component following the Omarchy shell's
`bar-widget` plugin contract (`manifest.json` + `BarWidget.qml` +
`Panel.qml`, modelled on the built-in `omarchy.weather` plugin). All
fetches are asynchronous — QML's `XMLHttpRequest` for capabilities,
`curl` subprocesses for geoip and the site list, and network-sourced
`Image` elements (decoded off the main thread) for frames — so the bar
never blocks.

Radar data: [Environment and Climate Change Canada](https://weather.gc.ca/).
Basemap: Natural Resources Canada. IP geolocation: BeaconDB (DB-IP data,
CC BY 4.0). This project is not affiliated with any of them.
