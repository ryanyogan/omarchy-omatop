//! One pass over `/proc` per tick, plus the classification that turns raw pids
//! into the App and Job groupings the protocol describes.
//!
//! Everything here is deliberately failure-tolerant. A process can vanish
//! between the `readdir` that named it and the `open` that reads its stat, so
//! every read error means "skip this pid", never "exit".

use std::collections::{HashMap, HashSet};
use std::fs;
use std::io::Read;
use std::os::unix::fs::MetadataExt;
use std::rc::Rc;

// ---------------------------------------------------------------------------
// Buckets and kinds
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Bucket {
    Apps,
    Desktop,
    Services,
    Kernel,
}

impl Bucket {
    pub fn as_str(self) -> &'static str {
        match self {
            Bucket::Apps => "apps",
            Bucket::Desktop => "desktop",
            Bucket::Services => "services",
            Bucket::Kernel => "kernel",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    App,
    Job,
    Service,
    Desktop,
    Kernel,
}

impl Kind {
    pub fn as_str(self) -> &'static str {
        match self {
            Kind::App => "app",
            Kind::Job => "job",
            Kind::Service => "service",
            Kind::Desktop => "desktop",
            Kind::Kernel => "kernel",
        }
    }
}

/// What a cgroup path tells us about the App that lives in it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CgroupClass {
    pub bucket: Bucket,
    pub kind: Kind,
    /// Unit name with systemd's `\xNN` escapes decoded, or "" when the cgroup
    /// is not a unit (the root cgroup, for instance).
    pub unit: String,
    /// True when the unit belongs to a `user@N.service` manager, i.e. when the
    /// action verbs need `systemctl --user`.
    pub user_unit: bool,
    pub read_only: bool,
}

/// Decode systemd's cgroup name escaping: `\x2d` is a literal `-`.
///
/// systemd escapes characters that are structural in unit names, so a scope for
/// `xdg-terminal-exec` is stored on disk as `xdg\x2dterminal\x2dexec`. Nothing
/// downstream should ever see the escaped form.
pub fn unescape_unit(s: &str) -> String {
    let b = s.as_bytes();
    let mut out = String::with_capacity(s.len());
    let mut i = 0;
    while i < b.len() {
        if b[i] == b'\\' && i + 3 < b.len() && b[i + 1] == b'x' {
            let hi = (b[i + 2] as char).to_digit(16);
            let lo = (b[i + 3] as char).to_digit(16);
            if let (Some(hi), Some(lo)) = (hi, lo) {
                out.push(((hi * 16 + lo) as u8) as char);
                i += 4;
                continue;
            }
        }
        // Not an escape: copy the byte through as a char. Unit names are ASCII
        // in practice, and `from_utf8_lossy` upstream guarantees valid UTF-8.
        let ch = s[i..].chars().next().unwrap_or('\u{fffd}');
        out.push(ch);
        i += ch.len_utf8();
    }
    out
}

/// Classify a cgroup v2 path (the part after `0::` in `/proc/<pid>/cgroup`).
pub fn classify(cgroup: &str) -> CgroupClass {
    // The unit is the last path segment that is a unit name. Slices in the
    // middle (`app-graphical.slice`) are structure, not identity.
    let unit_raw = cgroup
        .rsplit('/')
        .find(|seg| seg.ends_with(".scope") || seg.ends_with(".service"))
        .unwrap_or("");
    let unit = unescape_unit(unit_raw);

    // `/user.slice/user-1000.slice/user@1000.service/...` means the unit is
    // managed by that user's systemd, so actions need `--user`.
    let user_unit = cgroup.contains("/user@") && cgroup.contains(".service/");

    let is_scope = unit.ends_with(".scope");
    let is_service = unit.ends_with(".service");

    // Order matters: app.slice is checked first because a graphical app scope
    // also sits under user.slice, and the more specific rule should win.
    let (bucket, kind) = if cgroup.contains("/app.slice/") {
        // Both `*.scope` (launched) and `*.service` (autostarted) under
        // app.slice are things the user thinks of as their applications.
        (Bucket::Apps, Kind::App)
    } else if cgroup.contains("/session.slice/")
        || unit.starts_with("wayland-wm")
        || is_login_session_scope(&unit)
    {
        (Bucket::Desktop, Kind::Desktop)
    } else if is_service {
        (Bucket::Services, Kind::Service)
    } else if cgroup.starts_with("/system.slice") || cgroup.contains("init.scope") {
        (Bucket::Services, Kind::Service)
    } else if is_scope {
        (Bucket::Services, Kind::Service)
    } else {
        // Root cgroup and anything unrecognised. Kernel threads land here and
        // are re-bucketed by the caller; everything else is a service.
        (Bucket::Services, Kind::Service)
    };

    let read_only = bucket == Bucket::Desktop || bucket == Bucket::Kernel;
    CgroupClass { bucket, kind, unit, user_unit, read_only }
}

