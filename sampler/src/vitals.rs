//! System-wide Vitals: CPU, memory, GPU, disk, network, power, fan, PSI.
//!
//! Every sensor here is optional. The same binary has to run on a desktop with
//! no battery, an Intel laptop with no `amdgpu`, and a VM with no hwmon at all,
//! so discovery happens once at startup by *name* and each reader degrades to
//! `available: false` rather than failing the tick.

use serde::Serialize;
use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};

// ---------------------------------------------------------------------------
// Serialized shapes
// ---------------------------------------------------------------------------

#[derive(Serialize, Default)]
pub struct CpuVital {
    pub total: f64,
    pub cores: Vec<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub temp: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub freq: Option<u64>,
}

#[derive(Serialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct MemVital {
    pub total: u64,
    pub used: u64,
    pub avail: u64,
    pub swap_total: u64,
    pub swap_used: u64,
}

#[derive(Serialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct GpuVital {
    pub busy: f64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub temp: Option<f64>,
    pub vram_used: u64,
    pub vram_total: u64,
    pub available: bool,
}

#[derive(Serialize, Default)]
pub struct DiskVital {
    pub read: u64,
    pub write: u64,
}

#[derive(Serialize, Default)]
pub struct NetVital {
    pub rx: u64,
    pub tx: u64,
}

#[derive(Serialize, Default)]
pub struct PowerVital {
    pub watts: f64,
    pub battery: i32,
    pub charging: bool,
    pub available: bool,
}

#[derive(Serialize, Default)]
pub struct FanVital {
    pub rpm: u32,
    pub available: bool,
}

#[derive(Serialize, Default, Clone, Copy)]
#[serde(rename_all = "camelCase")]
pub struct PsiVital {
    pub cpu: f64,
    pub mem: f64,
    pub io: f64,
    pub mem_full: f64,
    pub io_full: f64,
}

#[derive(Serialize, Default)]
pub struct Vitals {
    pub cpu: CpuVital,
    pub mem: MemVital,
    pub gpu: GpuVital,
    pub disk: DiskVital,
    pub net: NetVital,
    pub power: PowerVital,
    pub fan: FanVital,
    pub psi: PsiVital,
    pub load: [f64; 3],
    pub uptime: f64,
    /// Pages swapped *in* per second, from `/proc/vmstat` `pswpin`.
    ///
    /// Not on the wire: it is an input to Pressure, not a Vital the overlay
    /// draws. It measures the thing that actually hurts -- the machine
    /// stalling to fetch a page back from swap -- which a swap-used ratio does
    /// not. On a zram box swap sits permanently non-zero and permanently
    /// painless, so the ratio is noise; a non-zero swap-in rate never is.
    #[serde(skip)]
    pub swap_in: f64,
}

// ---------------------------------------------------------------------------
// Sensor discovery
// ---------------------------------------------------------------------------

/// Paths found once at startup. hwmon numbering is assigned in probe order and
/// changes between boots, so nothing here may be hardcoded as `hwmonN`; we
/// match on the `name` file instead.
pub struct Sensors {
    pub cpu_temp: Option<PathBuf>,
    pub gpu_temp: Option<PathBuf>,
    pub fan_rpm: Option<PathBuf>,
    pub gpu_busy: Option<PathBuf>,
    pub vram_used: Option<PathBuf>,
    pub vram_total: Option<PathBuf>,
    pub battery: Option<PathBuf>,
    /// One `scaling_cur_freq` per online cpu.
    pub cpufreq: Vec<PathBuf>,
}

fn hwmon_by_name() -> HashMap<String, PathBuf> {
    let mut map = HashMap::new();
    let Ok(dir) = fs::read_dir("/sys/class/hwmon") else { return map };
    for e in dir.flatten() {
        let p = e.path();
        if let Ok(name) = fs::read_to_string(p.join("name")) {
            // First writer wins so the numbering stays deterministic when a
            // driver registers more than one hwmon under the same name.
            map.entry(name.trim().to_string()).or_insert(p);
        }
    }
    map
}

