//! Turning processes into Apps: cgroup grouping, Job extraction, desktop-entry
//! lookup, listening ports and per-App GPU time.

use crate::proc::{self, Bucket, Kind, ProcInfo, StaticCache};
use serde::Serialize;
use std::collections::{HashMap, HashSet};
use std::fs;
use std::path::PathBuf;

/// Cap on the `pids` array in a tick.
///
/// Chromium alone can run 150 processes; a full list would dominate the line
/// for no benefit, since nothing downstream acts on pids directly (Actions
/// re-derive the live set at the moment they fire).
const MAX_PIDS: usize = 64;
const MAX_CMD_CHARS: usize = 200;

// ---------------------------------------------------------------------------
// Wire shapes
// ---------------------------------------------------------------------------

#[derive(Serialize, Clone)]
#[serde(rename_all = "camelCase")]
pub struct App {
    pub id: String,
    pub kind: &'static str,
    pub bucket: &'static str,
    pub name: String,
    pub icon: String,
    pub tag: String,
    pub cmd: String,
    pub unit: String,
    pub user_unit: bool,
    pub cpu: f64,
    pub mem: u64,
    pub gpu: f64,
    pub nproc: usize,
    pub pids: Vec<i32>,
    pub leader: i32,
    pub started: u64,
    pub ports: Vec<u16>,
    pub state: &'static str,
    pub recent: bool,
    pub tty: String,
    pub read_only: bool,
    /// Not serialized: Actions need every pid, not the trimmed display list.
    #[serde(skip)]
    pub all_pids: Vec<i32>,
    /// Not serialized: a coalesced App spans more than one scope, and Stop or
    /// Freeze has to reach all of them.
    #[serde(skip)]
    pub all_units: Vec<String>,
    /// Not serialized: cgroup paths, for `cgroup.freeze` and `io.pressure`.
    #[serde(skip)]
    pub cgroups: Vec<String>,
}

#[derive(Serialize)]
pub struct ProcRow {
    pub pid: i32,
    pub comm: String,
    pub cpu: f64,
    pub mem: u64,
    pub state: String,
    pub cmd: String,
    pub threads: u32,
}

// ---------------------------------------------------------------------------
// Desktop entries
// ---------------------------------------------------------------------------

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct DesktopEntry {
    pub name: String,
    pub icon: String,
    pub tag: String,
}

/// Map a desktop entry's `Categories` to the single short Tag the overlay
/// shows. The order is a priority list, not the order the categories appear
/// in: an editor tagged `Development;TextEditor;Utility` is "Dev", not
/// "Utility".
pub fn categories_to_tag(categories: &str) -> String {
    let cats: HashSet<&str> = categories.split(';').map(str::trim).filter(|c| !c.is_empty()).collect();
    const RULES: &[(&str, &[&str])] = &[
        ("Browser", &["WebBrowser"]),
        ("Dev", &["Development", "IDE", "TextEditor"]),
        ("Terminal", &["TerminalEmulator"]),
        ("Media", &["AudioVideo", "Audio", "Video", "Player"]),
        ("Comms", &["InstantMessaging", "Chat", "Email"]),
        ("Game", &["Game"]),
        ("Graphics", &["Graphics"]),
        ("Office", &["Office"]),
        ("Utility", &["Utility", "System"]),
    ];
    for (tag, keys) in RULES {
        if keys.iter().any(|k| cats.contains(k)) {
            return (*tag).to_string();
        }
    }
    String::new()
}

/// Parse the `[Desktop Entry]` group of a .desktop file.
///
/// Only that group: files carry `[Desktop Action new-window]` sections with
/// their own `Name=`, and reading straight through would name Chromium
/// "New Incognito Window". Localised keys (`Name[de]=`) are skipped too.
pub fn parse_desktop_entry(text: &str) -> DesktopEntry {
    let mut e = DesktopEntry::default();
    let mut in_entry = false;
    for line in text.lines() {
        let line = line.trim();
        if line.starts_with('[') {
            in_entry = line == "[Desktop Entry]";
            continue;
        }
        if !in_entry {
            continue;
        }
        let Some((k, v)) = line.split_once('=') else { continue };
        match k.trim() {
            "Name" if e.name.is_empty() => e.name = v.trim().to_string(),
            "Icon" if e.icon.is_empty() => e.icon = v.trim().to_string(),
            "Categories" if e.tag.is_empty() => e.tag = categories_to_tag(v),
            _ => {}
        }
    }
    e
}

/// The `Exec` key's program name, with the field codes and any `env`-style
/// wrapper stripped: `/usr/bin/chromium %U` -> `chromium`.
pub fn exec_basename(text: &str) -> Option<String> {
    let mut in_entry = false;
    for line in text.lines() {
        let line = line.trim();
        if line.starts_with('[') {
            in_entry = line == "[Desktop Entry]";
            continue;
        }
        if !in_entry {
            continue;
        }
        if let Some(v) = line.strip_prefix("Exec=") {
            let prog = v
                .split_whitespace()
                .find(|t| !t.starts_with('%') && !t.contains('=') && *t != "env")?;
            return Some(prog.rsplit('/').next()?.to_string());
        }
    }
    None
}

/// Launcher prefixes systemd puts in front of the real application name.
const LAUNCHERS: &[&str] = &[
    "Hyprland", "hyprland", "gnome", "GNOME", "KDE", "kde", "plasma", "flatpak", "sway", "niri",
    "xfce", "wayfire", "labwc",
];

/// A trailing token that is systemd's uniquifier rather than part of the name:
/// an eight-digit hash, or the launching pid.
fn looks_like_unit_suffix(part: &str) -> bool {
    if part.is_empty() {
        return false;
    }
    if part.bytes().all(|c| c.is_ascii_digit()) {
        return true;
    }
    part.len() == 8 && part.bytes().all(|c| c.is_ascii_hexdigit())
}

