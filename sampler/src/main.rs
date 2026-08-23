//! omatop-sampler: reads the machine, writes one JSON object per tick.
//!
//! Long-lived child of the Omarchy shell. stdout is the protocol stream and
//! carries nothing else; stdin carries one command per line. The process is
//! expected to outlive every overlay session, so History keeps filling whether
//! or not anyone is reading, and no read error is ever fatal.

mod actions;
mod apps;
mod history;
mod proc;
mod vitals;

use actions::{ActionEvent, Actions, Target};
use apps::{App, BuildCtx, Grouper, ProcRow};
use history::{AppHistories, SystemHistory};
use proc::{Kind, StaticCache};
use serde::Serialize;
use std::collections::{HashMap, HashSet};
use std::io::{BufRead, Write};
use std::sync::mpsc::{self, RecvTimeoutError};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use vitals::{Vitals, VitalsSampler};

const PROTOCOL_VERSION: u32 = 1;
const MIN_RATE: f64 = 0.03;
const MAX_RATE: f64 = 10.0;

// ---------------------------------------------------------------------------
// Wire shapes owned by main
// ---------------------------------------------------------------------------

#[derive(Serialize)]
pub struct Pressure {
    pub level: &'static str,
    pub score: f64,
    pub reason: String,
    /// Not on the wire: which term won, so Culprit can follow it.
    #[serde(skip)]
    pub term: Term,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct HistoryOut {
    cpu: Vec<f64>,
    mem: Vec<f64>,
    gpu: Vec<f64>,
    temp: Vec<f64>,
    net_rx: Vec<f64>,
    net_tx: Vec<f64>,
    disk_read: Vec<f64>,
    disk_write: Vec<f64>,
    power: Vec<f64>,
}

#[derive(Serialize)]
struct DetailOut {
    id: String,
    cpu: Vec<f64>,
    mem: Vec<f64>,
    gpu: Vec<f64>,
}

#[derive(Serialize)]
struct EventOut {
    #[serde(rename = "type")]
    kind: &'static str,
    id: String,
    action: String,
    ok: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    error: Option<String>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Tick<'a> {
    v: u32,
    t: u64,
    interval: f64,
    ncpu: usize,
    vitals: &'a Vitals,
    pressure: Pressure,
    culprit: Option<&'a str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    history: Option<HistoryOut>,
    apps: &'a [App],
    /// True when `apps` is only the offenders, not the whole machine.
    lean: bool,
    processes: HashMap<&'a str, &'a [ProcRow]>,
    #[serde(skip_serializing_if = "Option::is_none")]
    detail: Option<DetailOut>,
    events: Vec<EventOut>,
}

// ---------------------------------------------------------------------------
// Pressure
// ---------------------------------------------------------------------------

/// Which signal is hurting the machine.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Term {
    Cpu,
    Memory,
    Io,
    Swapping,
    None,
}

/// The named terms of the Pressure score.
///
/// Each divisor is the value at which that signal alone means "the machine is
/// fully in trouble" (score 1.0). Taking the maximum rather than a sum is what
/// makes `reason` truthful: there is always exactly one dominant term to name.
///
/// Two terms that were here are deliberately gone. Raw temperature made this
/// laptop permanently critical -- a Ryzen boosting to 95 C for a second is
/// working, not suffering -- so heat is now only a multiplier on real stall,
/// and never a reason on its own. Swap *ratio* was inert on a zram box, where
/// swap is compressed RAM and sits non-zero at all times; the swap-in *rate* is
/// what actually costs the user something.
pub fn pressure(psi: &vitals::PsiVital, temp: Option<f64>, swap_in_pages_per_sec: f64) -> Pressure {
    let terms: [(f64, Term); 4] = [
        (psi.cpu / 60.0, Term::Cpu),
        (psi.mem_full / 10.0, Term::Memory),
        (psi.io_full / 40.0, Term::Io),
        (swap_in_pages_per_sec / 2000.0, Term::Swapping),
    ];
    let (raw, which) = terms
        .iter()
        .copied()
        .fold((0.0f64, Term::None), |acc, t| if t.0 > acc.0 { t } else { acc });

    // Thermal throttling makes every stall worse, so it amplifies what is
    // already there rather than inventing pressure of its own.
    let throttling = temp.map(|c| c >= 95.0).unwrap_or(false);
    let score = (if throttling { raw * 1.3 } else { raw }).clamp(0.0, 1.5);

    // Four steps so the bar mark can shade gradually with load: calm, then
    // load (light amber), heavy (orange), critical (red).
    let level = if score >= 1.0 {
        "critical"
    } else if score >= 0.55 {
        "heavy"
    } else if score >= 0.25 {
        "load"
    } else {
        "calm"
    };

    let reason = match which {
        _ if score < 0.05 => "calm".to_string(),
        Term::Cpu => format!("cpu stall {:.0}%", psi.cpu),
        Term::Memory => "memory stall".to_string(),
        Term::Io => "io stall".to_string(),
        Term::Swapping => "swapping".to_string(),
        Term::None => "calm".to_string(),
    };
    Pressure { level, score: (score * 100.0).round() / 100.0, reason, term: which }
}