fn existing(p: PathBuf) -> Option<PathBuf> {
    if p.exists() {
        Some(p)
    } else {
        None
    }
}

/// First hwmon whose name is in `names` and which has `file`.
fn pick(map: &HashMap<String, PathBuf>, names: &[&str], file: &str) -> Option<PathBuf> {
    names
        .iter()
        .filter_map(|n| map.get(*n))
        .find_map(|d| existing(d.join(file)))
}

/// Any hwmon at all that exposes `file`, as a last resort.
fn pick_any(map: &HashMap<String, PathBuf>, file: &str) -> Option<PathBuf> {
    let mut dirs: Vec<&PathBuf> = map.values().collect();
    dirs.sort();
    dirs.into_iter().find_map(|d| existing(d.join(file)))
}

fn first_glob(dir: &str, prefix: &str, tail: &str) -> Option<PathBuf> {
    let mut hits: Vec<PathBuf> = fs::read_dir(dir)
        .ok()?
        .flatten()
        .map(|e| e.path())
        .filter(|p| {
            p.file_name()
                .and_then(|n| n.to_str())
                .map(|n| n.starts_with(prefix) && !n.contains('-'))
                .unwrap_or(false)
        })
        .collect();
    hits.sort();
    hits.into_iter().find_map(|p| existing(p.join(tail)))
}

impl Sensors {
    pub fn discover() -> Sensors {
        let h = hwmon_by_name();

        // CPU package temperature. k10temp's temp1 is Tctl on AMD; the Intel
        // and generic fallbacks follow.
        let cpu_temp = pick(&h, &["k10temp", "zenpower", "coretemp", "cpu_thermal"], "temp1_input")
            .or_else(|| pick(&h, &["acpitz_0", "acpitz"], "temp1_input"));

        let gpu_temp = pick(&h, &["amdgpu", "nouveau", "i915", "radeon"], "temp1_input");

        // acpi_fan first: on this chassis `cros_ec` also exposes fan1_input but
        // reports the same fan through a less direct path.
        let fan_rpm = pick(&h, &["acpi_fan", "dell_smm", "thinkpad", "cros_ec", "asus"], "fan1_input")
            .or_else(|| pick_any(&h, "fan1_input"));

        // The DRM card number is not stable either -- this machine's only GPU
        // is `card1`, not `card0`.
        let gpu_busy = first_glob("/sys/class/drm", "card", "device/gpu_busy_percent");
        let vram_used = first_glob("/sys/class/drm", "card", "device/mem_info_vram_used");
        let vram_total = first_glob("/sys/class/drm", "card", "device/mem_info_vram_total");

        let battery = fs::read_dir("/sys/class/power_supply")
            .ok()
            .into_iter()
            .flatten()
            .flatten()
            .map(|e| e.path())
            .filter(|p| {
                fs::read_to_string(p.join("type"))
                    .map(|t| t.trim() == "Battery")
                    .unwrap_or(false)
            })
            .min();

        // Enumerated once. Reading 24 tiny sysfs files costs a fraction of
        // parsing /proc/cpuinfo, which on a 24-thread machine is ~40 KB of text
        // to recover one number.
        let mut cpufreq: Vec<PathBuf> = fs::read_dir("/sys/devices/system/cpu")
            .into_iter()
            .flatten()
            .flatten()
            .map(|e| e.path())
            .filter(|p| {
                p.file_name()
                    .and_then(|n| n.to_str())
                    .map(|n| n.starts_with("cpu") && n[3..].bytes().all(|c| c.is_ascii_digit()) && n.len() > 3)
                    .unwrap_or(false)
            })
            .filter_map(|p| existing(p.join("cpufreq/scaling_cur_freq")))
            .collect();
        cpufreq.sort();

        Sensors { cpu_temp, gpu_temp, fan_rpm, gpu_busy, vram_used, vram_total, battery, cpufreq }
    }
}