/// Extract the identifying token from a unit name.
///
/// `app-Hyprland-chromium-e1bdd203.scope` -> `chromium`
/// `app-org.chromium.Chromium-3808.scope` -> `org.chromium.Chromium`
/// `app-Hyprland-xdg-terminal-exec-558d9a36.scope` -> `xdg-terminal-exec`
pub fn scope_token(unit: &str) -> String {
    let mut s = unit;
    for suf in [".scope", ".service"] {
        if let Some(x) = s.strip_suffix(suf) {
            s = x;
            break;
        }
    }
    let s = s.strip_prefix("app-").unwrap_or(s);
    // A template instance (`app-dropbox@autostart`) identifies as its template.
    let s = s.split('@').next().unwrap_or(s);

    let mut parts: Vec<&str> = s.split('-').collect();
    if parts.len() > 1 && LAUNCHERS.contains(&parts[0]) {
        parts.remove(0);
    }
    if parts.len() > 1 && looks_like_unit_suffix(parts[parts.len() - 1]) {
        parts.pop();
    }
    parts.join("-")
}

pub struct DesktopIndex {
    dirs: Vec<PathBuf>,
    /// lowercased file stem -> path
    by_stem: HashMap<String, PathBuf>,
    /// Built on the first miss only: parsing every entry costs a few hundred
    /// file reads and most tokens resolve by filename.
    by_exec: Option<HashMap<String, PathBuf>>,
    cache: HashMap<String, Option<DesktopEntry>>,
}

impl Default for DesktopIndex {
    fn default() -> Self {
        Self::new()
    }
}

impl DesktopIndex {
    pub fn new() -> DesktopIndex {
        let home = std::env::var("HOME").unwrap_or_default();
        let dirs: Vec<PathBuf> = [
            format!("{home}/.local/share/applications"),
            "/usr/share/applications".to_string(),
            "/usr/local/share/applications".to_string(),
            "/var/lib/flatpak/exports/share/applications".to_string(),
            format!("{home}/.local/share/flatpak/exports/share/applications"),
        ]
        .into_iter()
        .map(PathBuf::from)
        .filter(|p| p.is_dir())
        .collect();

        let mut by_stem = HashMap::new();
        for d in &dirs {
            let Ok(rd) = fs::read_dir(d) else { continue };
            for e in rd.flatten() {
                let p = e.path();
                let Some(stem) = p.file_stem().and_then(|s| s.to_str()) else { continue };
                if p.extension().and_then(|s| s.to_str()) != Some("desktop") {
                    continue;
                }
                // Earlier dirs win, so ~/.local overrides /usr/share.
                by_stem.entry(stem.to_lowercase()).or_insert(p);
            }
        }
        DesktopIndex { dirs, by_stem, by_exec: None, cache: HashMap::new() }
    }

    fn exec_index(&mut self) -> &HashMap<String, PathBuf> {
        if self.by_exec.is_none() {
            let mut map = HashMap::new();
            for d in self.dirs.clone() {
                let Ok(rd) = fs::read_dir(&d) else { continue };
                for e in rd.flatten() {
                    let p = e.path();
                    if p.extension().and_then(|s| s.to_str()) != Some("desktop") {
                        continue;
                    }
                    let Ok(text) = fs::read_to_string(&p) else { continue };
                    if let Some(prog) = exec_basename(&text) {
                        map.entry(prog.to_lowercase()).or_insert(p);
                    }
                }
            }
            self.by_exec = Some(map);
        }
        self.by_exec.as_ref().unwrap()
    }

    fn read(&self, p: &PathBuf) -> Option<DesktopEntry> {
        let text = fs::read_to_string(p).ok()?;
        let mut e = parse_desktop_entry(&text);
        if e.name.is_empty() {
            e.name = p.file_stem()?.to_str()?.to_string();
        }
        Some(e)
    }

    fn find(&mut self, key: &str) -> Option<DesktopEntry> {
        let lower = key.to_lowercase();
        if let Some(p) = self.by_stem.get(&lower).cloned() {
            return self.read(&p);
        }
        // Reverse-DNS ids often have a plainly named entry:
        // `org.chromium.Chromium` -> `chromium.desktop`.
        if let Some(last) = lower.rsplit('.').next() {
            if last != lower {
                if let Some(p) = self.by_stem.get(last).cloned() {
                    return self.read(&p);
                }
            }
        }
        if let Some(p) = self.exec_index().get(&lower).cloned() {
            return self.read(&p);
        }
        None
    }

    /// Resolve a unit token (and the leader's comm as a fallback) to a desktop
    /// entry. Results are cached: this is the only part of a tick that touches
    /// the filesystem outside `/proc` and `/sys`.
    pub fn lookup(&mut self, token: &str, leader_comm: &str) -> Option<DesktopEntry> {
        // `xdg-terminal-exec` is a launcher shim, not an application: the scope
        // is named after it no matter which terminal it actually started, so
        // the leader's comm is the only thing that identifies the App.
        if token == "xdg-terminal-exec" || token == "xdg-terminal-exec-wrapper" {
            let key = format!("comm:{leader_comm}");
            if let Some(hit) = self.cache.get(&key) {
                return hit.clone();
            }
            let found = self.find(leader_comm).or(Some(DesktopEntry {
                name: "Terminal".into(),
                icon: String::new(),
                tag: "Terminal".into(),
            }));
            self.cache.insert(key, found.clone());
            return found;
        }

        if let Some(hit) = self.cache.get(token) {
            return hit.clone();
        }
        let found = self.find(token).or_else(|| {
            if leader_comm.is_empty() {
                None
            } else {
                self.find(leader_comm)
            }
        });
        self.cache.insert(token.to_string(), found.clone());
        found
    }
}

// ---------------------------------------------------------------------------
// File-descriptor scan: ports and GPU handles
// ---------------------------------------------------------------------------

/// The fd walk is by far the most expensive thing the sampler can do: an
/// `openat` plus a `readlinkat` for every descriptor of every process, which on
/// an idle desktop is some two thousand syscalls. At 1 Hz every one of those is
/// a cold-cache miss, and they alone cost more than reading all 500 `stat`
/// files.
///
/// So it is driven by change rather than by a timer:
///
/// * Only processes we own are ever scanned -- we cannot read anyone else's
///   `/proc/<pid>/fd` regardless.
/// * A process is scanned once, when it first appears. Its listening sockets
///   and DRM handles are opened during startup and then stay put.
/// * `/proc/net/tcp` is re-read every tick (two small files) and a full rescan
///   happens only when the set of listening sockets actually changed, which is
///   what makes a newly bound port show up on the very next tick.
/// * A periodic full rescan catches the rest: a long-lived process that opens
///   its first DRM handle an hour in.
///
/// Between scans only the fdinfo files already known to be DRM handles are
/// re-read, which is a handful of files rather than thousands.
const FULL_RESCAN_TICKS: u32 = 30;