/// The App to highlight.
///
/// Culprit follows the dominant term rather than always naming the biggest CPU
/// consumer: when the machine is thrashing, the process burning CPU is usually
/// the victim, not the cause. For IO the kernel already keeps per-cgroup
/// pressure, which is a far better answer than "who has the most CPU" -- and it
/// is read only in that case, never on every tick.
///
/// Calm machines have no culprit: pointing at whichever App happens to be top
/// of an idle list would be noise.
fn culprit<'a>(apps: &'a [App], p: &Pressure) -> Option<&'a str> {
    if p.level == "calm" {
        return None;
    }
    let actionable = |a: &&App| a.bucket != "kernel";

    let by_cpu = |apps: &'a [App]| {
        apps.iter()
            .filter(actionable)
            .max_by(|a, b| a.cpu.partial_cmp(&b.cpu).unwrap_or(std::cmp::Ordering::Equal))
    };

    let pick = match p.term {
        Term::Memory | Term::Swapping => apps.iter().filter(actionable).max_by_key(|a| a.mem),
        Term::Io => apps
            .iter()
            .filter(actionable)
            .filter_map(|a| {
                let worst = a
                    .cgroups
                    .iter()
                    .filter_map(|c| apps::cgroup_io_pressure(c))
                    .fold(f64::NAN, f64::max);
                (worst > 0.0).then_some((a, worst))
            })
            .max_by(|x, y| x.1.partial_cmp(&y.1).unwrap_or(std::cmp::Ordering::Equal))
            .map(|(a, _)| a)
            .or_else(|| by_cpu(apps)),
        _ => by_cpu(apps),
    };
    pick.map(|a| a.id.as_str())
}

// ---------------------------------------------------------------------------
// Sampler
// ---------------------------------------------------------------------------

/// The subset of an App an Action needs, kept from the last tick so a command
/// arriving between ticks can be answered without a fresh /proc walk.
struct TargetInfo {
    units: Vec<String>,
    user_unit: bool,
    read_only: bool,
    is_job: bool,
    pids: Vec<i32>,
    pgid: Option<i32>,
}

struct Sampler {
    vitals: VitalsSampler,
    grouper: Grouper,
    cache: StaticCache,
    sys_hist: SystemHistory,
    app_hist: AppHistories,
    actions: Actions,
    targets: HashMap<String, TargetInfo>,
    live_pids: HashSet<i32>,
    rate: f64,
    /// Omit apps and history from the tick. Set by the shell while no
    /// surface is open.
    lean: bool,
    /// A `now` command arrived: tick immediately instead of waiting.
    tick_now: bool,
    detail: Option<String>,
    last_tick: Instant,
    last_flush: Instant,
    last_save: Instant,
    pending_events: Vec<EventOut>,
}

impl Sampler {
    fn new() -> Sampler {
        let now = Instant::now();
        // The shell restarts the sampler on every plugin file save; without
        // this the user loses the two minutes of History they opened the
        // overlay to look at.
        let mut sys_hist = SystemHistory::default();
        sys_hist.load();
        Sampler {
            vitals: VitalsSampler::new(),
            grouper: Grouper::new(),
            cache: StaticCache::default(),
            sys_hist,
            app_hist: AppHistories::default(),
            actions: Actions::new(),
            targets: HashMap::new(),
            live_pids: HashSet::new(),
            rate: 1.0,
            lean: false,
            tick_now: false,
            detail: None,
            last_tick: now,
            last_flush: now,
            last_save: now,
            pending_events: Vec::new(),
        }
    }