// ---------------------------------------------------------------------------
// Small readers
// ---------------------------------------------------------------------------

fn read_num<T: std::str::FromStr>(p: &Option<PathBuf>) -> Option<T> {
    read_num_at(p.as_ref()?)
}

/// sysfs one-liners are read through the no-`statx` path too: the cpufreq
/// sweep alone is one file per cpu per tick.
fn read_num_at<T: std::str::FromStr>(p: &Path) -> Option<T> {
    let mut buf = [0u8; 64];
    crate::proc::read_small(p.to_str()?, &mut buf)?.trim().parse().ok()
}

// ---------------------------------------------------------------------------
// Stateful sampler
// ---------------------------------------------------------------------------

#[derive(Default, Clone)]
struct CpuTimes {
    idle: u64,
    total: u64,
}

fn parse_cpu_line(line: &str) -> CpuTimes {
    let v: Vec<u64> = line
        .split_whitespace()
        .skip(1)
        .filter_map(|x| x.parse().ok())
        .collect();
    // user nice system idle iowait irq softirq steal guest guest_nice
    let idle = v.get(3).copied().unwrap_or(0) + v.get(4).copied().unwrap_or(0);
    // guest and guest_nice are already counted inside user/nice, so summing the
    // first eight fields is the total without double counting.
    let total: u64 = v.iter().take(8).sum();
    CpuTimes { idle, total }
}

pub struct VitalsSampler {
    pub sensors: Sensors,
    pub ncpu: usize,
    pub clk_tck: u64,
    pub page_size: u64,
    pub btime: u64,
    prev_total: CpuTimes,
    prev_cores: Vec<CpuTimes>,
    prev_disk: Option<(u64, u64)>,
    prev_net: Option<(u64, u64)>,
    prev_pswpin: Option<u64>,
}

impl VitalsSampler {
    pub fn new() -> VitalsSampler {
        let stat = fs::read_to_string("/proc/stat").unwrap_or_default();
        let ncpu = stat
            .lines()
            .filter(|l| l.starts_with("cpu") && !l.starts_with("cpu "))
            .count()
            .max(1);
        let btime = stat
            .lines()
            .find_map(|l| l.strip_prefix("btime "))
            .and_then(|v| v.trim().parse().ok())
            .unwrap_or(0);

        VitalsSampler {
            sensors: Sensors::discover(),
            ncpu,
            clk_tck: detect_clk_tck(&stat, ncpu),
            page_size: detect_page_size(),
            btime,
            prev_total: CpuTimes::default(),
            prev_cores: Vec::new(),
            prev_disk: None,
            prev_net: None,
            prev_pswpin: None,
        }
    }

    pub fn sample(&mut self, interval: f64) -> Vitals {
        let mut v = Vitals::default();
        self.sample_cpu(&mut v);
        self.sample_mem(&mut v);
        self.sample_gpu(&mut v);
        self.sample_io(&mut v, interval);
        self.sample_power(&mut v);
        self.sample_fan(&mut v);
        v.psi = read_psi();
        v.swap_in = self.sample_swap_in(interval);
        v.load = read_loadavg();
        v.uptime = fs::read_to_string("/proc/uptime")
            .ok()
            .and_then(|s| s.split_whitespace().next()?.parse().ok())
            .unwrap_or(0.0);
        v
    }