pub struct FdScanner {
    pub enabled: bool,
    our_uid: u32,
    since_full: u32,
    /// pids whose fd table we have already walked
    scanned: HashSet<i32>,
    /// listening socket inode -> port, as of the last tick
    listening: HashMap<u64, u16>,
    /// pid -> fd numbers that point at a DRM device
    drm_fds: HashMap<i32, Vec<u32>>,
    /// pid -> listening TCP ports
    ports: HashMap<i32, Vec<u16>>,
}

impl Default for FdScanner {
    fn default() -> Self {
        Self::new()
    }
}

impl FdScanner {
    pub fn new() -> FdScanner {
        let our_uid = fs::metadata("/proc/self")
            .map(|m| std::os::unix::fs::MetadataExt::uid(&m))
            .unwrap_or(0);
        FdScanner {
            enabled: true,
            our_uid,
            since_full: u32::MAX, // force a full scan on the first tick
            scanned: HashSet::new(),
            listening: HashMap::new(),
            drm_fds: HashMap::new(),
            ports: HashMap::new(),
        }
    }

    pub fn tick(&mut self, procs: &[ProcInfo]) {
        if !self.enabled {
            self.drm_fds.clear();
            self.ports.clear();
            self.scanned.clear();
            self.since_full = u32::MAX;
            return;
        }

        // Forget dead pids first, so a recycled pid is treated as new and never
        // inherits stale ports.
        let live: HashSet<i32> = procs.iter().map(|p| p.pid).collect();
        self.drm_fds.retain(|p, _| live.contains(p));
        self.ports.retain(|p, _| live.contains(p));
        self.scanned.retain(|p| live.contains(p));

        let listening = read_listening_inodes();
        let sockets_changed = listening != self.listening;
        self.listening = listening;

        self.since_full = self.since_full.saturating_add(1);
        let full = sockets_changed || self.since_full >= FULL_RESCAN_TICKS;

        let targets: Vec<i32> = procs
            .iter()
            .filter(|p| p.uid == self.our_uid)
            .filter(|p| full || !self.scanned.contains(&p.pid))
            .map(|p| p.pid)
            .collect();

        if full {
            self.since_full = 0;
            // A full pass re-derives every attribution, so drop what we had
            // rather than merging old ports into new answers.
            self.ports.clear();
        }
        if !targets.is_empty() {
            self.scan_pids(&targets);
        }
    }

    fn scan_pids(&mut self, pids: &[i32]) {
        for pid in pids {
            self.scanned.insert(*pid);
            let Ok(rd) = fs::read_dir(format!("/proc/{}/fd", pid)) else { continue };
            let mut drm: Vec<u32> = Vec::new();
            let mut ports: Vec<u16> = Vec::new();
            for e in rd.flatten() {
                let Ok(target) = fs::read_link(e.path()) else { continue };
                let Some(t) = target.to_str() else { continue };
                if let Some(rest) = t.strip_prefix("socket:[") {
                    let Some(inode) = rest.strip_suffix(']').and_then(|x| x.parse::<u64>().ok()) else {
                        continue;
                    };
                    if let Some(port) = self.listening.get(&inode) {
                        ports.push(*port);
                    }
                } else if t.starts_with("/dev/dri/") {
                    if let Some(fd) = e.file_name().to_str().and_then(|n| n.parse::<u32>().ok()) {
                        drm.push(fd);
                    }
                }
            }
            if drm.is_empty() {
                self.drm_fds.remove(pid);
            } else {
                self.drm_fds.insert(*pid, drm);
            }
            if ports.is_empty() {
                self.ports.remove(pid);
            } else {
                ports.sort_unstable();
                ports.dedup();
                self.ports.insert(*pid, ports);
            }
        }
    }

    pub fn ports_for(&self, pid: i32) -> Option<&Vec<u16>> {
        self.ports.get(&pid)
    }

    /// GPU engine time per DRM client for one pid.
    ///
    /// A process holds several fds onto the same client (the card node and the
    /// render node), and only some of them carry the engine counters, so the
    /// caller dedupes by client id and keeps the largest reading.
    pub fn drm_clients(&self, pid: i32, out: &mut HashMap<u64, u64>) {
        let Some(fds) = self.drm_fds.get(&pid) else { return };
        for fd in fds {
            let Ok(text) = fs::read_to_string(format!("/proc/{}/fdinfo/{}", pid, fd)) else { continue };
            let Some((id, ns)) = parse_fdinfo(&text) else { continue };
            let e = out.entry(id).or_insert(0);
            *e = (*e).max(ns);
        }
    }
}

/// `(drm-client-id, drm-engine-gfx ns)` from one fdinfo file.
pub fn parse_fdinfo(text: &str) -> Option<(u64, u64)> {
    let mut id = None;
    let mut ns = 0u64;
    for line in text.lines() {
        if let Some(v) = line.strip_prefix("drm-client-id:") {
            id = v.trim().parse::<u64>().ok();
        } else if let Some(v) = line.strip_prefix("drm-engine-gfx:") {
            ns = v.split_whitespace().next().and_then(|x| x.parse().ok()).unwrap_or(0);
        }
    }
    Some((id?, ns))
}

/// inode -> port for every listening TCP socket, v4 and v6.
fn read_listening_inodes() -> HashMap<u64, u16> {
    let mut map = HashMap::new();
    for f in ["/proc/net/tcp", "/proc/net/tcp6"] {
        if let Ok(s) = fs::read_to_string(f) {
            parse_tcp_table(&s, &mut map);
        }
    }
    map
}