    fn period(&self) -> Duration {
        Duration::from_secs_f64(1.0 / self.rate)
    }

    fn command(&mut self, line: &str) {
        let line = line.trim();
        if line.is_empty() {
            return;
        }
        let (verb, arg) = line.split_once(char::is_whitespace).unwrap_or((line, ""));
        let arg = arg.trim();
        match verb {
            "rate" => {
                if let Ok(hz) = arg.parse::<f64>() {
                    if hz.is_finite() {
                        self.rate = hz.clamp(MIN_RATE, MAX_RATE);
                    }
                }
            }
            "detail" => {
                self.detail = if arg == "-" || arg.is_empty() { None } else { Some(arg.to_string()) };
            }
            "fds" => self.grouper.fds.enabled = arg != "off",
            "lean" => self.lean = arg != "off",
            "now" => self.tick_now = true,
            "stop" | "pause" | "resume" | "restart" => self.act(verb, arg),
            _ => {}
        }
    }

    fn act(&mut self, verb: &str, id: &str) {
        let Some(info) = self.targets.get(id) else {
            self.pending_events.push(EventOut {
                kind: "action",
                id: id.to_string(),
                action: verb.to_string(),
                ok: false,
                error: Some("unknown app".into()),
            });
            return;
        };
        let target = Target {
            id: id.to_string(),
            units: info.units.clone(),
            user_unit: info.user_unit,
            read_only: info.read_only,
            is_job: info.is_job,
            pids: info.pids.clone(),
            pgid: info.pgid,
        };
        if let Some(e) = self.actions.dispatch(verb, target) {
            self.pending_events.push(into_event(e));
        }
    }

