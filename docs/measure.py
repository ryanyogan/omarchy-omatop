#!/usr/bin/env python3
"""Omatop runtime-cost harness.

Samples /proc once per second for a labelled window and prints a row in the
shape of docs/performance.md, plus the per-second CPU series.

Per-process CPU comes from two independent sources, and both are reported:
  * `stat`      utime+stime from /proc/<pid>/stat, whole thread group, 10 ms
  * `schedstat` sum of /proc/<pid>/task/*/schedstat field 1, nanoseconds
/proc/<pid>/schedstat unsummed is the main thread only and is never used.

Usage:
  measure.py --label D --seconds 45 [--json out.json]
  measure.py --list-pids

Process discovery is by exact cmdline match; override with --shell-pid etc.
No input is generated and nothing is killed.  Drive surfaces yourself with
`omarchy-shell ...` around the window, or use --pre / --post to run a command
before / after the window (the harness sleeps --settle seconds after --pre).
"""

import argparse
import json
import os
import re
import subprocess
import sys
import time

CLK = os.sysconf("SC_CLK_TCK")
GPU_BUSY = "/sys/class/drm/card1/device/gpu_busy_percent"


# ----------------------------------------------------------------- discovery

def pids_matching(pattern):
    out = []
    rx = re.compile(pattern)
    for name in os.listdir("/proc"):
        if not name.isdigit():
            continue
        try:
            with open(f"/proc/{name}/cmdline", "rb") as fh:
                cmd = fh.read().replace(b"\0", b" ").decode(errors="replace").strip()
        except OSError:
            continue
        if cmd and rx.search(cmd):
            out.append((int(name), cmd))
    return out


def find_one(pattern, what):
    hits = pids_matching(pattern)
    # ignore our own shell wrappers
    hits = [(p, c) for (p, c) in hits if p != os.getpid()]
    if not hits:
        return None, None
    if len(hits) > 1:
        hits.sort()
    return hits[0]


# -------------------------------------------------------------------- probes

def proc_stat_cpu(pid):
    """utime+stime in seconds for the whole thread group."""
    try:
        with open(f"/proc/{pid}/stat") as fh:
            raw = fh.read()
    except OSError:
        return None
    # comm may contain spaces and parens; split on the last ')'
    tail = raw[raw.rindex(")") + 2:].split()
    utime, stime = int(tail[11]), int(tail[12])
    return (utime + stime) / CLK


def task_schedstat_ns(pid):
    """Sum of field 1 (ns on cpu) over every thread. Undercounts if threads
    exit mid-window, taking their accumulated ns with them."""
    total = 0
    nthreads = 0
    try:
        tasks = os.listdir(f"/proc/{pid}/task")
    except OSError:
        return None, 0
    for t in tasks:
        try:
            with open(f"/proc/{pid}/task/{t}/schedstat") as fh:
                total += int(fh.read().split()[0])
            nthreads += 1
        except (OSError, IndexError, ValueError):
            pass
    return total, nthreads


def proc_status(pid):
    out = {"rss_kb": None, "threads": None, "ctxsw": None}
    try:
        with open(f"/proc/{pid}/status") as fh:
            vol = nonvol = 0
            for line in fh:
                if line.startswith("VmRSS:"):
                    out["rss_kb"] = int(line.split()[1])
                elif line.startswith("Threads:"):
                    out["threads"] = int(line.split()[1])
                elif line.startswith("voluntary_ctxt_switches:"):
                    vol = int(line.split()[1])
                elif line.startswith("nonvoluntary_ctxt_switches:"):
                    nonvol = int(line.split()[1])
            out["ctxsw"] = vol + nonvol
    except OSError:
        return out
    return out


def machine_cpu():
    with open("/proc/stat") as fh:
        parts = fh.readline().split()[1:]
    vals = [int(v) for v in parts]
    idle = vals[3] + vals[4]          # idle + iowait
    return sum(vals), idle


def gpu_busy():
    try:
        with open(GPU_BUSY) as fh:
            return int(fh.read().strip())
    except OSError:
        return None


def layers_present(token=""):
    try:
        out = subprocess.run(["hyprctl", "layers"], capture_output=True,
                             text=True, timeout=5).stdout
    except Exception:
        return []
    names = re.findall(r"namespace:\s*([^,\n]+)", out)
    return sorted(set(n.strip() for n in names if token in n))


# -------------------------------------------------------------------- window

def sample(pids):
    s = {"t": time.time(), "gpu": gpu_busy()}
    tot, idle = machine_cpu()
    s["mach_total"], s["mach_idle"] = tot, idle
    for name, pid in pids.items():
        if pid is None:
            continue
        st = proc_status(pid)
        ns, nt = task_schedstat_ns(pid)
        s[name] = {
            "cpu_stat": proc_stat_cpu(pid),
            "sched_ns": ns,
            "sched_threads": nt,
            **st,
        }
    return s