/// `session-1.scope` under `user-N.slice` is the login session itself, not
/// something the user launched. The protocol lists `session.slice/**` as
/// Desktop; on a live Omarchy box the login scope is a sibling of it, and
/// stopping it would log the user out, so it gets the same read-only treatment.
fn is_login_session_scope(unit: &str) -> bool {
    let Some(rest) = unit.strip_prefix("session-") else { return false };
    let Some(n) = rest.strip_suffix(".scope") else { return false };
    !n.is_empty() && n.bytes().all(|c| c.is_ascii_digit())
}

/// Stable App id for a cgroup.
///
/// The protocol's example is `scope:<unit>`, which is what user units get.
/// System units are namespaced because unit names genuinely collide across
/// managers -- this machine runs `dbus-broker.service` both in `system.slice`
/// and in the user session, and merging them would be wrong.
pub fn app_id(unit: &str, user_unit: bool) -> String {
    if user_unit {
        format!("scope:{}", unit)
    } else {
        format!("scope:system/{}", unit)
    }
}

// ---------------------------------------------------------------------------
// Per-process facts
// ---------------------------------------------------------------------------

#[derive(Debug, Clone)]
pub struct ProcInfo {
    pub pid: i32,
    pub ppid: i32,
    pub pgid: i32,
    /// Session id (stat field 6). A process whose `pid == sid` leads its
    /// session -- the login shell, or the terminal itself -- and is never a Job.
    pub sid: i32,
    pub tty_nr: i32,
    pub comm: String,
    pub state: char,
    /// utime + stime, in clock ticks.
    pub cpu_ticks: u64,
    pub rss_pages: u64,
    pub threads: u32,
    /// Ticks since boot at which the process started.
    pub start_ticks: u64,
    pub uid: u32,
    /// Shared with the cache rather than copied: the same handful of cgroup
    /// paths are repeated across hundreds of pids, every tick.
    pub cgroup: Rc<str>,
}

/// Parse `/proc/<pid>/stat`.
///
/// `comm` can contain spaces and parentheses, so the split point is the *last*
/// `)`, not the first. Field numbers below are the 1-based ones from proc(5).
pub fn parse_stat(pid: i32, s: &str) -> Option<ProcInfo> {
    let close = s.rfind(')')?;
    let open = s.find('(')?;
    if open + 1 > close {
        return None;
    }
    let comm = s[open + 1..close].to_string();
    // Fields 3..24 on the stack: this runs 500 times a tick, and a Vec here is
    // 500 allocations a second for nothing.
    let mut fields: [&str; 22] = [""; 22];
    let mut it = s[close + 1..].split_whitespace();
    for slot in fields.iter_mut() {
        match it.next() {
            Some(v) => *slot = v,
            None => break,
        }
    }
    // fields[0] is field 3 (state), so field N is fields[N - 3].
    let f = |n: usize| -> Option<&str> {
        let v = fields[n - 3];
        if v.is_empty() {
            None
        } else {
            Some(v)
        }
    };
    let num = |n: usize| -> u64 { f(n).and_then(|v| v.parse().ok()).unwrap_or(0) };
    let inum = |n: usize| -> i32 { f(n).and_then(|v| v.parse().ok()).unwrap_or(0) };

    Some(ProcInfo {
        pid,
        ppid: inum(4),
        pgid: inum(5),
        sid: inum(6),
        tty_nr: inum(7),
        comm,
        state: f(3).and_then(|v| v.chars().next()).unwrap_or('?'),
        cpu_ticks: num(14) + num(15),
        // Field 24 is RSS in pages -- the same number `statm` reports as
        // "resident", for one fewer open/read per pid per tick.
        rss_pages: num(24),
        threads: num(20) as u32,
        start_ticks: num(22),
        uid: 0,
        cgroup: Rc::from(""),
    })
}