pub fn parse_tcp_table(s: &str, out: &mut HashMap<u64, u16>) {
    for line in s.lines().skip(1) {
        let f: Vec<&str> = line.split_whitespace().collect();
        if f.len() < 10 {
            continue;
        }
        // st == 0A is TCP_LISTEN; everything else is an established or dying
        // connection and does not represent a service on this machine.
        if f[3] != "0A" {
            continue;
        }
        let Some((_, port_hex)) = f[1].rsplit_once(':') else { continue };
        let Ok(port) = u16::from_str_radix(port_hex, 16) else { continue };
        let Ok(inode) = f[9].parse::<u64>() else { continue };
        out.insert(inode, port);
    }
}


// ---------------------------------------------------------------------------
// Scope coalescing
// ---------------------------------------------------------------------------

/// May these two cgroups be merged into one App?
///
/// Deliberately narrow. Cross-cgroup parentage is the normal case, not the
/// exception -- every system service's main process has systemd (in
/// `init.scope`) as its parent -- so an unguarded rule would collapse the whole
/// machine into one App. Requiring both sides to be `.scope` units under
/// `app.slice` restricts it to processes that re-registered a scope for
/// themselves, which is exactly the Chromium case and, on this machine, only
/// that case.
pub fn coalescable(child: &str, parent: &str) -> bool {
    child != parent
        && child.contains("/app.slice/")
        && parent.contains("/app.slice/")
        && child.ends_with(".scope")
        && parent.ends_with(".scope")
}

/// child cgroup -> parent cgroup, for every scope that should merge upward.
fn coalesce_scopes(
    procs: &[ProcInfo],
    by_pid: &HashMap<i32, usize>,
    claimed: &HashSet<i32>,
    kernel: &HashSet<i32>,
) -> HashMap<String, String> {
    let mut map = HashMap::new();
    for p in procs {
        if claimed.contains(&p.pid) || kernel.contains(&p.pid) {
            continue;
        }
        let Some(&pi) = by_pid.get(&p.ppid) else { continue };
        let parent = &procs[pi];
        if coalescable(&p.cgroup, &parent.cgroup) {
            map.insert(p.cgroup.to_string(), parent.cgroup.to_string());
        }
    }
    map
}

/// Follow the merge chain to the App that owns this cgroup.
///
/// The hop count is bounded because a cycle is possible in principle (two
/// scopes each parenting a process in the other) and an unbounded walk would
/// hang the tick.
fn resolve_merge<'a>(map: &'a HashMap<String, String>, cgroup: &'a str) -> &'a str {
    let mut cur = cgroup;
    for _ in 0..8 {
        match map.get(cur) {
            Some(next) if next != cur => cur = next,
            _ => break,
        }
    }
    cur
}

/// Read `cgroup.freeze` for a cgroup path. `Some(true)` means the kernel has
/// this cgroup frozen.
pub fn cgroup_frozen(cgroup: &str) -> Option<bool> {
    let mut buf = [0u8; 8];
    let path = format!("/sys/fs/cgroup{}/cgroup.freeze", cgroup);
    Some(proc::read_small(&path, &mut buf)?.trim() == "1")
}

/// Cumulative CPU time charged to a cgroup, in microseconds.
///
/// Better than summing `/proc/<pid>/stat` in two ways that matter for a
/// diagnostic tool: it is microseconds rather than 10 ms jiffies, and it counts
/// processes that lived and died *between* two ticks. A build that spawns a
/// thousand short-lived compilers is invisible to a once-a-second pid walk and
/// obvious here.
pub fn cgroup_cpu_usec(cgroup: &str) -> Option<u64> {
    let mut buf = [0u8; 256];
    let path = format!("/sys/fs/cgroup{}/cpu.stat", cgroup);
    let text = proc::read_small(&path, &mut buf)?;
    text.lines().find_map(|l| l.strip_prefix("usage_usec ")?.trim().parse().ok())
}

/// Memory charged to a cgroup, in bytes.
///
/// Summing per-process RSS counts every shared page once per process: on this
/// machine Chromium's RSS sum reads 367 MB against a real 203 MB, because forty
/// processes share one copy of the binary and its libraries. The cgroup counts
/// each page once, which is the number the user is actually asking about.
pub fn cgroup_memory_current(cgroup: &str) -> Option<u64> {
    let mut buf = [0u8; 32];
    let path = format!("/sys/fs/cgroup{}/memory.current", cgroup);
    proc::read_small(&path, &mut buf)?.trim().parse().ok()
}

/// A cgroup's IO pressure (`some avg10`), used to pick the Culprit when IO is
/// what is hurting. Read only for that case, never on every tick.
pub fn cgroup_io_pressure(cgroup: &str) -> Option<f64> {
    let mut buf = [0u8; 256];
    let path = format!("/sys/fs/cgroup{}/io.pressure", cgroup);
    let text = proc::read_small(&path, &mut buf)?;
    Some(crate::vitals::parse_pressure(text).0)
}

// ---------------------------------------------------------------------------
// Grouping
// ---------------------------------------------------------------------------

pub struct BuildCtx<'a> {
    pub interval: f64,
    pub clk_tck: u64,
    pub page_size: u64,
    pub ncpu: usize,
    pub btime: u64,
    pub now_unix: u64,
    /// App ids with a pending SIGKILL deadline, shown as `stopping`.
    pub stopping: &'a HashSet<String>,
    /// The App whose Processes the caller asked for.
    pub detail: Option<&'a str>,
    /// Job ids this sampler has SIGSTOPped. A Job has no cgroup of its own to
    /// ask, and the `T` state cannot answer the question -- Ctrl-Z produces it
    /// too, and that is the user's own doing, not a Pause.
    pub paused_jobs: &'a HashSet<String>,
}

/// One group of pids before it becomes an App.
struct Group {
    id: String,
    kind: Kind,
    bucket: Bucket,
    unit: String,
    user_unit: bool,
    read_only: bool,
    tty: String,
    /// Set for Jobs: the process that leads the group. Everything else picks
    /// its leader by age.
    leader_pid: Option<i32>,
    /// Every cgroup this App covers; the first is the one it is named from.
    /// More than one only after scope coalescing.
    cgroups: Vec<String>,
    pids: Vec<usize>, // indices into `procs`
}

