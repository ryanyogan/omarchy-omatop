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

function bytes(n) {
  n = Number(n) || 0
  if (n < 1024) return Math.round(n) + " B"
  var units = ["K", "M", "G", "T"]
  var u = -1
  while (n >= 1024 && u < units.length - 1) { n /= 1024; u++ }
  return String(n >= 100 ? Math.round(n) : n >= 10 ? n.toFixed(1) : n.toFixed(2)).replace(/\.0+$/, "") + units[u]
}

function rate(n) {
  return bytes(n) + "/s"
}

function pct(n, digits) {
  n = Number(n)
  if (!isFinite(n) || n < 0) return "--"
  if (digits === undefined) digits = n >= 10 ? 0 : 1
  return n.toFixed(digits) + "%"
}

function temp(c) {
  c = Number(c)
  if (!isFinite(c) || c <= 0) return "--"
  return Math.round(c) + "°"
}

function watts(w) {
  w = Number(w)
  if (!isFinite(w) || w <= 0) return "--"
  return (w >= 10 ? Math.round(w) : w.toFixed(1)) + "W"
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
var BUCKETS = ["apps", "services", "desktop", "kernel"]
var BUCKET_LABEL = { apps: "Apps", services: "Services", desktop: "Desktop", kernel: "Kernel" }

function sections(apps, pins, filter, sortKey, collapsed) {
  var f = (filter || "").trim().toLowerCase()
  var rows = []
  var recent = [], pinned = [], buckets = { apps: [], services: [], desktop: [], kernel: [] }

  for (var i = 0; i < apps.length; i++) {
    var a = apps[i]
    if (f && !matches(a, f)) continue
    if (a.recent && (a.kind === "job" || a.bucket === "apps")) recent.push(a)
    else if (a.pinned) pinned.push(a)
    else (buckets[a.bucket] || buckets.services).push(a)
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