    /// One tick, with a net under it.
    ///
    /// `/proc` is a minefield: files vanish between the readdir and the open,
    /// and a field that is always there until it is not turns a slice into a
    /// panic. One bad tick is a dropped sample; a dead sampler is a dead
    /// overlay and a lost History, so the panic is caught and the loop goes on.
    fn tick(&mut self, out: &mut impl Write) {
        let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| self.tick_inner(out)));
        if result.is_err() {
            // Keep the cadence honest so the next interval is not enormous.
            self.last_tick = Instant::now();
        }
    }

    fn tick_inner(&mut self, out: &mut impl Write) {
        let now = Instant::now();
        let interval = (now - self.last_tick).as_secs_f64().max(1e-3);
        self.last_tick = now;

        let v = self.vitals.sample(interval);

        let procs = proc::scan(&mut self.cache);
        self.live_pids.clear();
        self.live_pids.extend(procs.iter().map(|p| p.pid));
        self.cache.retain_live(&self.live_pids);
        self.grouper.fds.tick(&procs);

        let now_unix = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0);

        let stopping = self.actions.stopping();
        let paused_jobs = self.actions.paused_jobs().clone();
        let ctx = BuildCtx {
            interval,
            clk_tck: self.vitals.clk_tck,
            page_size: self.vitals.page_size,
            ncpu: self.vitals.ncpu,
            btime: self.vitals.btime,
            now_unix,
            stopping: &stopping,
            detail: self.detail.as_deref(),
            paused_jobs: &paused_jobs,
        };
        let (apps, detail_rows) = self.grouper.build(&procs, &mut self.cache, &ctx);

        // Refresh the Action targets from this tick's truth.
        self.targets.clear();
        self.targets.extend(apps.iter().map(|a| {
            (
                a.id.clone(),
                TargetInfo {
                    units: a.all_units.clone(),
                    user_unit: a.user_unit,
                    read_only: a.read_only,
                    is_job: a.kind == Kind::Job.as_str(),
                    pids: a.all_pids.clone(),
                    // A Job's leader leads its process group by definition,
                    // which is what makes `kill -- -pgid` safe here.
                    pgid: if a.kind == Kind::Job.as_str() { Some(a.leader) } else { None },
                },
            )
        }));
        self.actions
            .retain_jobs(&apps.iter().map(|a| a.id.clone()).collect());

        // --- History --------------------------------------------------------
        self.sys_hist.cpu.accumulate(v.cpu.total);
        // Percent of total, not bytes: the overlay draws these on one 0..100
        // axis alongside cpu and gpu, and a byte count there is meaningless.
        let mem_pct = if v.mem.total > 0 {
            v.mem.used as f64 / v.mem.total as f64 * 100.0
        } else {
            0.0
        };
        self.sys_hist.mem.accumulate(mem_pct);
        self.sys_hist.gpu.accumulate(v.gpu.busy);
        self.sys_hist.temp.accumulate(v.cpu.temp.unwrap_or(0.0));
        self.sys_hist.net_rx.accumulate(v.net.rx as f64);
        self.sys_hist.net_tx.accumulate(v.net.tx as f64);
        self.sys_hist.disk_read.accumulate(v.disk.read as f64);
        self.sys_hist.disk_write.accumulate(v.disk.write as f64);
        self.sys_hist.power.accumulate(v.power.watts);
        for a in &apps {
            self.app_hist.accumulate(&a.id, a.cpu, a.mem as f64, a.gpu);
        }

        // The ring advances once per tick: at the default 5 s refresh the
        // 120-slot window is ten minutes, at 1 Hz it is two. The shell labels
        // the axis from the tick interval, so nothing here needs to know.
        let live_ids: HashSet<String> = apps.iter().map(|a| a.id.clone()).collect();
        self.sys_hist.flush();
        self.app_hist.flush(&live_ids);
        self.last_flush = now;
        self.sys_hist.save_if_due(&mut self.last_save);

        // --- Events ---------------------------------------------------------
        let live = &self.live_pids;
        let mut events = std::mem::take(&mut self.pending_events);
        events.extend(self.actions.tick(&|pid| live.contains(&pid)).into_iter().map(into_event));

        // --- Emit -----------------------------------------------------------
        let p = pressure(&v.psi, v.cpu.temp, v.swap_in);
        let culprit_id = culprit(&apps, &p);

        // Lean ticks still carry the offenders: the top Apps by CPU and by
        // memory. That keeps the shell's rolling averages warm while nothing
        // is open, so the offenders panel is right the moment it appears.
        let lean_apps: Vec<App> = if self.lean {
            let mut by_cpu: Vec<&App> = apps.iter().filter(|a| a.bucket != "kernel").collect();
            by_cpu.sort_by(|a, b| b.cpu.partial_cmp(&a.cpu).unwrap_or(std::cmp::Ordering::Equal));
            let mut by_mem: Vec<&App> = apps.iter().filter(|a| a.bucket != "kernel").collect();
            by_mem.sort_by(|a, b| b.mem.cmp(&a.mem));
            let mut picked: Vec<&App> = Vec::new();
            for a in by_cpu.iter().take(16).chain(by_mem.iter().take(10)) {
                if !picked.iter().any(|p| p.id == a.id) {
                    picked.push(a);
                }
            }
            picked.into_iter().map(|a| a.clone()).collect()
        } else {
            Vec::new()
        };

        let mut processes = HashMap::new();
        if let Some(d) = self.detail.as_deref() {
            if !detail_rows.is_empty() {
                processes.insert(d, detail_rows.as_slice());
            }
        }
        let detail = self.detail.as_deref().and_then(|d| {
            let h = self.app_hist.get(d)?;
            Some(DetailOut {
                id: d.to_string(),
                cpu: h.cpu.rounded(1),
                mem: h.mem.rounded(0),
                gpu: h.gpu.rounded(1),
            })
        });

        let tick = Tick {
            v: PROTOCOL_VERSION,
            t: SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .map(|d| d.as_millis() as u64)
                .unwrap_or(0),
            interval: (interval * 1000.0).round() / 1000.0,
            ncpu: self.vitals.ncpu,
            vitals: &v,
            pressure: p,
            culprit: culprit_id,
            history: if self.lean { None } else { Some(HistoryOut {
                cpu: self.sys_hist.cpu.rounded(1),
                mem: self.sys_hist.mem.rounded(1),
                gpu: self.sys_hist.gpu.rounded(1),
                temp: self.sys_hist.temp.rounded(1),
                net_rx: self.sys_hist.net_rx.rounded(0),
                net_tx: self.sys_hist.net_tx.rounded(0),
                disk_read: self.sys_hist.disk_read.rounded(0),
                disk_write: self.sys_hist.disk_write.rounded(0),
                power: self.sys_hist.power.rounded(1),
            }) },
            // Lean ticks (nothing open in the shell) carry vitals, pressure and
            // the culprit only: the bar glyph needs nothing else, and the
            // shell should not parse 30 KB of Apps nobody is looking at.
            apps: if self.lean { &lean_apps } else { &apps },
            lean: self.lean,
            processes,
            detail,
            events,
        };

        if let Ok(s) = serde_json::to_string(&tick) {
            // A partial line would desynchronise the reader for good, so a
            // broken pipe ends the process rather than corrupting the stream.
            if writeln!(out, "{s}").is_err() || out.flush().is_err() {
                // The shell went away. Leave the History on disk so the next
                // sampler picks up where this one stopped.
                self.sys_hist.save();
                std::process::exit(0);
            }
        }
    }
}

