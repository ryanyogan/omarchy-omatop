//! Stop, Pause, Resume, Restart.
//!
//! Two mechanisms, chosen by what the App actually is. A systemd unit is
//! stopped through `systemctl`, so the manager knows the unit is down and does
//! not fight the sampler over restarts; the system bus path goes through polkit
//! and is allowed to fail with a readable error. Anything else -- a Job, a bare
//! process group -- gets signals.
//!
//! Signals are delivered by one `kill(1)` invocation per action rather than a
//! syscall, because the crate budget here is serde and serde_json only. One
//! spawn per user gesture is nothing; one spawn per pid per tick would not be.

use std::collections::HashSet;
use std::process::{Command, Stdio};
use std::sync::mpsc::{self, Receiver, Sender};
use std::time::{Duration, Instant};

/// How long a process gets to exit on its own after SIGTERM.
const GRACE: Duration = Duration::from_secs(5);

#[derive(Debug, Clone)]
pub struct ActionEvent {
    pub id: String,
    pub action: String,
    pub ok: bool,
    pub error: Option<String>,
}

/// A Stop that is still waiting to see whether SIGTERM was enough.
struct PendingKill {
    id: String,
    deadline: Instant,
    pids: Vec<i32>,
}

pub struct Actions {
    pending: Vec<PendingKill>,
    /// Jobs this sampler has SIGSTOPped. A Job has no cgroup of its own, so
    /// there is nothing to ask; this set is the answer.
    paused_jobs: HashSet<String>,
    tx: Sender<ActionEvent>,
    rx: Receiver<ActionEvent>,
}

/// What the caller knows about the App an action names. Resolved fresh at the
/// moment the action fires, never from the trimmed `pids` of an old tick.
pub struct Target {
    pub id: String,
    /// Every unit the App spans, the one it is named from first. A coalesced
    /// App (Chromium) has two.
    pub units: Vec<String>,
    pub user_unit: bool,
    pub read_only: bool,
    pub is_job: bool,
    pub pids: Vec<i32>,
    pub pgid: Option<i32>,
}

impl Target {
    fn primary(&self) -> &str {
        self.units.first().map(|s| s.as_str()).unwrap_or("")
    }

    /// Units in the order an Action should touch them: children first, the
    /// scope the App is named from last. Stopping Chromium's browser process
    /// before its renderers would leave a window full of crashed tabs.
    fn ordered(&self) -> Vec<String> {
        self.units.iter().rev().cloned().collect()
    }
}

impl Default for Actions {
    fn default() -> Self {
        Self::new()
    }
}

impl Actions {
    pub fn new() -> Actions {
        let (tx, rx) = mpsc::channel();
        Actions { pending: Vec::new(), paused_jobs: HashSet::new(), tx, rx }
    }

    /// Apps currently between SIGTERM and SIGKILL, reported as `stopping`.
    pub fn stopping(&self) -> HashSet<String> {
        self.pending.iter().map(|p| p.id.clone()).collect()
    }

    /// Jobs this sampler has stopped, reported as `paused`.
    pub fn paused_jobs(&self) -> &HashSet<String> {
        &self.paused_jobs
    }

    /// Forget Jobs that no longer exist, so a recycled id is never born paused.
    pub fn retain_jobs(&mut self, live: &HashSet<String>) {
        self.paused_jobs.retain(|id| live.contains(id));
    }

    /// Fire the SIGKILL for any Stop whose grace period has run out, and drain
    /// whatever action results have landed since the last tick.
    pub fn tick(&mut self, live: &dyn Fn(i32) -> bool) -> Vec<ActionEvent> {
        let now = Instant::now();
        let mut events = Vec::new();
        let mut still_pending = Vec::new();
        for p in std::mem::take(&mut self.pending) {
            let survivors: Vec<i32> = p.pids.iter().copied().filter(|pid| live(*pid)).collect();
            if survivors.is_empty() {
                continue; // SIGTERM was enough; the `ok` event already went out.
            }
            if now >= p.deadline {
                let err = signal("KILL", &survivors).err();
                events.push(ActionEvent {
                    id: p.id.clone(),
                    action: "stop".into(),
                    ok: err.is_none(),
                    error: err,
                });
            } else {
                still_pending.push(PendingKill { id: p.id, deadline: p.deadline, pids: survivors });
            }
        }
        self.pending = still_pending;
        while let Ok(e) = self.rx.try_recv() {
            events.push(e);
        }
        events
    }

