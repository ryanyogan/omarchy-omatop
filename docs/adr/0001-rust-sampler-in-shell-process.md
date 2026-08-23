# 1. A Rust sampler process feeds the shell, with a pure-QML bar fallback

Date: 2026-08-23
Status: Accepted

## Context

Omarchy plugins run inside the single long-lived Quickshell process that
also draws the bar. Walking ~500 PIDs plus cgroup, fdinfo and socket tables
every second in QML JavaScript would run on the UI thread and make the bar
stutter. History must be kept continuously (two minutes of every Vital and
App), so sampling has to run whether or not the overlay is open.

The plugin installer never runs plugin code, install hooks, or sudo, so a
compiled helper cannot be built at install time.

## Decision

Sampling lives in a small Rust binary shipped in the repo and built with
`cargo build --release` (Omarchy ships rustc and cargo). It runs as the
plugin's `service` kind, samples on a timer, keeps the History ring, and
streams one JSON document per tick to the shell over stdout. QML does one
JSON.parse per tick and renders.

The bar widget does not depend on the binary: it reads `/proc/stat`,
`/proc/meminfo` and hwmon directly for its own basic stats. If the binary
is missing, the overlay shows a build step and spawns cargo itself.

## Consequences

- The UI thread never touches /proc for the overlay. 60 fps is achievable.
- Per-App GPU (drm fdinfo) and Port (socket inode join) are feasible.
- Users on a machine without cargo get a working bar and a clear message,
  not a broken overlay.
- Two languages in one plugin; reviewers must read Rust to audit it.
