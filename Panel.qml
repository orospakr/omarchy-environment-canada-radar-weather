import QtQuick
import QtQuick.Controls as QQC
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

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
Panel {
  id: root
  moduleName: "andrew.radar"
  ipcTarget: "andrew.radar"
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
      console.warn("andrew.radar: settings NOT persisted (no bar.shell handle); keys:", Object.keys(entry).join(","))
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
  readonly property bool hasLocation: !autoActive || hasFix

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

  readonly property string autoName: {
    if (!hasFix || sites.length === 0) return "Auto"
    var near = Model.nearestSite(sites, Number(autoFix.latitude), Number(autoFix.longitude))
    return near ? near.name : "Auto"
  }
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
          console.warn("andrew.radar: geolocate failed or returned no fix")
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

  readonly property string siteCacheDir: Quickshell.env("HOME") + "/.cache/omarchy/andrew.radar"
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
      "d=\"$HOME/.cache/omarchy/andrew.radar\"; f=\"$d/site_list_towns_en.csv\"; mkdir -p \"$d\"; "
      + "if [ -e \"$f\" ] && [ -n \"$(find \"$f\" -newermt '-30 days' 2>/dev/null)\" ]; then exit 0; fi; "
      + "curl -fsS --max-time 15 -o \"$f.tmp\" https://dd.weather.gc.ca/today/citypage_weather/docs/site_list_towns_en.csv && mv \"$f.tmp\" \"$f\""]
    onExited: function(exitCode) {
      if (exitCode === 0) cachedSitesFile.reload()
    }
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

  readonly property string statusNote: {
    if (!hasLocation) return autoFixFailed ? "Location unavailable — R retries" : "Locating…"
    if (frameTimes.length === 0) return fetchFailed ? "Radar unavailable" : "Loading radar…"
    if (!framesSettled) return "Loading frames " + (framesLoaded + framesFailed) + "/" + frameTimes.length
    if (fetchFailed) return "Offline — showing last loop"
    if (framesFailed > 0) return framesFailed + " frame(s) unavailable"
    return (autoActive ? "AUTO · " : "") + activeName.toUpperCase() + " · " + frameTimes.length + " frames"
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

  function refresh() {
    // Only when the panel is actually open: the poll timer's triggeredOnStart
    // refresh fires before the bar injects settings, and a geolocate started
    // then couldn't see a cached fix. The startup warm-up is the injection-
    // delayed Timer below; every user-driven refresh path has the panel open.
    if (autoActive && opened) requestAutoFix()
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
    contentWidth: panel.fittedContentWidth(root.mapWidth)
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
        if (t === "r" || t === "R") { root.refresh(); return }
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
          title: "Radar"
          meta: root.statusNote
          detail: root.frameLabel
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

        // ---- Map: base layer, preloaded radar frames, location marker.
        Rectangle {
          id: mapFrame
          width: parent.width
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

          // Empty state for the Auto tab before any fix has ever arrived.
          Text {
            anchors.centerIn: parent
            visible: !root.hasLocation
            text: root.autoFixFailed ? "Location unavailable — press R to retry" : "Locating…"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
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
            color: Qt.rgba(0, 0, 0, 0.55)

            Text {
              id: pausedLabel
              anchors.centerIn: parent
              text: "PAUSED"
              color: root.foreground
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
              if (mouse.button === Qt.MiddleButton) root.refresh()
              else root.playing = !root.playing
            }
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