def run(label, seconds, pids, note=""):
    samples = []
    layer_checks = {}
    for i in range(seconds + 1):
        samples.append(sample(pids))
        if i in (0, seconds // 2, seconds):
            layer_checks[i] = layers_present()
        if i < seconds:
            time.sleep(max(0.0, samples[-1]["t"] + 1.0 - time.time()))
    return summarise(label, samples, layer_checks, pids, note)


def summarise(label, samples, layer_checks, pids, note):
    a, b = samples[0], samples[-1]
    wall = b["t"] - a["t"]
    res = {"label": label, "note": note, "seconds": round(wall, 2),
           "pids": pids, "layers": layer_checks,
           "n_samples": len(samples)}

    for name in pids:
        if pids[name] is None or name not in a or name not in b:
            continue
        pa, pb = a[name], b[name]
        rec = {}
        if pa["cpu_stat"] is not None and pb["cpu_stat"] is not None:
            rec["cpu_pct_stat"] = 100.0 * (pb["cpu_stat"] - pa["cpu_stat"]) / wall
            rec["cpu_sec"] = pb["cpu_stat"] - pa["cpu_stat"]
        if pa["sched_ns"] and pb["sched_ns"]:
            rec["cpu_pct_sched"] = 100.0 * (pb["sched_ns"] - pa["sched_ns"]) / 1e9 / wall
        rec["rss_start_mib"] = round(pa["rss_kb"] / 1024, 1) if pa["rss_kb"] else None
        rec["rss_end_mib"] = round(pb["rss_kb"] / 1024, 1) if pb["rss_kb"] else None
        rec["threads_start"] = pa["threads"]
        rec["threads_end"] = pb["threads"]
        if pa["ctxsw"] is not None and pb["ctxsw"] is not None:
            rec["ctxsw_per_s"] = (pb["ctxsw"] - pa["ctxsw"]) / wall
        # per-second CPU% series from stat
        series = []
        for i in range(1, len(samples)):
            x, y = samples[i - 1].get(name), samples[i].get(name)
            dt = samples[i]["t"] - samples[i - 1]["t"]
            if x and y and x["cpu_stat"] is not None and y["cpu_stat"] is not None:
                series.append(round(100.0 * (y["cpu_stat"] - x["cpu_stat"]) / dt, 1))
        rec["cpu_series"] = series
        res[name] = rec

    dt_tot = b["mach_total"] - a["mach_total"]
    dt_idle = b["mach_idle"] - a["mach_idle"]
    res["machine_cpu_pct"] = 100.0 * (1 - dt_idle / dt_tot) if dt_tot else None
    gpus = [s["gpu"] for s in samples if s["gpu"] is not None]
    if gpus:
        res["gpu_mean"] = sum(gpus) / len(gpus)
        res["gpu_max"] = max(gpus)
        res["gpu_series"] = gpus
    return res


def fmt(res):
    L = []
    L.append(f"--- {res['label']}  ({res['seconds']}s, {res['n_samples']} samples) {res['note']}")
    for name in ("shell", "sampler", "hypr"):
        r = res.get(name)
        if not r:
            continue
        L.append(
            f"  {name:8s} cpu {r.get('cpu_pct_stat', float('nan')):6.3f}% (stat) "
            f"{r.get('cpu_pct_sched', float('nan')):6.3f}% (sched)  "
            f"cpu_s {r.get('cpu_sec', 0):.3f}  "
            f"rss {r['rss_start_mib']} -> {r['rss_end_mib']} MiB  "
            f"thr {r['threads_start']}->{r['threads_end']}  "
            f"ctxsw/s {r.get('ctxsw_per_s', 0):.1f}")
    L.append(f"  machine  {res['machine_cpu_pct']:.2f}%   gpu {res.get('gpu_mean', 0):.2f} / {res.get('gpu_max', 0)}")
    L.append(f"  layers   {res['layers']}")
    sh = res.get("shell", {}).get("cpu_series")
    if sh:
        L.append("  shell CPU%/s: " + " ".join(f"{v:5.1f}" for v in sh))
    return "\n".join(L)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--label", default="X")
    ap.add_argument("--seconds", type=int, default=45)
    ap.add_argument("--note", default="")
    ap.add_argument("--json")
    ap.add_argument("--pre", help="shell command to run before the window")
    ap.add_argument("--post", help="shell command to run after the window")
    ap.add_argument("--settle", type=float, default=3.0)
    ap.add_argument("--shell-pid", type=int)
    ap.add_argument("--sampler-pid", type=int)
    ap.add_argument("--hypr-pid", type=int)
    ap.add_argument("--shell-pat", default=r"^quickshell .*-p /usr/share/omarchy/shell")
    ap.add_argument("--sampler-pat", default=r"omatop-sampler")
    ap.add_argument("--hypr-pat", default=r"^Hyprland")
    ap.add_argument("--list-pids", action="store_true")
    args = ap.parse_args()

    pids = {}
    for key, given, pat in (("shell", args.shell_pid, args.shell_pat),
                            ("sampler", args.sampler_pid, args.sampler_pat),
                            ("hypr", args.hypr_pid, args.hypr_pat)):
        if given:
            pids[key] = given
        else:
            pid, cmd = find_one(pat, key)
            pids[key] = pid
            if args.list_pids:
                print(f"{key:8s} {pid}  {cmd}")
    if args.list_pids:
        print("layers:", layers_present())
        return

    if args.pre:
        subprocess.run(args.pre, shell=True)
        time.sleep(args.settle)

    res = run(args.label, args.seconds, pids, args.note)

    if args.post:
        subprocess.run(args.post, shell=True)

    print(fmt(res))
    if args.json:
        with open(args.json, "w") as fh:
            json.dump(res, fh, indent=1)


if __name__ == "__main__":
    main()
