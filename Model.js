.pragma library

// Pure helpers shared by the service, bar widget, dropdown and overlay.
// Vocabulary follows CONTEXT.md.

// ---- Identity ---------------------------------------------------------------

// Pins survive restarts, so they key on what the App *is*, not on its PID.
function pinKey(app) {
  if (!app) return ""
  if (app.kind === "job") return "job:" + (app.name || "")
  if (app.unit) return "unit:" + app.unit.replace(/-[0-9a-f]{8}\.scope$/, "").replace(/-\d+\.scope$/, "")
  return app.kind + ":" + (app.name || "")
}

function isPinned(pins, app) {
  if (!pins || !pins.length) return false
  var key = pinKey(app)
  for (var i = 0; i < pins.length; i++) if (pins[i] === key) return true
  return false
}

// ---- Formatting -------------------------------------------------------------

// Always "ddd" + unit (3 significant figures), so a value never changes width
// as it moves: 0.26K, 5.18K, 12.0M, 145M, 1.54G. Monospace keeps it aligned.
function bytes(n) {
  n = Number(n) || 0
  var units = ["K", "M", "G", "T"]
  var u = 0
  n /= 1024
  while (n >= 1000 && u < units.length - 1) { n /= 1024; u++ }
  var s = n >= 100 ? Math.round(n).toString() : n >= 10 ? n.toFixed(1) : n.toFixed(2)
  return s + units[u]
}

function rate(n) {
  return bytes(n) + "/s"
}

// Always one decimal: "0.0%", "38.2%", "100.0%". No width dance between 9% and 10%.
function pct(n, digits) {
  n = Number(n)
  if (!isFinite(n) || n < 0) return "--"
  return n.toFixed(1) + "%"
}

// Human span for an axis: 120s → "2m", 600s → "10m", 45s → "45s".
function span(ms) {
  var s = Math.round(ms / 1000)
  if (s < 60) return s + "s"
  var m = Math.round(s / 60)
  if (m < 60) return m + "m"
  return Math.round(m / 60) + "h"
}

function temp(c) {
  c = Number(c)
  if (!isFinite(c) || c <= 0) return "--"
  return Math.round(c) + "°"
}

function watts(w) {
  w = Number(w)
  if (!isFinite(w) || w <= 0) return "--"
  return w.toFixed(1) + "W"
}

function age(startedSec, nowMs) {
  var s = Math.max(0, Math.round(nowMs / 1000 - Number(startedSec || 0)))
  if (s < 60) return s + "s"
  var m = Math.floor(s / 60)
  if (m < 60) return m + "m"
  var h = Math.floor(m / 60)
  if (h < 24) return h + "h" + (m % 60 ? (m % 60) + "m" : "")
  return Math.floor(h / 24) + "d"
}

function ports(list) {
  if (!list || !list.length) return ""
  return list.map(function(p) { return ":" + p }).join(" ")
}

// ---- Sections ---------------------------------------------------------------

// Builds the overlay list: Recent (newest first, stable), Pinned, then Buckets.
// Returns flat rows: { type: "header"|"app", section, app, label, collapsed }.
var BUCKETS = ["user", "system", "desktop", "kernel"]
var BUCKET_LABEL = { user: "User", system: "System", desktop: "Desktop", kernel: "Kernel" }
function bucketOf(app) {
  if (app.kind === "job" || app.bucket === "apps") return "user"
  if (app.bucket === "services") return "system"
  return app.bucket
}