/// Render a `tty_nr` as the name a user would recognise (`pts/3`, `tty1`).
///
/// The encoding splits the minor number across two ranges, which is why this
/// is not simply `nr & 0xff`.
pub fn tty_name(tty_nr: i32) -> String {
    if tty_nr == 0 {
        return String::new();
    }
    let major = (tty_nr >> 8) & 0xfff;
    let minor = (tty_nr & 0xff) | ((tty_nr >> 12) & 0xfff00);
    match major {
        4 => format!("tty{}", minor),
        136..=143 => format!("pts/{}", minor + (major - 136) * 256),
        _ => String::new(),
    }
}

/// Cache of facts that cannot change while a pid lives.
///
/// A pid's cgroup and command line are fixed for its lifetime in every case we
/// care about, and re-reading them for 500 pids every second is the single
/// largest avoidable cost in the tick. The `start_ticks` guard catches pid
/// reuse: a recycled pid has a different start time, so the entry is dropped.
#[derive(Default)]
pub struct StaticCache {
    /// pid -> (start_ticks, cgroup, uid)
    identity: HashMap<i32, (u64, Rc<str>, u32)>,
    cmdlines: HashMap<i32, (u64, Rc<str>)>,
}

impl StaticCache {
    /// Cgroup and owning uid for a pid. Neither changes over a process's life
    /// in any case the overlay cares about, and re-deriving them costs an open
    /// and a statx per pid per tick -- the single largest avoidable cost in the
    /// walk. `start_ticks` guards against pid reuse: a recycled pid has a
    /// different start time, so its stale entry is replaced.
    pub fn identity(&mut self, pid: i32, start_ticks: u64) -> (Rc<str>, u32) {
        if let Some((st, cg, uid)) = self.identity.get(&pid) {
            if *st == start_ticks {
                return (cg.clone(), *uid);
            }
        }
        let cg: Rc<str> = Rc::from(read_cgroup(pid).as_str());
        let uid = fs::metadata(format!("/proc/{}", pid)).map(|m| m.uid()).unwrap_or(0);
        self.identity.insert(pid, (start_ticks, cg.clone(), uid));
        (cg, uid)
    }

    pub fn cmdline(&mut self, pid: i32, start_ticks: u64) -> Rc<str> {
        if let Some((st, v)) = self.cmdlines.get(&pid) {
            if *st == start_ticks {
                return v.clone();
            }
        }
        let v: Rc<str> = Rc::from(read_cmdline(pid).as_str());
        self.cmdlines.insert(pid, (start_ticks, v.clone()));
        v
    }

    pub fn retain_live(&mut self, live: &HashSet<i32>) {
        self.identity.retain(|p, _| live.contains(p));
        self.cmdlines.retain(|p, _| live.contains(p));
    }
}

fn read_cgroup(pid: i32) -> String {
    let Ok(s) = fs::read_to_string(format!("/proc/{}/cgroup", pid)) else {
        return String::new();
    };
    // cgroup v2 puts everything on the single `0::` line.
    for line in s.lines() {
        if let Some(rest) = line.strip_prefix("0::") {
            return rest.to_string();
        }
    }
    String::new()
}

