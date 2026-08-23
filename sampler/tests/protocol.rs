//! End-to-end check of the wire contract.
//!
//! The unit tests cover the classification rules; this one covers the thing
//! they cannot -- that the binary, run against this actual machine, emits lines
//! the shell can parse, and answers commands on stdin. It runs the real
//! executable, so it is the only test that would catch a field going missing
//! from the serialized shape.

use serde_json::Value;
use std::io::{BufRead, BufReader, Write};
use std::process::{Child, ChildStdout, Command, Stdio};
use std::sync::mpsc;
use std::time::Duration;

const BIN: &str = env!("CARGO_BIN_EXE_omatop-sampler");

struct Sampler {
    child: Child,
    rx: mpsc::Receiver<String>,
}

impl Sampler {
    fn start() -> Sampler {
        let mut child = Command::new(BIN)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .expect("spawn sampler");
        let stdout: ChildStdout = child.stdout.take().unwrap();
        let (tx, rx) = mpsc::channel();
        std::thread::spawn(move || {
            for line in BufReader::new(stdout).lines().map_while(Result::ok) {
                if tx.send(line).is_err() {
                    break;
                }
            }
        });
        Sampler { child, rx }
    }

    fn send(&mut self, cmd: &str) {
        let stdin = self.child.stdin.as_mut().unwrap();
        writeln!(stdin, "{cmd}").unwrap();
        stdin.flush().unwrap();
    }

    /// Next tick, or a panic. A hang here is a real failure, not a slow test.
    fn tick(&self) -> Value {
        let line = self
            .rx
            .recv_timeout(Duration::from_secs(10))
            .expect("sampler produced a tick within 10s");
        serde_json::from_str(&line).expect("tick is valid JSON")
    }
}

