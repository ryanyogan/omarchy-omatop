//! Rings of the last two minutes.
//!
//! The overlay's whole promise is that opening it after a spike still shows the
//! spike, so History is kept whether or not anyone is looking. The ring always
//! advances at 1 Hz: `rate 4` gives the caller a smoother live number without
//! shortening the window to thirty seconds, so sub-second samples are averaged
//! into the second they belong to.

use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::fs;
use std::path::PathBuf;
use std::time::{SystemTime, UNIX_EPOCH};

pub const CAP: usize = 120;

/// How often the ring is written to disk.
const SAVE_EVERY: Duration = Duration::from_secs(10);
/// Older than this and the saved ring describes a machine that has moved on.
const MAX_AGE_SECS: u64 = 300;

use std::time::Duration;

/// One series: a ring of up to `CAP` finished seconds, plus the running mean of
/// the second in progress.
#[derive(Default, Clone)]
pub struct Series {
    values: Vec<f32>,
    sum: f64,
    count: u32,
}

impl Series {
    pub fn accumulate(&mut self, v: f64) {
        self.sum += v;
        self.count += 1;
    }

    /// Close the current second and push its mean.
    ///
    /// A second with no samples still advances the ring with a zero so every
    /// series stays index-aligned in time; the alternative is graphs that drift
    /// apart after a stall.
    pub fn flush(&mut self) {
        let mean = if self.count > 0 { self.sum / self.count as f64 } else { 0.0 };
        if self.values.len() == CAP {
            self.values.remove(0);
        }
        self.values.push(mean as f32);
        self.sum = 0.0;
        self.count = 0;
    }

    #[cfg_attr(not(test), allow(dead_code))]
    pub fn values(&self) -> &[f32] {
        &self.values
    }

    fn restore(&mut self, v: Vec<f32>) {
        self.values = v;
        if self.values.len() > CAP {
            let drop = self.values.len() - CAP;
            self.values.drain(..drop);
        }
    }

    /// Rounded for the wire. Percentages want one decimal; byte counts are
    /// integers and would otherwise cost several characters each across 120
    /// samples and a dozen series.
    pub fn rounded(&self, decimals: u32) -> Vec<f64> {
        let m = 10f64.powi(decimals as i32);
        self.values.iter().map(|v| (*v as f64 * m).round() / m).collect()
    }

}

/// The nine system-wide series the protocol names.
#[derive(Default)]
pub struct SystemHistory {
    pub cpu: Series,
    pub mem: Series,
    pub gpu: Series,
    pub temp: Series,
    pub net_rx: Series,
    pub net_tx: Series,
    pub disk_read: Series,
    pub disk_write: Series,
    pub power: Series,
}

/// What gets written to disk. Named fields rather than a tuple so a future
/// series can be added without invalidating everyone's saved ring.
#[derive(Serialize, Deserialize, Default)]
struct Saved {
    t: u64,
    #[serde(default)]
    cpu: Vec<f32>,
    #[serde(default)]
    mem: Vec<f32>,
    #[serde(default)]
    gpu: Vec<f32>,
    #[serde(default)]
    temp: Vec<f32>,
    #[serde(default)]
    net_rx: Vec<f32>,
    #[serde(default)]
    net_tx: Vec<f32>,
    #[serde(default)]
    disk_read: Vec<f32>,
    #[serde(default)]
    disk_write: Vec<f32>,
    #[serde(default)]
    power: Vec<f32>,
}

fn now_secs() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0)
}

/// `$HOME/.local/state/omatop/history.json`.
///
/// Omatop keeps its own state directory. It used to write next to Omarchy's
/// own state, but the shell's bar watches `~/.local/state/omarchy/current`
/// through a directory watch that fires for every entry created, renamed or
/// removed in `~/.local/state/omarchy`, and each firing re-sampled the
/// wallpaper. Our 10 s atomic rename was that trigger.
pub fn state_path() -> Option<PathBuf> {
    let home = std::env::var("HOME").ok()?;
    Some(PathBuf::from(home).join(".local/state/omatop/history.json"))
}

/// Where versions before 1.1.7 kept the ring.
fn legacy_state_path() -> Option<PathBuf> {
    let home = std::env::var("HOME").ok()?;
    Some(PathBuf::from(home).join(".local/state/omarchy/omatop-history.json"))
}

/// Move a ring left by an older version into the new directory, once.
fn migrate_legacy_state(path: &PathBuf) {
    let Some(legacy) = legacy_state_path() else { return };
    if path.exists() || !legacy.exists() {
        return;
    }
    if let Some(dir) = path.parent() {
        let _ = fs::create_dir_all(dir);
    }
    let _ = fs::rename(&legacy, path);
    let _ = fs::remove_file(legacy.with_extension("json.tmp"));
}

impl SystemHistory {
    pub fn flush(&mut self) {
        for s in self.all_mut() {
            s.flush();
        }
    }