    pub fn dispatch(&mut self, verb: &str, t: Target) -> Option<ActionEvent> {
        if t.read_only {
            return Some(ActionEvent {
                id: t.id,
                action: verb.into(),
                ok: false,
                error: Some("read-only bucket".into()),
            });
        }
        match verb {
            "stop" => self.stop(t),
            "pause" => Some(self.pause_resume("pause", &t)),
            "resume" => Some(self.pause_resume("resume", &t)),
            "restart" => self.restart(t),
            _ => Some(ActionEvent {
                id: t.id,
                action: verb.into(),
                ok: false,
                error: Some(format!("unknown action {verb}")),
            }),
        }
    }

    fn stop(&mut self, t: Target) -> Option<ActionEvent> {
        if !t.units.is_empty() {
            // systemd owns these units' lifecycles; going behind its back with a
            // signal would just make it restart the thing.
            self.systemctl_async("stop", &t, &[]);
            self.paused_jobs.remove(&t.id);
            return None;
        }
        // The process group first, so a shell pipeline dies as a unit rather
        // than one member at a time; then any stragglers that left the group.
        if let Some(pgid) = t.pgid {
            let _ = signal_group("TERM", pgid);
        }
        let err = signal("TERM", &t.pids).err();
        self.paused_jobs.remove(&t.id);
        self.pending.push(PendingKill {
            id: t.id.clone(),
            deadline: Instant::now() + GRACE,
            pids: t.pids,
        });
        Some(ActionEvent { id: t.id, action: "stop".into(), ok: err.is_none(), error: err })
    }

    fn restart(&mut self, t: Target) -> Option<ActionEvent> {
        // systemd cannot restart a `.scope`: it has no ExecStart and no memory
        // of how the processes got there. A `.service` it can, wherever the
        // bucket rules happen to have filed it.
        if !t.primary().ends_with(".service") {
            return Some(ActionEvent {
                id: t.id,
                action: "restart".into(),
                ok: false,
                error: Some("restart needs a systemd .service unit".into()),
            });
        }
        self.systemctl_async("restart", &t, &[]);
        None
    }

    /// Pause and Resume.
    ///
    /// For units this is the cgroup freezer via `systemctl freeze`/`thaw`. It
    /// is atomic over the whole cgroup -- including processes forked since the
    /// last tick, which a pid list can never be -- and it is a state the kernel
    /// will tell us about afterwards through `cgroup.freeze`. Signalling every
    /// pid by hand is racy in both directions: a process that forks between the
    /// scan and the signal escapes, and nothing records that a Pause happened.
    ///
    /// A Job has no cgroup of its own -- it lives inside the terminal's -- so it
    /// gets the process-group signal a shell would send, and the sampler
    /// remembers that it did.
    fn pause_resume(&mut self, verb: &str, t: &Target) -> ActionEvent {
        let unit_verb = if verb == "pause" { "freeze" } else { "thaw" };
        let sig = if verb == "pause" { "STOP" } else { "CONT" };

        let err = if !t.units.is_empty() {
            self.systemctl_all(unit_verb, t)
        } else if let Some(pgid) = t.pgid {
            signal_group(sig, pgid).or_else(|_| signal(sig, &t.pids)).err()
        } else {
            signal(sig, &t.pids).err()
        };

        if err.is_none() && t.is_job {
            if verb == "pause" {
                self.paused_jobs.insert(t.id.clone());
            } else {
                self.paused_jobs.remove(&t.id);
            }
        }
        ActionEvent { id: t.id.clone(), action: verb.into(), ok: err.is_none(), error: err }
    }

    /// Run one systemctl verb over every unit of the App, synchronously.
    /// Freeze and thaw return immediately, unlike stop, so there is nothing to
    /// gain from a thread and a straight answer is better.
    fn systemctl_all(&self, verb: &str, t: &Target) -> Option<String> {
        let mut first_err = None;
        for unit in t.ordered() {
            if let Err(e) = systemctl(&[verb], &unit, t.user_unit) {
                first_err.get_or_insert(e);
            }
        }
        first_err
    }

