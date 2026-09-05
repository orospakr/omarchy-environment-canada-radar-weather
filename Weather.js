.pragma library
// Weather.js — Environment Canada citypage_weather data layer.
//
// Pure string/regex/JSON functions only: no Qt, no DOM, no XMLHttpRequest.
// Runs identically under Quickshell QML (as a .pragma library import) and
// plain node (for tests — strip the .pragma line before eval'ing).
//
// Feed source: https://dd.weather.gc.ca/today/citypage_weather/{PROV}/{HH}/
//   - {HH} is the UTC hour the file was PUBLISHED in; dirs for future hours
//     of the current UTC day do not exist (404), and there is NO /yesterday
//     root for citypage_weather (verified 2026-09-02). So: probe from the
//     current UTC hour downward to 00 and take the newest file found.

// ---------------------------------------------------------------------------
// Bounds. The feed is untrusted input: every extracted string is truncated,
// every list is capped, and an input larger than MAX_XML_CHARS is refused
// outright, so a malformed or hostile payload can neither balloon memory
// nor push oversized text into the UI. A real citypage file is ~35 KB with
// 12 forecast periods, 24 hourly entries and a handful of warnings; the
// longest real text field is a winter textSummary of a few hundred chars.
// ---------------------------------------------------------------------------
var MAX_XML_CHARS = 1000000;
var MAX_TEXT_CHARS = 160;      // condition, period names, abbreviated summaries
var MAX_SUMMARY_CHARS = 1000;  // full-sentence <textSummary>
var MAX_WARNING_CHARS = 400;   // warning description
var MAX_FORECASTS = 14;
var MAX_HOURLY = 48;
var MAX_WARNINGS = 10;

// Truncate a string field to n chars; null/undefined pass through.
function clip(s, n) {
    if (s === null || s === undefined) return s;
    s = String(s);
    return s.length > n ? s.slice(0, n) : s;
}

// Site codes ("s0000458") and province codes ("ON") come from the remote
// site list and end up in a URL path and a RegExp, so they are checked
// against their exact shapes before use (every code in the published list
// is "s" + 7 digits; provinces are two capitals).
var SITE_CODE_RE = /^s\d{7}$/;
var PROVINCE_RE = /^[A-Z]{2}$/;
function validSiteCode(code) { return SITE_CODE_RE.test(String(code || "")); }
function validProvince(prov) { return PROVINCE_RE.test(String(prov || "")); }

// ---------------------------------------------------------------------------
// Tiny tolerant XML helpers (regex over well-formed EC XML; good enough here)
// ---------------------------------------------------------------------------

