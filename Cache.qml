import QtQuick
import Quickshell.Io

// The panel's on-disk cache, one bin/ec-cache call at a time.
//
// The shell never opens anything under ~/.cache itself: the helper walks
// the directory chain with no-follow, owner-checked descriptors and
// replaces files atomically relative to them (see bin/ec-cache). Calls are
// serialised, and a write queued behind another for the same name just
// replaces its contents, so a burst of index saves costs one process.
//
// The helper only ever touches the local disk and answers in well under a
// second; the deadline is a backstop for a wedged filesystem.
Item {
  id: cache

  readonly property string helperPath: Qt.resolvedUrl("bin/ec-cache").toString().replace(/^file:\/\//, "")
  property int timeoutMs: 10000

  property var queue: []
  property var current: null

  // `done(ok, out)`: ok is false for a missing file as well as a refused or
  // failed one (the reason is in the journal); out is the helper's stdout —
  // the file for a read, a basemap as base64.
  function read(name, done) {
    enqueue({ op: "read", name: name, done: done })
  }

  function write(name, data, done) {
    for (var i = 0; i < queue.length; i++) {
      var q = queue[i]
      if (q.op === "write" && q.name === name) {
        q.data = String(data)
        // Both callers asked; both hear how it went.
        var first = q.done
        q.done = function(ok, out) {
          if (first) first(ok, out)
          if (done) done(ok, out)
        }
        return
      }
    }
    enqueue({ op: "write", name: name, data: String(data), done: done })
  }

  function enqueue(req) {
    var q = queue.slice()
    q.push(req)
    queue = q
    pump()
  }

  function pump() {
    if (current !== null || queue.length === 0) return
    var q = queue.slice()
    var req = q.shift()
    queue = q
    current = req
    var job = jobComponent.createObject(cache, { req: req })
    if (!job) {
      console.warn("ca.orospakr.ec-radar-weather: could not create the cache helper process")
      finish(req, false, "")
      return
    }
    job.start()
  }

  // Only the job in flight ever answers (once), so this always frees the
  // slot. No identity check: a JS object read back through a `property var`
  // is not guaranteed to be the object that was stored.
  function finish(req, ok, out) {
    current = null
    try {
      if (req.done) req.done(ok, out)
    } catch (e) {
      console.warn("ca.orospakr.ec-radar-weather: cache callback threw: " + e)
    }
    pump()
  }

  // ArrayBuffer -> base64, for handing a basemap to the helper over stdin
  // (Process.write takes text) and for the map Image's data: URL. Qt.btoa
  // would UTF-8-encode bytes above 0x7F first.
  readonly property string b64chars: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
  function base64(buf) {
    var b = new Uint8Array(buf)
    var c = b64chars
    var out = []
    var i = 0
    for (; i + 2 < b.length; i += 3) {
      var n = (b[i] << 16) | (b[i + 1] << 8) | b[i + 2]
      out.push(c[n >> 18] + c[(n >> 12) & 63] + c[(n >> 6) & 63] + c[n & 63])
    }
    if (i < b.length) {
      var m = b[i] << 16
      if (i + 1 < b.length) m |= b[i + 1] << 8
      out.push(c[m >> 18] + c[(m >> 12) & 63]
        + (i + 1 < b.length ? c[(m >> 6) & 63] : "=") + "=")
    }
    return out.join("")
  }

  // An Item rather than a bare Process so it can hold its deadline Timer.
  Component {
    id: jobComponent

    Item {
      id: job
      property var req: null
      property bool launched: false
      property bool answered: false

      function answer(ok, out) {
        if (job.answered) return
        job.answered = true
        cache.finish(job.req, ok, out)
      }

      function start() {
        proc.command = ["python3", cache.helperPath, job.req.op, job.req.name]
        proc.stdinEnabled = job.req.op === "write"
        proc.running = true
      }

      Process {
        id: proc
        running: false
        stdout: StdioCollector { id: out; waitForEnd: true }
        stderr: StdioCollector { id: err; waitForEnd: true }
        onStarted: {
          job.launched = true
          if (job.req.op !== "write") return
          proc.write(job.req.data)
          proc.stdinEnabled = false   // closes stdin: the helper reads to EOF
        }
        onExited: function(exitCode, exitStatus) {
          // 3 is "no such file": an empty cache, not worth a journal line.
          if (exitCode !== 0 && exitCode !== 3) {
            var why = String(err.text || "").trim() || ("exit status " + exitCode)
            console.warn("ca.orospakr.ec-radar-weather: cache " + job.req.op + " " + job.req.name + " failed: " + why)
          }
          job.answer(exitCode === 0, exitCode === 0 ? String(out.text || "") : "")
          job.destroy()
        }
        // Quickshell reports a process that never started (python3 missing)
        // by clearing `running` without an `exited`.
        onRunningChanged: {
          if (proc.running || job.launched || job.answered) return
          console.warn("ca.orospakr.ec-radar-weather: cache helper could not be started (is python3 installed?)")
          job.answer(false, "")
          job.destroy()
        }
      }

      Timer {
        interval: cache.timeoutMs
        running: proc.running && !job.answered
        onTriggered: {
          console.warn("ca.orospakr.ec-radar-weather: cache " + job.req.op + " " + job.req.name + " timed out")
          job.answer(false, "")
          proc.signal(9)
        }
      }
    }
  }
}