pub struct Grouper {
    pub desktop: DesktopIndex,
    pub fds: FdScanner,
    prev_ticks: HashMap<i32, u64>,
    prev_gpu: HashMap<u64, u64>,
    prev_cg_cpu: HashMap<String, u64>,
}

impl Default for Grouper {
    fn default() -> Self {
        Self::new()
    }
}

impl Grouper {
    pub fn new() -> Grouper {
        Grouper {
            desktop: DesktopIndex::new(),
            fds: FdScanner::new(),
            prev_ticks: HashMap::new(),
            prev_gpu: HashMap::new(),
            prev_cg_cpu: HashMap::new(),
        }
    }

    pub fn build(
        &mut self,
        procs: &[ProcInfo],
        cache: &mut StaticCache,
        ctx: &BuildCtx,
    ) -> (Vec<App>, Vec<ProcRow>) {
        let by_pid: HashMap<i32, usize> = procs.iter().enumerate().map(|(i, p)| (p.pid, i)).collect();
        let kernel = proc::kernel_pids(procs);

        // --- Jobs first: their pids are removed from the terminal's App -----
        let mut claimed: HashSet<i32> = HashSet::new();
        let mut groups: Vec<Group> = Vec::new();

        let mut leaders: Vec<&ProcInfo> = procs.iter().filter(|p| proc::is_job_leader(p)).collect();
        leaders.sort_by_key(|p| p.pid);
        let leader_pids: HashSet<i32> = leaders.iter().map(|p| p.pid).collect();

        for leader in leaders.iter() {
            if claimed.contains(&leader.pid) {
                continue;
            }
            let members = proc::job_members(leader, procs, &leader_pids);
            let idx: Vec<usize> = members
                .iter()
                .filter(|p| !claimed.contains(p))
                .filter_map(|p| by_pid.get(p).copied())
                .collect();
            if idx.is_empty() {
                continue;
            }
            for i in &idx {
                claimed.insert(procs[*i].pid);
            }
            let started = ctx.btime + leader.start_ticks / ctx.clk_tck.max(1);
            // The Job's identity has to survive pid reuse, so the start time is
            // part of it.
            let class = proc::classify(&leader.cgroup);
            groups.push(Group {
                id: format!("job:{}:{}", leader.pid, started),
                kind: Kind::Job,
                bucket: if class.bucket == Bucket::Desktop { Bucket::Apps } else { class.bucket },
                unit: String::new(),
                user_unit: false,
                read_only: false,
                tty: proc::tty_name(leader.tty_nr),
                leader_pid: Some(leader.pid),
                // Deliberately empty. A Job has no cgroup of its own -- it
                // lives inside the terminal's -- so borrowing the terminal's
                // would make Pause freeze the whole terminal and Stop take down
                // the shell the user is typing into. Jobs are driven by signals
                // to their process group, which is exactly what a shell does.
                cgroups: Vec::new(),
                pids: idx,
            });
        }

        // --- Everything else, grouped by cgroup ----------------------------
        // Chromium registers its own browser process into a second scope and
        // leaves every child in the one uwsm made, so "App = one cgroup" splits
        // it in two -- and Stop on the half named `chromium` would kill eighteen
        // renderers and leave the window standing. Where a process's parent
        // lives in a different scope, the two scopes are one App.
        let merge_into = coalesce_scopes(procs, &by_pid, &claimed, &kernel);

        let mut by_cgroup: HashMap<&str, Vec<usize>> = HashMap::new();
        let mut members: HashMap<&str, HashSet<&str>> = HashMap::new();
        let mut kernel_idx: Vec<usize> = Vec::new();
        for (i, p) in procs.iter().enumerate() {
            if claimed.contains(&p.pid) {
                continue;
            }
            if kernel.contains(&p.pid) {
                kernel_idx.push(i);
                continue;
            }
            let root = resolve_merge(&merge_into, &p.cgroup);
            by_cgroup.entry(root).or_default().push(i);
            members.entry(root).or_default().insert(&p.cgroup);
        }

        for (cg, idx) in by_cgroup {
            let class = proc::classify(cg);
            let id = if class.unit.is_empty() {
                format!("cgroup:{cg}")
            } else {
                proc::app_id(&class.unit, class.user_unit)
            };
            // The naming cgroup first; the rest in a stable order.
            let mut cgroups = vec![cg.to_string()];
            if let Some(m) = members.get(cg) {
                let mut rest: Vec<String> =
                    m.iter().filter(|c| **c != cg).map(|c| c.to_string()).collect();
                rest.sort();
                cgroups.extend(rest);
            }
            groups.push(Group {
                id,
                kind: class.kind,
                bucket: class.bucket,
                unit: class.unit,
                user_unit: class.user_unit,
                read_only: class.read_only,
                tty: String::new(),
                leader_pid: None,
                cgroups,
                pids: idx,
            });
        }

        if !kernel_idx.is_empty() {
            groups.push(Group {
                id: "kernel".to_string(),
                kind: Kind::Kernel,
                bucket: Bucket::Kernel,
                unit: String::new(),
                user_unit: false,
                read_only: true,
                tty: String::new(),
                leader_pid: None,
                cgroups: Vec::new(),
                pids: kernel_idx,
            });
        }

        // --- Materialise ----------------------------------------------------
        // Cgroups that lost processes to a Job. Their cgroup counters still
        // include those processes, so those Apps must stay on per-pid
        // accounting or the terminal would be charged twice for its Jobs.
        let job_cgroups: HashSet<&str> = procs
            .iter()
            .filter(|p| claimed.contains(&p.pid))
            .map(|p| &*p.cgroup)
            .collect();

        let capacity = ctx.interval * ctx.clk_tck as f64 * ctx.ncpu as f64;
        let mut apps = Vec::with_capacity(groups.len());
        let mut detail_rows = Vec::new();
        let mut next_gpu: HashMap<u64, u64> = HashMap::new();

        for g in groups {
            let app = self.materialise(procs, &g, ctx, capacity, &mut next_gpu, cache, &job_cgroups);
            if ctx.detail == Some(app.id.as_str()) {
                detail_rows = self.detail_rows(procs, &g, capacity, ctx, cache);
            }
            apps.push(app);
        }

        // Retain only clients still present, so a closed GPU context does not
        // leave a counter behind that a reused client id would delta against.
        self.prev_gpu = next_gpu;
        // Reuse the map's allocation rather than building a fresh 500-entry
        // table every second.
        self.prev_ticks.clear();
        self.prev_ticks.extend(procs.iter().map(|p| (p.pid, p.cpu_ticks)));
        let live_ids: HashSet<&str> = apps.iter().map(|a| a.id.as_str()).collect();
        self.prev_cg_cpu.retain(|id, _| live_ids.contains(id.as_str()));

        apps.sort_by(|a, b| b.cpu.partial_cmp(&a.cpu).unwrap_or(std::cmp::Ordering::Equal));
        (apps, detail_rows)
    }