    fn sample_cpu(&mut self, v: &mut Vitals) {
        let stat = fs::read_to_string("/proc/stat").unwrap_or_default();
        let mut cores = Vec::with_capacity(self.ncpu);
        let mut total = CpuTimes::default();
        for line in stat.lines() {
            if !line.starts_with("cpu") {
                break;
            }
            if line.starts_with("cpu ") {
                total = parse_cpu_line(line);
            } else {
                cores.push(parse_cpu_line(line));
            }
        }

        // Busy fraction from the jiffy deltas. The first tick has no previous
        // sample, so it reports 0 rather than a meaningless since-boot average.
        let busy = |now: &CpuTimes, prev: &CpuTimes| -> f64 {
            let dt = now.total.saturating_sub(prev.total);
            if dt == 0 {
                return 0.0;
            }
            let di = now.idle.saturating_sub(prev.idle);
            (100.0 * (dt.saturating_sub(di)) as f64 / dt as f64).clamp(0.0, 100.0)
        };

        v.cpu.total = round1(busy(&total, &self.prev_total));
        v.cpu.cores = cores
            .iter()
            .enumerate()
            .map(|(i, c)| {
                let prev = self.prev_cores.get(i).cloned().unwrap_or_default();
                round1(busy(c, &prev))
            })
            .collect();
        self.prev_total = total;
        self.prev_cores = cores;

        v.cpu.temp = read_num::<f64>(&self.sensors.cpu_temp).map(|m| round1(m / 1000.0));
        v.cpu.freq = self.read_freq_mhz();
    }

    /// Average core frequency in MHz.
    ///
    /// `scaling_cur_freq` (kHz) per cpu is the cheap and accurate source.
    /// `/proc/cpuinfo` is the fallback for machines with no cpufreq driver --
    /// most VMs -- and is deliberately not the default: parsing it every tick
    /// cost more than walking all 500 processes.
    fn read_freq_mhz(&self) -> Option<u64> {
        if !self.sensors.cpufreq.is_empty() {
            let mut sum = 0.0;
            let mut n = 0u32;
            for p in &self.sensors.cpufreq {
                if let Some(khz) = read_num_at::<f64>(p) {
                    sum += khz;
                    n += 1;
                }
            }
            if n > 0 {
                return Some((sum / n as f64 / 1000.0).round() as u64);
            }
        }
        let info = fs::read_to_string("/proc/cpuinfo").ok()?;
        let mut sum = 0.0;
        let mut n = 0u32;
        for line in info.lines() {
            if let Some(rest) = line.strip_prefix("cpu MHz") {
                if let Some(val) = rest.split(':').nth(1) {
                    if let Ok(f) = val.trim().parse::<f64>() {
                        sum += f;
                        n += 1;
                    }
                }
            }
        }
        (n > 0).then(|| (sum / n as f64).round() as u64)
    }

    fn sample_mem(&mut self, v: &mut Vitals) {
        let Ok(s) = fs::read_to_string("/proc/meminfo") else { return };
        let mut get = HashMap::new();
        for line in s.lines() {
            let mut it = line.split(':');
            let (Some(k), Some(val)) = (it.next(), it.next()) else { continue };
            let kb: u64 = val.split_whitespace().next().and_then(|x| x.parse().ok()).unwrap_or(0);
            get.insert(k.to_string(), kb * 1024);
        }
        let g = |k: &str| get.get(k).copied().unwrap_or(0);
        v.mem.total = g("MemTotal");
        v.mem.avail = g("MemAvailable");
        // "Used" as a human means it: total minus what the kernel says it could
        // hand out, not total minus free.
        v.mem.used = v.mem.total.saturating_sub(v.mem.avail);
        v.mem.swap_total = g("SwapTotal");
        v.mem.swap_used = g("SwapTotal").saturating_sub(g("SwapFree"));
    }

    fn sample_gpu(&mut self, v: &mut Vitals) {
        let busy = read_num::<f64>(&self.sensors.gpu_busy);
        let temp = read_num::<f64>(&self.sensors.gpu_temp).map(|m| round1(m / 1000.0));
        v.gpu.available = busy.is_some() || temp.is_some();
        v.gpu.busy = busy.unwrap_or(0.0);
        v.gpu.temp = temp;
        v.gpu.vram_used = read_num(&self.sensors.vram_used).unwrap_or(0);
        v.gpu.vram_total = read_num(&self.sensors.vram_total).unwrap_or(0);
    }