    /// `systemctl stop` on a system unit can sit for seconds waiting on polkit
    /// or on the unit's own shutdown, and the tick loop must not stall with it.
    /// The result is posted back and surfaces on whichever tick it arrives.
    fn systemctl_async(&self, verb: &str, t: &Target, _unused: &[&str]) {
        let tx = self.tx.clone();
        let (id, units, user, verb) = (t.id.clone(), t.ordered(), t.user_unit, verb.to_string());
        std::thread::spawn(move || {
            let mut err = None;
            for unit in &units {
                if let Err(e) = systemctl(&[verb.as_str()], unit, user) {
                    err.get_or_insert(e);
                }
            }
            let _ = tx.send(ActionEvent { id, action: verb, ok: err.is_none(), error: err });
        });
    }
}

fn systemctl(args: &[&str], unit: &str, user_unit: bool) -> Result<(), String> {
    let mut cmd = Command::new("systemctl");
    if user_unit {
        cmd.arg("--user");
    }
    // No sudo: a system unit goes through polkit, which is the only path that
    // can prompt the user's own session for authorisation.
    cmd.args(args).arg(unit);
    run(cmd)
}

fn signal(sig: &str, pids: &[i32]) -> Result<(), String> {
    if pids.is_empty() {
        return Ok(());
    }
    let mut cmd = Command::new("kill");
    cmd.arg(format!("-{sig}"));
    cmd.arg("--");
    for p in pids {
        cmd.arg(p.to_string());
    }
    run(cmd)
}

fn signal_group(sig: &str, pgid: i32) -> Result<(), String> {
    let mut cmd = Command::new("kill");
    // `--` keeps the negative pid from being read as an option.
    cmd.arg(format!("-{sig}")).arg("--").arg(format!("-{pgid}"));
    run(cmd)
}

fn run(mut cmd: Command) -> Result<(), String> {
    // stdout must stay clean: it is the protocol stream.
    cmd.stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::piped());
    match cmd.output() {
        Err(e) => Err(e.to_string()),
        Ok(out) if out.status.success() => Ok(()),
        Ok(out) => {
            let msg = String::from_utf8_lossy(&out.stderr).trim().to_string();
            if all_already_gone(&msg) {
                return Ok(());
            }
            Err(if msg.is_empty() { format!("exit {}", out.status) } else { msg })
        }
    }
}

/// Is every complaint just "that process is already gone"?
///
/// Stop signals the process group first and then the individual pids, so a
/// well-behaved Stop routinely races itself: the group kill reaps the pid and
/// the follow-up finds nothing to signal. That is the success case, and
/// reporting it as `ok: false` would put a scary error in front of a user whose
/// App did exactly what they asked.
fn all_already_gone(stderr: &str) -> bool {
    let lines: Vec<&str> = stderr.lines().map(str::trim).filter(|l| !l.is_empty()).collect();
    !lines.is_empty() && lines.iter().all(|l| l.contains("No such process"))
}

// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    fn target(id: &str) -> Target {
        Target {
            id: id.into(),
            units: vec![],
            user_unit: false,
            read_only: false,
            is_job: false,
            pids: vec![],
            pgid: None,
        }
    }

    #[test]
    fn a_stop_that_won_the_race_with_itself_is_still_a_success() {
        // What `kill(1)` prints when the process-group signal already reaped
        // the pid that the per-pid signal then tried to hit.
        assert!(all_already_gone("kill: sending signal to 91870 failed: No such process"));
        assert!(all_already_gone(
            "kill: sending signal to 1 failed: No such process\nkill: sending signal to 2 failed: No such process"
        ));
        // A real refusal must still surface.
        assert!(!all_already_gone("kill: sending signal to 1 failed: Operation not permitted"));
        assert!(!all_already_gone(
            "kill: sending signal to 1 failed: No such process\nkill: sending signal to 2 failed: Operation not permitted"
        ));
        assert!(!all_already_gone(""));
    }

    #[test]
    fn desktop_apps_refuse_every_action() {
        let mut a = Actions::new();
        let mut t = target("scope:pipewire.service");
        t.read_only = true;
        let e = a.dispatch("stop", t).unwrap();
        assert!(!e.ok);
        assert_eq!(e.error.as_deref(), Some("read-only bucket"));
    }

    #[test]
    fn restart_is_refused_for_jobs() {
        let mut a = Actions::new();
        let e = a.dispatch("restart", target("job:500:1787499744")).unwrap();
        assert!(!e.ok);
        assert!(e.error.unwrap().contains("needs a systemd .service unit"));
    }

    #[test]
    fn unknown_verbs_are_reported_not_ignored() {
        let mut a = Actions::new();
        let e = a.dispatch("obliterate", target("scope:x")).unwrap();
        assert!(!e.ok);
    }

    #[test]
    fn a_coalesced_app_stops_its_child_scope_before_its_parent() {
        // Chromium: the browser scope names the App and must die last, or the
        // user is left with a window full of crashed tabs.
        let mut t = target("scope:app-org.chromium.Chromium-3808.scope");
        t.units = vec![
            "app-org.chromium.Chromium-3808.scope".into(),
            "app-Hyprland-chromium-e1bdd203.scope".into(),
        ];
        assert_eq!(
            t.ordered(),
            vec![
                "app-Hyprland-chromium-e1bdd203.scope".to_string(),
                "app-org.chromium.Chromium-3808.scope".to_string()
            ]
        );
        assert_eq!(t.primary(), "app-org.chromium.Chromium-3808.scope");
    }

    #[test]
    fn restart_needs_a_service_unit_not_a_scope() {
        let mut a = Actions::new();
        // A scope has no ExecStart; systemd cannot restart it.
        let mut scope = target("scope:app-Hyprland-chromium-e1bdd203.scope");
        scope.units = vec!["app-Hyprland-chromium-e1bdd203.scope".into()];
        let e = a.dispatch("restart", scope).unwrap();
        assert!(!e.ok);
        // A `.service` is restartable wherever it is bucketed -- including the
        // Apps bucket, where autostarted units live.
        let mut svc = target("scope:app-dropbox@autostart.service");
        svc.units = vec!["app-dropbox@autostart.service".into()];
        // dispatch returns None because the work went to a thread.
        assert!(a.dispatch("restart", svc).is_none());
    }

    #[test]
    fn a_job_never_carries_a_unit() {
        // A Job lives inside the terminal's cgroup. If it reported that unit,
        // Pause would freeze the terminal and Stop would kill the shell the
        // user is typing into.
        let mut t = target("job:500:1");
        t.is_job = true;
        assert!(t.units.is_empty());
        assert_eq!(t.primary(), "");
        assert!(t.ordered().is_empty());
    }

    #[test]
    fn a_paused_job_is_remembered_and_forgotten() {
        let mut a = Actions::new();
        let mut t = target("job:500:1");
        t.is_job = true;
        t.pids = vec![]; // an empty signal succeeds, which is all this asserts
        a.dispatch("pause", t);
        assert!(a.paused_jobs().contains("job:500:1"));

        let mut t = target("job:500:1");
        t.is_job = true;
        a.dispatch("resume", t);
        assert!(!a.paused_jobs().contains("job:500:1"));

        // A Job that has gone must not leave its paused flag behind for a
        // recycled id to inherit.
        let mut t = target("job:501:1");
        t.is_job = true;
        a.dispatch("pause", t);
        assert!(a.paused_jobs().contains("job:501:1"));
        a.retain_jobs(&HashSet::new());
        assert!(a.paused_jobs().is_empty());
    }

    #[test]
    fn stop_marks_the_app_stopping_until_the_pids_are_gone() {
        let mut a = Actions::new();
        let mut t = target("job:500:1");
        t.pids = vec![999_999]; // signalling this fails; the bookkeeping is what is under test
        a.dispatch("stop", t);
        assert!(a.stopping().contains("job:500:1"));
        // Once every pid has vanished the App stops being `stopping`, and no
        // SIGKILL is sent.
        let events = a.tick(&|_| false);
        assert!(events.is_empty());
        assert!(a.stopping().is_empty());
    }

    #[test]
    fn survivors_are_killed_only_after_the_grace_period() {
        let mut a = Actions::new();
        let mut t = target("job:501:1");
        t.pids = vec![999_999];
        a.dispatch("stop", t);
        // Still inside the 5 s window: nothing escalates yet.
        assert!(a.tick(&|_| true).is_empty());
        assert!(a.stopping().contains("job:501:1"));
        // Wind the deadline back to simulate the grace period expiring.
        a.pending[0].deadline = Instant::now() - Duration::from_secs(1);
        let events = a.tick(&|_| true);
        assert_eq!(events.len(), 1);
        assert_eq!(events[0].action, "stop");
        assert!(a.stopping().is_empty());
    }
}