    fn materialise(
        &mut self,
        procs: &[ProcInfo],
        g: &Group,
        ctx: &BuildCtx,
        capacity: f64,
        next_gpu: &mut HashMap<u64, u64>,
        cache: &mut StaticCache,
        job_cgroups: &HashSet<&str>,
    ) -> App {
        let mut cpu_ticks = 0u64;
        let mut rss_pages = 0u64;
        let mut oldest = u64::MAX;
        let mut leader_idx = g.pids[0];
        let mut ports: Vec<u16> = Vec::new();
        let mut clients: HashMap<u64, u64> = HashMap::new();

        for &i in &g.pids {
            let p = &procs[i];
            let prev = self.prev_ticks.get(&p.pid).copied().unwrap_or(p.cpu_ticks);
            cpu_ticks += p.cpu_ticks.saturating_sub(prev);
            rss_pages += p.rss_pages;
            if p.start_ticks < oldest {
                oldest = p.start_ticks;
                leader_idx = i;
            }
            if let Some(pp) = self.fds.ports_for(p.pid) {
                ports.extend_from_slice(pp);
            }
            self.fds.drm_clients(p.pid, &mut clients);
        }

        // A Job's leader is the process that started it, which is not the
        // oldest member: a `node` job's oldest process may be a worker thread,
        // and naming the Job after that reads as gibberish ("MainThread").
        if let Some(want) = g.leader_pid {
            if let Some(&i) = g.pids.iter().find(|&&i| procs[i].pid == want) {
                leader_idx = i;
            }
        }

        let mut gpu_ns = 0u64;
        let mut saw_client = false;
        for (id, ns) in clients {
            saw_client = true;
            let prev = self.prev_gpu.get(&id).copied().unwrap_or(ns);
            gpu_ns += ns.saturating_sub(prev);
            let e = next_gpu.entry(id).or_insert(0);
            *e = (*e).max(ns);
        }
        let gpu = if saw_client && ctx.interval > 0.0 {
            crate::vitals::round1((gpu_ns as f64 / (ctx.interval * 1e9)) * 100.0)
        } else {
            -1.0
        };

        let leader = &procs[leader_idx];
        let started = ctx.btime + oldest / ctx.clk_tck.max(1);
        ports.sort_unstable();
        ports.dedup();

        // Prefer the kernel's own per-cgroup accounting when this App owns its
        // cgroups outright. Falls back to the per-pid sums whenever anything is
        // unreadable or a Job was carved out of the cgroup, so the numbers are
        // never a mix of the two for one App.
        let cgroup_owned =
            !g.cgroups.is_empty() && !g.cgroups.iter().any(|c| job_cgroups.contains(c.as_str()));
        let mut cpu_pct = if capacity > 0.0 { cpu_ticks as f64 / capacity * 100.0 } else { 0.0 };
        let mut mem_bytes = rss_pages * ctx.page_size;
        if cgroup_owned {
            let usec: Option<u64> = g
                .cgroups
                .iter()
                .map(|c| cgroup_cpu_usec(c))
                .try_fold(0u64, |acc, v| v.map(|v| acc + v));
            let mem: Option<u64> = g
                .cgroups
                .iter()
                .map(|c| cgroup_memory_current(c))
                .try_fold(0u64, |acc, v| v.map(|v| acc + v));
            if let (Some(usec), Some(mem)) = (usec, mem) {
                let prev = self.prev_cg_cpu.get(&g.id).copied().unwrap_or(usec);
                let denom = ctx.interval * 1e6 * ctx.ncpu as f64;
                if denom > 0.0 {
                    cpu_pct = usec.saturating_sub(prev) as f64 / denom * 100.0;
                }
                mem_bytes = mem;
                self.prev_cg_cpu.insert(g.id.clone(), usec);
            }
        }

        let (name, icon, tag) = self.identify(g, leader);

        let mut all_pids: Vec<i32> = g.pids.iter().map(|&i| procs[i].pid).collect();
        all_pids.sort_unstable();
        // Leader first, then the rest in pid order, so trimming a 150-process
        // Chromium never drops the one pid that identifies it.
        let mut pids: Vec<i32> = Vec::with_capacity(MAX_PIDS);
        pids.push(leader.pid);
        pids.extend(all_pids.iter().copied().filter(|p| *p != leader.pid));
        pids.truncate(MAX_PIDS);

        // Paused is asked, never inferred. `T` also means "the user pressed
        // Ctrl-Z", and reporting that as a Pause the overlay could Resume would
        // be a lie about who did what.
        let paused = if g.kind == Kind::Job {
            ctx.paused_jobs.contains(&g.id)
        } else {
            let mut asked = false;
            let mut all_frozen = true;
            for c in &g.cgroups {
                if let Some(frozen) = cgroup_frozen(c) {
                    asked = true;
                    all_frozen &= frozen;
                }
            }
            asked && all_frozen
        };
        let state = if ctx.stopping.contains(&g.id) {
            "stopping"
        } else if paused {
            "paused"
        } else {
            "running"
        };

        // Every unit the App spans, so Stop and Freeze reach all of them.
        let mut all_units: Vec<String> = g
            .cgroups
            .iter()
            .map(|c| proc::classify(c).unit)
            .filter(|u| !u.is_empty())
            .collect();
        all_units.dedup();

        App {
            id: g.id.clone(),
            kind: g.kind.as_str(),
            bucket: g.bucket.as_str(),
            name,
            icon,
            tag,
            cmd: proc::truncate_chars(&cache.cmdline(leader.pid, leader.start_ticks), MAX_CMD_CHARS),
            unit: g.unit.clone(),
            user_unit: g.user_unit,
            cpu: crate::vitals::round1(cpu_pct),
            mem: mem_bytes,
            gpu,
            nproc: g.pids.len(),
            pids,
            leader: leader.pid,
            started,
            recent: ctx.now_unix.saturating_sub(started) < 30 * 60 || !ports.is_empty(),
            ports,
            state,
            tty: g.tty.clone(),
            read_only: g.read_only,
            all_pids,
            all_units,
            cgroups: g.cgroups.clone(),
        }
    }

