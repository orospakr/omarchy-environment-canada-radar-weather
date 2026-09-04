.pragma library

// Environment Canada citypage site list, e.g.
//   s0000458,Toronto,ON,43.65N,79.38W
// Two header rows, then one site per line. The published file uses no
// quoting (verified against the full list), so a plain split is enough.
function parseSiteList(csvText) {
  var out = []
  var lines = String(csvText || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var parts = lines[i].trim().split(",")
    if (parts.length < 5) continue
    var code = parts[0].trim()
    if (!/^s\d+$/.test(code)) continue // skips both header rows
    var lat = parseHemisphere(parts[3], "N", "S")
    var lon = parseHemisphere(parts[4], "E", "W")
    if (lat === null || lon === null) continue
    out.push({
      siteCode: code,
      name: parts[1].trim(),
      province: parts[2].trim(),
      latitude: lat,
      longitude: lon
    })
  }
  return out
}

// "43.65N" -> 43.65, "79.38W" -> -79.38
function parseHemisphere(raw, positive, negative) {
  var m = String(raw || "").trim().match(/^(\d+(?:\.\d+)?)([A-Za-z])$/)
  if (!m) return null
  var value = parseFloat(m[1])
  if (!isFinite(value)) return null
  var hemi = m[2].toUpperCase()
  if (hemi === positive) return value
  if (hemi === negative) return -value
  return null
}

// Lowercase and strip diacritics, so "montreal" matches "Montréal" (and
// an accented query matches either way). NFD + combining-mark strip does
// the general job; the charmap catches what NFD leaves alone (ligatures,
// curly apostrophe) and, covering every accented letter the site list
// actually uses, doubles as a full fallback if the engine lacks
// String.normalize.
var FOLD_MAP = {
  "à": "a", "â": "a", "ä": "a", "ç": "c", "è": "e", "é": "e", "ê": "e",
  "ë": "e", "î": "i", "ï": "i", "ô": "o", "ö": "o", "ù": "u", "û": "u",
  "ü": "u", "ÿ": "y", "æ": "ae", "œ": "oe", "ø": "o", "ß": "ss", "’": "'"
}
function fold(value) {
  var s = String(value || "").toLowerCase()
  if (s.normalize) s = s.normalize("NFD").replace(/[\u0300-\u036f]/g, "")
  return s.replace(/[^\x20-\x7e]/g, function(ch) { return FOLD_MAP[ch] || ch })
}

// Case- and accent-insensitive substring match over name and province.
function filterSites(sites, query) {
  var q = fold(String(query || "").trim())
  if (!q) return sites
  var out = []
  for (var i = 0; i < sites.length; i++) {
    var s = sites[i]
    if (fold(s.name).indexOf(q) !== -1
        || s.province.toLowerCase().indexOf(q) !== -1) out.push(s)
  }
  return out
}

// Nearest site to a fix, equirectangular distance — plenty for naming a
// ~25 km geoip fix; no need for haversine at these spans.
// Great-circle distance in kilometres (haversine). nearestSite() only
// ranks, so its flat approximation is fine there; a coverage threshold
// needs the real thing.
function distanceKm(lat1, lon1, lat2, lon2) {
  var r = Math.PI / 180
  var dLat = (lat2 - lat1) * r
  var dLon = (lon2 - lon1) * r
  var a = Math.sin(dLat / 2) * Math.sin(dLat / 2)
    + Math.cos(lat1 * r) * Math.cos(lat2 * r) * Math.sin(dLon / 2) * Math.sin(dLon / 2)
  return 2 * 6371 * Math.asin(Math.sqrt(Math.min(1, a)))
}

function nearestSite(sites, lat, lon) {
  var best = null
  var bestD = Infinity
  var cosLat = Math.cos(lat * Math.PI / 180)
  for (var i = 0; i < sites.length; i++) {
    var s = sites[i]
    var dLat = s.latitude - lat
    var dLon = (s.longitude - lon) * cosLat
    var d = dLat * dLat + dLon * dLon
    if (d < bestD) { bestD = d; best = s }
  }
  return best
}

// BeaconDB /v1/geolocate response:
//   {"accuracy":25000,"location":{"lat":45.03,"lng":-79.32},...}
function parseGeolocate(raw) {
  try {
    var data = JSON.parse(String(raw || ""))
    var loc = data && data.location
    var lat = loc ? Number(loc.lat) : NaN
    var lon = loc ? Number(loc.lng) : NaN
    if (!isFinite(lat) || !isFinite(lon)) return null
    return { latitude: lat, longitude: lon, accuracy: Number(data.accuracy) || 0 }
  } catch (e) {
    return null
  }
}