fn read_cmdline(pid: i32) -> String {
    let Ok(raw) = fs::read(format!("/proc/{}/cmdline", pid)) else {
        return String::new();
    };
    let s: String = String::from_utf8_lossy(&raw)
        .chars()
        .map(|c| if c == '\0' { ' ' } else { c })
        .collect();
    s.trim().to_string()
}

/// Truncate to at most `max` characters without splitting a UTF-8 sequence.
pub fn truncate_chars(s: &str, max: usize) -> String {
    if s.chars().count() <= max {
        return s.to_string();
    }
    s.chars().take(max).collect()
}

/// Read a small `/proc` or `/sys` file into a caller-owned buffer.
///
/// `fs::read_to_string` asks the kernel for the file's size first so it can
/// presize its `String`. For procfs that size is always 0 and the answer is
/// useless, but the `statx` is real -- one wasted syscall per file, five
/// hundred times a tick. This does `open`, `read`, `close` and nothing else,
/// and borrows the buffer so there is no allocation either.
pub fn read_small<'a>(path: &str, buf: &'a mut [u8]) -> Option<&'a str> {
    let mut f = fs::File::open(path).ok()?;
    let mut n = 0;
    while n < buf.len() {
        match f.read(&mut buf[n..]) {
            Ok(0) => break,
            Ok(k) => n += k,
            Err(_) => return None,
        }
    }
    std::str::from_utf8(&buf[..n]).ok()
}

/// Append `/proc/<pid>/<leaf>` to a reused buffer.
fn proc_path(buf: &mut String, pid: i32, leaf: &str) {
    use std::fmt::Write;
    buf.clear();
    let _ = write!(buf, "/proc/{}/{}", pid, leaf);
}

/// Walk `/proc` once and return every process we could read.
pub fn scan(cache: &mut StaticCache) -> Vec<ProcInfo> {
    let mut out = Vec::with_capacity(512);
    let Ok(dir) = fs::read_dir("/proc") else { return out };
    // Two reused buffers for the whole walk: one for the path we are about to
    // open, one for the bytes we read back.
    let mut path = String::with_capacity(32);
    let mut buf = [0u8; 1024];
    for entry in dir.flatten() {
        let name = entry.file_name();
        let Some(name) = name.to_str() else { continue };
        let Ok(pid) = name.parse::<i32>() else { continue };

        // One `stat` read carries state, parentage, tty, cpu, rss and threads.
        proc_path(&mut path, pid, "stat");
        let Some(text) = read_small(&path, &mut buf) else { continue };
        let Some(mut p) = parse_stat(pid, text) else { continue };
        // A zombie holds no memory, burns no CPU and cannot be acted on -- it is
        // a slot in its parent's process table waiting to be reaped. Two of them
        // on this machine were forming an App of their own.
        if p.state == 'Z' {
            continue;
        }

        let (cgroup, uid) = cache.identity(pid, p.start_ticks);
        p.cgroup = cgroup;
        p.uid = uid;
        out.push(p);
    }
    out
}

/// The set of kernel threads: pid 2 and everything descended from it.
///
/// Kernel threads have no address space, so they are also the processes with an
/// empty `cmdline`; parentage is the more direct signal and is what the
/// protocol specifies.
pub fn kernel_pids(procs: &[ProcInfo]) -> HashSet<i32> {
    let mut children: HashMap<i32, Vec<i32>> = HashMap::new();
    for p in procs {
        children.entry(p.ppid).or_default().push(p.pid);
    }
    let mut set = HashSet::new();
    let mut stack = vec![2];
    while let Some(pid) = stack.pop() {
        if !set.insert(pid) {
            continue;
        }
        if let Some(kids) = children.get(&pid) {
            stack.extend(kids.iter().copied());
        }
    }
    set
}