fn into_event(e: ActionEvent) -> EventOut {
    EventOut { kind: "action", id: e.id, action: e.action, ok: e.ok, error: e.error }
}

// ---------------------------------------------------------------------------

fn main() {
    // Commands arrive on their own thread: a blocking read on stdin must never
    // hold up a tick, and a tick must never make a command wait a whole period.
    let (tx, rx) = mpsc::channel::<String>();
    std::thread::spawn(move || {
        let stdin = std::io::stdin();
        for line in stdin.lock().lines() {
            let Ok(line) = line else { break };
            if tx.send(line).is_err() {
                break;
            }
        }
    });

    let mut s = Sampler::new();
    let mut out = std::io::BufWriter::new(std::io::stdout());
    let mut stdin_open = true;
    let mut next = Instant::now();

    loop {
        // Wait out the rest of the period, handling commands as they land.
        while stdin_open {
            let now = Instant::now();
            if now >= next {
                break;
            }
            match rx.recv_timeout(next - now) {
                Ok(line) => {
                    s.command(&line);
                    if s.tick_now {
                        s.tick_now = false;
                        break;
                    }
                }
                Err(RecvTimeoutError::Timeout) => break,
                // stdin closed (the sampler can be run standalone, or the
                // shell may never open it). Keep sampling; just stop waiting.
                Err(RecvTimeoutError::Disconnected) => stdin_open = false,
            }
        }
        if !stdin_open {
            let now = Instant::now();
            if now < next {
                std::thread::sleep(next - now);
            }
        }

        // Apply anything that landed while we were not waiting (the shell
        // sends `rate`, `lean` and `fds` right after spawning us), so the very
        // first tick already honours them.
        while let Ok(line) = rx.try_recv() {
            s.command(&line);
        }
        s.tick_now = false;
        s.tick(&mut out);

        next += s.period();
        let now = Instant::now();
        if next <= now {
            // Fell behind: skip the missed ticks instead of spinning to catch up.
            next = now + s.period();
        }
    }
}

// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use proc::Bucket;
    use vitals::PsiVital;

    fn psi(cpu: f64, mem_full: f64, io_full: f64) -> PsiVital {
        PsiVital { cpu, mem: 0.0, io: 0.0, mem_full, io_full }
    }

    #[test]
    fn an_idle_machine_is_calm_with_no_culprit() {
        let p = pressure(&psi(0.0, 0.0, 0.0), Some(45.0), 0.0);
        assert_eq!(p.level, "calm");
        assert_eq!(p.score, 0.0);
        assert_eq!(p.reason, "calm");
        assert_eq!(culprit(&[], &p), None);
    }

    #[test]
    fn cpu_stall_crosses_load_at_15_percent() {
        // 0.25 * 60 = 15
        assert_eq!(pressure(&psi(14.0, 0.0, 0.0), None, 0.0).level, "calm");
        let p = pressure(&psi(16.0, 0.0, 0.0), None, 0.0);
        assert_eq!(p.level, "load");
        assert_eq!(p.reason, "cpu stall 16%");
    }

    #[test]
    fn cpu_stall_crosses_critical_at_60_percent() {
        assert_eq!(pressure(&psi(53.0, 0.0, 0.0), None, 0.0).level, "heavy");
        assert_eq!(pressure(&psi(60.0, 0.0, 0.0), None, 0.0).level, "critical");
    }

    #[test]
    fn the_dominant_term_names_the_reason() {
        // Memory stalls are weighted ten times harder than IO, so a smaller
        // number wins.
        let p = pressure(&psi(10.0, 5.0, 20.0), Some(60.0), 0.0);
        assert_eq!(p.reason, "memory stall");
        assert_eq!(p.term, Term::Memory);
        assert!((p.score - 0.5).abs() < 1e-9);

        let p = pressure(&psi(10.0, 0.0, 30.0), None, 0.0);
        assert_eq!(p.reason, "io stall");
        assert_eq!(p.term, Term::Io);
    }

    #[test]
    fn a_hot_cpu_is_never_a_reason_on_its_own() {
        // This laptop idles in the 50s and touches 95 C on any boost. Under the
        // old raw-temperature term it read `critical` while doing nothing,
        // which trained the user to ignore the bar.
        for temp in [70.0, 88.0, 95.0, 105.0] {
            let p = pressure(&psi(0.0, 0.0, 0.0), Some(temp), 0.0);
            assert_eq!(p.level, "calm", "{temp} C alone must not be pressure");
            assert_eq!(p.score, 0.0);
            assert_eq!(p.reason, "calm");
        }
    }

    #[test]
    fn throttling_amplifies_a_real_stall() {
        // Below the throttle point the score is the raw term.
        let cool = pressure(&psi(30.0, 0.0, 0.0), Some(80.0), 0.0);
        assert_eq!(cool.score, 0.5);
        // At the throttle point the same stall hurts more, but the reason still
        // names the stall, not the heat.
        let hot = pressure(&psi(30.0, 0.0, 0.0), Some(95.0), 0.0);
        assert_eq!(hot.score, 0.65);
        assert_eq!(hot.reason, "cpu stall 30%");
    }

    #[test]
    fn swapping_is_measured_by_rate_not_by_how_full_swap_is() {
        // A zram box sits with swap permanently non-zero and nothing wrong.
        assert_eq!(pressure(&psi(0.0, 0.0, 0.0), None, 0.0).level, "calm");
        // Actually faulting pages back in is what costs the user time.
        let p = pressure(&psi(0.0, 0.0, 0.0), None, 1800.0);
        assert_eq!(p.reason, "swapping");
        assert_eq!(p.term, Term::Swapping);
        assert_eq!(p.level, "heavy"); // 1800/2000 = 0.9
    }

    #[test]
    fn a_missing_sensor_never_contributes() {
        let p = pressure(&psi(0.0, 0.0, 0.0), None, 0.0);
        assert_eq!(p.score, 0.0);
    }

    #[test]
    fn score_is_capped_at_one_and_a_half() {
        let p = pressure(&psi(100.0, 100.0, 100.0), Some(110.0), 100000.0);
        assert_eq!(p.score, 1.5);
    }

    fn app(id: &str, bucket: &'static str, cpu: f64, mem: u64) -> App {
        App {
            id: id.into(),
            kind: "app",
            bucket,
            name: id.into(),
            icon: String::new(),
            tag: String::new(),
            cmd: String::new(),
            unit: String::new(),
            user_unit: true,
            cpu,
            mem,
            gpu: -1.0,
            nproc: 1,
            pids: vec![1],
            leader: 1,
            started: 0,
            ports: vec![],
            state: "running",
            recent: false,
            tty: String::new(),
            read_only: false,
            all_pids: vec![1],
            all_units: vec![],
            cgroups: vec![],
        }
    }

    #[test]
    fn culprit_follows_cpu_when_cpu_is_the_problem() {
        let apps = [app("scope:a", "apps", 90.0, 1), app("scope:b", "apps", 5.0, 9_000)];
        let p = pressure(&psi(40.0, 0.0, 0.0), None, 0.0);
        assert_eq!(culprit(&apps, &p), Some("scope:a"));
    }

    #[test]
    fn culprit_follows_memory_when_memory_is_the_problem() {
        let apps = [app("scope:a", "apps", 90.0, 1), app("scope:b", "apps", 5.0, 9_000)];
        let p = pressure(&psi(0.0, 6.0, 0.0), None, 0.0);
        assert_eq!(culprit(&apps, &p), Some("scope:b"));
    }

    #[test]
    fn culprit_follows_memory_while_swapping_too() {
        // The App burning CPU while the machine thrashes is the victim.
        let apps = [app("scope:a", "apps", 90.0, 1), app("scope:b", "apps", 5.0, 9_000)];
        let p = pressure(&psi(0.0, 0.0, 0.0), None, 1500.0);
        assert_eq!(culprit(&apps, &p), Some("scope:b"));
    }

    #[test]
    fn io_culprit_falls_back_to_cpu_when_no_cgroup_answers() {
        // These fixtures have no cgroup paths, so io.pressure is unreadable.
        let apps = [app("scope:a", "apps", 90.0, 1), app("scope:b", "apps", 5.0, 9_000)];
        let p = pressure(&psi(0.0, 0.0, 30.0), None, 0.0);
        assert_eq!(p.term, Term::Io);
        assert_eq!(culprit(&apps, &p), Some("scope:a"));
    }

    #[test]
    fn kernel_is_never_the_culprit() {
        // Kernel threads cannot be acted on, so naming them helps nobody.
        let apps = [app("kernel", "kernel", 99.0, 0), app("scope:a", "apps", 3.0, 0)];
        let p = pressure(&psi(40.0, 0.0, 0.0), None, 0.0);
        assert_eq!(culprit(&apps, &p), Some("scope:a"));
    }

    #[test]
    fn rate_is_clamped_to_the_documented_range() {
        let mut s = Sampler::new();
        s.command("rate 4");
        assert_eq!(s.rate, 4.0);
        assert_eq!(s.period(), Duration::from_millis(250));
        s.command("rate 900");
        assert_eq!(s.rate, MAX_RATE);
        s.command("rate 0.01");
        assert_eq!(s.rate, MIN_RATE);
        s.command("rate nonsense");
        assert_eq!(s.rate, MIN_RATE); // unparseable input leaves the rate alone
    }

    #[test]
    fn detail_sets_and_clears() {
        let mut s = Sampler::new();
        s.command("detail scope:app-Hyprland-chromium-e1bdd203.scope");
        assert_eq!(s.detail.as_deref(), Some("scope:app-Hyprland-chromium-e1bdd203.scope"));
        s.command("detail -");
        assert_eq!(s.detail, None);
    }

    #[test]
    fn fds_toggles() {
        let mut s = Sampler::new();
        s.command("fds off");
        assert!(!s.grouper.fds.enabled);
        s.command("fds on");
        assert!(s.grouper.fds.enabled);
    }

    #[test]
    fn an_action_on_an_unknown_app_answers_rather_than_going_silent() {
        let mut s = Sampler::new();
        s.command("stop scope:nothing.service");
        assert_eq!(s.pending_events.len(), 1);
        assert!(!s.pending_events[0].ok);
        assert_eq!(s.pending_events[0].error.as_deref(), Some("unknown app"));
    }

    #[test]
    fn unknown_commands_are_ignored_not_fatal() {
        let mut s = Sampler::new();
        s.command("frobnicate everything");
        s.command("");
        assert_eq!(s.rate, 1.0);
    }

    #[test]
    fn buckets_and_kinds_serialize_as_the_protocol_spells_them() {
        assert_eq!(Bucket::Apps.as_str(), "apps");
        assert_eq!(Bucket::Desktop.as_str(), "desktop");
        assert_eq!(Bucket::Services.as_str(), "services");
        assert_eq!(Bucket::Kernel.as_str(), "kernel");
        assert_eq!(Kind::Job.as_str(), "job");
        assert_eq!(Kind::Service.as_str(), "service");
    }
}