    fn sample_io(&mut self, v: &mut Vitals, interval: f64) {
        let (r, w) = read_diskstats();
        if let Some((pr, pw)) = self.prev_disk {
            v.disk.read = rate(r, pr, interval);
            v.disk.write = rate(w, pw, interval);
        }
        self.prev_disk = Some((r, w));

        let (rx, tx) = read_netdev();
        if let Some((prx, ptx)) = self.prev_net {
            v.net.rx = rate(rx, prx, interval);
            v.net.tx = rate(tx, ptx, interval);
        }
        self.prev_net = Some((rx, tx));
    }

    fn sample_power(&mut self, v: &mut Vitals) {
        let Some(bat) = self.sensors.battery.clone() else { return };
        v.power.available = true;
        v.power.battery = read_num_at::<i32>(&bat.join("capacity")).unwrap_or(-1);
        let status = fs::read_to_string(bat.join("status")).unwrap_or_default();
        v.power.charging = status.trim() == "Charging";

        // `power_now` is the direct answer but plenty of batteries (this one
        // included) only export charge-based `current_now`/`voltage_now`, both
        // in micro-units, so watts = µA * µV / 1e12.
        let watts = read_num_at::<f64>(&bat.join("power_now"))
            .map(|uw| uw / 1_000_000.0)
            .or_else(|| {
                let ua = read_num_at::<f64>(&bat.join("current_now"))?;
                let uv = read_num_at::<f64>(&bat.join("voltage_now"))?;
                Some(ua * uv / 1e12)
            })
            .unwrap_or(0.0);
        v.power.watts = round1(watts.abs());
    }
}

impl VitalsSampler {
    fn sample_swap_in(&mut self, interval: f64) -> f64 {
        let now = read_vmstat_pswpin();
        let rate = match (self.prev_pswpin, now) {
            (Some(prev), Some(now)) if interval > 0.0 => now.saturating_sub(prev) as f64 / interval,
            _ => 0.0,
        };
        if now.is_some() {
            self.prev_pswpin = now;
        }
        rate
    }

    fn sample_fan(&mut self, v: &mut Vitals) {
        // A fanless machine has no hwmon fan input at all; a fan that is simply
        // off reports 0 rpm. Only the first is `available: false`.
        if let Some(rpm) = read_num::<f64>(&self.sensors.fan_rpm) {
            v.fan.available = true;
            v.fan.rpm = rpm.max(0.0) as u32;
        }
    }
}

fn rate(now: u64, prev: u64, interval: f64) -> u64 {
    if interval <= 0.0 {
        return 0;
    }
    (now.saturating_sub(prev) as f64 / interval).round() as u64
}

pub fn round1(x: f64) -> f64 {
    (x * 10.0).round() / 10.0
}

/// USER_HZ is not exposed to a process without `sysconf`, and we have no libc
/// crate. It is inferable: the aggregate `/proc/stat` line counts jiffies for
/// every cpu since boot, so `total / (uptime * ncpu)` lands on the real value.
/// Snapping to the four values the kernel actually ships keeps rounding noise
/// from producing something absurd.
fn detect_clk_tck(stat: &str, ncpu: usize) -> u64 {
    let uptime: f64 = fs::read_to_string("/proc/uptime")
        .ok()
        .and_then(|s| s.split_whitespace().next()?.parse().ok())
        .unwrap_or(0.0);
    if uptime < 5.0 {
        return 100;
    }
    let Some(line) = stat.lines().find(|l| l.starts_with("cpu ")) else { return 100 };
    let total = parse_cpu_line(line).total as f64;
    let est = total / (uptime * ncpu as f64);
    [100u64, 250, 300, 1000]
        .into_iter()
        .min_by(|a, b| {
            let da = (*a as f64 - est).abs();
            let db = (*b as f64 - est).abs();
            da.partial_cmp(&db).unwrap()
        })
        .unwrap_or(100)
}

/// Page size, for turning RSS pages into bytes. 4096 everywhere on x86_64, but
/// aarch64 kernels ship 16k pages and `smaps` states it outright.
fn detect_page_size() -> u64 {
    fs::read_to_string("/proc/self/smaps")
        .ok()
        .and_then(|s| {
            s.lines().find_map(|l| {
                let rest = l.strip_prefix("KernelPageSize:")?;
                let kb: u64 = rest.split_whitespace().next()?.parse().ok()?;
                Some(kb * 1024)
            })
        })
        .filter(|p| *p > 0)
        .unwrap_or(4096)
}