function sections(apps, offenders, pins, filter, sortKey, collapsed) {
  var f = (filter || "").trim().toLowerCase()
  var rows = []
  var recent = [], pinned = [], buckets = { user: [], system: [], desktop: [], kernel: [] }

  for (var i = 0; i < apps.length; i++) {
    var a = apps[i]
    if (f && !matches(a, f)) continue
    if (a.recent && (a.kind === "job" || a.bucket === "apps")) recent.push(a)
    else if (a.pinned) pinned.push(a)
    else (buckets[bucketOf(a)] || buckets.system).push(a)
  }
  var heavy = []
  for (var o = 0; o < (offenders ? offenders.length : 0); o++) {
    if (f && !matches(offenders[o], f)) continue
    heavy.push(offenders[o])
  }

  // Recent keeps the order things were started, newest first. Never by usage.
  recent.sort(function(x, y) { return (y.started || 0) - (x.started || 0) })
  pinned.sort(byName)

  function push(section, label, list) {
    if (!list.length) return
    var isCollapsed = collapsed && collapsed[section] === true
    rows.push({ type: "header", section: section, label: label, count: list.length, collapsed: isCollapsed })
    if (isCollapsed) return
    for (var k = 0; k < list.length; k++) rows.push({ type: "app", section: section, app: list[k] })
  }

  push("recent", "Recent", recent)
  push("offenders", "Offenders", heavy)
  push("pinned", "Pinned", pinned)
  for (var b = 0; b < BUCKETS.length; b++) {
    var list = buckets[BUCKETS[b]]
    list.sort(sorter(sortKey))
    push(BUCKETS[b], BUCKET_LABEL[BUCKETS[b]], list)
  }
  return rows
}

function matches(app, f) {
  if ((app.name || "").toLowerCase().indexOf(f) !== -1) return true
  if ((app.cmd || "").toLowerCase().indexOf(f) !== -1) return true
  if ((app.tag || "").toLowerCase().indexOf(f) !== -1) return true
  var p = f.replace(/^:/, "")
  if (/^\d+$/.test(p) && app.ports) {
    for (var i = 0; i < app.ports.length; i++) if (String(app.ports[i]).indexOf(p) === 0) return true
  }
  return false
}

function byName(x, y) {
  var a = (x.name || "").toLowerCase(), b = (y.name || "").toLowerCase()
  return a < b ? -1 : a > b ? 1 : 0
}

function sorter(key) {
  if (key === "mem") return function(x, y) { return (y.mem || 0) - (x.mem || 0) || byName(x, y) }
  if (key === "name") return byName
  if (key === "gpu") return function(x, y) { return (y.gpu || 0) - (x.gpu || 0) || byName(x, y) }
  return function(x, y) { return (y.cpu || 0) - (x.cpu || 0) || byName(x, y) }
}

function topApps(apps, n) {
  var list = apps.filter(function(a) { return a.bucket === "apps" || a.kind === "job" })
  list.sort(sorter("cpu"))
  return list.slice(0, n)
}

function pinnedApps(apps) {
  return apps.filter(function(a) { return a.pinned }).sort(byName)
}

// Meter scales per section: the worst value in the section sets the full
// bar, with a floor so a quiet machine does not show every bar full.
function scales(rows) {
  var out = {}
  for (var i = 0; i < rows.length; i++) {
    var r = rows[i]
    if (r.type !== "app") continue
    var s = out[r.section] || (out[r.section] = { cpu: 5, mem: 256 * 1024 * 1024 })
    var avg = r.section === "offenders"
    var c = avg && r.app.avgCpu !== undefined ? r.app.avgCpu : r.app.cpu
    var mm = avg && r.app.avgMem !== undefined ? r.app.avgMem : r.app.mem
    if (c > s.cpu) s.cpu = c
    if (mm > s.mem) s.mem = mm
  }
  return out
}

// ---- Pressure ---------------------------------------------------------------

// Pressure hues come from the theme: Calm uses the foreground, Critical uses
// the theme's own urgent colour, Busy sits between them. No hard-coded palette.
function pressureColor(level, calm, urgent) {
  if (level === "critical") return urgent
  if (level === "busy") return Qt.tint(calm, Qt.rgba(urgent.r, urgent.g, urgent.b, 0.55))
  return calm
}

function pressureLabel(level) {
  if (level === "critical") return "critical"
  if (level === "busy") return "busy"
  return "calm"
}

// ---- History helpers --------------------------------------------------------

function maxOf(arr, floor) {
  var m = floor || 0
  if (!arr) return m
  for (var i = 0; i < arr.length; i++) if (arr[i] > m) m = arr[i]
  return m
}

function last(arr, fallback) {
  if (!arr || !arr.length) return fallback
  return arr[arr.length - 1]
}