    /// Name, icon and tag for a group.
    fn identify(&mut self, g: &Group, leader: &ProcInfo) -> (String, String, String) {
        match g.kind {
            Kind::Kernel => ("Kernel".into(), String::new(), String::new()),
            // A Job is identified by what was run, never by a desktop entry.
            Kind::Job => (leader.comm.clone(), String::new(), String::new()),
            Kind::App => {
                let token = scope_token(&g.unit);
                match self.desktop.lookup(&token, &leader.comm) {
                    Some(e) => (e.name, e.icon, e.tag),
                    None if !token.is_empty() => (token, String::new(), String::new()),
                    None => (leader.comm.clone(), String::new(), String::new()),
                }
            }
            // Services and desktop units are named by their unit: a user
            // recognises `tailscaled` and `pipewire`, and inventing prettier
            // names for them would only make them harder to search for.
            _ => {
                let n = g
                    .unit
                    .strip_suffix(".service")
                    .or_else(|| g.unit.strip_suffix(".scope"))
                    .unwrap_or(&g.unit);
                if n.is_empty() {
                    (leader.comm.clone(), String::new(), String::new())
                } else {
                    (n.to_string(), String::new(), String::new())
                }
            }
        }
    }

    fn detail_rows(
        &mut self,
        procs: &[ProcInfo],
        g: &Group,
        capacity: f64,
        _ctx: &BuildCtx,
        cache: &mut StaticCache,
    ) -> Vec<ProcRow> {
        let mut rows: Vec<ProcRow> = g
            .pids
            .iter()
            .map(|&i| {
                let p = &procs[i];
                let prev = self.prev_ticks.get(&p.pid).copied().unwrap_or(p.cpu_ticks);
                let d = p.cpu_ticks.saturating_sub(prev);
                ProcRow {
                    pid: p.pid,
                    comm: p.comm.clone(),
                    cpu: crate::vitals::round1(if capacity > 0.0 { d as f64 / capacity * 100.0 } else { 0.0 }),
                    mem: p.rss_pages * _ctx.page_size,
                    state: p.state.to_string(),
                    cmd: proc::truncate_chars(&cache.cmdline(p.pid, p.start_ticks), MAX_CMD_CHARS),
                    threads: p.threads,
                }
            })
            .collect();
        rows.sort_by(|a, b| b.cpu.partial_cmp(&a.cpu).unwrap_or(std::cmp::Ordering::Equal));
        rows
    }
}

// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    const CHROME_BROWSER: &str = "/user.slice/user-1000.slice/user@1000.service/app.slice/app-org.chromium.Chromium-3808.scope";
    const CHROME_CHILDREN: &str = "/user.slice/user-1000.slice/user@1000.service/app.slice/app-graphical.slice/app-Hyprland-chromium-e1bdd203.scope";
    const INIT: &str = "/user.slice/user-1000.slice/user@1000.service/init.scope";
    const COMPOSITOR: &str = "/user.slice/user-1000.slice/user@1000.service/session.slice/wayland-wm@hyprland.desktop.service";
    const UDISKIE: &str = "/user.slice/user-1000.slice/user@1000.service/app.slice/app-graphical.slice/app-Hyprland-udiskie-1ce1af6d.scope";

    #[test]
    fn chromiums_two_scopes_coalesce() {
        // The renderers' scope merges into the browser's, because 3827's parent
        // is 3808. Without this, Stop on the half named `chromium` kills
        // eighteen renderers and leaves the window standing.
        assert!(coalescable(CHROME_CHILDREN, CHROME_BROWSER));
    }

    #[test]
    fn coalescing_does_not_swallow_the_machine() {
        // Every system service's main process is parented by systemd in
        // init.scope. An unguarded parent-in-another-cgroup rule would merge
        // all of them into one App.
        assert!(!coalescable(CHROME_CHILDREN, INIT));
        assert!(!coalescable("/system.slice/tailscaled.service", "/init.scope"));
        // The compositor is parented by a scope under app.slice on this box.
        // Merging the desktop into udiskie would be absurd.
        assert!(!coalescable(COMPOSITOR, UDISKIE));
        assert!(!coalescable(UDISKIE, COMPOSITOR));
        // A docker container scope under system.slice stays its own App.
        assert!(!coalescable(
            "/system.slice/docker-8cd099f8.scope",
            "/system.slice/containerd.service"
        ));
        // And nothing merges into itself.
        assert!(!coalescable(CHROME_BROWSER, CHROME_BROWSER));
    }

    #[test]
    fn merge_chains_resolve_and_cycles_terminate() {
        let mut m = HashMap::new();
        m.insert("c".to_string(), "b".to_string());
        m.insert("b".to_string(), "a".to_string());
        assert_eq!(resolve_merge(&m, "c"), "a");
        assert_eq!(resolve_merge(&m, "a"), "a");
        assert_eq!(resolve_merge(&m, "unknown"), "unknown");

        // Two scopes each parenting a process in the other must not hang the tick.
        let mut cyc = HashMap::new();
        cyc.insert("x".to_string(), "y".to_string());
        cyc.insert("y".to_string(), "x".to_string());
        let _ = resolve_merge(&cyc, "x");
    }

    #[test]
    fn the_merged_app_is_named_from_the_parent_scope() {
        // The parent scope carries the Desktop ID, which is what finds
        // chromium.desktop and gives the App its name, icon and Browser tag.
        // The child scope's token is the launcher's argv[0].
        assert_eq!(scope_token("app-org.chromium.Chromium-3808.scope"), "org.chromium.Chromium");
        assert_eq!(scope_token("app-Hyprland-chromium-e1bdd203.scope"), "chromium");
    }

    #[test]
    fn extracts_tokens_from_real_scope_names() {
        let cases = [
            ("app-Hyprland-chromium-e1bdd203.scope", "chromium"),
            ("app-org.chromium.Chromium-3808.scope", "org.chromium.Chromium"),
            ("app-Hyprland-xdg-terminal-exec-558d9a36.scope", "xdg-terminal-exec"),
            ("app-Hyprland-omarchy-hyprland-monitor-watch-28f4821c.scope", "omarchy-hyprland-monitor-watch"),
            ("app-1password-1658.scope", "1password"),
            ("app-dropbox@autostart.service", "dropbox"),
            ("app-flatpak-com.spotify.Client-4242.scope", "com.spotify.Client"),
            ("app-gnome-org.gnome.Nautilus-9001.scope", "org.gnome.Nautilus"),
        ];
        for (unit, want) in cases {
            assert_eq!(scope_token(unit), want, "token for {unit}");
        }
    }

    #[test]
    fn token_extraction_runs_after_unescaping() {
        let raw = r"app-Hyprland-xdg\x2dterminal\x2dexec-558d9a36.scope";
        assert_eq!(scope_token(&proc::unescape_unit(raw)), "xdg-terminal-exec");
    }

    #[test]
    fn token_never_eats_the_whole_name() {
        // A one-part name that looks like a suffix must survive.
        assert_eq!(scope_token("app-1234.scope"), "1234");
        assert_eq!(scope_token("app-Hyprland.scope"), "Hyprland");
    }

    #[test]
    fn maps_categories_to_one_tag_in_priority_order() {
        assert_eq!(categories_to_tag("Network;WebBrowser;"), "Browser");
        assert_eq!(categories_to_tag("Development;IDE;Utility;"), "Dev");
        assert_eq!(categories_to_tag("TextEditor;Utility;"), "Dev");
        assert_eq!(categories_to_tag("System;TerminalEmulator;Utility;"), "Terminal");
        assert_eq!(categories_to_tag("AudioVideo;Player;"), "Media");
        assert_eq!(categories_to_tag("Network;InstantMessaging;"), "Comms");
        assert_eq!(categories_to_tag("Game;ActionGame;"), "Game");
        assert_eq!(categories_to_tag("Graphics;RasterGraphics;"), "Graphics");
        assert_eq!(categories_to_tag("Office;Spreadsheet;"), "Office");
        assert_eq!(categories_to_tag("Utility;"), "Utility");
        assert_eq!(categories_to_tag("System;"), "Utility");
        // Absent is an honest state, never guessed.
        assert_eq!(categories_to_tag("Network;"), "");
        assert_eq!(categories_to_tag(""), "");
    }

    #[test]
    fn browser_beats_network_and_terminal_beats_system() {
        // Priority order, not the order in the file.
        assert_eq!(categories_to_tag("Utility;WebBrowser;"), "Browser");
        assert_eq!(categories_to_tag("Utility;System;TerminalEmulator;"), "Terminal");
    }

    #[test]
    fn desktop_entry_ignores_action_groups() {
        // Chromium's real entry: the Desktop Actions each carry their own Name.
        let text = "[Desktop Entry]\n\
                    Name=Chromium\n\
                    Name[de]=Chromium DE\n\
                    Exec=/usr/bin/chromium %U\n\
                    Icon=chromium\n\
                    Categories=Network;WebBrowser;\n\
                    Actions=new-window;new-private-window;\n\
                    \n\
                    [Desktop Action new-window]\n\
                    Name=New Window\n\
                    Exec=/usr/bin/chromium\n\
                    Icon=wrong\n";
        let e = parse_desktop_entry(text);
        assert_eq!(e.name, "Chromium");
        assert_eq!(e.icon, "chromium");
        assert_eq!(e.tag, "Browser");
        assert_eq!(exec_basename(text).as_deref(), Some("chromium"));
    }

    #[test]
    fn exec_basename_skips_wrappers_and_field_codes() {
        let mk = |exec: &str| format!("[Desktop Entry]\nExec={exec}\n");
        assert_eq!(exec_basename(&mk("/usr/bin/foot")).as_deref(), Some("foot"));
        assert_eq!(exec_basename(&mk("env GDK_BACKEND=wayland /usr/bin/ghostty %F")).as_deref(), Some("ghostty"));
        assert_eq!(exec_basename(&mk("alacritty")).as_deref(), Some("alacritty"));
    }

    #[test]
    fn listening_sockets_only() {
        let s = "  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
   0: 00000000:445C 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 22965 1 0 100 0 0 10 0
   1: 0100007F:1F90 0100007F:CF2A 01 00000000:00000000 00:00000000 00000000  1000        0 33333 1 0 100 0 0 10 0";
        let mut m = HashMap::new();
        parse_tcp_table(s, &mut m);
        assert_eq!(m.get(&22965), Some(&0x445C));
        // 0x1F90 is 8080, but that socket is ESTABLISHED, not LISTEN.
        assert!(!m.values().any(|p| *p == 8080));
    }

    #[test]
    fn fdinfo_needs_a_client_id_but_tolerates_a_missing_engine() {
        // The card-node fd on amdgpu carries a client id and memory figures but
        // no engine counters; the render-node fd for the same client has them.
        let card = "pos:\t0\ndrm-driver:\tamdgpu\ndrm-client-id:\t28\ndrm-total-vram:\t12 KiB\n";
        assert_eq!(parse_fdinfo(card), Some((28, 0)));
        let render = "drm-client-id:\t28\ndrm-engine-gfx:\t53659863182 ns\ndrm-engine-compute:\t51687 ns\n";
        assert_eq!(parse_fdinfo(render), Some((28, 53659863182)));
        assert_eq!(parse_fdinfo("pos:\t0\nflags:\t02\n"), None);
    }
}