/// Is this a whole physical disk (as opposed to a partition, a device-mapper
/// target, a loop device or zram)?
///
/// Counting both `nvme0n1` and `nvme0n1p2` would double every byte, and `dm-0`
/// on a LUKS root mirrors the traffic of the disk beneath it.
pub fn is_physical_disk(name: &str) -> bool {
    let b = name.as_bytes();
    if let Some(rest) = name.strip_prefix("nvme") {
        // nvme<d>n<d> with nothing after: `nvme0n1` yes, `nvme0n1p1` no.
        let mut it = rest.splitn(2, 'n');
        let (Some(ctrl), Some(ns)) = (it.next(), it.next()) else { return false };
        return !ctrl.is_empty()
            && ctrl.bytes().all(|c| c.is_ascii_digit())
            && !ns.is_empty()
            && ns.bytes().all(|c| c.is_ascii_digit());
    }
    if let Some(rest) = name.strip_prefix("mmcblk") {
        return !rest.is_empty() && rest.bytes().all(|c| c.is_ascii_digit());
    }
    if name.starts_with("sd") || name.starts_with("vd") {
        let rest = &b[2..];
        return !rest.is_empty() && rest.iter().all(|c| c.is_ascii_lowercase());
    }
    false
}

/// Total sectors read and written across physical disks, converted to bytes.
/// The 512 factor is the fixed sector unit `diskstats` uses regardless of the
/// device's real block size.
pub fn read_diskstats() -> (u64, u64) {
    let Ok(s) = fs::read_to_string("/proc/diskstats") else { return (0, 0) };
    parse_diskstats(&s)
}

pub fn parse_diskstats(s: &str) -> (u64, u64) {
    let mut read = 0u64;
    let mut write = 0u64;
    for line in s.lines() {
        let f: Vec<&str> = line.split_whitespace().collect();
        if f.len() < 10 {
            continue;
        }
        if !is_physical_disk(f[2]) {
            continue;
        }
        read += f[5].parse::<u64>().unwrap_or(0) * 512;
        write += f[9].parse::<u64>().unwrap_or(0) * 512;
    }
    (read, write)
}

pub fn read_netdev() -> (u64, u64) {
    let Ok(s) = fs::read_to_string("/proc/net/dev") else { return (0, 0) };
    parse_netdev(&s)
}

pub fn parse_netdev(s: &str) -> (u64, u64) {
    let mut rx = 0u64;
    let mut tx = 0u64;
    for line in s.lines().skip(2) {
        let Some((iface, rest)) = line.split_once(':') else { continue };
        if iface.trim() == "lo" {
            continue;
        }
        let f: Vec<&str> = rest.split_whitespace().collect();
        if f.len() < 9 {
            continue;
        }
        rx += f[0].parse::<u64>().unwrap_or(0);
        tx += f[8].parse::<u64>().unwrap_or(0);
    }
    (rx, tx)
}

fn read_vmstat_pswpin() -> Option<u64> {
    let s = fs::read_to_string("/proc/vmstat").ok()?;
    parse_pswpin(&s)
}

pub fn parse_pswpin(s: &str) -> Option<u64> {
    s.lines()
        .find_map(|l| l.strip_prefix("pswpin ")?.trim().parse().ok())
}

pub fn read_psi() -> PsiVital {
    let g = |file: &str| -> (f64, f64) { parse_pressure(&fs::read_to_string(file).unwrap_or_default()) };
    let (cpu_some, _) = g("/proc/pressure/cpu");
    let (mem_some, mem_full) = g("/proc/pressure/memory");
    let (io_some, io_full) = g("/proc/pressure/io");
    PsiVital { cpu: cpu_some, mem: mem_some, io: io_some, mem_full, io_full }
}