// Decode the five standard entities plus numeric character references.
function decodeEntities(s) {
    if (s === null || s === undefined) return s;
    return s
        .replace(/&#x([0-9a-fA-F]+);/g, function (_, h) { return String.fromCharCode(parseInt(h, 16)); })
        .replace(/&#(\d+);/g, function (_, d) { return String.fromCharCode(parseInt(d, 10)); })
        .replace(/&lt;/g, "<").replace(/&gt;/g, ">")
        .replace(/&quot;/g, '"').replace(/&apos;/g, "'")
        .replace(/&amp;/g, "&"); // last, so &amp;lt; doesn't double-decode
}

// All occurrences of <tag ...>inner</tag> (or self-closing <tag ... />) in xml.
// Returns [{ open: full opening tag, inner: raw inner text ("" if self-closed) }].
// Non-greedy inner match — fine for EC's flat, non-self-nested elements.
function elements(xml, tag) {
    var out = [];
    if (!xml) return out;
    var re = new RegExp("<" + tag + "((?:\\s[^>]*)?)(/?)>", "g");
    var m;
    while ((m = re.exec(xml)) !== null) {
        if (m[2] === "/") { // self-closing
            out.push({ open: m[0], inner: "" });
            continue;
        }
        var close = xml.indexOf("</" + tag + ">", re.lastIndex);
        if (close < 0) { out.push({ open: m[0], inner: "" }); continue; }
        out.push({ open: m[0], inner: xml.slice(re.lastIndex, close) });
        re.lastIndex = close + tag.length + 3;
    }
    return out;
}

function firstElement(xml, tag) {
    var els = elements(xml, tag);
    return els.length ? els[0] : null;
}

// Decoded, trimmed text content of the first <tag> in xml, or null if
// absent/empty (EC uses empty elements, e.g. <gust ...></gust>, for "no data").
function textOf(xml, tag) {
    var el = firstElement(xml, tag);
    if (!el) return null;
    var t = decodeEntities(el.inner.replace(/<[^>]*>/g, "")).replace(/\s+/g, " ").trim();
    return t === "" ? null : t;
}

// Attribute value from an opening tag string, decoded; null if absent.
function attrOf(openTag, name) {
    if (!openTag) return null;
    var m = openTag.match(new RegExp("\\b" + name + '\\s*=\\s*"([^"]*)"'));
    return m ? decodeEntities(m[1]) : null;
}

// Number or null (tolerates "-2.5"; rejects "" and non-numeric like "calm").
function numOf(s) {
    if (s === null || s === undefined) return null;
    var n = parseFloat(s);
    return isNaN(n) ? null : n;
}

// EC timeStamp "YYYYMMDDHHMMSS" (or dateTimeUTC "YYYYMMDDHHMM") -> epoch ms UTC.
function stampToMs(stamp) {
    if (!stamp) return null;
    var m = String(stamp).match(/^(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})?$/);
    if (!m) return null;
    return Date.UTC(+m[1], +m[2] - 1, +m[3], +m[4], +m[5], m[6] ? +m[6] : 0);
}

// Epoch ms from the zone="UTC" <dateTime> in scope (dateTime elements come in
// UTC/local pairs — we always want the UTC one). Optional name filter.
function utcDateTimeMs(xml, name) {
    var els = elements(xml, "dateTime");
    for (var i = 0; i < els.length; i++) {
        if (attrOf(els[i].open, "zone") !== "UTC") continue;
        if (name && attrOf(els[i].open, "name") !== name) continue;
        var ms = stampToMs(textOf(els[i].inner, "timeStamp"));
        if (ms !== null) return ms;
    }
    return null;
}

// Zero-pad an icon code to two digits ("9" -> "09"); null-safe.
function padIcon(code) {
    if (code === null || code === undefined) return null;
    var s = String(code).trim();
    return s.length === 1 ? "0" + s : s;
}

// ---------------------------------------------------------------------------
// parseCitypage
// ---------------------------------------------------------------------------

function parseCitypage(xmlText) {
    if (!xmlText || xmlText.length > MAX_XML_CHARS) return null;
    if (xmlText.indexOf("<siteData") < 0) return null;

    // --- currentConditions (can be sparse or missing entirely at some sites)
    var current = {
        temperature: null, condition: null, iconCode: null,
        humidity: null, humidex: null, windChill: null,
        wind: null, observedAt: null
    };
    var cc = firstElement(xmlText, "currentConditions");
    if (cc && cc.inner.trim() !== "") {
        current.temperature = numOf(textOf(cc.inner, "temperature"));
        current.condition = clip(textOf(cc.inner, "condition"), MAX_TEXT_CHARS);
        current.iconCode = padIcon(textOf(cc.inner, "iconCode"));
        current.humidity = numOf(textOf(cc.inner, "relativeHumidity"));
        current.humidex = numOf(textOf(cc.inner, "humidex"));     // observed; often absent
        current.windChill = numOf(textOf(cc.inner, "windChill")); // observed; often absent
        current.observedAt = utcDateTimeMs(cc.inner, "observation");
        var w = firstElement(cc.inner, "wind");
        if (w) {
            current.wind = {
                speed: numOf(textOf(w.inner, "speed")),      // km/h
                gust: numOf(textOf(w.inner, "gust")),        // often empty -> null
                direction: clip(textOf(w.inner, "direction"), MAX_TEXT_CHARS) // e.g. "E", "VR"
            };
        }
    }

    // --- forecastGroup: issue time + 12 day/night forecast entries
    var forecasts = [];
    var issuedAt = null;
    var fg = firstElement(xmlText, "forecastGroup");
    if (fg) {
        issuedAt = utcDateTimeMs(fg.inner, "forecastIssue");
        var fEls = elements(fg.inner, "forecast");
        for (var i = 0; i < fEls.length && i < MAX_FORECASTS; i++) {
            var f = fEls[i].inner;
            var periodEl = firstElement(f, "period");
            var abbrev = firstElement(f, "abbreviatedForecast");
            var temps = firstElement(f, "temperatures");
            var temperature = null;
            if (temps) {
                var tEl = firstElement(temps.inner, "temperature");
                if (tEl) {
                    temperature = {
                        value: numOf(decodeEntities(tEl.inner.trim())),
                        "class": attrOf(tEl.open, "class") // "high" | "low"
                    };
                }
            }
            forecasts.push({
                // textForecastName is the friendly label ("Tonight", "Wednesday")
                period: periodEl ? clip(attrOf(periodEl.open, "textForecastName") ||
                                         decodeEntities(periodEl.inner.trim()), MAX_TEXT_CHARS) : null,
                // First <textSummary> inside <forecast> is the direct child
                // (full sentence forecast); <period> precedes it and holds none.
                textSummary: clip(textOf(f, "textSummary"), MAX_SUMMARY_CHARS),
                summary: abbrev ? clip(textOf(abbrev.inner, "textSummary"), MAX_TEXT_CHARS) : null,
                iconCode: abbrev ? padIcon(textOf(abbrev.inner, "iconCode")) : null,
                temperature: temperature,
                pop: abbrev ? numOf(textOf(abbrev.inner, "pop")) : null
            });
        }
    }

    // --- hourlyForecastGroup: usually 24 entries, keyed by dateTimeUTC attr
    var hourly = [];
    var hg = firstElement(xmlText, "hourlyForecastGroup");
    if (hg) {
        var hEls = elements(hg.inner, "hourlyForecast");
        for (var j = 0; j < hEls.length && j < MAX_HOURLY; j++) {
            var h = hEls[j];
            hourly.push({
                at: stampToMs(attrOf(h.open, "dateTimeUTC")),
                temperature: numOf(textOf(h.inner, "temperature")),
                condition: clip(textOf(h.inner, "condition"), MAX_TEXT_CHARS),
                iconCode: padIcon(textOf(h.inner, "iconCode")),
                lop: numOf(textOf(h.inner, "lop")),          // chance of precip %
                windChill: numOf(textOf(h.inner, "windChill")), // empty in summer
                humidex: numOf(textOf(h.inner, "humidex"))      // empty in winter
            });
        }
    }

    // --- warnings: attributes on <event>; often <warnings/> (empty).
    // Newer feed uses alertColourLevel instead of the old priority attribute;
    // fall back to it so `priority` stays useful ("yellow"/"red"...).
    var warnings = [];
    var wBlock = firstElement(xmlText, "warnings");
    if (wBlock) {
        var evs = elements(wBlock.inner, "event");
        for (var k = 0; k < evs.length && k < MAX_WARNINGS; k++) {
            warnings.push({
                description: clip(attrOf(evs[k].open, "description"), MAX_WARNING_CHARS),
                type: clip(attrOf(evs[k].open, "type"), MAX_TEXT_CHARS),
                priority: clip(attrOf(evs[k].open, "priority") ||
                               attrOf(evs[k].open, "alertColourLevel"), MAX_TEXT_CHARS)
            });
        }
    }

    // --- riseSet: sunrise/sunset (UTC pair members)
    var sunrise = null, sunset = null;
    var rs = firstElement(xmlText, "riseSet");
    if (rs) {
        sunrise = utcDateTimeMs(rs.inner, "sunrise");
        sunset = utcDateTimeMs(rs.inner, "sunset");
    }

    return {
        current: current,
        forecasts: forecasts,
        hourly: hourly,
        warnings: warnings,
        sunrise: sunrise,
        sunset: sunset,
        issuedAt: issuedAt
    };
}

// ---------------------------------------------------------------------------
// Icon mapping (EC iconCode 00-48 -> Nerd Font / Material Design glyphs)
// ---------------------------------------------------------------------------

var _GLYPH = {
    "00": "\u{F0599}", // sunny                     󰖙
    "01": "\u{F0599}", // mainly sunny              󰖙
    "02": "\u{F0595}", // mix of sun and cloud      󰖕
    "03": "\u{F0595}", // mostly cloudy (day)       󰖕
    "04": "\u{F0595}", // increasing cloudiness     󰖕
    "05": "\u{F0595}", // clearing                  󰖕
    "06": "\u{F0597}", // chance of showers         󰖗
    "07": "\u{F067F}", // rain or snow showers      󰙿
    "08": "\u{F0598}", // snow showers/flurries     󰖘
    "09": "\u{F0593}", // thundershowers            󰖓
    "10": "\u{F0590}", // cloudy                    󰖐
    "11": "\u{F0597}", // light rain / drizzle      󰖗
    "12": "\u{F0596}", // rain                      󰖖
    "13": "\u{F0596}", // heavy rain                󰖖
    "14": "\u{F0592}", // freezing rain             󰖒
    "15": "\u{F067F}", // rain and snow             󰙿
    "16": "\u{F0598}", // light snow                󰖘
    "17": "\u{F0598}", // snow                      󰖘
    "18": "\u{F0598}", // heavy snow                󰖘
    "19": "\u{F0593}", // thunderstorm              󰖓
    "22": "\u{F0595}", // mix (day)                 󰖕
    "23": "\u{F0F30}", // haze                      󰼰
    "24": "\u{F0591}", // fog                       󰖑
    "25": "\u{F0598}", // drifting snow             󰖘
    "26": "\u{F0592}", // ice                       󰖒
    "27": "\u{F0592}", // hail                      󰖒
    "28": "\u{F0597}", // drizzle                   󰖗
    "30": "\u{F0594}", // clear night               󰖔
    "31": "\u{F0F31}", // few clouds (night)        󰼱
    "32": "\u{F0F31}", // partly cloudy (night)     󰼱
    "33": "\u{F0F31}", // mostly cloudy (night)     󰼱
    "34": "\u{F0F31}", // increasing cloud (night)  󰼱
    "35": "\u{F0594}", // clearing (night)          󰖔
    "36": "\u{F0F31}", // night mix                 󰼱
    "37": "\u{F0597}", // night rain showers        󰖗
    "38": "\u{F0598}", // night snow showers        󰖘
    "39": "\u{F0593}", // night thundershowers      󰖓
    "40": "\u{F0598}", // blowing snow              󰖘
    "43": "\u{F059D}", // windy                     󰖝
    "44": "\u{F0591}", // smoke                     󰖑
    "46": "\u{F0593}", // thunderstorm with hail    󰖓
    "47": "\u{F0593}", // thunderstorm (variant)    󰖓
    "48": "\u{F0593}"  // thunderstorm (variant)    󰖓
};

function iconGlyph(iconCode) {
    var g = _GLYPH[padIcon(iconCode)];
    return g !== undefined ? g : "\u{F0590}"; // unknown -> cloudy 󰖐
}

// Severe-ish categories: thunderstorms and freezing precip / ice / hail.
var _SEVERE = { "09": 1, "14": 1, "19": 1, "26": 1, "27": 1, "39": 1, "46": 1, "47": 1, "48": 1 };

function iconIsSevere(iconCode) {
    return _SEVERE[padIcon(iconCode)] === 1;
}

// Bar tint for a warning/advisory. EC's alertColourLevel (surfaced on the
// warning as `priority`, alongside the legacy priority attr's values) wins;
// fall back to the event type. Returns a colour string, or null for
// grey/informational events -- the caller renders those muted.
function warningColour(warning) {
    var level = ((warning && warning.priority) || "").toLowerCase();
    if (level === "red" || level === "urgent") return "#e0524d";
    if (level === "orange" || level === "high") return "#e08b3c";
    if (level === "yellow" || level === "medium") return "#e3b341";
    if (level === "grey" || level === "gray" || level === "low") return null;
    var type = ((warning && warning.type) || "").toLowerCase();
    if (type === "warning") return "#e0524d";
    if (type === "watch") return "#e08b3c";
    if (type === "advisory") return "#e3b341";
    return null;
}

// ---------------------------------------------------------------------------
// Fetch-strategy helpers (the QML side does the actual HTTP)
// ---------------------------------------------------------------------------

// Directory listings to probe, newest-plausible first: today's dirs from the
// current UTC hour down to 00. Dirs for hours that haven't happened yet 404,
// and /yesterday/citypage_weather does not exist, so right after 00:00 UTC
// the only dir is {PROV}/00/ — which is populated within minutes of rollover
// (EC republishes every site into 00/ shortly after midnight UTC). If even
// 00/ has no match yet, keep the previously fetched data and retry later.
function citypageProbeUrls(provinceCode, utcNowMs) {
    var prov = String(provinceCode).toUpperCase();
    if (!validProvince(prov)) return []; // never interpolate an unvetted code into the path
    var hourNow = new Date(utcNowMs).getUTCHours();
    var urls = [];
    for (var h = hourNow; h >= 0; h--) {
        urls.push("https://dd.weather.gc.ca/today/citypage_weather/" + prov + "/" +
                  (h < 10 ? "0" + h : String(h)) + "/");
    }
    return urls;
}

// From an Apache directory-listing HTML page, pick the newest file for a site:
// filenames are "{ISO-instant}_MSC_CitypageWeather_{siteCode}_{lang}.xml", so
// the lexicographically greatest match is the newest. Returns filename or null.
function pickCitypageFile(listingHtml, siteCode, lang) {
    if (!listingHtml) return null;
    // siteCode lands inside a RegExp and the result inside a URL path.
    if (!validSiteCode(siteCode) || !/^(en|fr)$/.test(String(lang))) return null;
    var re = new RegExp('href="([^"/]*_MSC_CitypageWeather_' + siteCode + "_" + lang + '\\.xml)"', "g");
    var best = null, m;
    while ((m = re.exec(listingHtml)) !== null) {
        if (best === null || m[1] > best) best = m[1];
    }
    return best;
}