impl Drop for Sampler {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

#[test]
fn every_tick_carries_the_documented_shape() {
    let s = Sampler::start();
    let t = s.tick();

    for key in ["v", "t", "interval", "ncpu", "vitals", "pressure", "history", "apps", "events"] {
        assert!(t.get(key).is_some(), "tick is missing `{key}`");
    }
    assert_eq!(t["v"], 1);
    assert!(t["t"].as_u64().unwrap() > 1_600_000_000_000, "t is unix milliseconds");
    assert!(t["ncpu"].as_u64().unwrap() >= 1);
    // `culprit` is nullable but must always be present so the reader can rely on it.
    assert!(t.get("culprit").is_some());

    let v = &t["vitals"];
    for key in ["cpu", "mem", "gpu", "disk", "net", "power", "fan", "psi", "load", "uptime"] {
        assert!(v.get(key).is_some(), "vitals is missing `{key}`");
    }
    assert_eq!(
        v["cpu"]["cores"].as_array().unwrap().len(),
        t["ncpu"].as_u64().unwrap() as usize,
        "one core figure per cpu"
    );
    assert_eq!(v["load"].as_array().unwrap().len(), 3);
    assert!(v["mem"]["total"].as_u64().unwrap() > 0);
    // Optional sensors must say so rather than inventing a reading.
    for key in ["gpu", "power", "fan"] {
        assert!(v[key]["available"].is_boolean(), "{key}.available must be a bool");
    }
    for key in ["cpu", "mem", "io", "memFull", "ioFull"] {
        assert!(v["psi"][key].is_number(), "psi.{key}");
    }

    let p = &t["pressure"];
    assert!(["calm", "busy", "critical"].contains(&p["level"].as_str().unwrap()));
    let score = p["score"].as_f64().unwrap();
    assert!((0.0..=1.5).contains(&score), "score {score} out of range");
    assert!(p["reason"].is_string());

    for key in ["cpu", "mem", "gpu", "temp", "netRx", "netTx", "diskRead", "diskWrite", "power"] {
        let series = t["history"][key].as_array().expect(key);
        assert!(series.len() <= 120, "{key} history exceeds two minutes");
    }
}

#[test]
fn apps_cover_every_bucket_and_carry_every_field() {
    let s = Sampler::start();
    let t = s.tick();
    let apps = t["apps"].as_array().unwrap();
    assert!(!apps.is_empty(), "a running Linux machine always has Apps");

    for a in apps {
        for key in [
            "id", "kind", "bucket", "name", "icon", "tag", "cmd", "unit", "userUnit", "cpu", "mem",
            "gpu", "nproc", "pids", "leader", "started", "ports", "state", "recent", "tty",
            "readOnly",
        ] {
            assert!(a.get(key).is_some(), "app {} is missing `{key}`", a["id"]);
        }
        let id = a["id"].as_str().unwrap();
        assert!(!id.is_empty());
        assert!(["app", "job", "service", "desktop", "kernel"].contains(&a["kind"].as_str().unwrap()));
        assert!(["apps", "desktop", "services", "kernel"].contains(&a["bucket"].as_str().unwrap()));
        assert!(["running", "paused", "stopping"].contains(&a["state"].as_str().unwrap()));
        assert!(a["cmd"].as_str().unwrap().chars().count() <= 200, "cmd not truncated: {id}");
        assert!(a["pids"].as_array().unwrap().len() <= 64, "pids not trimmed: {id}");
        assert!(!a["name"].as_str().unwrap().is_empty(), "every App needs a name: {id}");
        // -1 means "no DRM handle"; anything else is a percentage.
        let gpu = a["gpu"].as_f64().unwrap();
        assert!(gpu == -1.0 || gpu >= 0.0, "odd gpu value on {id}");
        // The Desktop bucket is read-only by definition.
        if a["bucket"] == "desktop" {
            assert_eq!(a["readOnly"], true, "desktop App {id} must be read-only");
        }
    }

    // Every machine has kernel threads, and they are one App called Kernel.
    let kernel: Vec<&Value> = apps.iter().filter(|a| a["bucket"] == "kernel").collect();
    assert_eq!(kernel.len(), 1, "kernel is exactly one App");
    assert_eq!(kernel[0]["name"], "Kernel");
    assert_eq!(kernel[0]["readOnly"], true);

    // Ids are unique: the shell keys its rows on them.
    let mut ids: Vec<&str> = apps.iter().map(|a| a["id"].as_str().unwrap()).collect();
    ids.sort_unstable();
    let before = ids.len();
    ids.dedup();
    assert_eq!(before, ids.len(), "duplicate App ids");
}

#[test]
fn rate_changes_the_tick_interval() {
    let mut s = Sampler::start();
    s.tick();
    s.send("rate 4");
    // Let the new rate take effect, then measure a few ticks.
    for _ in 0..2 {
        s.tick();
    }
    let start = std::time::Instant::now();
    for _ in 0..4 {
        s.tick();
    }
    let elapsed = start.elapsed();
    assert!(
        elapsed < Duration::from_millis(1800),
        "4 ticks at 4 Hz took {elapsed:?}; rate was not applied"
    );
    let t = s.tick();
    let interval = t["interval"].as_f64().unwrap();
    assert!(interval < 0.5, "interval {interval} does not reflect rate 4");
}

#[test]
fn detail_adds_processes_and_history_then_clears() {
    let mut s = Sampler::start();
    s.send("rate 4");
    let first = s.tick();
    // Pick an App with several processes so the Process list is meaningful.
    let target = first["apps"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|a| a["nproc"].as_u64().unwrap() > 1 && a["bucket"] != "kernel")
        .map(|a| a["id"].as_str().unwrap().to_string())
        .next()
        .expect("some App has more than one Process");

    s.send(&format!("detail {target}"));
    let mut detail = None;
    for _ in 0..12 {
        let t = s.tick();
        if t.get("detail").is_some() {
            detail = Some(t);
            break;
        }
    }
    let t = detail.expect("`detail` appears after the command");
    assert_eq!(t["detail"]["id"].as_str().unwrap(), target);
    for key in ["cpu", "mem", "gpu"] {
        assert!(t["detail"][key].is_array(), "detail.{key}");
    }

    let rows = t["processes"][&target].as_array().expect("processes for the detail App");
    assert!(!rows.is_empty());
    for r in rows {
        for key in ["pid", "comm", "cpu", "mem", "state", "cmd", "threads"] {
            assert!(r.get(key).is_some(), "process row is missing `{key}`");
        }
    }
    // Only the requested App gets a Process list.
    assert_eq!(t["processes"].as_object().unwrap().len(), 1);

    s.send("detail -");
    let mut cleared = false;
    for _ in 0..12 {
        if s.tick().get("detail").is_none() {
            cleared = true;
            break;
        }
    }
    assert!(cleared, "`detail -` did not clear the request");
}

#[test]
fn actions_always_answer_even_when_they_fail() {
    let mut s = Sampler::start();
    s.send("rate 4");
    s.tick();
    s.send("stop scope:definitely-not-a-real-unit.service");

    let mut event = None;
    for _ in 0..12 {
        let t = s.tick();
        if let Some(e) = t["events"].as_array().and_then(|v| v.first().cloned()) {
            event = Some(e);
            break;
        }
    }
    let e = event.expect("an action always produces an event");
    assert_eq!(e["type"], "action");
    assert_eq!(e["id"], "scope:definitely-not-a-real-unit.service");
    assert_eq!(e["action"], "stop");
    assert_eq!(e["ok"], false);
    assert!(e["error"].is_string());
}

#[test]
fn a_tick_line_stays_small_enough_to_ship_every_second() {
    let s = Sampler::start();
    s.tick();
    let line = s.rx.recv_timeout(Duration::from_secs(10)).unwrap();
    assert!(
        line.len() < 150 * 1024,
        "tick line is {} bytes, over the 150 KB budget",
        line.len()
    );
    assert!(!line.contains('\n'), "a tick must be exactly one line");
}
