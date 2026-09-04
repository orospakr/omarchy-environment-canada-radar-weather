import QtQuick
import QtQuick.Controls as QQC
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model
import "Weather.js" as Weather
import "Lightning.js" as Lightning

// Animated Environment and Climate Change Canada radar loop.
//
// Two WMS sources are stacked at the exact same bbox so they line up pixel
// for pixel: the CBMT base map from GeoGratis underneath, and a preloaded
// stack of RADAR_1KM_RRAI rain-rate frames on top. Only the active frame is
// opaque — switching opacity on already-decoded images is what keeps the
// loop from flickering, which swapping a single Image's `source` would not.
//
// Locations are tabs: "Auto" resolves through BeaconDB's geoip fallback
// (a ~25 km fix — plenty to pick a radar view), and manual cities come
// from Environment Canada's citypage site list via the "+" picker.
//
// Lightning strikes ride on top of the loop as bolt glyphs, from the same
// 6-minute feed weather.gc.ca's own map draws — best-effort, never gating
// the radar.
//
// Beside the radar sits the citypage weather feed for the same location:
// current conditions, the next period's forecast text, an hourly strip,
// and the week ahead (hover a day for its full text).
Panel {
  id: root
  moduleName: "ca.orospakr.ec-radar-weather"
  ipcTarget: "ca.orospakr.ec-radar-weather"
  manageIpc: false

  property var anchorItem: null
  property bool openedFromHotkey: false

  // The bar tracks the widget mounted in its slot — BarWidget.qml — not this
  // nested panel, so everything the bar identifies a panel by (popout
  // coordinator, open-panel dot, panel switching) has to be that widget.
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  function open() {
    openedFromHotkey = false
    setCenterHoverRevealSuppressed(false)
    root.controller.show()
    root.refresh()
  }

  function openFromHotkey() {
    openedFromHotkey = true
    root.controller.show()
    root.refresh()
    // Set after showing: showing hands the popout coordinator over, which
    // closes whichever panel was open, and that close clears the shared flag.
    Qt.callLater(function() {
      if (root.opened) setCenterHoverRevealSuppressed(true)
    })
  }

  function close() {
    setCenterHoverRevealSuppressed(false)
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.openFromHotkey()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  function setCenterHoverRevealSuppressed(value) {
    if (root.bar && "centerHoverRevealSuppressed" in root.bar)
      root.bar.centerHoverRevealSuppressed = value
  }

  // ---------------------------------------------------------------- theme
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.5)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // ---------------------------------------------------------- persistence
  //
  // Settings live inline on this widget's shell.json layout entry. Apply
  // locally first so the UI answers the click, mirror into the bar widget's
  // copy so it never writes a stale entry back, then persist through the
  // shell (which is a no-op if the widget has no writable entry).
  function persistSettings(values, removeKeys) {
    var entry = { id: root.moduleName }
    for (var existing in root.settings) if (existing !== "id") entry[existing] = root.settings[existing]
    for (var key in values) entry[key] = values[key]
    if (removeKeys) for (var i = 0; i < removeKeys.length; i++) delete entry[removeKeys[i]]

    root.settings = entry
    if (root.hostWidget && "settings" in root.hostWidget) root.hostWidget.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
    else
      // Session-only fallback: without the shell handle the entry cannot
      // be written, and the change would vanish on the next reload. Say
      // so in the journal instead of losing data silently.
      console.warn("ca.orospakr.ec-radar-weather: settings NOT persisted (no bar.shell handle); keys:", Object.keys(entry).join(","))
  }

  // ------------------------------------------------------------- location
  //
  // "active" is either "auto" (BeaconDB geoip fix) or the siteCode of one
  // of the configured cities in "locations". An unknown code — a city that
  // was removed out from under it — falls back to auto.
  // Injected settings arrive as Qt containers after a shell restart (a
  // QVariantList is array-like but fails Array.isArray), while in-session
  // persists hand back real JS arrays. Copy either shape into a JS array so
  // the rest of the panel never sees the difference.
  readonly property var locations: {
    var v = setting("locations", [])
    if (Array.isArray(v)) return v
    var out = []
    if (v && typeof v === "object" && isFinite(Number(v.length)))
      for (var i = 0; i < v.length; i++) out.push(v[i])
    return out
  }
  readonly property string active: String(setting("active", "auto"))
  readonly property var autoFix: setting("autoFix", null)
  readonly property bool hasFix: !!(autoFix
    && isFinite(Number(autoFix.latitude)) && isFinite(Number(autoFix.longitude)))

  readonly property var activeCity: {
    for (var i = 0; i < locations.length; i++)
      if (String(locations[i].siteCode) === active) return locations[i]
    return null
  }
  readonly property bool autoActive: activeCity === null
  // Auto counts as located only when the fix is near enough to a citypage
  // site to mean anything: beyond coverageKm the fix is outside Canada (or
  // deep in the high Arctic) and the map would be blank, so the panel shows
  // the out-of-coverage state instead of an empty loop.
  readonly property bool hasLocation: !autoActive || (hasFix && !autoOutOfRange)

  // The fallback coordinates only keep the bbox math finite while the map
  // is hidden behind the "Locating…" empty state; they are never shown.
  readonly property real latitude: autoActive
    ? (hasFix ? Number(autoFix.latitude) : 43.65)
    : Number(activeCity.latitude)
  readonly property real longitude: autoActive
    ? (hasFix ? Number(autoFix.longitude) : -79.38)
    : Number(activeCity.longitude)

  readonly property var addedCodes: {
    var m = {}
    for (var i = 0; i < locations.length; i++) m[String(locations[i].siteCode)] = true
    return m
  }

  // Nearest citypage site to the geoip fix: names the Auto tab and serves
  // as the weather source while Auto is active.
  readonly property var autoSite: (!hasFix || sites.length === 0) ? null
    : Model.nearestSite(sites, Number(autoFix.latitude), Number(autoFix.longitude))
  readonly property real coverageKm: 200
  readonly property real autoDistanceKm: (hasFix && autoSite)
    ? Model.distanceKm(Number(autoFix.latitude), Number(autoFix.longitude),
                       Number(autoSite.latitude), Number(autoSite.longitude))
    : 0
  readonly property bool autoOutOfRange: hasFix && autoSite !== null && autoDistanceKm > coverageKm
  readonly property string autoName: (autoSite && !autoOutOfRange) ? autoSite.name : "Auto"
  readonly property string activeName: autoActive ? autoName : String(activeCity.name)

  function cityEntry(site) {
    return {
      siteCode: String(site.siteCode),
      name: String(site.name),
      province: String(site.province || ""),
      latitude: Number(site.latitude),
      longitude: Number(site.longitude)
    }
  }

  function switchActive(value) {
    if (String(value) === active) return
    persistSettings({ active: String(value) })
    if (String(value) === "auto") requestAutoFix()
  }

  function chooseCity(site) {
    if (addedCodes[String(site.siteCode)])
      switchActive(site.siteCode)
    else
      persistSettings({ locations: locations.concat([cityEntry(site)]), active: String(site.siteCode) })
  }

  function toggleCity(site) {
    if (addedCodes[String(site.siteCode)]) removeCity(site.siteCode)
    else persistSettings({ locations: locations.concat([cityEntry(site)]) })
  }

  // Reorder from a chip drag. Indices are into tabOptions (0 = Auto, last
  // = "+"); `to` means "insert before that option", counted pre-removal.
  function moveCity(fromOption, toOption) {
    var from = fromOption - 1
    var to = toOption - 1
    if (to > from) to--
    if (from < 0 || from >= locations.length || to < 0 || to === from) return
    var next = locations.slice()
    var moved = next.splice(from, 1)[0]
    next.splice(to, 0, moved)
    persistSettings({ locations: next })
  }

  function removeCity(code) {
    var next = locations.filter(function(l) { return String(l.siteCode) !== String(code) })
    var values = { locations: next }
    if (active === String(code)) values.active = "auto"
    persistSettings(values)
    // Removing the active city lands the user on Auto; without a cached fix
    // that would otherwise sit on "Locating…" until the next poll.
    if (values.active) requestAutoFix()
  }

  // Pre-tabs entries wrote latitude/longitude/locationName directly on the
  // shell.json entry. Fold such an entry into a single manual city so the
  // configuration survives the upgrade. Runs on every settings injection
  // but is self-disarming: the first persist writes "locations".
  // Deferred: the first settings change fires mid-construction with empty
  // settings and unsettled bindings (observed: autoActive evaluates false
  // there). Qt.callLater coalesces that phantom with the real injection,
  // so the kick runs once, after the entry — cached fix included — is
  // actually visible.
  onSettingsChanged: {
    migrateLegacySettings()
    Qt.callLater(root.kickAutoFix)
  }
  function migrateLegacySettings() {
    var s = root.settings || {}
    if (s.locations !== undefined) return
    if (s.latitude === undefined && s.longitude === undefined) return
    var lat = Number(s.latitude)
    var lon = Number(s.longitude)
    if (!isFinite(lat) || !isFinite(lon)) return
    var name = s.locationName !== undefined ? String(s.locationName) : "Saved location"
    persistSettings(
      { locations: [{ siteCode: "legacy", name: name, province: "", latitude: lat, longitude: lon }], active: "legacy" },
      ["latitude", "longitude", "locationName"])
  }

  readonly property real spanKm: Math.max(40, Number(setting("spanKm", 280)))
  readonly property int frameCount: Math.max(2, Math.min(30, parseInt(setting("frames", 12), 10) || 12))
  readonly property int stepMs: Math.max(60, parseInt(setting("frameMs", 250), 10) || 250)
  readonly property int holdMs: Math.max(stepMs, parseInt(setting("holdMs", 1000), 10) || 1000)
  readonly property int pollMinutes: Math.max(1, parseInt(setting("pollMinutes", 30), 10) || 30)

  // ------------------------------------------------------ geoip auto fix
  //
  // BeaconDB's fallback geolocate endpoint: an empty request body means
  // "locate me by IP". Coarse (tens of km) but exactly the granularity a
  // 280 km radar view needs, with no Geoclue dependency.
  property bool autoFixFailed: false

  function requestAutoFix() {
    if (!settingsInjected) return
    if (geolocateProc.running) return
    if (hasFix && !autoFixFailed
        && Date.now() - Number(autoFix.at || 0) < 3600000) return
    geolocateProc.running = true
  }

  Process {
    id: geolocateProc
    command: ["curl", "-fsS", "--max-time", "6",
      "-H", "content-type: application/json", "-d", "{}",
      "https://api.beacondb.net/v1/geolocate"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var fix = Model.parseGeolocate(text)
        if (!fix) {
          // Keep any cached fix; the empty state only shows when there has
          // never been one.
          console.warn("ca.orospakr.ec-radar-weather: geolocate failed or returned no fix")
          root.autoFixFailed = true
          return
        }
        root.autoFixFailed = false
        fix.at = Date.now()
        root.persistSettings({ autoFix: fix })
      }
    }
  }

  // Startup warm-up, driven by the bar's settings injection rather than a
  // timer: a timer that fires before injection cannot see a cached fix and
  // refetches for nothing (observed: a 10-minute-old fix refetched at shell
  // start). The bar always injects into a mounted widget, so this always
  // runs exactly once, after the cache is visible.
  property bool autoFixKicked: false
  function kickAutoFix() {
    if (autoFixKicked) return
    autoFixKicked = true
    if (autoActive) requestAutoFix()
    requestWeather(false)
  }

  // Belt-and-braces for the same construction-order hazard on the write
  // side: never persist the geoip fix before the entry has been injected,
  // since persistSettings snapshots root.settings and updateEntryInline
  // replaces the whole entry — a pre-injection write would wipe the
  // configured cities (the exact bug that ate them during development).
  readonly property bool settingsInjected: autoFixKicked

  // ------------------------------------------------------------ site list
  //
  // The Environment Canada citypage site list feeds both the "+" search
  // popup and the naming of the auto fix. A snapshot ships with the plugin
  // so search works offline; a cache in ~/.cache is refreshed monthly and
  // preferred when it parses.
  property var sites: []

  readonly property string siteCacheDir: Quickshell.env("HOME") + "/.cache/omarchy/ca.orospakr.ec-radar-weather"
  readonly property string bundledSitesPath: Qt.resolvedUrl("data/site_list_towns_en.csv").toString().replace(/^file:\/\//, "")

  function applySites(text) {
    var parsed = Model.parseSiteList(text)
    if (parsed.length < 10) return false
    sites = parsed
    return true
  }

  FileView {
    id: cachedSitesFile
    path: root.siteCacheDir + "/site_list_towns_en.csv"
    printErrors: false
    onLoaded: if (!root.applySites(text())) bundledSitesFile.reload()
    onLoadFailed: bundledSitesFile.reload()
  }

  FileView {
    id: bundledSitesFile
    path: root.bundledSitesPath
    printErrors: false
    // The cache wins when both load; only fill in if it hasn't.
    onLoaded: if (root.sites.length === 0) root.applySites(text())
  }

  Process {
    id: siteListRefreshProc
    running: true
    command: ["bash", "-c",
      "d=\"$HOME/.cache/omarchy/ca.orospakr.ec-radar-weather\"; f=\"$d/site_list_towns_en.csv\"; mkdir -p \"$d\"; "
      + "if [ -e \"$f\" ] && [ -n \"$(find \"$f\" -newermt '-30 days' 2>/dev/null)\" ]; then exit 0; fi; "
      + "curl -fsS --max-time 15 -o \"$f.tmp\" https://dd.weather.gc.ca/today/citypage_weather/docs/site_list_towns_en.csv && mv \"$f.tmp\" \"$f\""]
    onExited: function(exitCode) {
      if (exitCode === 0) cachedSitesFile.reload()
    }
  }

  // -------------------------------------------------------------- weather
  //
  // Citypage weather for the active tab. Files are published into per-UTC-
  // hour directories under /today (there is no /yesterday root), so the
  // probe walks today's hour listings newest-first and takes the newest
  // file for the site. Parsed results are cached per site for the poll
  // interval, which makes tab switches instant and free.
  property var weather: null
  property var weatherCache: ({})
  property bool weatherFetching: false
  property bool weatherFailed: false
  property string weatherSiteCode: ""
  property int weatherEpoch: 0
  readonly property int weatherPaneWidth: Style.space(500)

  // The site whose weather is shown: the active city, or for Auto the
  // nearest site to the geoip fix.
  readonly property var activeSite: autoActive ? (autoOutOfRange ? null : autoSite) : activeCity
  onActiveSiteChanged: requestWeather(false)

  function requestWeather(force) {
    var site = activeSite
    if (!site || !site.siteCode || !site.province || String(site.siteCode) === "legacy") {
      // Invalidate any in-flight fetch too: a late callback for the
      // previous tab must not repopulate the pane under this one.
      weatherEpoch++
      weatherFetching = false
      weatherFailed = false
      weatherSiteCode = ""
      weather = null
      return
    }
    var code = String(site.siteCode)
    var cached = weatherCache[code]
    if (!force && cached && Date.now() - cached.at < pollMinutes * 60000) {
      weatherSiteCode = code
      weather = cached.data
      weatherFailed = false
      return
    }
    if (weatherFetching && weatherSiteCode === code) return
    weatherEpoch++
    weatherSiteCode = code
    weatherFetching = true
    weatherFailed = false
    // Show the stale cache, if any, while the fetch runs.
    weather = cached ? cached.data : null
    probeWeatherListing(Weather.citypageProbeUrls(site.province, Date.now()), 0, code, weatherEpoch)
  }

  // Walk the hour-directory listings until one contains a file for the
  // site. Every callback checks the epoch so a tab switch mid-flight
  // abandons the stale chain instead of racing the new one.
  function probeWeatherListing(urls, index, code, epoch) {
    if (epoch !== weatherEpoch) return
    if (index >= urls.length) { weatherDone(epoch, code, null); return }
    var xhr = new XMLHttpRequest()
    xhr.onreadystatechange = function() {
      if (xhr.readyState !== XMLHttpRequest.DONE) return
      if (epoch !== root.weatherEpoch) return
      var file = xhr.status === 200 ? Weather.pickCitypageFile(xhr.responseText, code, "en") : null
      if (file) root.fetchWeatherXml(urls[index] + file, code, epoch)
      else root.probeWeatherListing(urls, index + 1, code, epoch)
    }
    xhr.open("GET", urls[index])
    xhr.send()
  }

  function fetchWeatherXml(url, code, epoch) {
    var xhr = new XMLHttpRequest()
    xhr.onreadystatechange = function() {
      if (xhr.readyState !== XMLHttpRequest.DONE) return
      if (epoch !== root.weatherEpoch) return
      var parsed = null
      if (xhr.status === 200) {
        try { parsed = Weather.parseCitypage(xhr.responseText) } catch (e) { parsed = null }
      }
      root.weatherDone(epoch, code, parsed)
    }
    xhr.open("GET", url)
    xhr.send()
  }

  function weatherDone(epoch, code, parsed) {
    if (epoch !== weatherEpoch) return
    weatherFetching = false
    if (!parsed) {
      // Whatever was on screen (cached data or the empty state) stays.
      weatherFailed = true
      return
    }
    var cache = weatherCache
    cache[code] = { at: Date.now(), data: parsed }
    weatherCache = cache
    if (weatherSiteCode === code) weather = parsed
  }

  // ------------------------------------------------------------- dark map
  //
  // CBMT is a bright paper map, so on a dark desktop the panel used to open
  // with a flash of white. "auto" follows the desktop; "on"/"off" pin it.
  readonly property string darkMapMode: {
    var mode = String(setting("darkMap", "auto")).toLowerCase()
    return mode === "on" || mode === "off" ? mode : "auto"
  }

  // Qt reads the colour scheme from the platform theme (gtk3 here), which is
  // exactly what omarchy's theme switch writes with `gsettings set
  // org.gnome.desktop.interface color-scheme`, so this updates live. Only if
  // no platform theme answers do we fall back to the luminance of the shell
  // theme's background, using omarchy-theme-color's own >382 rule.
  readonly property bool darkTheme: {
    var scheme = Application.styleHints.colorScheme
    if (scheme === Qt.Dark) return true
    if (scheme === Qt.Light) return false
    return (Color.background.r + Color.background.g + Color.background.b) * 255 <= 382
  }

  readonly property bool darkMapActive: darkMapMode === "on" || (darkMapMode === "auto" && darkTheme)

  // Drives the shader's mix factor, so switching themes cross-fades between
  // the paper map and the dark one instead of snapping.
  property real darkAmount: darkMapActive ? 1 : 0
  Behavior on darkAmount {
    NumberAnimation { duration: 250; easing.type: Easing.InOutQuad }
  }

  // WMS 1.3.0 + EPSG:4326 orders the bbox lat,lon: minLat,minLon,maxLat,maxLon.
  readonly property real latSpan: spanKm / 111.0
  readonly property real lonSpan: spanKm / (111.0 * Math.max(0.05, Math.cos(latitude * Math.PI / 180)))
  readonly property real minLat: latitude - latSpan / 2
  readonly property real maxLat: latitude + latSpan / 2
  readonly property real minLon: longitude - lonSpan / 2
  readonly property real maxLon: longitude + lonSpan / 2

  // Request the tiles at exactly the size they are drawn at, and derive the
  // height from the bbox so a degree of latitude and a degree of longitude
  // get the same number of pixels per kilometre (no east-west stretch).
  readonly property int mapWidth: Style.space(560)
  readonly property int mapHeight: Math.max(120, Math.round(mapWidth * latSpan / lonSpan))

  readonly property string bboxParam: minLat.toFixed(4) + "," + minLon.toFixed(4) + "," + maxLat.toFixed(4) + "," + maxLon.toFixed(4)
  readonly property string geometryParams: "&crs=EPSG:4326"
    + "&bbox=" + bboxParam
    + "&width=" + mapWidth
    + "&height=" + mapHeight
    + "&format=image/png"

  readonly property string basemapUrl: "https://maps.geogratis.gc.ca/wms/CBMT?service=WMS&version=1.3.0&request=GetMap&layers=CBMT&styles=" + geometryParams

  function frameUrl(time) {
    return "https://geo.weather.gc.ca/geomet?service=WMS&version=1.3.0&request=GetMap&layers=RADAR_1KM_RRAI"
      + geometryParams + "&transparent=true&TIME=" + time
  }

  // ------------------------------------------------------------- playback
  property var frameTimes: []
  property int frameIndex: 0
  property bool playing: true
  property int framesLoaded: 0
  property int framesFailed: 0
  property bool fetching: false
  property bool fetchFailed: false
  property double lastUpdatedMs: 0

  // Everything that changes which pixels a frame URL returns. The frame
  // Repeater's model derives from this, so a location (or span) switch
  // recreates every delegate — the per-delegate `counted` latch would
  // otherwise never re-fire on a bare source change and the settled gate
  // would count frames that are still reloading.
  readonly property string locKey: hasLocation
    ? latitude.toFixed(4) + "," + longitude.toFixed(4) + "," + spanKm
    : ""
  onLocKeyChanged: {
    framesLoaded = 0
    framesFailed = 0
    frameIndex = 0
  }

  readonly property var frameModel: {
    if (!hasLocation) return []
    var key = locKey
    return frameTimes.map(function(t) { return { time: t, key: key } })
  }

  // Hold the loop until every frame has finished decoding. Advancing through
  // half-loaded frames would render the animation as a stutter of blanks.
  readonly property bool framesSettled: frameTimes.length > 0 && (framesLoaded + framesFailed) >= frameTimes.length
  readonly property string currentFrameTime: frameIndex >= 0 && frameIndex < frameTimes.length ? frameTimes[frameIndex] : ""

  readonly property string frameLabel: {
    if (currentFrameTime === "") return ""
    var d = new Date(currentFrameTime)
    if (isNaN(d.getTime())) return ""
    return Qt.formatDateTime(d, "HH:mm")
  }

  // ------------------------------------------------------------ lightning
  //
  // weather.gc.ca's map feed: national strike points in 6-minute bins whose
  // end times land exactly on the radar frame timestamps, so a frame shows
  // the strikes from the six minutes leading up to it. Only the last hour is
  // published, and the feed is the site's own internal API rather than a
  // documented open-data product, so everything here is best-effort: it
  // never gates the radar loop, and it marks itself unavailable rather than
  // guessing.
  property var lightningBins: ({})   // frame ISO time -> [{lon, lat, n}]
  property int lightningRev: 0       // bumped after every bins mutation
  property string lightningLatestIso: ""
  // The newest bin is served live and partial until the next one appears,
  // so the copy cached while it was newest gets refetched once it is final.
  property string lightningPartialIso: ""
  property bool lightningFetching: false
  property bool lightningFailed: false
  property bool lightningStale: false

  // The feed clusters strikes server-side; the distance follows the map span
  // the same way the site follows zoom. Part of the cache identity.
  readonly property real clusterDistance: Lightning.clusterDistanceFor(spanKm)
  // Bumped when the cache identity changes so callbacks from an in-flight
  // batch at the old distance are dropped instead of repopulating it.
  property int lightningGen: 0
  onClusterDistanceChanged: {
    lightningGen++
    lightningBins = ({})
    lightningPartialIso = ""
    lightningRev++
    lightningFetching = false
    refreshLightning()
  }

  readonly property var currentLightning: {
    var rev = lightningRev // dependency: bins are mutated in place
    if (currentFrameTime === "") return null
    var pts = lightningBins[currentFrameTime]
    return pts ? pts : null
  }
  readonly property bool lightningDown: lightningFailed || lightningStale

  readonly property string lightningChip: {
    if (lightningDown) return "󱐋 UNAVAILABLE"
    if (lightningRev === 0 && lightningFetching) return "󱐋 LOADING"
    return "󱐋 LIGHTNING"
  }

  // Map chips sit on a fixed dark translucent fill whatever the theme, so
  // their text is fixed light too — the theme foreground is dark in light
  // mode and vanished into the chip.
  readonly property color chipFill: Qt.rgba(0, 0, 0, 0.55)
  readonly property color chipText: "#f2f2f2"

  readonly property string statusNote: {
    if (!hasLocation) {
      if (autoOutOfRange) return "AUTO · OUT OF COVERAGE"
      return autoFixFailed ? "Location unavailable — R retries" : "Locating…"
    }
    var name = (autoActive ? "AUTO · " : "") + activeName.toUpperCase()
    if (frameTimes.length === 0) return name + (fetchFailed ? " · Radar unavailable" : " · Loading radar…")
    if (fetchFailed) return name + " · Offline — showing last loop"
    var note = lightningDown ? " · Lightning unavailable" : ""
    if (framesFailed > 0) return name + " · " + framesFailed + " frame(s) unavailable" + note
    return name + note
  }

  // Frame count / loading progress, shown as a chip on the map itself.
  readonly property string framesChip: {
    if (frameTimes.length === 0) return ""
    if (!framesSettled) return "LOADING " + (framesLoaded + framesFailed) + "/" + frameTimes.length
    return frameTimes.length + " FRAMES"
  }

  readonly property var tabOptions: {
    var opts = [{ value: "auto", label: "Auto", tooltip: "Follow detected location" }]
    for (var i = 0; i < locations.length; i++)
      opts.push({
        value: String(locations[i].siteCode),
        label: String(locations[i].name),
        tooltip: "Right-click to remove"
      })
    opts.push({ value: "+add", label: "+", tooltip: "Add city" })
    return opts
  }

  function isoAt(ms) {
    var d = new Date(ms)
    function p(n) { return (n < 10 ? "0" : "") + n }
    return d.getUTCFullYear() + "-" + p(d.getUTCMonth() + 1) + "-" + p(d.getUTCDate())
      + "T" + p(d.getUTCHours()) + ":" + p(d.getUTCMinutes()) + ":" + p(d.getUTCSeconds()) + "Z"
  }

  // GeoMet advertises the available radar window as
  // "<start>/<end>/PT6M" inside the layer's time Dimension. nearestValue is
  // 0, so every TIME we ask for has to land exactly on that grid. The time
  // grid is global to the layer — location changes never require re-asking.
  function applyCapabilities(body) {
    var match = String(body || "").match(/<Dimension[^>]*name="time"[^>]*>([^<]*)<\/Dimension>/)
    if (!match) return false
    var parts = String(match[1]).trim().split("/")
    if (parts.length < 2) return false

    var startMs = Date.parse(parts[0])
    var endMs = Date.parse(parts[1])
    if (!isFinite(startMs) || !isFinite(endMs) || endMs < startMs) return false

    var periodMatch = parts.length > 2 ? String(parts[2]).match(/PT(\d+)M/) : null
    var stepMinutes = periodMatch ? parseInt(periodMatch[1], 10) : 6
    if (!isFinite(stepMinutes) || stepMinutes <= 0) stepMinutes = 6
    var frameStepMs = stepMinutes * 60000

    var available = Math.floor((endMs - startMs) / frameStepMs) + 1
    var count = Math.max(1, Math.min(root.frameCount, available))

    var times = []
    for (var i = count - 1; i >= 0; i--) times.push(isoAt(endMs - i * frameStepMs))

    root.lastUpdatedMs = Date.now()
    // Rebuilding an identical list would drop and re-create every Image,
    // restarting the loop for no reason.
    if (times.join(",") === root.frameTimes.join(",")) return true

    root.framesLoaded = 0
    root.framesFailed = 0
    root.frameIndex = 0
    root.frameTimes = times
    return true
  }

  // `force` (the R key / middle-click) refetches weather even when the
  // per-site cache is fresh; timers and opens go through the cache.
  function refresh(force) {
    // Only when the panel is actually open: the poll timer's triggeredOnStart
    // refresh fires before the bar injects settings, and a geolocate started
    // then couldn't see a cached fix. The startup warm-up is the injection-
    // delayed Timer below; every user-driven refresh path has the panel open.
    if (autoActive && opened) requestAutoFix()
    requestWeather(force === true)
    refreshLightning()
    if (fetching) return
    fetching = true

    var xhr = new XMLHttpRequest()
    xhr.onreadystatechange = function() {
      if (xhr.readyState !== XMLHttpRequest.DONE) return
      root.fetching = false
      var ok = false
      if (xhr.status === 200) {
        try {
          ok = root.applyCapabilities(xhr.responseText)
        } catch (e) {
          ok = false
        }
      }
      // On failure the previous frames stay on screen; the footer says so.
      root.fetchFailed = !ok
    }
    xhr.open("GET", "https://geo.weather.gc.ca/geomet?lang=en&service=WMS&version=1.3.0&request=GetCapabilities&layer=RADAR_1KM_RRAI")
    xhr.send()
  }

  // Bin list first, then only the bins we lack. Ended bins are immutable,
  // so they stay cached until they fall off the radar loop — the feed only
  // lists the last hour, six minutes short of a 12-frame loop, but after
  // the first background poll the cache covers all of it. The newest bin
  // is a live partial that regenerates every minute, so it is always
  // refetched, and once more after it stops being newest.
  function refreshLightning() {
    if (lightningFetching) return
    lightningFetching = true
    var gen = lightningGen

    var xhr = new XMLHttpRequest()
    xhr.onreadystatechange = function() {
      if (xhr.readyState !== XMLHttpRequest.DONE) return
      if (gen !== root.lightningGen) return
      var bins = xhr.status === 200 ? Lightning.parseMetadata(xhr.responseText) : []
      if (bins.length === 0) {
        root.lightningFetching = false
        root.lightningFailed = true
        return
      }
      var latest = Lightning.binToIso(bins[bins.length - 1])
      root.lightningLatestIso = latest || ""
      root.lightningStale = Lightning.isStale(latest, Date.now())

      var wanted = []
      for (var i = 0; i < bins.length; i++) {
        var iso = Lightning.binToIso(bins[i])
        if (!iso) continue
        if (i === bins.length - 1 || iso === root.lightningPartialIso || !(iso in root.lightningBins))
          wanted.push(bins[i])
      }
      root.lightningPartialIso = latest || ""
      root.fetchLightningBins(wanted, bins, gen)
    }
    xhr.open("GET", Lightning.METADATA_URL)
    xhr.send()
  }

  function fetchLightningBins(wanted, listed, gen) {
    var cd = clusterDistance
    var keep = {}
    for (var i = 0; i < listed.length; i++) {
      var k = Lightning.binToIso(listed[i])
      if (k) keep[k] = true
    }
    var pending = wanted.length
    var failed = 0

    function finish() {
      var next = {}
      var oldest = root.frameTimes.length > 0 ? root.frameTimes[0] : ""
      for (var key in root.lightningBins)
        if (keep[key] || key >= oldest) next[key] = root.lightningBins[key]
      root.lightningBins = next
      root.lightningRev++
      root.lightningFetching = false
      // Partial success still draws what arrived; only a total miss is "down".
      root.lightningFailed = wanted.length > 0 && failed === wanted.length
    }

    if (pending === 0) { finish(); return }
    wanted.forEach(function(bin) {
      var iso = Lightning.binToIso(bin)
      var xhr = new XMLHttpRequest()
      xhr.onreadystatechange = function() {
        if (xhr.readyState !== XMLHttpRequest.DONE) return
        if (gen !== root.lightningGen) return
        if (xhr.status === 200) root.lightningBins[iso] = Lightning.parseBin(xhr.responseText).points
        else failed++
        if (--pending === 0) finish()
      }
      xhr.open("GET", Lightning.binUrl(bin, cd))
      xhr.send()
    })
  }

  function noteFrameSettled(status) {
    if (status === Image.Ready) root.framesLoaded++
    else if (status === Image.Error) root.framesFailed++
  }

  function advance() {
    if (frameTimes.length === 0) return
    frameIndex = (frameIndex + 1) % frameTimes.length
  }

  function openRemoveMenu(value, chip) {
    if (value === "auto" || value === "+add") return
    var city = null
    for (var i = 0; i < locations.length; i++)
      if (String(locations[i].siteCode) === String(value)) city = locations[i]
    if (!city) return
    removeMenu.targetCode = String(value)
    removeMenu.targetName = String(city.name)
    removeMenu.parent = chip || tabsRow
    removeMenu.x = 0
    removeMenu.y = (chip ? chip.height : 0) + Style.spacing.xxs
    removeMenu.open()
  }

  Timer {
    id: playTimer
    running: root.opened && root.playing && root.framesSettled && root.frameTimes.length > 1
    repeat: true
    // Linger on the newest frame so the loop reads as "here is now", then
    // rewinds, instead of a uniform smear.
    interval: root.frameIndex === root.frameTimes.length - 1 ? root.holdMs : root.stepMs
    onTriggered: root.advance()
  }

  // Keep the loop warm in the background so opening the panel shows radar
  // immediately instead of a "Loading frames…" stall. Radar composites publish
  // every 6 minutes, but polling that hard while nobody is looking would be
  // rude to GeoMet for no benefit — a slower background cadence plus the
  // refresh() every open() does is enough. triggeredOnStart warms the loop
  // once when the shell mounts this resident panel at startup.
  Timer {
    id: pollTimer
    running: true
    repeat: true
    triggeredOnStart: true
    interval: root.pollMinutes * 60 * 1000
    onTriggered: root.refresh()
  }

  IpcHandler {
    target: root.ipcTarget

    function open(): void { root.openFromHotkey() }
    function close(): void { root.close() }
    function show(): void { root.openFromHotkey() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): void { root.refresh() }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: true
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(root.mapWidth + Style.space(16) + root.weatherPaneWidth)
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // The picker and the remove menu own the keyboard while open; the
      // search field in particular must see plain letters, not hotkeys.
      blocked: cityPicker.opened || removeMenu.opened
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onActivateRequested: root.playing = !root.playing
      onMoveRequested: function(dx, dy) {
        if (dx === 0 || root.frameTimes.length === 0) return
        root.playing = false
        root.frameIndex = (root.frameIndex + dx + root.frameTimes.length) % root.frameTimes.length
      }
      onDeleteRequested: {
        if (root.activeCity) root.openRemoveMenu(root.active, tabs.chipForValue(root.active))
      }
      onTextKey: function(t) {
        if (t === "r" || t === "R") { root.refresh(true); return }
        if (t === "a" || t === "A" || t === "+") { cityPicker.open(); return }
        // 1 = Auto, 2… = the cities in tab order.
        var n = parseInt(t, 10)
        if (!isFinite(n) || n < 1) return
        if (n === 1) root.switchActive("auto")
        else if (n - 2 < root.locations.length) root.switchActive(root.locations[n - 2].siteCode)
      }

      Column {
        id: column
        width: parent.width
        spacing: Style.space(12)

        PanelHero {
          width: parent.width
          title: "Environment Canada Radar & Weather"
          meta: root.statusNote
          foreground: root.foreground
          fontFamily: root.fontFamily

          iconComponent: Component {
            Text {
              text: "󰐷"  // nf-md-radar
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.display
            }
          }
        }

        PanelSeparator {
          foreground: root.foreground
        }

        // ---- Location tabs: Auto, configured cities, "+" to add.
        Item {
          id: tabsRow
          width: parent.width
          implicitHeight: tabs.implicitHeight

          RadarTabs {
            id: tabs
            width: parent.width
            foreground: root.foreground
            accent: Color.accent
            fontFamily: root.fontFamily
            options: root.tabOptions
            value: root.autoActive ? "auto" : root.active
            onChanged: function(value) {
              if (value === "+add") cityPicker.open()
              else root.switchActive(value)
            }
            onRightClicked: function(value, chip) { root.openRemoveMenu(value, chip) }
            onReordered: function(from, to) { root.moveCity(from, to) }
          }

          CityPicker {
            id: cityPicker
            x: 0
            y: tabs.height + Style.spacing.xxs
            width: Math.min(tabsRow.width, Style.space(300))
            height: Math.min(Style.space(340), keyCatcher.height - column.y - tabsRow.y - tabs.height - Style.space(16))
            sites: root.sites
            addedCodes: root.addedCodes
            fontFamily: root.fontFamily
            onChoose: function(site) { root.chooseCity(site) }
            onToggleStar: function(site) { root.toggleCity(site) }
          }

          // Right-click context menu for a city chip. Reparented onto the
          // chip it was invoked on so it drops down right underneath.
          QQC.Popup {
            id: removeMenu
            property string targetCode: ""
            property string targetName: ""

            readonly property var borderSpec: Border.localOrSurfaceSpec("popups", "border", Color.popups.border, Color.popups.border, Style.normalBorderWidth)

            padding: Style.spacing.hairline
            leftPadding: Border.left(borderSpec) + Style.spacing.hairline
            rightPadding: Border.right(borderSpec) + Style.spacing.hairline
            topPadding: Border.top(borderSpec) + Style.spacing.hairline
            bottomPadding: Border.bottom(borderSpec) + Style.spacing.hairline
            // Opened from the keyboard (x/Delete) the catcher is blocked, so
            // the menu itself must own Enter/Escape.
            focus: true

            // The menu is reparented onto whichever chip invoked it, and
            // removing a city rebuilds the chip row — park it back on the
            // stable row before the chip it sat on is destroyed.
            onClosed: removeMenu.parent = tabsRow

            background: BorderSurface {
              color: Color.popups.background
              borderSpec: removeMenu.borderSpec
              radius: Style.cornerRadius
            }

            contentItem: Button {
              focus: true
              text: "Remove " + removeMenu.targetName
              iconText: "✕"
              foreground: Color.popups.text
              accent: Color.accent
              fontFamily: root.fontFamily
              onClicked: {
                removeMenu.close()
                root.removeCity(removeMenu.targetCode)
              }
              Keys.onPressed: function(event) {
                if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                  removeMenu.close()
                  root.removeCity(removeMenu.targetCode)
                  event.accepted = true
                } else if (event.key === Qt.Key_Escape) {
                  removeMenu.close()
                  event.accepted = true
                }
              }
            }
          }
        }

        // ---- Radar left, weather right.
        Row {
          width: parent.width
          spacing: Style.space(16)

          Rectangle {
            id: mapFrame
            width: root.mapWidth
            height: root.mapHeight
            radius: Style.cornerRadius
            clip: true
            color: Qt.rgba(0, 0, 0, 0.35)
            border.width: 1
            border.color: Style.normalBorderFor(root.foreground, Color.accent)

            Item {
              id: mapArea
              // The WMS tiles are requested at mapWidth; centre them if the
              // panel had to be narrowed to fit the screen.
              width: root.mapWidth
              height: root.mapHeight
              anchors.centerIn: parent
              visible: root.hasLocation

              Image {
                id: basemap
                anchors.fill: parent
                asynchronous: true
                source: root.hasLocation ? root.basemapUrl : ""
                // Knocked back so the radar returns stay the brightest thing on
                // the map without the roads and shorelines becoming unreadable.
                // The dark version needs a little more knock-back still.
                opacity: 0.82 - 0.12 * root.darkAmount

                // invert + hue-rotate(180deg), the CSS "dark map" recipe: a
                // plain invert would leave the lakes brown. Only the basemap is
                // layered — the radar frames above it keep their real colours —
                // and in light mode the layer stays off entirely, so nothing
                // about the old render path changes.
                layer.enabled: root.darkAmount > 0
                layer.smooth: true
                layer.effect: ShaderEffect {
                  property var source: null
                  property real amount: root.darkAmount
                  fragmentShader: Qt.resolvedUrl("shaders/darkmap.frag.qsb")
                }
              }

              Repeater {
                model: root.frameModel

                Image {
                  required property int index
                  required property var modelData

                  anchors.fill: parent
                  asynchronous: true
                  source: root.frameUrl(modelData.time)
                  // Load-bearing: a rebuilt frame list re-creates every delegate,
                  // and Qt's pixmap cache is what keeps that to downloading only
                  // the genuinely new timestamps — or, on a return to an
                  // already-viewed location, none at all.
                  cache: true
                  // Opacity, not source-swapping: every frame stays decoded in
                  // the scene graph so advancing costs nothing and never blanks.
                  opacity: index === root.frameIndex ? 1 : 0
                  visible: opacity > 0

                  property bool counted: false
                  onStatusChanged: {
                    if (counted) return
                    if (status === Image.Ready || status === Image.Error) {
                      counted = true
                      root.noteFrameSettled(status)
                    }
                  }
                }
              }

              // Strikes for the frame on screen, as bolt glyphs sized by
              // cluster count. One Canvas repainted per frame step: a few
              // hundred small paths cost a few ms, far cheaper than a delegate
              // per strike, and nothing here holds up the loop.
              Canvas {
                id: lightningCanvas
                anchors.fill: parent
                visible: root.currentLightning !== null
                property var points: root.currentLightning
                onPointsChanged: requestPaint()
                onWidthChanged: requestPaint()
                onHeightChanged: requestPaint()
                Connections {
                  target: root
                  function onLocKeyChanged() { lightningCanvas.requestPaint() }
                }

                onPaint: {
                  var ctx = getContext("2d")
                  ctx.clearRect(0, 0, width, height)
                  var pts = points
                  if (!pts || width <= 0 || height <= 0) return
                  var shown = Lightning.pointsInBox(pts, root.minLat, root.maxLat, root.minLon, root.maxLon)
                  // Big clusters first so single strikes stay visible on top.
                  shown.sort(function(a, b) { return b.n - a.n })

                  var bolt = Lightning.BOLT
                  var lonSpan = root.maxLon - root.minLon
                  var latSpan = root.maxLat - root.minLat
                  ctx.lineWidth = Math.max(1, Style.space(1))
                  ctx.lineJoin = "round"
                  // A soft outline: hard black edges on hundreds of packed
                  // glyphs turn a storm core into a smear that hides the rain.
                  ctx.strokeStyle = "rgba(0, 0, 0, 0.5)"
                  ctx.fillStyle = "#ffe14d"
                  for (var i = 0; i < shown.length; i++) {
                    var p = shown[i]
                    var h = Style.space(Lightning.sizeFor(Lightning.bucket(p.n)))
                    var w = h * 0.65
                    var cx = (p.lon - root.minLon) / lonSpan * width
                    var cy = (root.maxLat - p.lat) / latSpan * height
                    ctx.beginPath()
                    for (var j = 0; j < bolt.length; j++) {
                      var x = cx - w / 2 + bolt[j][0] * w
                      var y = cy - h / 2 + bolt[j][1] * h
                      if (j === 0) ctx.moveTo(x, y)
                      else ctx.lineTo(x, y)
                    }
                    ctx.closePath()
                    ctx.fill()
                    ctx.stroke()
                  }
                }
              }

              // Active location, projected into the bbox. For auto this is the
              // geoip fix — coarse, but honest about what is being centred on.
              Rectangle {
                id: marker
                width: Style.space(9)
                height: width
                radius: width / 2
                color: "transparent"
                border.width: Math.max(1, Style.space(2))
                border.color: Color.accent
                x: (root.longitude - root.minLon) / (root.maxLon - root.minLon) * mapArea.width - width / 2
                y: (root.maxLat - root.latitude) / (root.maxLat - root.minLat) * mapArea.height - height / 2

                Rectangle {
                  anchors.centerIn: parent
                  width: Math.max(1, Style.space(3))
                  height: width
                  radius: width / 2
                  color: Color.accent
                }
              }
            }

            // Empty state for the Auto tab: before any fix has ever arrived,
            // or when the fix is too far from any Environment Canada site
            // for the map or forecast to mean anything.
            Column {
              anchors.centerIn: parent
              width: parent.width - Style.space(32)
              visible: !root.hasLocation
              spacing: Style.space(8)

              // Desert-island silhouette, drawn in the dim foreground so it
              // reads as a placeholder on either theme.
              Canvas {
                id: islandArt
                visible: root.autoOutOfRange
                anchors.horizontalCenter: parent.horizontalCenter
                width: Style.space(132)
                height: Style.space(88)
                property color ink: root.dim
                onInkChanged: requestPaint()
                onWidthChanged: requestPaint()
                onHeightChanged: requestPaint()
                onPaint: {
                  var ctx = getContext("2d")
                  var w = width, h = height
                  ctx.clearRect(0, 0, w, h)
                  ctx.fillStyle = ink
                  ctx.strokeStyle = ink
                  ctx.lineCap = "round"
                  ctx.lineJoin = "round"

                  // Sand: a low mound, its lower half trimmed at the waterline.
                  var sea = h * 0.86
                  var seaLine = Math.max(1, h * 0.03)
                  ctx.beginPath()
                  ctx.ellipse(w * 0.16, sea - h * 0.2, w * 0.68, h * 0.4)
                  ctx.fill()
                  ctx.clearRect(0, sea + seaLine / 2, w, h - sea)

                  // Water: a flat line with a small gap either side of the island.
                  ctx.lineWidth = seaLine
                  ctx.beginPath(); ctx.moveTo(w * 0.02, sea); ctx.lineTo(w * 0.14, sea); ctx.stroke()
                  ctx.beginPath(); ctx.moveTo(w * 0.86, sea); ctx.lineTo(w * 0.98, sea); ctx.stroke()

                  // Trunk: a gentle lean to the right.
                  var bx = w * 0.46, by = sea - h * 0.02
                  var tx = w * 0.60, ty = h * 0.24
                  ctx.lineWidth = Math.max(2, w * 0.035)
                  ctx.beginPath()
                  ctx.moveTo(bx, by)
                  ctx.quadraticCurveTo(w * 0.48, h * 0.45, tx, ty)
                  ctx.stroke()

                  // Fronds: lens-shaped leaves radiating from the crown, drooping.
                  function frond(ang, len, wid, droop) {
                    var ex = tx + Math.cos(ang) * len
                    var ey = ty + Math.sin(ang) * len + droop
                    var mx = tx + Math.cos(ang) * len * 0.5
                    var my = ty + Math.sin(ang) * len * 0.5 + droop * 0.35
                    var nx = -Math.sin(ang) * wid, ny = Math.cos(ang) * wid
                    ctx.beginPath()
                    ctx.moveTo(tx, ty)
                    ctx.quadraticCurveTo(mx + nx, my + ny, ex, ey)
                    ctx.quadraticCurveTo(mx - nx, my - ny, tx, ty)
                    ctx.closePath()
                    ctx.fill()
                  }
                  var L = w * 0.30, W = h * 0.075, D = h * 0.10
                  frond(Math.PI * 1.02, L * 0.95, W, D)          // left
                  frond(Math.PI * 1.22, L * 0.85, W, D * 0.6)    // upper left
                  frond(Math.PI * 1.50, L * 0.62, W * 0.9, 0)    // straight up
                  frond(Math.PI * 1.78, L * 0.85, W, D * 0.6)    // upper right
                  frond(Math.PI * 1.98, L * 0.95, W, D)          // right
                  frond(Math.PI * 0.18, L * 0.7, W, D * 1.3)     // low right, drooping

                  // Coconuts at the crown.
                  var cr = Math.max(1.5, w * 0.022)
                  ctx.beginPath(); ctx.ellipse(tx - cr * 2.2, ty + cr * 0.6, cr * 2, cr * 2); ctx.fill()
                  ctx.beginPath(); ctx.ellipse(tx + cr * 0.2, ty + cr * 1.2, cr * 2, cr * 2); ctx.fill()
                }
              }

              Text {
                visible: root.autoOutOfRange
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WordWrap
                textFormat: Text.StyledText
                text: "<i>Hoser took off.</i> Out of the country or coverage area."
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }

              Text {
                visible: root.autoOutOfRange
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WordWrap
                text: {
                  var km = Math.round(root.autoDistanceKm / 10) * 10
                  var site = root.autoSite ? (root.autoSite.name + ", " + root.autoSite.province) : "a forecast site"
                  var s = "Your network places you about " + km.toLocaleString(Qt.locale(), "f", 0)
                    + " km from the nearest Environment Canada site (" + site + ")."
                  if (root.locations.length > 0)
                    s += " Press 2 for " + String(root.locations[0].name) + ", or"
                  return s
                }
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              Button {
                visible: root.autoOutOfRange
                anchors.horizontalCenter: parent.horizontalCenter
                bordered: true
                iconText: "+"
                text: "Add a Canadian city"
                foreground: root.foreground
                accent: Color.accent
                fontFamily: root.fontFamily
                onClicked: cityPicker.open()
              }

              Text {
                visible: !root.autoOutOfRange
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                text: root.autoFixFailed ? "Location unavailable — press R to retry" : "Locating…"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }
            }

            // Lightning state chip, top left of the map. Absent on frames
            // with no strikes to draw (older than the feed's one-hour
            // window); still shown while loading or when the feed is down.
            Rectangle {
              visible: root.hasLocation && root.lightningChip !== ""
                && (root.currentLightning !== null || root.lightningDown || root.lightningFetching)
              anchors.top: parent.top
              anchors.left: parent.left
              anchors.margins: Style.space(8)
              width: lightningChipLabel.implicitWidth + Style.space(12)
              height: lightningChipLabel.implicitHeight + Style.space(6)
              radius: Style.cornerRadius
              color: root.chipFill

              Text {
                id: lightningChipLabel
                anchors.centerIn: parent
                text: root.lightningChip
                color: root.chipText
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                font.letterSpacing: 1.2
              }
            }

            // Paused badge, so a stopped loop never looks like a stuck fetch.
            Rectangle {
              visible: !root.playing && root.frameTimes.length > 0 && root.hasLocation
              anchors.top: parent.top
              anchors.right: parent.right
              anchors.margins: Style.space(8)
              width: pausedLabel.implicitWidth + Style.space(12)
              height: pausedLabel.implicitHeight + Style.space(6)
              radius: Style.cornerRadius
              color: root.chipFill

              Text {
                id: pausedLabel
                anchors.centerIn: parent
                text: "PAUSED"
                color: root.chipText
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                font.letterSpacing: 1.2
              }
            }

            // Frame-count chip, bottom left of the map.
            Rectangle {
              visible: root.hasLocation && root.framesChip !== ""
              anchors.bottom: parent.bottom
              anchors.left: parent.left
              anchors.margins: Style.space(8)
              width: framesChipLabel.implicitWidth + Style.space(12)
              height: framesChipLabel.implicitHeight + Style.space(6)
              radius: Style.cornerRadius
              color: root.chipFill

              Text {
                id: framesChipLabel
                anchors.centerIn: parent
                text: root.framesChip
                color: root.chipText
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                font.letterSpacing: 1.2
              }
            }

            // Timestamp of the frame on screen, bottom right of the map.
            Rectangle {
              visible: root.hasLocation && root.frameLabel !== ""
              anchors.bottom: parent.bottom
              anchors.right: parent.right
              anchors.margins: Style.space(8)
              width: frameLabelChip.implicitWidth + Style.space(12)
              height: frameLabelChip.implicitHeight + Style.space(6)
              radius: Style.cornerRadius
              color: root.chipFill

              Text {
                id: frameLabelChip
                anchors.centerIn: parent
                text: root.frameLabel
                color: root.chipText
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                font.letterSpacing: 1.2
              }
            }

            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              acceptedButtons: Qt.LeftButton | Qt.MiddleButton
              onClicked: function(mouse) {
                if (mouse.button === Qt.MiddleButton) root.refresh(true)
                else root.playing = !root.playing
              }
            }
          }

          WeatherPane {
            id: weatherPane
            // Fill whatever width the panel actually got: the shell may
            // clamp contentWidth below the request, and a fixed width
            // would overflow the panel border.
            width: Math.max(Style.space(220), parent.width - root.mapWidth - Style.space(16))
            height: Math.max(implicitHeight, mapFrame.height)
            weather: root.weather
            statusText: root.weatherFetching ? "Loading weather…"
              : (root.weatherFailed ? "Weather unavailable — R retries"
              : (root.activeSite ? ""
              : (root.autoActive && root.autoOutOfRange ? "No nearby forecast site" : "Waiting for location…")))
            stale: root.weatherFailed && !!root.weather
            foreground: root.foreground
            dim: root.dim
            accent: Color.accent
            fontFamily: root.fontFamily
          }
        }

        // ---- Footer: attribution left, interaction hint right.
        Item {
          width: parent.width
          implicitHeight: Math.max(attribution.implicitHeight, hint.implicitHeight)

          Text {
            id: attribution
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: "Data: Environment and Climate Change Canada"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          Text {
            id: hint
            anchors.left: attribution.right
            anchors.leftMargin: Style.space(16)
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            horizontalAlignment: Text.AlignRight
            elide: Text.ElideRight
            text: root.playing ? "R refresh · 1-9 tabs · A add" : "Click map to play · ←/→ step"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }
    }
  }
}