    /// Reload the ring written by a previous run.
    ///
    /// The shell restarts the sampler on every plugin file save, and the whole
    /// point of History is that the spike is still there when you look. A ring
    /// older than five minutes describes a machine that has moved on, so it is
    /// discarded rather than shown as if it were now.
    pub fn load(&mut self) {
        let Some(path) = state_path() else { return };
        migrate_legacy_state(&path);
        let Ok(text) = fs::read_to_string(&path) else { return };
        let Ok(s) = serde_json::from_str::<Saved>(&text) else { return };
        let age = now_secs().saturating_sub(s.t);
        if s.t == 0 || age > MAX_AGE_SECS {
            return;
        }
        self.cpu.restore(s.cpu);
        self.mem.restore(s.mem);
        self.gpu.restore(s.gpu);
        self.temp.restore(s.temp);
        self.net_rx.restore(s.net_rx);
        self.net_tx.restore(s.net_tx);
        self.disk_read.restore(s.disk_read);
        self.disk_write.restore(s.disk_write);
        self.power.restore(s.power);
    }

    /// Write the ring if `SAVE_EVERY` has passed. Returns the new deadline.
    pub fn save_if_due(&self, last: &mut std::time::Instant) {
        if last.elapsed() < SAVE_EVERY {
            return;
        }
        *last = std::time::Instant::now();
        self.save();
    }

    pub fn save(&self) {
        let Some(path) = state_path() else { return };
        let saved = Saved {
            t: now_secs(),
            cpu: self.cpu.values.clone(),
            mem: self.mem.values.clone(),
            gpu: self.gpu.values.clone(),
            temp: self.temp.values.clone(),
            net_rx: self.net_rx.values.clone(),
            net_tx: self.net_tx.values.clone(),
            disk_read: self.disk_read.values.clone(),
            disk_write: self.disk_write.values.clone(),
            power: self.power.values.clone(),
        };
        let Ok(text) = serde_json::to_string(&saved) else { return };
        if let Some(dir) = path.parent() {
            let _ = fs::create_dir_all(dir);
        }
        // Write-then-rename: a reader must never see half a file, and a crash
        // mid-write must not destroy the ring that was already there.
        let tmp = path.with_extension("json.tmp");
        if fs::write(&tmp, text).is_ok() {
            let _ = fs::rename(&tmp, &path);
        }
    }

    fn all_mut(&mut self) -> [&mut Series; 9] {
        [
            &mut self.cpu,
            &mut self.mem,
            &mut self.gpu,
            &mut self.temp,
            &mut self.net_rx,
            &mut self.net_tx,
            &mut self.disk_read,
            &mut self.disk_write,
            &mut self.power,
        ]
    }
}

/// Per-App cpu / mem / gpu, kept for every App so that `detail <id>` can answer
/// immediately with two minutes of backlog instead of starting from empty.
#[derive(Default, Clone)]
pub struct AppHistory {
    pub cpu: Series,
    pub mem: Series,
    pub gpu: Series,
}

#[derive(Default)]
pub struct AppHistories {
    map: HashMap<String, AppHistory>,
}

impl AppHistories {
    pub fn accumulate(&mut self, id: &str, cpu: f64, mem: f64, gpu: f64) {
        let e = self.map.entry(id.to_string()).or_default();
        e.cpu.accumulate(cpu);
        e.mem.accumulate(mem);
        // `-1` means "this App has no GPU handle". Averaging it with real
        // percentages would produce a number that means nothing, so unknown
        // samples are recorded as zero.
        e.gpu.accumulate(if gpu < 0.0 { 0.0 } else { gpu });
    }

    /// Close the second for every App we still know about, and forget the ones
    /// that have gone. Retaining dead Apps would leak a ring per short-lived
    /// shell command.
    pub fn flush(&mut self, live: &std::collections::HashSet<String>) {
        self.map.retain(|id, _| live.contains(id));
        for h in self.map.values_mut() {
            h.cpu.flush();
            h.mem.flush();
            h.gpu.flush();
        }
    }

    pub fn get(&self, id: &str) -> Option<&AppHistory> {
        self.map.get(id)
    }
}

// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn averages_sub_second_samples_into_one_slot() {
        let mut s = Series::default();
        // Four samples in one second at `rate 4` collapse to their mean.
        for v in [10.0, 20.0, 30.0, 40.0] {
            s.accumulate(v);
        }
        s.flush();
        assert_eq!(s.values(), &[25.0]);
    }

    #[test]
    fn ring_holds_two_minutes_and_drops_the_oldest() {
        let mut s = Series::default();
        for i in 0..(CAP + 5) {
            s.accumulate(i as f64);
            s.flush();
        }
        assert_eq!(s.values().len(), CAP);
        assert_eq!(s.values()[0], 5.0);
        assert_eq!(*s.values().last().unwrap(), (CAP + 4) as f32);
    }

    #[test]
    fn a_silent_second_still_advances_the_ring() {
        let mut s = Series::default();
        s.accumulate(9.0);
        s.flush();
        s.flush();
        assert_eq!(s.values(), &[9.0, 0.0]);
    }

    #[test]
    fn dead_apps_are_forgotten() {
        let mut h = AppHistories::default();
        h.accumulate("scope:a", 1.0, 2.0, -1.0);
        h.accumulate("scope:b", 1.0, 2.0, 3.0);
        let live = ["scope:a".to_string()].into_iter().collect();
        h.flush(&live);
        assert!(h.get("scope:a").is_some());
        assert!(h.get("scope:b").is_none());
        // Unknown GPU is stored as 0, not as -1.
        assert_eq!(h.get("scope:a").unwrap().gpu.values(), &[0.0]);
    }
}
