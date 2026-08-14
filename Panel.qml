import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Animated Environment and Climate Change Canada radar loop.
//
// Two WMS sources are stacked at the exact same bbox so they line up pixel
// for pixel: the CBMT base map from GeoGratis underneath, and a preloaded
// stack of RADAR_1KM_RRAI rain-rate frames on top. Only the active frame is
// opaque — switching opacity on already-decoded images is what keeps the
// loop from flickering, which swapping a single Image's `source` would not.
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

  // ------------------------------------------------------------- location
  //
  // Extra keys on this widget's shell.json layout entry override the
  // Toronto defaults, e.g. { "id": "andrew.radar", "latitude": 49.28, ... }.
  readonly property real latitude: Number(setting("latitude", 43.65))
  readonly property real longitude: Number(setting("longitude", -79.38))
  readonly property string locationName: String(setting("locationName", "Toronto"))
  readonly property real spanKm: Math.max(40, Number(setting("spanKm", 280)))
  readonly property int frameCount: Math.max(2, Math.min(30, parseInt(setting("frames", 12), 10) || 12))
  readonly property int stepMs: Math.max(60, parseInt(setting("frameMs", 250), 10) || 250)
  readonly property int holdMs: Math.max(stepMs, parseInt(setting("holdMs", 1000), 10) || 1000)
  readonly property int pollMinutes: Math.max(1, parseInt(setting("pollMinutes", 30), 10) || 30)

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
    if (frameTimes.length === 0) return fetchFailed ? "Radar unavailable" : "Loading radar…"
    if (!framesSettled) return "Loading frames " + (framesLoaded + framesFailed) + "/" + frameTimes.length
    if (fetchFailed) return "Offline — showing last loop"
    if (framesFailed > 0) return framesFailed + " frame(s) unavailable"
    return locationName.toUpperCase() + " · " + frameTimes.length + " frames"
  }

  function isoAt(ms) {
    var d = new Date(ms)
    function p(n) { return (n < 10 ? "0" : "") + n }
    return d.getUTCFullYear() + "-" + p(d.getUTCMonth() + 1) + "-" + p(d.getUTCDate())
      + "T" + p(d.getUTCHours()) + ":" + p(d.getUTCMinutes()) + ":" + p(d.getUTCSeconds()) + "Z"
  }

  // GeoMet advertises the available radar window as
  // "<start>/<end>/PT6M" inside the layer's time Dimension. nearestValue is
  // 0, so every TIME we ask for has to land exactly on that grid.
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
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onActivateRequested: root.playing = !root.playing
      onMoveRequested: function(dx, dy) {
        if (dx === 0 || root.frameTimes.length === 0) return
        root.playing = false
        root.frameIndex = (root.frameIndex + dx + root.frameTimes.length) % root.frameTimes.length
      }
      onTextKey: function(t) {
        if (t === "r" || t === "R") root.refresh()
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

            Image {
              id: basemap
              anchors.fill: parent
              asynchronous: true
              source: root.basemapUrl
              // Knocked back so the radar returns stay the brightest thing on
              // the map without the roads and shorelines becoming unreadable.
              opacity: 0.82
            }

            Repeater {
              model: root.frameTimes

              Image {
                required property int index
                required property string modelData

                anchors.fill: parent
                asynchronous: true
                source: root.frameUrl(modelData)
                // Load-bearing: a rebuilt frame list re-creates every delegate,
                // and Qt's pixmap cache is what keeps that to downloading only
                // the genuinely new timestamps rather than the whole loop.
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

            // Configured location, projected into the bbox.
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

          // Paused badge, so a stopped loop never looks like a stuck fetch.
          Rectangle {
            visible: !root.playing && root.frameTimes.length > 0
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
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: root.playing ? "Click map to pause · R refresh" : "Click map to play · ←/→ step"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }
    }
  }
}
