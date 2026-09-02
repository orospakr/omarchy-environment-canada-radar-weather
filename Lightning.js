.pragma library

// Lightning overlay for the radar map, from the same internal feed the
// weather.gc.ca map draws:
//   GET .../Lightning/metadata/1
//     -> ["2026-09-02_180600", "2026-09-02_181200.msg", ...]
//        UTC bin end times, 6-minute cadence, last hour. ".msg" entries are
//        placeholders for bins the feed doesn't have; drop them.
//   GET .../Lightning/1/<bin>?clusterDistance=<0.5|1.5|3>
//     -> GeoJSON FeatureCollection of Points; properties {} for a single
//        strike, {numPoints: N} for a server-side cluster.
// The bin named T covers the six minutes ending at T, so bin ends line up
// with the radar frame timestamps ("YYYY-MM-DDTHH:MM:SSZ") the panel keys
// frames by.
//
// Pure string/JSON functions only, no Qt: runs identically under QML and
// under node for tests (strip the .pragma line, then eval).

var METADATA_URL = "https://weather.gc.ca/api/app/v2/Lightning/metadata/1"

function binUrl(bin, clusterDistance) {
  return "https://weather.gc.ca/api/app/v2/Lightning/1/" + bin
    + "?clusterDistance=" + clusterDistance
}

// "2026-09-02_190600" -> "2026-09-02T19:06:00Z"; null for anything else
// (including the ".msg" placeholders).
function binToIso(bin) {
  var m = String(bin || "").match(/^(\d{4}-\d{2}-\d{2})_(\d{2})(\d{2})(\d{2})$/)
  if (!m) return null
  return m[1] + "T" + m[2] + ":" + m[3] + ":" + m[4] + "Z"
}

// "2026-09-02T19:06:00Z" -> "2026-09-02_190600"; null if not that form.
function isoToBin(iso) {
  var m = String(iso || "").match(/^(\d{4}-\d{2}-\d{2})T(\d{2}):(\d{2}):(\d{2})Z$/)
  if (!m) return null
  return m[1] + "_" + m[2] + m[3] + m[4]
}

// Metadata JSON (text or already-parsed array) -> ascending, de-duplicated
// list of valid bin names. [] on anything unparseable.
function parseMetadata(text) {
  var list
  try {
    list = typeof text === "string" ? JSON.parse(text) : text
  } catch (e) {
    return []
  }
  if (!list || typeof list.length !== "number") return []
  var seen = {}
  var out = []
  for (var i = 0; i < list.length; i++) {
    var bin = String(list[i])
    if (binToIso(bin) === null) continue
    if (seen[bin]) continue
    seen[bin] = true
    out.push(bin)
  }
  // Bin names are fixed-width and zero-padded, so a plain string sort is
  // chronological.
  out.sort()
  return out
}

// Bin JSON (text or parsed object) ->
//   { from, to, points: [{ lon, lat, n }] }
// n is the cluster size (1 for a lone strike). Features without a Point
// geometry or with non-finite coordinates are skipped.
function parseBin(text) {
  var empty = { from: null, to: null, points: [] }
  var data
  try {
    data = typeof text === "string" ? JSON.parse(text) : text
  } catch (e) {
    return empty
  }
  if (!data || typeof data !== "object") return empty
  var features = data.features
  var points = []
  if (features && typeof features.length === "number") {
    for (var i = 0; i < features.length; i++) {
      var f = features[i]
      var g = f && f.geometry
      if (!g || g.type !== "Point") continue
      var c = g.coordinates
      if (!c || typeof c.length !== "number" || c.length < 2) continue
      var lon = Number(c[0])
      var lat = Number(c[1])
      if (!isFinite(lon) || !isFinite(lat)) continue
      var n = f.properties ? Number(f.properties.numPoints) : NaN
      points.push({ lon: lon, lat: lat, n: n >= 1 ? Math.floor(n) : 1 })
    }
  }
  return {
    from: typeof data.dateFrom === "string" ? data.dateFrom : null,
    to: typeof data.dateTo === "string" ? data.dateTo : null,
    points: points
  }
}

// Server-side cluster radius to request for a map span, mirroring the
// site's zoom bands: tight when zoomed in, coarse for a whole-country view.
function clusterDistanceFor(spanKm) {
  if (spanKm <= 450) return 0.5
  if (spanKm <= 1500) return 1.5
  return 3
}

// Legend bands on the site: 1-5 / 6-25 / 26-100 / 101+ strikes.
function bucket(n) {
  if (n < 6) return 0
  if (n < 26) return 1
  if (n < 101) return 2
  return 3
}

// Glyph height in px per bucket.
var SIZES = [11, 14, 18, 22]
function sizeFor(b) {
  return SIZES[Math.max(0, Math.min(3, b | 0))]
}

// The site hides the layer once the newest bin is over an hour old; do the
// same rather than draw strikes that stopped being news.
var STALE_MS = 60 * 60 * 1000
function isStale(latestIso, nowMs) {
  if (!latestIso) return true
  var t = Date.parse(latestIso)
  if (!isFinite(t)) return true
  return nowMs - t > STALE_MS
}

// Points inside a lat/lon box, with a small margin so a glyph straddling
// the edge still gets drawn (and clipped) rather than popping.
function pointsInBox(points, minLat, maxLat, minLon, maxLon) {
  var mLat = (maxLat - minLat) * 0.005
  var mLon = (maxLon - minLon) * 0.005
  var out = []
  for (var i = 0; i < points.length; i++) {
    var p = points[i]
    if (p.lat < minLat - mLat || p.lat > maxLat + mLat) continue
    if (p.lon < minLon - mLon || p.lon > maxLon + mLon) continue
    out.push(p)
  }
  return out
}

// Filled bolt polygon in a unit box, top to bottom: a slanted upper stroke,
// a jog left at the waist, and a tapering lower stroke ending in a point.
// Scale x and y by the same glyph height; the shape is ~0.65 wide.
var BOLT = [
  [0.62, 0.00],
  [0.18, 0.56],
  [0.46, 0.56],
  [0.36, 1.00],
  [0.84, 0.40],
  [0.56, 0.40],
  [0.70, 0.00]
]
