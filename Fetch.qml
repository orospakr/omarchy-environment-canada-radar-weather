import QtQuick

// One HTTP request at a time, with a hard deadline, bounded retries and a
// size cap — the panel's replacement for shelling out to curl.
//
// QML's XMLHttpRequest has no timeout of its own, and both Environment
// Canada and GeoGratis stall at connect time now and then (measured
// 2026-09-08: roughly one CBMT request in five never answered at all). A
// stalled request would otherwise sit until the socket gave up on its own,
// so every request here is aborted at `timeoutMs` and retried. Redirects
// are followed by Qt itself (an HTTPS-to-HTTP downgrade is refused), so the
// fixed HTTPS origins the callers use are what pin the requests.
QtObject {
  id: fetch

  property int timeoutMs: 8000
  // Attempts after the first: a stall is transient, so one or two retries
  // recover it; anything beyond that is a real outage.
  property int retries: 2
  // Bytes for a binary body, characters for text (a UTF-8 body has at
  // least as many bytes as characters, so a char cap is never looser).
  property int cap: 1000000
  property string what: "request"   // journal label

  readonly property bool busy: current !== null

  // The body — a string, or an ArrayBuffer for a binary request — or null
  // after the last attempt failed, timed out, or overran the cap.
  signal done(var body)

  property var current: null

  property Timer deadline: Timer {
    interval: fetch.timeoutMs
    onTriggered: {
      var req = fetch.current
      if (!req || !req.xhr) return
      var xhr = req.xhr
      req.timedOut = true
      xhr.abort()
      // abort() normally dispatches readystatechange itself; if it did not,
      // the request is still the current one with the same xhr and needs
      // to be failed here.
      if (fetch.current === req && req.xhr === xhr) fetch.failAttempt(req)
    }
  }

  function get(url, binary) {
    return start({ method: "GET", url: url, binary: !!binary })
  }

  function post(url, contentType, payload) {
    return start({ method: "POST", url: url, binary: false, contentType: contentType, payload: String(payload) })
  }

  function start(req) {
    if (current !== null) return false
    req.attempt = 0
    current = req
    send(req)
    return true
  }

  function send(req) {
    var xhr = new XMLHttpRequest()
    req.xhr = xhr
    req.timedOut = false
    if (req.binary) xhr.responseType = "arraybuffer"
    xhr.onreadystatechange = function() {
      if (xhr.readyState !== XMLHttpRequest.DONE) return
      // A stale callback: the deadline already moved this request on.
      if (fetch.current !== req || req.xhr !== xhr) return
      fetch.deadline.stop()
      if (xhr.status !== 200) { fetch.failAttempt(req); return }
      var body = req.binary ? xhr.response : String(xhr.responseText || "")
      var size = req.binary ? (body ? body.byteLength : 0) : body.length
      if (!body || size === 0) { fetch.failAttempt(req); return }
      if (size > fetch.cap) {
        // A bigger response will not shrink on retry.
        console.warn("ca.orospakr.ec-radar-weather: " + fetch.what + " response too large ("
          + size + " > " + fetch.cap + "); ignored")
        fetch.finish(null)
        return
      }
      fetch.finish(body)
    }
    xhr.open(req.method, req.url)
    if (req.contentType) xhr.setRequestHeader("content-type", req.contentType)
    deadline.restart()
    if (req.payload !== undefined) xhr.send(req.payload)
    else xhr.send()
  }

  function failAttempt(req) {
    deadline.stop()
    var reason = req.timedOut ? "timed out after " + timeoutMs + " ms"
      : "failed (HTTP " + (req.xhr ? req.xhr.status : 0) + ")"
    if (req.attempt < retries) {
      req.attempt++
      console.warn("ca.orospakr.ec-radar-weather: " + what + " " + reason + "; retry " + req.attempt + "/" + retries)
      send(req)
      return
    }
    console.warn("ca.orospakr.ec-radar-weather: " + what + " " + reason + "; giving up")
    finish(null)
  }

  function finish(body) {
    deadline.stop()
    current = null
    done(body)
  }
}