/// Is this process the leader of a Job?
///
/// This is the POSIX definition of a job, which is what a shell itself uses: a
/// process group, on a terminal, that is not the session leader's own group.
///
/// The earlier formulation ("parent's comm is a shell, own comm is not") was
/// wrong in both directions. `bash deploy.sh` and `{ a | b ; } &` have a shell
/// as their leader's comm and were silently folded back into the terminal, so
/// their CPU appeared to belong to the terminal; meanwhile `./deploy.sh` run
/// through a shebang *was* detected, because the kernel sets comm to the script
/// name. Same script, different answer, depending on how it was invoked.
///
/// `pid != sid` is what excludes the login shell and the terminal emulator
/// without needing to know the name of every shell that exists. It also gets
/// nvim's `:terminal` right for free: the embedded shell leads its own session,
/// so it is not a Job, while what you run inside it still is.
pub fn is_job_leader(p: &ProcInfo) -> bool {
    p.pid == p.pgid && p.tty_nr != 0 && p.pid != p.sid
}

/// Members of a Job: everything in the leader's process group, plus every
/// descendant of the leader (children often call `setpgid` for their own job
/// control, so process group alone is not enough).
///
/// The walk stops at any other Job leader. Jobs nest -- run a build from a
/// shell inside an editor that was itself started from a shell -- and the inner
/// one has to stay its own row. Without this, the outermost Job swallows every
/// Job started beneath it, which is precisely the merging the domain model
/// forbids.
pub fn job_members(leader: &ProcInfo, procs: &[ProcInfo], other_leaders: &HashSet<i32>) -> HashSet<i32> {
    let mut members: HashSet<i32> = procs
        .iter()
        .filter(|p| p.pgid == leader.pgid && !other_leaders.contains(&p.pid))
        .map(|p| p.pid)
        .collect();
    members.insert(leader.pid);

    let mut children: HashMap<i32, Vec<i32>> = HashMap::new();
    for p in procs {
        children.entry(p.ppid).or_default().push(p.pid);
    }
    // `visited` is tracked separately from `members`: a child may already be a
    // member via the process group, and stopping there would miss the
    // grandchildren that called setpgid for themselves.
    let mut visited: HashSet<i32> = HashSet::new();
    let mut stack = vec![leader.pid];
    while let Some(pid) = stack.pop() {
        if !visited.insert(pid) {
            continue;
        }
        if pid != leader.pid && other_leaders.contains(&pid) {
            continue; // that subtree is its own Job
        }
        members.insert(pid);
        if let Some(kids) = children.get(&pid) {
            stack.extend(kids.iter().copied());
        }
    }
    members
}

// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    fn p(pid: i32, ppid: i32, pgid: i32, tty: i32, comm: &str) -> ProcInfo {
        ps(pid, ppid, pgid, 1, tty, comm)
    }

    /// Same, with an explicit session id.
    fn ps(pid: i32, ppid: i32, pgid: i32, sid: i32, tty: i32, comm: &str) -> ProcInfo {
        ProcInfo {
            pid,
            ppid,
            pgid,
            sid,
            tty_nr: tty,
            comm: comm.into(),
            state: 'S',
            cpu_ticks: 0,
            rss_pages: 0,
            threads: 1,
            start_ticks: 0,
            uid: 1000,
            cgroup: Rc::from(""),
        }
    }

    #[test]
    fn unescapes_systemd_hex() {
        assert_eq!(unescape_unit(r"xdg\x2dterminal\x2dexec"), "xdg-terminal-exec");
        assert_eq!(unescape_unit("app-Hyprland-chromium-e1bdd203.scope"), "app-Hyprland-chromium-e1bdd203.scope");
        // A lone backslash must survive rather than eat the rest of the name.
        assert_eq!(unescape_unit(r"weird\name"), r"weird\name");
    }

    #[test]
    fn classifies_graphical_app_scope() {
        let c = classify(r"/user.slice/user-1000.slice/user@1000.service/app.slice/app-graphical.slice/app-Hyprland-chromium-e1bdd203.scope");
        assert_eq!(c.bucket, Bucket::Apps);
        assert_eq!(c.kind, Kind::App);
        assert_eq!(c.unit, "app-Hyprland-chromium-e1bdd203.scope");
        assert!(c.user_unit);
        assert!(!c.read_only);
    }

    #[test]
    fn classifies_autostart_service_under_app_slice_as_an_app() {
        let c = classify("/user.slice/user-1000.slice/user@1000.service/app.slice/app-graphical.slice/app-dropbox@autostart.service");
        assert_eq!(c.bucket, Bucket::Apps);
        assert_eq!(c.kind, Kind::App);
        assert!(c.user_unit);
    }

    #[test]
    fn classifies_session_slice_as_readonly_desktop() {
        let c = classify("/user.slice/user-1000.slice/user@1000.service/session.slice/wayland-wm@hyprland.desktop.service");
        assert_eq!(c.bucket, Bucket::Desktop);
        assert_eq!(c.kind, Kind::Desktop);
        assert!(c.read_only);

        let c = classify("/user.slice/user-1000.slice/user@1000.service/session.slice/pipewire.service");
        assert_eq!(c.bucket, Bucket::Desktop);
        assert!(c.read_only);
    }

    #[test]
    fn classifies_login_session_scope_as_desktop() {
        let c = classify("/user.slice/user-1000.slice/session-1.scope");
        assert_eq!(c.bucket, Bucket::Desktop);
        assert!(c.read_only);
    }

    #[test]
    fn classifies_system_and_user_services() {
        let sys = classify("/system.slice/tailscaled.service");
        assert_eq!(sys.bucket, Bucket::Services);
        assert_eq!(sys.kind, Kind::Service);
        assert!(!sys.user_unit);

        let nested = classify("/system.slice/system-cups.slice/cups.service");
        assert_eq!(nested.bucket, Bucket::Services);
        assert_eq!(nested.unit, "cups.service");

        let init = classify("/init.scope");
        assert_eq!(init.bucket, Bucket::Services);
    }

    #[test]
    fn same_unit_name_in_two_managers_gets_two_ids() {
        let sys = classify("/system.slice/dbus-broker.service");
        let usr = classify("/user.slice/user-1000.slice/user@1000.service/session.slice/dbus-broker.service");
        assert_ne!(app_id(&sys.unit, sys.user_unit), app_id(&usr.unit, usr.user_unit));
        assert_eq!(app_id(&usr.unit, true), "scope:dbus-broker.service");
    }

    #[test]
    fn parses_stat_with_spaces_in_comm() {
        // `tmux: server` has both a space and, in the pathological case,
        // parentheses; the parser must key off the last ')'.
        let line = "1234 (tmux: server) S 1 1234 1234 34816 1234 4194304 100 0 0 0 \
                    11 22 0 0 20 0 3 0 999 8482816 1466 18446744073709551615 0 0 0 0 0 0 0 0 0 0 0 0 17 13 0 0 0 0 0";
        let p = parse_stat(1234, line).unwrap();
        assert_eq!(p.comm, "tmux: server");
        assert_eq!(p.ppid, 1);
        assert_eq!(p.pgid, 1234);
        assert_eq!(p.cpu_ticks, 33);
        assert_eq!(p.threads, 3);
        assert_eq!(p.start_ticks, 999);
        assert_eq!(p.rss_pages, 1466);
        assert_eq!(p.state, 'S');
    }

    #[test]
    fn renders_tty_names() {
        assert_eq!(tty_name(0), "");
        assert_eq!(tty_name(34816), "pts/0"); // major 136, minor 0
        assert_eq!(tty_name(34819), "pts/3");
        assert_eq!(tty_name(1025), "tty1"); // major 4, minor 1
    }

    #[test]
    fn detects_a_job_started_from_a_shell() {
        // sid 7374 is the login shell; claude leads its own group on the tty.
        assert!(is_job_leader(&ps(7818, 7374, 7818, 7374, 34816, "claude")));
    }

    #[test]
    fn detects_jobs_the_old_comm_based_rule_missed() {
        // `bash deploy.sh &` -- leader's comm is a shell, which used to exclude it.
        assert!(is_job_leader(&ps(52665, 52662, 52665, 52662, 34817, "bash")));
        // `{ sleep 30 | cat ; } &` -- the pipeline subshell leads the group.
        assert!(is_job_leader(&ps(52666, 52662, 52666, 52662, 34817, "bash")));
        // `./deploy.sh &` via shebang, which the old rule happened to catch.
        assert!(is_job_leader(&ps(52673, 52662, 52673, 52662, 34817, "dump2.sh")));
    }

    #[test]
    fn rejects_non_jobs() {
        // The login shell leads its own session: it is the terminal, not a Job.
        assert!(!is_job_leader(&ps(7374, 7348, 7374, 7374, 34816, "bash")));
        // The terminal emulator itself has no controlling tty.
        assert!(!is_job_leader(&ps(7348, 1, 7348, 7348, 0, "foot")));
        // A daemon with no tty.
        assert!(!is_job_leader(&ps(500, 400, 500, 400, 0, "sleep")));
        // Not a process group leader: a member inside an existing Job.
        assert!(!is_job_leader(&ps(501, 500, 500, 400, 34819, "sleep")));
        // nvim's :terminal -- the embedded shell leads its own session.
        assert!(!is_job_leader(&ps(9001, 9000, 9001, 9001, 34820, "bash")));
    }

    #[test]
    fn job_members_span_pgid_and_descendants() {
        let leader = p(500, 400, 500, 34819, "npm");
        let procs = vec![
            p(400, 300, 400, 34819, "bash"),
            leader.clone(),
            p(501, 500, 500, 34819, "node"),   // same process group
            p(502, 501, 502, 34819, "esbuild"), // descendant that made its own group
            p(600, 400, 600, 34819, "vim"),     // a different Job entirely
        ];
        let others = [600].into_iter().collect();
        let m = job_members(&leader, &procs, &others);
        assert_eq!(m, [500, 501, 502].into_iter().collect::<HashSet<_>>());
    }

    #[test]
    fn a_nested_job_is_not_swallowed_by_the_outer_one() {
        // claude -> bash -> sleep: `sleep` is its own Job and must not be
        // absorbed into the tree of the Job that happens to contain its shell.
        let outer = p(7818, 400, 7818, 34819, "claude");
        let inner = p(90646, 90645, 90646, 34821, "sleep");
        let procs = vec![
            p(400, 300, 400, 34819, "bash"),
            outer.clone(),
            p(90645, 7818, 90645, 34821, "bash"), // a shell inside the outer Job
            inner.clone(),
        ];
        let others: HashSet<i32> = [7818, 90646].into_iter().collect();
        let om = job_members(&outer, &procs, &others);
        assert!(om.contains(&7818) && om.contains(&90645));
        assert!(!om.contains(&90646), "outer Job must not claim the nested Job");
        let im = job_members(&inner, &procs, &others);
        assert_eq!(im, [90646].into_iter().collect::<HashSet<_>>());
    }

    #[test]
    fn kernel_pids_follow_kthreadd() {
        let procs = vec![
            p(1, 0, 1, 0, "systemd"),
            p(2, 0, 0, 0, "kthreadd"),
            p(3, 2, 0, 0, "rcu_gp"),
            p(40, 3, 0, 0, "nested_kworker"),
            p(1492, 1, 1492, 0, "Hyprland"),
        ];
        let k = kernel_pids(&procs);
        assert!(k.contains(&2) && k.contains(&3) && k.contains(&40));
        assert!(!k.contains(&1) && !k.contains(&1492));
    }

    #[test]
    fn truncates_on_char_boundaries() {
        assert_eq!(truncate_chars("héllo", 3), "hél");
        assert_eq!(truncate_chars("hi", 10), "hi");
    }
}