/// Pull the `avg10` figures off a `/proc/pressure/*` file. Returns
/// `(some, full)`; the cpu file has no `full` line on most kernels.
pub fn parse_pressure(s: &str) -> (f64, f64) {
    let mut some = 0.0;
    let mut full = 0.0;
    for line in s.lines() {
        let val = line
            .split_whitespace()
            .find_map(|t| t.strip_prefix("avg10=")?.parse::<f64>().ok())
            .unwrap_or(0.0);
        if line.starts_with("some") {
            some = val;
        } else if line.starts_with("full") {
            full = val;
        }
    }
    (some, full)
}

fn read_loadavg() -> [f64; 3] {
    let s = fs::read_to_string("/proc/loadavg").unwrap_or_default();
    let f: Vec<f64> = s.split_whitespace().take(3).filter_map(|x| x.parse().ok()).collect();
    [
        f.first().copied().unwrap_or(0.0),
        f.get(1).copied().unwrap_or(0.0),
        f.get(2).copied().unwrap_or(0.0),
    ]
}

// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn physical_disks_only() {
        for good in ["nvme0n1", "nvme1n2", "sda", "sdab", "vda", "mmcblk0"] {
            assert!(is_physical_disk(good), "{good} should count");
        }
        for bad in ["nvme0n1p1", "nvme0n1p2", "sda1", "vda12", "mmcblk0p1", "dm-0", "zram0", "loop3", "sr0"] {
            assert!(!is_physical_disk(bad), "{bad} should not count");
        }
    }

    #[test]
    fn diskstats_skip_partitions_and_dm() {
        // Real lines from this machine: the partitions and the LUKS dm target
        // mirror nvme0n1's traffic and must not be added to it.
        let s = "\
 259       0 nvme0n1 292908 7756 100 69918 177130 21462 200 82964 0 24932 153222
 259       1 nvme0n1p1 1021 3297 20045 711 13 0 11 0 0 50 711
 253       0 dm-0 296203 0 10772136 68011 198574 0 6755544 382708 0 35204 450719
 252       0 zram0 75 0 2848 0 1 0 8 0 0 0 0";
        assert_eq!(parse_diskstats(s), (100 * 512, 200 * 512));
    }

    #[test]
    fn netdev_excludes_loopback() {
        let s = "Inter-|   Receive                        |  Transmit
 face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed
    lo:   50596     609    0    0    0     0          0         0    50596     609    0    0    0     0       0          0
wlp192s0: 100  112462    0   29    0     0          0         0 200  60232    0    9    0     0       0          0";
        assert_eq!(parse_netdev(s), (100, 200));
    }

    #[test]
    fn pressure_reads_avg10_only() {
        let s = "some avg10=1.25 avg60=2.00 avg300=3.00 total=3595820\n\
                 full avg10=0.50 avg60=0.10 avg300=0.00 total=0\n";
        assert_eq!(parse_pressure(s), (1.25, 0.50));
        // The cpu file has no `full` line on most kernels.
        assert_eq!(parse_pressure("some avg10=4.00 avg60=0.00 avg300=0.00 total=1\n"), (4.0, 0.0));
        assert_eq!(parse_pressure(""), (0.0, 0.0));
    }

    #[test]
    fn reads_swap_in_counter() {
        let s = "pgpgin 12345\npswpin 678\npswpout 90\n";
        assert_eq!(parse_pswpin(s), Some(678));
        assert_eq!(parse_pswpin("nr_free_pages 1\n"), None);
        // `pswpin` must not be confused with `pswpout` by a prefix match.
        assert_eq!(parse_pswpin("pswpout 90\npswpin 7\n"), Some(7));
    }

    #[test]
    fn cpu_line_excludes_guest_double_count() {
        // guest/guest_nice (fields 9 and 10) are already inside user/nice.
        let t = parse_cpu_line("cpu  10 0 10 70 10 0 0 0 999 999");
        assert_eq!(t.total, 100);
        assert_eq!(t.idle, 80);
    }
}
