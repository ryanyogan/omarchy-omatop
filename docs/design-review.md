# Omatop design review

Adversarial review of `CONTEXT.md`, `docs/sampler-protocol.md` and
`docs/adr/0001-rust-sampler-in-shell-process.md` against the installed Omarchy
shell contract and against **this machine**.

Review host: Framework, AMD Ryzen AI 9 HX 370 / Radeon 890M (`amdgpu`),
kernel `7.1.8-arch1-3`, systemd 261, quickshell-git `0.3.0.r20.g28771c7-1`,
24 CPUs, 502 PIDs, 95 cgroups, Hyprland via uwsm + sddm.

All evidence below was captured read-only on that host. Nothing was killed,
stopped, frozen or restarted.

---

## Steel-man first

The parts of the design that are right, and worth defending before the attack:

- **The App/Process/Job split is the correct primary abstraction.** `top` and
  `btop` are useless on a modern desktop precisely because Chromium is forty
  rows. Grouping by launch scope is the only grouping the system actually
  maintains for you, and it is free to read.
- **A separate sampler process is the right call.** The measurements below
  confirm the cost: a naive full `/proc` walk with `fdinfo` is ~3 s of
  shell-loop time and ~1 s even for `stat`+`statm` only. Rust will be 50-100x
  faster, but the *shape* of the work — hundreds of syscalls, blocking reads on
  vanishing files — is exactly what must not run on the Quickshell UI thread.
  ADR-0001 is correct and the pure-QML bar fallback is a good hedge.
- **Newline-delimited JSON over stdout/stdin is the right IPC.** Quickshell's
  `Process` has `stdout: SplitParser` and `write()`; no socket, no D-Bus, no
  file polling. One `JSON.parse` per tick is cheap.
- **Keeping History whether or not the overlay is open** is the single feature
  that makes this a diagnostic tool instead of a dashboard. "Open it after the
  spike and see the spike" is the product.
- **Pressure as one derived state read by bar, dropdown and overlay** is good
  design discipline: three surfaces that cannot disagree.
- **`Recent` never re-sorting** is a genuinely thoughtful UX decision that most
  process monitors get wrong.
- **`readOnly: true` for the desktop bucket** is the right safety rail.
- **Actions via systemd units rather than raw signals**, where a unit exists, is
  the right instinct — see finding 12 for where it needs to go further.

Now the attack.

---

## Verdict summary

| # | Finding | Verdict |
|---|---|---|
| 1 | Job rule misses every `bash script.sh` and every compound job | **needs change** |
| 2 | Job rule's `parent comm is a shell` test is redundant *and* wrong | **needs change** |
| 3 | Job leader can die and leave the group orphaned | **needs change** |
| 4 | Job `name = leader comm` produces `MainThread`, `npm exec @playw` | **needs change** |
| 5 | `/proc/<pid>/stat` field-splitting is broken on this box today | **needs change** |
| 6 | Chromium is **two** scopes; the browser process is not in the one named `chromium` | **needs change** |
| 7 | Scope names come from `argv[0]` of the launcher, not the app (`xdg-terminal-exec`) | **needs change** |
| 8 | Real cgroups on this box that the bucket rules do not classify | **needs change** |
| 9 | Zombies form phantom Apps (`omarchy-browser-*.service`) | **needs change** |
| 10 | `drm-engine-gfx` works, but is present on only 4 of 502 processes | **holds, with caveats** |
| 11 | Per-App GPU is unreadable for any process not owned by the user | **needs change** |
| 12 | `systemctl --user stop` is right but blocks up to 90 s and has no undo | **needs change** |
| 13 | `systemctl kill -s STOP` is the wrong Pause; `freeze` is strictly better | **needs change** |
| 14 | Pressure: the temperature term makes this laptop permanently "critical" | **needs change** |
| 15 | Pressure: the swap term is inert on a zram box | **needs change** |
| 16 | Pressure: PSI divisors are miscalibrated; `psi.cpu` full is always 0 | **needs change** |
| 17 | Culprit by "highest cpu" ignores the per-cgroup PSI that is right there | **needs change** |
| 18 | Service lifecycle: the sampler is killed on every plugin file save | **needs change** |
| 19 | Services receive no settings; pins must be read off `shell.shellConfig` | **needs change** |
| 20 | `updateEntryInline` replaces the entry wholesale and can drop settings | **needs change** |
| 21 | `omarchy-refresh-shell` resets `shell.json`; pins evaporate | **holds, document it** |
| 22 | Control characters in `comm` can break the tick JSON | **needs change** |
| 23 | Unbounded `cmdline` reads; UTF-8 truncation will panic | **needs change** |
| 24 | `.desktop` parsing: `Name=` appears 3x in `chromium.desktop` | **needs change** |
| 25 | The overlay building and executing `cargo` output is the biggest security hole | **needs change** |
| 26 | Ports: containers and other netns are invisible; `/3000` will lie | **needs change** |
| 27 | Per-cgroup accounting is ~8x cheaper than the per-pid walk the design specifies | **opportunity** |
| 28 | VRAM on this APU reads 96% full at idle | **needs change** |
| 29 | Battery `power_now` is not system power draw | **needs change** |
| 30 | The QML fallback cannot `watchChanges` on `/proc` | **needs change** |

---

# 1. Job detection

## Finding 1 — The rule misses every job whose leader is a shell

The spec says:

> **Job** = a process group started from a shell: leader has `pid == pgid`,
> `tty != 0`, parent's comm is one of `bash zsh fish sh dash nu tmux: server`,
> **and its own comm is not a shell**.

That last clause deletes the most common long-running job on a developer
machine: a shell script.

### Evidence

Ran a controlled probe on a real pty (`script -qec "bash --norc -i ./probe2.sh"`)
launching: `sleep 30 &`, `bash -c 'sleep 30' &`, `bash ./script_job.sh &`,
`{ sleep 30 | cat ; } &`. Dump of every process with a tty in that session:

```
PID    PPID   PGID   ST COMM      PCOMM   CMDLINE                      TTY
52662  52661  52662  S  bash      script  bash --norc -i ./probe2.sh   34817   <- session leader
52663  52662  52663  S  sleep     bash    sleep 30                     34817   <- JOB, detected
52664  52662  52664  S  sleep     bash    sleep 30                     34817   <- JOB, detected
52665  52662  52665  S  bash      bash    bash ./script_job.sh         34817   <- MISSED
52666  52662  52666  S  bash      bash    bash --norc -i ./probe2.sh   34817   <- MISSED (pipeline subshell)
52669  52666  52666  S  sleep     bash    sleep 30                     34817   <- not a leader
52671  52666  52666  S  cat       bash    cat                          34817   <- not a leader
52672  52665  52665  S  sleep     bash    sleep 25                     34817   <- not a leader
52673  52662  52673  S  dump2.sh  bash    /bin/bash /tmp/.../dump2.sh  34817   <- JOB, detected
```

- **52665** is `bash ./script_job.sh` — `pid == pgid`, `tty != 0`, parent comm
  `bash`. Excluded solely because its own comm is `bash`. Its only child (52672)
  has `pgid 52665 != pid`, so it is not a leader either. **The whole job is
  invisible**; its CPU silently folds back into the terminal App.
- **52666** is the pipeline `{ sleep 30 | cat ; } &`. Same story: the subshell is
  the group leader, comm `bash`, both children are non-leaders. **Invisible.**
- Note the inconsistency: **52673** (`./dump2.sh`, run via shebang) *is*
  detected, because the kernel sets `comm` to the script basename for shebang
  execs. So `./deploy.sh` shows up and `bash deploy.sh` does not, for the same
  script. That is not a rule, that is a coin flip.

### Verdict

**Needs change.** The `own comm is not a shell` clause is the bug, not the fix.

### Recommendation

Replace the whole rule with POSIX job-control semantics, which is what a "job"
actually is:

```
Job leader  ⟺  pid == pgid  &&  tty != 0  &&  pid != sid
```

A job is a process group in a session that is **not** the session leader's group.
That is the definition the shell itself uses. Verify against the table above:

| pid | pid==pgid | tty | pid==sid | new rule | correct? |
|---|---|---|---|---|---|
| 7374 `bash` (login shell) | yes | pts/0 | **yes** | not a Job | ✓ stays in terminal App |
| 7348 `foot` | yes | **0** | yes | not a Job | ✓ |
| 7818 `claude` | yes | pts/0 | no (sid 7374) | **Job** | ✓ |
| 8409 `npm exec` (child) | no | pts/0 | no | member | ✓ |
| 52665 `bash script.sh` | yes | pts/1 | no | **Job** | ✓ **fixed** |
| 52666 pipeline subshell | yes | pts/1 | no | **Job** | ✓ **fixed** |
| 1336 `sh signal-handler.sh` | yes | tty1 | **yes** | not a Job | ✓ |

It also handles nvim's `:terminal` correctly for free: the embedded shell is a
session leader in its own pty (`pid == sid`) so it is not a Job, while commands
run inside it still are.

---

## Finding 2 — The `parent comm is a shell` test is redundant and wrong

Under the corrected rule of finding 1 the parent test is unnecessary. It is also
actively harmful as written.

### Evidence

- `tmux: server` is listed as a parent shell. But the tmux **server** is never
  the parent of a job — it is the parent of the *shell* that owns the job. Its
  presence in the list only creates the risk of promoting an interactive shell
  to a Job; that risk is currently masked by the `own comm is not a shell`
  clause, which finding 1 removes. Under any fix, this entry is a landmine.
- The list omits `elvish`, `xonsh`, `ksh`, `tcsh`, `csh`, `oil`/`osh`, `zsh`
  variants, and Nushell's actual comm. Every omission is a silently missed Job.
- `comm` is 15 bytes. `tmux: server` fits, but a hypothetical
  `some-long-shell` would truncate and never match.

### Verdict

**Needs change.**

### Recommendation

Delete the parent-comm test entirely. Keep a *separate*, purely cosmetic notion
of "which terminal App does this Job belong to": that is answered by the cgroup,
not by the parent's comm. The Job's cgroup is
`app-Hyprland-xdg\x2dterminal\x2dexec-558d9a36.scope` — the same scope as the
terminal — which is exactly the containment relation the design wants.

---

## Finding 3 — A job whose leader exits leaves an orphaned group

The spec defines `id = job:<leaderPid>:<started>` and finds members by
`pid == pgid`. When the group leader exits but the group survives, no process
satisfies `pid == pgid` and the job vanishes from the UI while still burning CPU.

### Evidence

This is the normal steady state for `make -j`, `cargo build`, and any
`exec`-less wrapper. In the probe, if 52666 (the pipeline subshell) exits while
`cat` (52671) is still reading, pgid 52666 still exists with a live member and
no leader.

`omarchy-launch-browser` produces the reverse case, also observed live:

```
$ cat /proc/3809/stat | awk '{print $3, $4, $5}'   # (uwsm-app)
Z 3808 3808
$ cat /proc/3810/stat | awk '{print $3, $4, $5}'   # (systemctl)
Z 3808 3808
```

Two zombies whose group leader (3808) is alive but in a different cgroup.

### Verdict

**Needs change.**

### Recommendation

Group by `(sid, pgid)` as the key, not by finding a leader. Then:

- `id = job:<sid>:<pgid>:<startedOfOldestMember>` — stable across leader exit.
- Pick the display process as: the leader if alive, else the **oldest** member.
- Drop groups whose every member is a zombie (`state == 'Z'`, see finding 9).

---

## Finding 4 — `name = leader comm` produces garbage on real processes

### Evidence

Live on this box right now:

```
PID    COMM               CMDLINE
8409   npm exec @playw    npm exec @playwright/mcp@latest
8999   MainThread         node .../node_modules/.bin/playwright-mcp
10045  MainThread         node .../node_modules/.bin/prisma mcp
8415   uv                 /home/ryan/.local/bin/uv tool uvx awslabs.aws-iac-mcp-server@latest
9630   python             .../bin/python .../bin/awslabs.aws-iac-mcp-server
```

`comm` is whatever the process last `prctl(PR_SET_NAME)`d — for Node that is a
**thread name** (`MainThread`), for npm it is a truncated 15-byte command
fragment. Three separate MCP servers all named `python`. A `bun run dev` job
would be named `bun`; four of them are named `bun`.

### Verdict

**Needs change.** Job identity is the thing the user searches by; `comm` is not
identity.

### Recommendation

Derive the Job name from `cmdline`, with `comm` only as a last resort:

1. Take `argv[0]`'s basename.
2. If it is a known interpreter/wrapper (`node`, `python`, `python3`, `bun`,
   `deno`, `ruby`, `perl`, `sh`, `bash`, `uv`, `uvx`, `npm`, `npx`, `pnpm`,
   `yarn`, `sudo`, `env`, `doas`), advance to the first argv token that is not a
   flag and take *its* basename, keeping the interpreter as a prefix:
   `npm run dev`, `python awslabs.aws-iac-mcp-server`.
3. Fall back to `comm` only when `cmdline` is empty (kernel threads, zombies).

Cap the displayed name at ~40 chars and keep the full string in `cmd`.

---

## Finding 5 — `/proc/<pid>/stat` field-splitting is broken on this box today

The spec says "per-pid utime+stime delta from `/proc/<pid>/stat` (fields 14,15)".
Naive whitespace splitting is wrong, and not theoretically — it is wrong right
now.

### Evidence

```
$ awk '{print $3}' /proc/*/stat | sort | uniq -c
      3 exec        <- should be a state char
    225 I
      1 phy0)       <- should be a state char
      3 R
    272 S
      3 Z
```

`comm` contains spaces (`npm exec @playw`, `mt7925 phy0`, `tmux: server`), so
field 3 is not the state. Worse, `comm` can contain `)`. Proven on this box with
an unprivileged `prctl(PR_SET_NAME)`:

```
$ od -c /proc/60496/comm
0000000   e   v   "   i   l  \a   ) 001       x  \n

$ head -c 60 /proc/60496/stat | od -c
0000000   6   0   4   9   6       (   e   v   "   i   l  \a   ) 001
0000020   x   )       S       1   2   7   2       6   0   4   9   6
```

Splitting on the *first* `)` yields state `\x01` and ppid `x`. Any process on the
machine can do this to any monitor that parses naively.

### Verdict

**Needs change.**

### Recommendation

Parse `/proc/<pid>/stat` by locating the **last** `") "` in the buffer:

```rust
let close = buf.rfind(") ").ok_or(Skip)?;
let comm  = &buf[buf.find(" (").ok_or(Skip)? + 2 .. close];
let rest  = &buf[close + 2 ..];          // fields 3..=52, whitespace-separated
```

Then `state = rest[0]`, `ppid = rest[1]`, `pgrp = rest[2]`, `session = rest[3]`,
`tty_nr = rest[4]`, `utime = rest[11]`, `stime = rest[12]`. Add this to the
protocol doc as a normative rule — it is the single most common bug in
/proc-reading code, and this machine reproduces it without any effort.

---

# 2. Apps and scopes

## Finding 6 — Chromium is two scopes, and the browser process is not in the one named `chromium`

The design's headline example — "Chromium is one App with forty Processes" — is
false under its own rule on this machine.

### Evidence

```
$ systemctl --user list-units --type=scope --all
app-1password-1658.scope                                  running app-1password-1658.scope
app-Hyprland-chromium-e1bdd203.scope                      running chromium
app-Hyprland-omarchy\x2dhyprland\x2dmonitor\x2dwatch-...  running omarchy-hyprland-monitor-watch
app-Hyprland-udiskie-1ce1af6d.scope                       running udiskie
app-Hyprland-xdg\x2dterminal\x2dexec-558d9a36.scope       running xdg-terminal-exec
app-org.chromium.Chromium-3808.scope                      running app-org.chromium.Chromium-3808.scope
```

Contents:

```
# app-org.chromium.Chromium-3808.scope   (2 procs)
3808  /usr/lib/chromium/chromium --ozone-platform=wayland ...      <- THE BROWSER
4325  /usr/lib/chromium/chromium --type=utility ...AudioService

# app-Hyprland-chromium-e1bdd203.scope   (18 procs)
3814  chrome_crashpad_handler
3827  chromium --type=zygote --no-zygote-sandbox
3828  chromium --type=zygote
3830  chromium --type=zygote
3863  chromium --type=gpu-process        <- the only Chromium proc with GPU counters
3864  chromium --type=utility ...NetworkService
3972  chromium --type=renderer  (x9 more renderers)
...
```

Chromium moved its own main process into a self-registered scope
(`app-org.chromium.Chromium-3808.scope`, `Slice=app.slice`) while all children
stayed in the uwsm scope (`Slice=app-graphical.slice`). Consequences under the
current rules:

- Two Apps appear. One is named `chromium` (from `Description=chromium`) and
  contains no browser process; the other has `Description=app-org.chromium.Chromium-3808.scope`
  and would display as that raw unit name.
- **`stop` on the `chromium`-named App kills 18 renderers and leaves the browser
  window alive.** The user asked to stop Chromium and got a browser with every
  tab crashed.
- The GPU number (finding 10) lands on the *other* App than the one named
  Chromium.

The same split affects 1Password:

```
app-1password-1658.scope             1658  /opt/1Password/1password --silent
app-1password@autostart.service      1879, 1882, 1986, 2311 (gpu), 2318 (network)
```

### Verdict

**Needs change.** "App = one cgroup" is a good default and a wrong invariant.

### Recommendation

Make App identity a two-step process: **cgroup for grouping, then a coalescing
pass.** Merge two scopes into one App when *any* of:

1. A process in scope A has its `ppid` in scope B (3827's ppid is 3808 — this
   alone catches Chromium and 1Password).
2. Both scopes' leaders share the same executable path (`/proc/<pid>/exe`
   readlink) and the same `HYPRLAND_INSTANCE_SIGNATURE` era.

Rule 1 is cheap (you already have the ppid map) and sufficient for both cases
observed here. Represent the merged App's `unit` as a **list**, and make `stop`
act on all of them, ordered so the parent scope goes last.

Also: when picking the display name, prefer the scope whose `Description` is not
equal to its own unit name.

---

## Finding 7 — Scope names come from the launcher's `argv[0]`, not the app

### Evidence

The terminal on this box:

```
$ cat /proc/7348/cgroup
0::/user.slice/.../app-graphical.slice/app-Hyprland-xdg\x2dterminal\x2dexec-558d9a36.scope
$ cat /proc/7348/comm
foot
$ systemctl --user show 'app-Hyprland-xdg\x2dterminal\x2dexec-558d9a36.scope' -p Description
Description=xdg-terminal-exec
```

Because `omarchy-launch-terminal` runs:

```bash
exec setsid uwsm-app -- xdg-terminal-exec --dir="$(omarchy-cmd-terminal-cwd)" "$@"
```

`uwsm-app` names the scope after the first token it is given. So the terminal App
is named `xdg-terminal-exec`, has no matching `.desktop` (there is
`foot.desktop`, `footclient.desktop`, `foot-server.desktop` — no
`xdg-terminal-exec.desktop`), therefore **no icon and no Tag**. Same class of
problem for anything launched through a wrapper script.

This also breaks Pinned. `CONTEXT.md` says pin identity is "the App's name, not
its PID". Every foot window gets its own scope hash but the *same* name
`xdg-terminal-exec` — so pinning one terminal pins all terminals, and pinning
"Chromium" is ambiguous between the two scopes in finding 6.

### Verdict

**Needs change.**

### Recommendation

Name resolution order, most-trusted first:

1. `.desktop` lookup by the scope's **Desktop ID** when the unit is
   `app-<DesktopID>@autostart.service` or `app-<DesktopID>-<pid>.scope`
   (systemd's documented `app-<launcher>-<DesktopID>-<random>.scope` form).
   `app-org.chromium.Chromium-3808.scope` → `org.chromium.Chromium.desktop`.
   This alone fixes Chromium's name and gives it the right icon and Category.
2. `.desktop` lookup by the **leader's executable basename**
   (`readlink /proc/<leader>/exe` → `foot` → `foot.desktop`).
3. Unit `Description`, but only if it differs from the unit name.
4. Leader `comm`.

For **Pinned identity**, do not use the display name. Use a stable key derived
in this order: Desktop ID → `basename(realpath(/proc/<leader>/exe))` → name.
That gives `foot` for every terminal and `chromium` for both Chromium scopes,
which is what the user means when they pin something.

---

## Finding 8 — Real cgroups on this box that the bucket rules do not classify

The spec's rules:

> `app.slice/**/*.scope` or `*.service` under `app.slice` → apps
> `session.slice/**` and `wayland-wm*` → desktop
> `*.service` elsewhere (user or system) → services
> pid 2 and its children → kernel
> Anything else under `system.slice` or `init.scope` → services

### Evidence — full cgroup census, 502 processes

Unclassified or misclassified by the rules as written:

| cgroup | procs | problem |
|---|---|---|
| `/` | 363 | kernel threads; matched only via the "pid 2 and children" rule |
| `/user.slice/user-1000.slice/session-1.scope` | 3 | not `app.slice`, not `session.slice`, not `system.slice`, not `init.scope`, not a `.service` — **falls through** (`sddm-helper`, uwsm `signal-handler.sh`, `systemctl --wait`) |
| `.../user@1000.service/background.slice/wayland-session-bindpid@1336.service` | 1 | `background.slice` is not mentioned anywhere |
| `.../user@1000.service/init.scope` | 2 | `systemd --user` itself; the rule says `init.scope` → services, but this is the *user* init.scope, and it is not under `system.slice` |
| `.../app.slice/app-dbus\x2d:1.22\x2dorg.a11y.atspi.Registry.slice/dbus-:1.22-org.a11y.atspi.Registry@0.service` | 1 | a nested **slice** under `app.slice` — matches "`*.service` under `app.slice`" and would land in `apps` as a user-facing App named `dbus-:1.22-org.a11y.atspi.Registry@0` |
| `/system.slice/docker-8cd099f8dc14e17164295a2455976f6f8e1bc5fcdbec5ed3f45a3de1ed79973f.scope` | 1 | a **container**, presented as a service with a 64-hex-char name |
| `.../app.slice/omarchy-sleep-lock.service`, `omarchy-crash-watch.service`, `voxtype.service`, `omarchy-fcitx5.service`, `bt-agent.service`, `dconf.service`, `gnome-keyring-daemon.service`, `xdg-desktop-portal-gtk.service` | 15 | `.service` under `app.slice` → bucket `apps`, so background plumbing appears in the same list as Chromium |

Also note `machine.slice` exists (currently inactive) and will hold
systemd-nspawn/podman containers.

### Verdict

**Needs change.**

### Recommendation

Rewrite the bucket rules as an ordered match on the **full** cgroup path, with a
mandatory fallthrough:

```
1. cgroup == "/"                                       -> kernel   (exact, cheap;
                                                          cgroup v2's "no internal
                                                          processes" rule guarantees
                                                          only kthreads live here —
                                                          drop the pid-2-ancestry walk)
2. .../session.slice/**                                -> desktop, readOnly
3. .../user@N.service/init.scope                       -> desktop, readOnly  (systemd --user)
4. /user.slice/user-N.slice/session-N.scope            -> desktop, readOnly  (login session)
5. .../app.slice/**/app-graphical.slice/**/*.scope     -> apps
6. .../app.slice/**/app-*.scope                        -> apps
7. .../app.slice/**/app-*.service                      -> apps
8. .../app.slice/**/*.service                          -> services  (user background units)
9. .../background.slice/**                             -> services
10. /system.slice/docker-*.scope
    /system.slice/**/libpod-*.scope
    /machine.slice/**                                  -> services, tag "Container"
11. /system.slice/**                                   -> services
12. anything else                                      -> services, name = last path segment
```

Rule 12 is the important one: the current spec has no fallthrough, so an
unmatched cgroup either disappears (processes unaccounted for, so the App CPU
sum will not equal the system CPU total) or panics. Never lose a process.

For containers (rule 10), resolve the display name: for
`docker-<64hex>.scope`, read the container name from
`/sys/fs/cgroup/system.slice/docker-<id>.scope/cgroup.procs` → the shim's
`/proc/<pid>/cmdline` carries `-id <id>`, or just truncate to `docker:<id[..12]>`.
Showing a 64-character hex string in the UI is not acceptable.

---

## Finding 9 — Zombies form phantom Apps

### Evidence

```
$ cat /proc/3809/comm; cat /proc/3809/stat | awk '{print "state="$3" ppid="$4}'
uwsm-app
state=Z ppid=3808
$ cat /proc/3810/comm
systemctl
state=Z ppid=3808
$ sed -n 's/^0:://p' /proc/3809/cgroup
/user.slice/.../app.slice/omarchy-browser-1787499744187347665.service
```

`omarchy-launch-browser` wraps `uwsm-app` in `systemd-run --unit=omarchy-browser-<ns>`.
The wrapper exits; two zombies remain reparented into that transient unit's
cgroup. The design would render an App named
`omarchy-browser-1787499744187347665` with `nproc: 2`, `cpu: 0`, `mem: 0`, and a
`stop` button that does nothing.

Note this unit name embeds a nanosecond timestamp, so a **new phantom App
appears every time the user opens a browser window**.

### Verdict

**Needs change.**

### Recommendation

- Skip processes with `state == 'Z'` for all accounting (their `statm` is zero
  and their `utime`/`stime` are already reaped into the parent).
- Drop any App whose every member is a zombie.
- Additionally suppress Apps whose cgroup has `cgroup.procs` non-empty but
  `pids.current == 0`… actually simpler: after zombie filtering, if `nproc == 0`,
  the App does not exist.

---

# 3. Per-App GPU via drm fdinfo

## Finding 10 — `drm-engine-gfx` works on amdgpu 7.x, with three caveats

### Evidence

Full scan of every fd of every PID on the box:

```
$ for p in /proc/[0-9]*; do for f in $p/fdinfo/*; do
    grep -q '^drm-engine-' "$f" && echo "$p $(basename $f) $(grep -E '^drm-(client-id|engine-)' $f | tr '\n' ' ')"
  done; done

pid=1492 comm=Hyprland   fd=31 client=7  drm-engine-gfx: 59230858585 ns  drm-engine-compute: 22662816 ns
pid=1492 comm=Hyprland   fd=32 client=7  drm-engine-gfx: 59234225493 ns  drm-engine-compute: 22662816 ns
pid=1492 comm=Hyprland   fd=33 client=7  drm-engine-gfx: 59237479340 ns  drm-engine-compute: 22662816 ns
pid=1575 comm=quickshell fd=36 client=17 drm-engine-gfx:   434334378 ns  drm-engine-compute:  7711817 ns
pid=1575 comm=quickshell fd=37 client=17 drm-engine-gfx:   434334378 ns  drm-engine-compute:  7711817 ns
pid=1575 comm=quickshell fd=38 client=17 drm-engine-gfx:   434334378 ns  drm-engine-compute:  7711817 ns
pid=1601 comm=Xwayland   fd=5  client=13 drm-engine-gfx:       56116 ns  drm-engine-compute:    51687 ns
   ... (fds 6,7,8 identical)
pid=3863 comm=chromium   fd=17 client=31 drm-engine-gfx:  4121150486 ns  drm-engine-compute: 251899222 ns
   ... (fds 18,19,20 identical)
```

**Caveat A — the counters exist but are rare.** Only **4 processes out of 502**
expose `drm-engine-*`. Processes that hold an amdgpu fd but expose *no* engine
counters include:

```
pid 3808 (chromium, THE BROWSER)   fd 27  drm-client-id: 28  -> memory lines only, no drm-engine-*
pid 2311 (1password --type=gpu-process) fd 15 drm-client-id: 24 -> memory lines only
pid 1492 (Hyprland)                fd 20  drm-client-id: 6   -> memory lines only
```

amdgpu only emits `drm-engine-*` once a client has created a scheduler entity
and submitted work. A GPU-heavy app that renders through a different path — or
one whose render fd is a second, idle client — reports nothing.

**Caveat B — dedupe by `drm-client-id` is mandatory and the spec is right about
it.** Hyprland holds one client (7) across three fds with identical values;
Xwayland holds client 13 across four. Summing per-fd triples/quadruples the
number.

**Caveat C — the spec's assumption about units is correct for amdgpu but not
portable.** amdgpu reports **nanoseconds**. There is no `drm-cycles-*` or
`drm-total-cycles-*` anywhere on this box — those are the Intel i915/Xe form
(`drm-cycles-<engine>` + `drm-total-cycles-<engine>`, a ratio not a duration).

### Verdict

**Holds** for the mechanism, **needs change** for the presentation and for the
formula's edge cases.

### Recommendation

Keep the design's formula but state it precisely and handle amdgpu's multi-ring
engines:

```
# per App, per tick:
for each pid in app:
  for each fd in /proc/pid/fdinfo/*:
    read only if first line region contains "drm-driver"
    cid = drm-client-id ; if seen(cid) continue ; seen.insert(cid)
    for each "drm-engine-<name>: <N> ns" line: engine_ns[name] += N

busy_pct = (engine_ns["gfx"] - prev_gfx_ns) / (interval_secs * 1e9) * 100
```

- **Use `gfx` only for the headline number.** `drm-engine-compute` on amdgpu is
  summed across up to 8 compute rings, so `compute` alone can legitimately
  exceed 100%. Report it as a separate series if at all.
- **Clamp to [0, 100]** and treat a negative delta as a client-id reuse: reset
  the baseline, emit `-1` for that tick rather than a spike.
- **Distinguish three states, not two.** The spec has `-1` for "unknown".
  That conflates:
  - no drm fd at all → `gpu: -1`, render as `—`
  - drm fd present but no `drm-engine-*` → `gpu: null`, render as `?` with a
    tooltip. This is Chromium's *browser* process and 1Password's GPU process.
    Showing `—` implies "no GPU use", which is a lie.
  - counters present → a number.
- **Add the memory lines while you are already reading the file.** amdgpu gives
  you `drm-total-vram` / `drm-resident-vram` / `drm-total-gtt` per client for
  free in the same read. Per-App VRAM is a better diagnostic than per-App GPU
  busy on an APU (see finding 28), and it is available for *every* client
  including 3808 and 2311.
- Also record the parsing detail: sizes come as `12 KiB` / `2 MiB` / bare `0` —
  three formats in one file. Parse the unit suffix; do not assume bytes.

---

## Finding 11 — Per-App GPU and Ports are unreadable for any process not owned by the user

### Evidence

```
$ ls /proc/1/fdinfo/
ls: cannot open directory '/proc/1/fdinfo/': Permission denied
```

`/proc/<pid>/fd` and `/proc/<pid>/fdinfo` require `PTRACE_MODE_READ` — i.e. same
uid, or CAP_SYS_PTRACE. Every process in `system.slice`, every root-owned
service, and any Job run under `sudo` returns `EACCES`.

This matters for the design's headline Port feature: `/3000 finds whatever is on
port 3000`. On this box:

```
$ ss -ltnp
LISTEN  0.0.0.0:17500     users:(("dropbox",pid=3292,fd=75))   <- readable (uid 1000)
LISTEN  127.0.0.53%lo:53                                        <- systemd-resolved, root: no pid shown
LISTEN  127.0.0.1:631                                           <- cups, root: no pid shown
LISTEN  172.17.0.1:53                                           <- docker, root
```

Three of four listeners on this machine are unattributable to the sampler.

### Verdict

**Needs change** — not the mechanism, the honesty of the output.

### Recommendation

- Record `EACCES` distinctly from "no match". Emit
  `"portsAvailable": false` on an App whose fd scan was denied, and render
  "requires root" rather than an empty ports list.
- `/proc/net/tcp` field 8 is the socket's **uid**. Use it: a listening socket
  with `uid != our uid` that no readable pid claims can still be shown in the
  search index as `port 631 — owned by uid 0 (not attributable)`. That is
  strictly better than the port not existing.
- Same treatment for Actions: `stop`/`pause` on a root-owned Job will fail with
  `EPERM`. Return that as `events: [{type:"action", ok:false, error:"EPERM: not your process"}]`,
  and grey the action in the UI when `uid != geteuid()`.
- Do **not** add a setuid helper or a polkit action for this. The plugin is
  unsandboxed third-party QML; escalating it is the wrong trade.

---

# 4. Stop, Pause, Resume

## Finding 12 — `systemctl --user stop <scope>` is the right verb, but it blocks and it has no undo

### Evidence

```
$ systemctl --user show app-Hyprland-chromium-e1bdd203.scope \
    -p ControlGroup -p CanStop -p CanFreeze -p CanStart -p KillMode \
    -p TimeoutStopUSec -p KillSignal -p FinalKillSignal -p FreezerState
ControlGroup=/user.slice/user-1000.slice/user@1000.service/app.slice/app-graphical.slice/app-Hyprland-chromium-e1bdd203.scope
CanStop=yes
CanFreeze=yes
CanStart=no
KillMode=control-group
TimeoutStopUSec=1min 30s
KillSignal=15
FinalKillSignal=9
FreezerState=running
```

Four things follow:

1. **`CanStop=yes`** — the mechanism works. `KillMode=control-group` means
   SIGTERM to every process in the cgroup, which is exactly the "SIGTERM every
   Process" semantic the protocol wants, done atomically by PID 1 with no
   fork-race.
2. **`TimeoutStopUSec=1min 30s`**, not 5 s. The protocol doc promises "SIGTERM
   every Process, SIGKILL survivors after 5 s". For units that promise is false —
   a hung Chromium gets 90 seconds before SIGKILL. Two different behaviours
   documented as one.
3. **`systemctl stop` blocks until the job completes.** If the sampler shells out
   synchronously it stalls its own tick loop for up to 90 s: the whole UI freezes
   because the user pressed Stop.
4. **`CanStart=no`.** A scope cannot be restarted. Stop is irreversible from the
   UI. The design already scopes Restart to Services, which is correct — but the
   *confirm* dialog should say so.

And per finding 6, stopping the scope named `chromium` does not stop Chromium.

### Verdict

**Needs change.**

### Recommendation

- Use **`systemctl --user stop --no-block <unit>`** and report completion from
  the next tick's cgroup observation (`cgroup.procs` empty / unit gone), not from
  the command's exit status. Set `state: "stopping"` immediately — the protocol
  already has that state, use it.
- For a multi-unit App (finding 6), stop children first, parent last.
- Align the timeouts: either set `TimeoutStopSec` on transient scopes you create
  (you do not create them, so you cannot), or **document that unit Stop honours
  the unit's own timeout** and change the protocol table from "SIGKILL survivors
  after 5 s" to "for units, systemd's `TimeoutStopSec` applies (90 s default for
  uwsm scopes)".
- For the **non-unit** path (Jobs), `kill(-pgid, SIGTERM)` then `SIGKILL` at 5 s
  is fine and matches shell semantics. Prefer signalling the *process group*
  (`kill(-pgid, ...)`) over iterating pids: it is atomic and cannot miss a
  process forked mid-iteration.
- Confirm dialog copy for Apps should say "Chromium cannot be restarted from
  here" when `CanStart=no`.

---

## Finding 13 — `systemctl kill -s STOP` is the wrong Pause; the cgroup freezer is strictly better

### Evidence

```
$ systemctl --user show app-Hyprland-chromium-e1bdd203.scope -p CanFreeze -p FreezerState
CanFreeze=yes
FreezerState=running

$ ls /sys/fs/cgroup/user.slice/.../app-Hyprland-chromium-e1bdd203.scope/ | grep -E 'freeze|kill'
cgroup.freeze
cgroup.kill
$ cat .../cgroup.freeze
0
```

Every user scope and service on this box reports `CanFreeze=yes`. systemd 261
implements `freeze`/`thaw` by writing `cgroup.freeze`.

SIGSTOP loses on five counts:

| | `systemctl kill -s STOP` | `systemctl --user freeze` |
|---|---|---|
| Atomicity | iterates the cgroup's pids; a process forked between enumeration and delivery escapes and keeps running | kernel freezes the cgroup, including processes forked during and after |
| Readback | must infer from `/proc/<pid>/stat` state `T` | `systemctl show -p FreezerState` → `frozen` / `freezing` / `running`; or read `cgroup.freeze` |
| Ambiguity | state `T` is also what **Ctrl-Z** sets. A user who backgrounded a job in their terminal would be shown as "Paused by omatop", and Resume would send SIGCONT to a job the shell thinks it owns, desynchronising the shell's job table | freezer state is unambiguous and orthogonal to job control |
| ptrace | state `t` (tracing stop) is a *third* state that looks like neither | unaffected |
| Recovery | if omatop or the shell dies, the app is SIGSTOPped forever with no UI to resume, and nothing records that it happened | `systemctl --user thaw <unit>`; and `systemctl --user list-units` shows it |

The one point in SIGSTOP's favour — that a frozen cgroup cannot be killed by
SIGTERM until thawed — is real: `systemctl stop` on a frozen unit will thaw it
first in systemd ≥ 246, so this is handled.

### Verdict

**Needs change.**

### Recommendation

- **Apps and Services (unit-backed): `systemctl --user freeze <unit>` /
  `systemctl --user thaw <unit>`.** Read state back from `FreezerState`, or
  cheaper, read `cgroup.freeze` (0/1) and `cgroup.events`'s `frozen` key during
  the tick you are already doing. That gives `state: "paused"` for free and
  correct across shell restarts.
- **Jobs (no unit): `kill(-pgid, SIGSTOP)` / `SIGCONT`.** There is no cgroup to
  freeze — a Job shares the terminal's cgroup, and freezing that would freeze the
  terminal. Signalling the process group is correct here and matches what
  Ctrl-Z does.
  - But **detect the ambiguity**: before showing a Job as `paused`, check
    whether omatop paused it. Keep an in-sampler set of pgids it stopped.
    A Job in state `T` that omatop did not stop should render as
    `stopped (Ctrl-Z)`, not `paused`, and Resume should be offered with that
    label.
- Update the protocol table accordingly:

  | Command | Effect |
  |---|---|
  | `stop <appId>` | unit: `systemctl [--user] stop --no-block <unit…>`. Job: `kill(-pgid, SIGTERM)`, `SIGKILL` at 5 s. |
  | `pause <appId>` | unit: `systemctl [--user] freeze <unit…>`. Job: `kill(-pgid, SIGSTOP)`. |
  | `resume <appId>` | unit: `systemctl [--user] thaw <unit…>`. Job: `kill(-pgid, SIGCONT)`. |

---

# 5. Pressure

Current formula:

```
score = max( psi.cpu/60,
             psi.memFull/10,
             psi.ioFull/40,
             (temp-70)/20,
             swapUsed/swapTotal*1.2 )
busy ≥ 0.35 ; critical ≥ 0.9
```

## Finding 14 — The temperature term makes this laptop permanently "critical"

### Evidence

```
$ cat /sys/class/hwmon/hwmon9/name /sys/class/hwmon/hwmon9/temp1_label /sys/class/hwmon/hwmon9/temp1_input
k10temp
Tctl
50000

$ grep -m1 "model name" /proc/cpuinfo
model name : AMD Ryzen AI 9 HX 370 w/ Radeon 890M
```

Only `Tctl` is exposed — no `Tdie`, no `Tccd*`. On Zen 4/5 mobile parts Tctl has
**no offset** (the +27 °C offset applies to Threadripper and older HEDT SKUs), so
50 °C is the real junction temperature. Good.

The problem is the threshold, not the sensor. This SoC's **design behaviour is to
boost until it hits ~95 °C and then hold there**. That is not a fault condition,
it is the power management working. Under the current formula:

- 78 °C (a `cargo build` for ten seconds) → `(78-70)/20 = 0.40` → **busy**
- 88 °C (normal sustained multicore load) → `0.90` → **critical**
- 95 °C (thermal target, entirely healthy) → `1.25` → **critical**, and it
  dominates `max()` so `reason` will say "temperature" while the actual story is
  "you're compiling".

The bar glyph would sit at Critical for the entire duration of every build. A
warning that is always on is not a warning.

### Verdict

**Needs change.** This is the most user-visible flaw in the design.

### Recommendation

Stop using absolute temperature as a pressure term. Temperature is a *state*,
not a *stall*. Two replacements, in order of preference:

**(a) Use thermal throttling, not temperature.** The signal you actually want is
"the machine is slower than it should be because it is hot", and the kernel
reports that directly:

```
/sys/devices/system/cpu/cpufreq/policy0/scaling_cur_freq   vs   cpuinfo_max_freq
```

Better on AMD: read `/sys/class/hwmon/hwmon9/temp1_crit` (Tctl critical) and
compute headroom, or watch `power1_average` against `power1_cap`. Simplest
robust version:

```
throttle = clamp((tempC - tempWarn) / (tempCrit - tempWarn), 0, 1)
where tempWarn = tempCrit - 15,  tempCrit = read from temp1_crit (fall back 100)
```

On this box `tempCrit` would come from sysfs rather than a hardcoded 70.

**(b) At minimum, make the term advisory.** Drop temperature out of `max()`
entirely and let it only *raise* an existing PSI-derived score:

```
score = psiScore * (1 + 0.25 * throttle)
```

So a hot-but-responsive machine reads Calm, and a hot-and-stalling machine reads
worse than a cool-and-stalling one. That matches what the user experiences.

Also: read the sensor by label, not by index. `hwmon9` is not stable across
boots. Enumerate `/sys/class/hwmon/*/name`, find `k10temp` (or `coretemp` on
Intel), then find the `tempN_label` equal to `Tdie`, falling back to `Tctl`,
falling back to `temp1_input`. This box has 18 hwmon devices; hardcoding an index
will read the wifi chip.

---

## Finding 15 — The swap term is inert on a zram box, and wrong in principle

### Evidence

```
$ cat /proc/swaps
Filename                  Type       Size       Used    Priority
/swap/swapfile            file       15628880   0       0
/dev/zram0                partition  15625212   62860   100

$ free -b | grep Swap
Swap:  32004190208  64368640  31939821568
```

Two swap devices. `zram0` has **priority 100** so it is used first; the disk
swapfile has priority 0 and is currently untouched.

`swapUsed/swapTotal * 1.2` right now = `64368640 / 32004190208 * 1.2` = **0.0024**.
To reach `busy` (0.35) this machine would need **9.3 GB** of swap in use; to
reach `critical`, 24 GB. By then it has been unusable for minutes.

Worse, the term is semantically wrong here: **zram is compressed RAM, not disk.**
Pages in zram cost ~1 µs to fault back. A machine with 8 GB in zram and no disk
swap touched is healthy. A machine with 200 MB on the *disk* swapfile is in
trouble. The formula cannot tell them apart because it sums them.

### Verdict

**Needs change.**

### Recommendation

Delete the swap-fraction term. It is trying to be a proxy for memory stall, and
PSI already *is* memory stall, measured directly.

If you want a swap signal at all, make it a **rate on backing-store swap only**:

```
# parse /proc/swaps; classify each device:
#   Type == "partition" && name starts /dev/zram  -> compressed RAM (ignore for pressure)
#   everything else                               -> backing store
diskSwapIn = delta(/proc/vmstat pswpin) * 4096 / interval   # bytes/s read back from swap
swapTerm   = min(diskSwapIn / (50 * 1024 * 1024), 1.0)      # 50 MB/s sustained = pinned
```

`pswpin` is the honest signal: pages coming *back* from disk means the working
set does not fit. Report zram usage separately as a Vital
(`vitals.mem.zramUsed` / `zramCompressedRatio` from
`/sys/block/zram0/mm_stat`) — it is genuinely interesting and it is not pressure.

---

## Finding 16 — PSI divisors are miscalibrated, and `psi.cpu` needs the right field

### Evidence

```
$ cat /proc/pressure/cpu
some avg10=0.00 avg60=0.00 avg300=0.00 total=3848791
full avg10=0.00 avg60=0.00 avg300=0.00 total=0
$ cat /proc/pressure/memory
some avg10=0.05 avg60=0.06 avg300=0.01 total=162205
full avg10=0.05 avg60=0.06 avg300=0.01 total=160725
$ cat /proc/pressure/io
some avg10=0.00 avg60=0.00 avg300=0.00 total=3540983
full avg10=0.00 avg60=0.00 avg300=0.00 total=3288325
```

Observations:

- **`cpu full` is structurally 0 at the system level** (`total=0`). "Full" means
  *every* runnable task stalled, which cannot happen for CPU at the root. The
  spec correctly uses `psi.cpu` (some) — but the protocol's tick schema lists
  `psi: { cpu, mem, io, memFull, ioFull }` with no `cpuFull`, which is right.
  Worth an explicit comment so nobody adds it later.
- **`psi.cpu / 60`** requires `cpu some avg10 = 21` for busy and **54** for
  critical. On a 24-thread box, `cpu some` of 21% means one-fifth of the time at
  least one task was queued — which is normal during any parallel build and the
  machine still feels fine. But 54% is genuinely thrashing. The divisor is not
  crazy; it is just very late.
- **`psi.ioFull / 40`** requires `io full avg10 = 14` for busy. `io full` at 14%
  means *everything on the machine* was blocked on I/O for 14% of the last ten
  seconds. That is already a visibly hung desktop. Far too lax.
- **`psi.memFull / 10`** → busy at 3.5, critical at 9. This one is roughly right.
- **avg10 semantics**: it is an exponentially-decayed 10-second average, updated
  by the kernel every 2 s. Sampling it at 1 Hz gives duplicate values half the
  time, and at 10 Hz gives ten copies of the same number. Fine, but the History
  ring should downsample by *max*, not by mean, or two-second spikes vanish.

### Verdict

**Needs change.**

### Recommendation

Recalibrate against what the user actually perceives. Suggested:

```
cpuTerm = psi.cpu.some.avg10   / 40     # busy at 14%, critical at 36%
memTerm = psi.mem.full.avg10   / 8      # busy at 2.8%, critical at 7.2%
ioTerm  = psi.io.full.avg10    / 12     # busy at 4.2%, critical at 11%
swapTerm = (see finding 15)
thermal  = (see finding 14, as a multiplier not a term)

score = max(cpuTerm, memTerm, ioTerm, swapTerm) * (1 + 0.25 * throttle)
```

Rationale for the ranking: memory-full and io-full stalls block *everything* and
are what "the machine is unusable" feels like, so they need the tightest
divisors. CPU stall is graceful degradation and deserves the loosest.

Additionally:

- **Add hysteresis.** avg10 is jittery; a bar glyph that flickers between Busy
  and Calm every second is worse than no glyph. Require the score to hold above
  a threshold for 3 consecutive ticks before escalating, and 5 before
  de-escalating. This is a UI-quality requirement, not a nicety.
- **Downsample History by max, not mean** (the spec currently says "downsample by
  averaging"). For a diagnostic tool whose selling point is "open it after the
  spike and see the spike", averaging is exactly the wrong operator for PSI, CPU
  and GPU series. Keep mean for memory and temperature, use max for the rest.

---

## Finding 17 — Culprit by "highest cpu" ignores the per-cgroup PSI sitting right there

### Evidence

Every App cgroup on this box carries its own PSI and accounting files:

```
$ ls /sys/fs/cgroup/user.slice/.../app-Hyprland-chromium-e1bdd203.scope/
cgroup.freeze  cgroup.kill  cgroup.procs  cgroup.stat
cpu.pressure   cpu.stat     cpu.stat.local
io.pressure    irq.pressure
memory.current memory.peak  memory.pressure  memory.stat  memory.swap.current
pids.current   pids.peak

$ cat .../cpu.stat
usage_usec 146794275
user_usec  125701939
system_usec 21092336

$ cat .../memory.current
809738240
$ cat .../io.pressure
some avg10=0.00 avg60=0.00 avg300=0.00 total=520509
full avg10=0.00 avg60=0.00 avg300=0.00 total=512358
```

The design defines Culprit as "App with highest `cpu`, or highest `mem` when the
mem term dominates". When Pressure is `critical` because of `io.full`, the
highest-CPU App is very often *not* the one doing the I/O — it is whatever is
spinning while waiting.

### Verdict

**Needs change.**

### Recommendation

Match the Culprit to the dominant term:

| dominant term | Culprit = App with max |
|---|---|
| cpuTerm | `cpu.stat` `usage_usec` delta |
| memTerm | `memory.current` (or `memory.stat` `anon`) |
| ioTerm | **`io.pressure` `full avg10`** of the App's own cgroup |
| swapTerm | `memory.swap.current` |

`io.pressure` per cgroup is the single most valuable number in this whole review
and the design does not use it. It answers "which app is making my disk
unusable" directly, which no other desktop monitor on Linux does.

Caveat to verify at build time: `io` is **not** in
`user@1000.service/cgroup.subtree_control` on this box —

```
$ cat /sys/fs/cgroup/user.slice/user-1000.slice/user@1000.service/cgroup.controllers
cpu memory pids
```

— yet `io.pressure` files still exist and are populated (PSI is always accounted
even without the io controller delegated). Confirm the values are non-zero under
real I/O load before shipping the feature; if they are always zero, fall back to
per-pid `/proc/<pid>/io` `read_bytes`/`write_bytes` deltas.

---

# 6. Plugin contract compliance

## Finding 18 — The sampler is killed on every plugin file save and every `rescanPlugins`

### Evidence

`shell.qml`:

```qml
function reloadPlugins() {
  ...
  shell.pluginReloading = true
  shell.unloadPanels()
  shell.unloadPluginServices()      // line 746
  shell.unloadPluginWidgets()
  Qt.callLater(shell.finishPluginReload)
}

function unloadPluginServices() {   // line 348
  for (var existingId in _services) {
    var inst = _services[existingId]
    if (inst && typeof inst.destroy === "function") inst.destroy()
  }
  _services = ({})
}
```

Triggers for `reloadPlugins()`:

```qml
function rescanPlugins(): void { shell.reloadPlugins() }          // line 890, IPC

Connections {
  target: shell.pluginRegistry
  function onLocalPluginChanged(pluginId) {
    console.log("Local plugin changed, reloading:", pluginId)
    localPluginReloadTimer.restart()                               // line ~755
  }
}
```

The shell README confirms: *"Saving a file anywhere under
`~/.config/omarchy/plugins/` reloads plugin code automatically."*

Quickshell's `Process` (`/usr/lib/qt6/qml/Quickshell/Io/quickshell-io.qmltypes`)
exposes `running`, `signal(int)`, `write(QString)`, `startDetached()` — and no
`killOnDestroy` opt-out. QProcess's destructor kills a still-running child.

So: **every `Ctrl-S` in the plugin directory, every `omarchy-shell shell
rescanPlugins`, and every `omarchy-restart-shell` kills the sampler and discards
the two-minute History ring.**

This directly contradicts `CONTEXT.md`:

> **History** — The last two minutes of every Vital and of every App's CPU,
> memory and GPU, kept whether or not the overlay is open. Opening the overlay
> after a spike shows the spike.

There is also a **double-sampler window**: `reloadPlugins()` destroys the service
and then `Qt.callLater(finishPluginReload)` → `rescan()` → `onScanFinished` →
`_syncServices()` creates a new one. The old QProcess teardown is asynchronous;
two samplers can briefly both be walking `/proc` at 1 Hz.

### Verdict

**Needs change.**

### Recommendation

1. **Persist the History ring.** On `Component.onDestruction` in the service QML,
   send the sampler a `snapshot <path>` command, or simpler: have the sampler
   write its ring to `$XDG_STATE_HOME/omatop/history.json` every 10 s and
   reload it at startup, discarding samples older than 120 s. This is ~15 KB and
   makes History survive reloads, shell restarts, and crashes. Cheap, and it
   turns a contract violation into a feature.
2. **Make startup idempotent and cheap.** The sampler must be safe to start
   twice; it holds no exclusive resource, so this is free — just do not create
   a pidfile or a socket.
3. **Guard against the double-sampler window** by having the QML service set
   `running: false` explicitly in `Component.onDestruction` before the object is
   torn down, so the SIGKILL happens promptly rather than at destructor time.
4. **Do not use `startDetached()`** to survive reloads. A detached sampler
   outlives the shell, accumulates one instance per reload, and there is no
   reaper. The persist-and-restart approach is correct.
5. **Two shells**: Hyprland autostart launches one shell per graphical session
   (shell README). A second graphical session gives two shells and two samplers.
   Because the sampler is stateless-on-disk except for the history file, add an
   `O_EXCL` lock or just include the shell's PID in the history filename to avoid
   two samplers clobbering one ring.

---

## Finding 19 — Services receive no settings; the design has no stated way to read pins

### Evidence

`shell.qml` `ensureService()` — the complete set of properties injected into a
`service`-kind plugin:

```qml
var inst = comp.createObject(serviceHost)
if ("omarchyPath"      in inst) inst.omarchyPath      = shell.omarchyPath
if ("shell"            in inst) inst.shell            = shell
if ("manifest"         in inst) inst.manifest         = manifest
if ("barWidgetRegistry" in inst) inst.barWidgetRegistry = shell.barWidgetRegistry
if ("pluginRegistry"   in inst) inst.pluginRegistry   = shell.pluginRegistry
```

Panels/overlays get the same five plus `service`:

```qml
if ("service" in item) item.service = shell.serviceFor(panelEntry.pluginId)
```

**Bar widgets** are the only kind that get settings, and they get them from
`Bar.qml`:

```qml
if ("moduleName" in target) target.moduleName = moduleName      // Bar.qml:1751
if ("settings"   in target) target.settings   = moduleSettings  // Bar.qml:1752
```

So neither the sampler service nor the overlay is handed its `shell.json` entry.

The established first-party workaround (and omaday's, in `BarWidget.qml`):

```qml
readonly property var service: bar && bar.shell ? bar.shell.serviceFor(root.moduleName) : null
onSettingsChanged: root.service.widgetSettings = root.settings
```

— the bar widget receives settings and pushes them into the service.

### Verdict

**Needs change** — the design does not say where pins live or how they are read.

### Recommendation

Document the pin path explicitly in `docs/sampler-protocol.md` or a new
`docs/plugin-wiring.md`:

- **Read**: the service and overlay both have `shell`, and
  `shell.shellConfig` is a plain `property var` (shell.qml:56) holding the
  parsed `shell.json`. Read pins with a helper that scans
  `shellConfig.bar.layout.{left,center,right}` then `shellConfig.plugins[]` for
  `id === "ryanyogan.omatop"`. Do **not** rely on the bar widget being present —
  the user may add the overlay without the widget.
- **Watch**: `userConfigFile` has `watchChanges: true` and reassigns
  `shellConfig` on change, so a binding on `shell.shellConfig` updates
  reactively. Use a binding, not a one-shot read at `Component.onCompleted`.
- Mirror omaday's `service.widgetSettings` pattern so the bar widget stays the
  fast path when it exists.

---

## Finding 20 — `updateEntryInline` replaces the entry wholesale

### Evidence

`shell.qml:366`:

```qml
function updateEntryInline(moduleName, settings) {
  ...
  var next = { id: stripped }
  for (var k in settings) if (k !== "id") next[k] = settings[k]
  if (JSON.stringify(arr[i]) !== JSON.stringify(next)) { arr[i] = next; dirty = true }
  ...
}
```

`next` is built from scratch. Any key present on the existing entry but absent
from `settings` is **deleted**. Callers must pass the full merged object.
First-party callers do exactly that:

```
plugins/panels/power/Panel.qml:174   root.bar.shell.updateEntryInline(root.moduleName, root.settings)
plugins/bar/widgets/Tray.qml:186     ...updateEntryInline(id, { id: id, pinned: pinned, hidden: hidden })
plugins/panels/clock/BarWidget.qml:51
plugins/panels/tailscale/Panel.qml:159
```

Two further constraints:

- It only writes to an entry that **already exists** in `bar.layout.*` or
  `plugins[]`. If the plugin's id is not there, `updateEntryInline` silently
  returns `false` and nothing persists.
- If both the bar widget and the overlay call it with their own partial view of
  settings, whichever writes last wins and drops the other's keys.

### Verdict

**Needs change** — the design must name a single writer.

### Recommendation

- Designate **one owner** of persisted settings: the **service** (it is the
  singleton, it always exists when the plugin is enabled, and it already holds
  the sampler state). Bar widget and overlay call
  `service.setPins(newArray)`; the service merges into the full settings object
  it read per finding 19 and calls `shell.updateEntryInline(id, merged)` once.
- Always pass the **complete** settings object, never a delta.
- Handle the `return false` case: if the entry does not exist, pins cannot be
  saved. Surface that once, quietly, rather than silently discarding pins.
- Note `Util.canonicalWidgetId()` is applied to the id — use the exact manifest
  id (`ryanyogan.omatop`) and let the shell canonicalise.

---

## Finding 21 — `omarchy-refresh-shell` resets `shell.json`

### Evidence

```
$ head -8 /usr/share/omarchy/bin/omarchy-refresh-shell
# omarchy:summary=Reset shell.json to Omarchy defaults
omarchy-refresh-config omarchy/shell.json
```

Pins persisted into `shell.json` are destroyed by a command whose name sounds
harmless. (`omarchy-restart-shell` is the safe one.)

### Verdict

**Holds** — this is the contract, and pins genuinely are user config. But the
design should not be surprised by it.

### Recommendation

Accept it, and say so in the README: pins live in `shell.json` and are reset by
`omarchy-refresh-shell`, like every other shell customisation. Do **not** invent
a side-car settings file to dodge this — storage rule 3 in the shell README
explicitly forbids it ("No `config:` sub-object, no separate per-plugin settings
file, no merge layers").

Corollary: the ephemeral History ring (finding 18) belongs in
`$XDG_STATE_HOME`, not in `shell.json`. Keep that distinction sharp.

---

## Finding 21b — Manifest and IPC details that are already correct

Verified, no change needed:

- `entryPoints.barWidget` (not `bar-widget`) — confirmed against the shell README
  example and omaday's shipping manifest. `docs/references.md` already flags this.
- `kinds: ["bar-widget", "overlay", "service"]` is a supported combination —
  omaday ships exactly that, and `omarchy.media` does too.
- `keepLoaded: true` keeps the overlay's layer-shell window mounted between
  summons (README, and image-picker uses it). Worth setting for omatop so summon
  is instant, at the cost of holding the window's memory.
- Summoning: `shell.toggle(id, "{}")` from the bar widget, matching
  `BarWidget.qml:43` in omaday.

---

# 7. Security

## Finding 22 — Control characters in `comm` can break the tick JSON

### Evidence

An unprivileged process set its own name to contain `"`, `BEL` (0x07), `)`, and
`SOH` (0x01):

```
$ od -c /proc/60496/comm
0000000   e   v   "   i   l  \a   ) 001       x  \n
```

Every one of those bytes reaches the sampler through `comm`, and `cmdline` is
even less constrained (any byte except NUL, unbounded length).

Consequences:

- **Hand-rolled JSON emits invalid JSON.** Raw bytes < 0x20 are illegal inside
  a JSON string (RFC 8259 §7). `JSON.parse` in QML throws, the entire tick is
  dropped, and the overlay freezes at the last good frame **with no error
  shown**. Any user on the machine — or any program the user runs — can do this
  deliberately or by accident.
- Even with correct escaping, the bytes reach QML.

### Verdict

**Needs change.**

### Recommendation

- **Serialize with `serde_json`, never with `format!`.** It escapes `"`, `\`,
  and emits `\u00XX` for C0 controls correctly. Add a test that round-trips a
  string containing `"`, `\`, `\n`, ``, ``, and a lone surrogate-ish
  byte sequence.
- **Sanitize at the source anyway**, because escaping is not the only concern:
  strip or replace C0 control characters (`0x00`–`0x1F`, `0x7F`) with `U+FFFD`
  in `name`, `cmd`, `comm`, and `tty` before serialization. The user has no use
  for a BEL in a process name and QML's text shaping does odd things with them.
- **Handle invalid UTF-8.** `/proc` gives bytes, not `str`. Use
  `String::from_utf8_lossy`, never `from_utf8().unwrap()`.
- **On the QML side, render every sampler-supplied string with
  `textFormat: Text.PlainText`.** This is not theoretical: the shell already
  uses `Text.StyledText` in `plugins/notifications/components/NotificationCard.qml:177`,
  so the pattern is in the codebase and easy to copy by accident. With
  `StyledText` or `RichText`, a process named
  `<img src="http://attacker/?c=1">` causes Qt to issue a network request from
  inside `omarchy-shell`. Set `textFormat` explicitly on every `Text` that shows
  a name, cmdline, unit, or tag.
- **Never build a shell command from sampler output.** The shell's
  `Util.execDetached(cmd)` runs `bash -lc cmd`. If omatop ever shells out for an
  action, use `Process { command: ["systemctl", "--user", "stop", unit] }` —
  an argv array, no shell — or `Util.shellQuote()` (Commons/Util.qml:49), which
  is correct single-quote wrapping.

---

## Finding 23 — Unbounded `cmdline` reads and a UTF-8 truncation panic

### Evidence

Longest cmdline currently on the box: **945 bytes** (a Claude Code
`bash -c source .../snapshot-bash-....sh ...`). `/proc/<pid>/cmdline` is capped
only by `ARG_MAX` (2 MB on Linux), and a process can legitimately have a
multi-hundred-KB command line (bulk `rm`, `find -exec`, some build tools).

The spec says `cmd` is "leader cmdline, truncated to 200 chars".

Two hazards:

1. At 10 Hz across 500 PIDs, reading full cmdlines is up to 500 × 2 MB × 10/s of
   `read()` traffic in the worst case.
2. `&cmdline[..200]` **panics** if byte 200 lands inside a multi-byte UTF-8
   sequence. A process with a CJK or emoji argument at exactly the wrong offset
   kills the sampler.

### Verdict

**Needs change.**

### Recommendation

- Read `cmdline` with a **bounded read** — `File::open` + `.take(4096).read_to_end()`.
  You need at most 200 displayed chars; 4 KiB is generous headroom for the
  argv[0]-skipping logic in finding 4.
- **Cache it.** `cmdline` is immutable for the life of a process in practice
  (only `setproctitle` changes it, and only for a handful of daemons). Read it
  **once per PID** on first sight, keyed by `(pid, starttime)`, and never again.
  This removes it from the hot loop entirely.
- Truncate on a **char boundary**:
  ```rust
  fn truncate_chars(s: &str, n: usize) -> &str {
      match s.char_indices().nth(n) { Some((i, _)) => &s[..i], None => s }
  }
  ```
- Same treatment for `/proc/<pid>/stat` (bounded, but read once per tick) and
  `comm` (16 bytes, cache with cmdline).

---

## Finding 24 — `.desktop` parsing: three `Name=` lines in `chromium.desktop`

### Evidence

```
$ grep -E '^(Name|Icon|Categories|StartupWMClass)=' /usr/share/applications/chromium.desktop
Name=Chromium
StartupWMClass=@@startup_wm_class
Icon=chromium
Categories=Network;WebBrowser;
Name=New Window
Name=New Incognito Window
```

The last two come from `[Desktop Action new-window]` / `[Desktop Action new-private-window]`
groups. A naive "last match wins" scan names Chromium **"New Incognito Window"**.

Note also `StartupWMClass=@@startup_wm_class` — an unsubstituted build template,
i.e. `.desktop` files in the wild contain garbage.

And `~/.local/share/applications/` is **user-writable** and contains 20+ files on
this box (`ChatGPT.desktop`, `Basecamp.desktop`, `Age of Empires II Definitive Edition.desktop`,
…), several written by omarchy's webapp installer. `Name=` there is arbitrary
attacker-influenced text if the user ever installs a webapp from a URL.

### Verdict

**Needs change.**

### Recommendation

- Parse only the `[Desktop Entry]` group. Stop at the first `[` that is not
  `[Desktop Entry]`.
- Honour `Name[<locale>]` by matching `$LC_MESSAGES`/`$LANG`, falling back to
  bare `Name`.
- Respect `NoDisplay=true` and `Hidden=true` (do not use those entries at all).
- Apply the same sanitization as finding 22 to `Name`, `Icon`, and `Categories`
  — these are file contents, not trusted metadata.
- Cap `Icon` to a plausible icon-name charset (`[A-Za-z0-9._+-]`) or an absolute
  path that exists; an `Icon=` value flows into a QML `Image.source` and
  `../../../` traversal or a `http://` URL should not be honoured.
- Cache the `.desktop` index; do not re-parse `/usr/share/applications` (hundreds
  of files) per tick. Watch the two directories and rebuild on change.

---

## Finding 25 — The overlay building and then executing `cargo` output is the largest security hole in the design

ADR-0001:

> If the binary is missing, the overlay shows a build step and **spawns cargo
> itself**.

The shell README is explicit that this is the boundary the installer deliberately
does not cross:

> The installer never runs plugin code, install hooks, or sudo — it only clones
> files, validates the manifest, and toggles enabled state over shell IPC.

The design routes around that guarantee: `omarchy plugin add` stays safe, and
then the first summon of the overlay compiles arbitrary Rust from the plugin
checkout and executes the result — inside the process that draws the bar, holds
the polkit agent, and owns the lock screen.

Compounding factors:

- `omarchy plugin update` fast-forwards the git checkout. A user who reviewed
  the Rust at install time does not re-review it on update, and the shell
  hot-reloads on file change, so a `git pull` can swap the source under a
  running shell.
- `cargo build` runs `build.rs` and proc macros from the dependency tree —
  arbitrary code execution at build time, from whatever `Cargo.lock` resolves to.
- The build output path is inside a user-writable directory.

### Verdict

**Needs change.** The mechanism is defensible; the framing is not.

### Recommendation

1. **Never auto-build.** Show the build step as a **command the user runs in a
   terminal**, with the path printed:
   `cd ~/.config/omarchy/plugins/ryanyogan.omatop/sampler && cargo build --release`.
   One extra step, and the user explicitly consents to compiling and running
   native code. This is the same posture as `omarchy plugin add`'s warning.
2. **Commit `Cargo.lock`** and keep the dependency tree tiny — ideally zero
   non-`std` dependencies except `serde`/`serde_json`, and consider hand-rolling
   the serializer's escaping to reach literally zero. Every crate is a build-time
   RCE vector the reviewer must audit.
3. **Verify before exec.** Resolve the binary path, and refuse to run it if the
   path is a symlink, is group/other-writable, or lives outside the plugin dir.
4. **Spawn with an argv array and a clean environment**
   (`Process { command: [binPath] }`), never through `bash -lc`.
5. **Say it in the README.** "This plugin compiles and runs a native binary
   inside `omarchy-shell`" belongs above the fold, next to the build
   instructions. The ADR's "reviewers must read Rust to audit it" consequence is
   honest — put it where users see it, not only where reviewers do.
6. **Validate stdin commands in the sampler.** It accepts commands on stdin; if
   the shell is ever compromised the sampler is a signal-sending oracle. Parse
   with a strict grammar (`^(rate|detail|stop|pause|resume|restart|fds) [A-Za-z0-9:_.\\@-]{0,256}$`),
   reject anything else, and cap line length. Never pass an id through to a shell.
   The `appId` for units embeds a systemd unit name, which systemd escapes
   (`app-Hyprland-xdg\x2dterminal\x2dexec-558d9a36.scope`), so it is already
   constrained — but validate rather than assume.

---

## Finding 26 — Ports: containers and other network namespaces are invisible

### Evidence

```
$ readlink /proc/self/ns/net
net:[4026531833]
$ ls /sys/fs/cgroup/system.slice/ | grep docker
docker-8cd099f8dc14e17164295a2455976f6f8e1bc5fcdbec5ed3f45a3de1ed79973f.scope
docker.service
$ wc -l /proc/net/tcp /proc/net/tcp6
49 /proc/net/tcp
 2 /proc/net/tcp6
```

`/proc/net/tcp` is **per-netns** — it shows the reader's namespace only. A
container listening on `:3000` internally is not in it. A published port
(`docker run -p 3000:3000`) appears, but attributed to `docker-proxy` under
`system.slice` (root-owned, so unreadable `fd/` per finding 11), not to the
`docker compose up` Job the user is looking at.

The design's promise is specific: *"`/3000` finds whatever is on port 3000"*.

Also note `/proc/net/tcp` only covers IPv4; `tcp6` is a separate file with a
different address column width, and a dual-stack listener on `::` appears only in
`tcp6`. And Unix sockets — the actual IPC mechanism for most dev servers'
sidecars — are in `/proc/net/unix` and out of scope entirely.

### Verdict

**Needs change** — the feature is good, the promise is too broad.

### Recommendation

- Read **both** `/proc/net/tcp` and `/proc/net/tcp6`, state `0A`, and dedupe by
  port. Parse the address column by length, not by a fixed offset.
- For unattributable ports, still index them (finding 11) with an owner of
  `uid N` so search finds them.
- **Attribute published container ports.** For each `docker-<id>.scope`, the
  container's netns is reachable at `/proc/<pid-in-scope>/net/tcp` — readable if
  the container runs as your uid, otherwise not. Simpler and always available:
  for a Job whose leader cmdline starts with `docker`/`podman`/`docker-compose`,
  parse `-p HOST:CONT` / `--publish` out of the cmdline and attach those host
  ports to the Job as `ports` with a `"published"` marker. Crude, but it makes
  `/3000` find the compose job, which is the actual user intent.
- Narrow the CONTEXT.md wording from "whatever is on port 3000" to "the App or
  Job listening on port 3000, when it is one of yours".

---

# 8. Additional findings

## Finding 27 — Per-cgroup accounting is ~8x cheaper than the per-pid walk

### Evidence

```
$ find /sys/fs/cgroup -maxdepth 6 -name cgroup.procs | wc -l
95
$ ls /proc | grep -cE '^[0-9]+$'
502

# read cpu.stat for every cgroup:
real  0m0.127s

# read stat + statm for every pid:
real  0m0.998s

# read every fdinfo of every pid (the `fds on` path):
real  0m3.065s
```

The spec computes App CPU as a sum of per-pid `utime+stime` deltas and App
memory as a sum of `statm` RSS. Both numbers already exist per-cgroup:
`cpu.stat`'s `usage_usec` and `memory.current`.

### Verdict

**Opportunity**, not a defect — but it changes the architecture enough to decide
now rather than later.

### Recommendation

Two-tier sampling:

- **Every tick**: walk the 95 cgroups. `cpu.stat` → App CPU, `memory.current` →
  App memory, `pids.current` → `nproc`, `*.pressure` → Culprit input. This is
  the entire App list and it costs ~1/8 of the per-pid walk. It is also *more
  accurate*: `usage_usec` counts processes that were born and died between
  ticks, which the per-pid diff structurally cannot.
- **Only for the `detail` App** (and for Job detection, which needs `sid`/`pgid`):
  walk `/proc/<pid>` for the pids in that one cgroup.
- **fdinfo scan** (`fds on`): keep it, but run it at a **lower rate** than the
  base tick — 1-in-5 ticks is plenty for Ports, and GPU deltas over 5 s are
  fine. 3 s of shell-loop time per full scan is the single most expensive thing
  in the design; in Rust it will be perhaps 30-60 ms, which is still 3-6% of one
  core at 1 Hz and blows the ADR's "< 1% of one core at 500 pids" budget on its
  own. Also skip `fdinfo` entirely for any pid whose `/proc/<pid>/fd` you
  already know is unreadable.

Caveat: `memory.current` includes page cache (`memory.stat` on the Chromium scope
shows `anon 371171328` vs `file 409833472` of a `memory.current` of 809738240).
Sum of RSS and `memory.current` are different quantities. Pick one, label it, and
be consistent — `anon + kernel` from `memory.stat` is the closest analogue to
"what this app costs you" and is a single read.

---

## Finding 28 — VRAM reads 96% full at idle on this APU

### Evidence

```
$ cat /sys/class/drm/card1/device/mem_info_vram_used
514387968
$ cat /sys/class/drm/card1/device/mem_info_vram_total
536870912
$ cat /sys/class/drm/card1/device/gpu_busy_percent
8
```

**95.8% VRAM used with the GPU at 8% busy.** The Radeon 890M is an APU: 512 MiB
is the BIOS carve-out, and the driver keeps it full because there is no cost to
doing so — real capacity is system RAM via GTT. A VRAM bar pinned at 96% is a
permanent false alarm, exactly like the temperature term in finding 14.

### Verdict

**Needs change.**

### Recommendation

- Detect the APU case: if `mem_info_vram_total` is small (≤ 2 GiB) **and**
  `/sys/class/drm/card1/device/mem_info_gtt_total` is large, treat the GPU as
  integrated.
- For integrated GPUs, either hide the VRAM Vital entirely or report
  `vram = mem_info_vram_used + mem_info_gtt_used` against
  `vram_total + gtt_total`, labelled "GPU memory" not "VRAM".
- Keep `gpu_busy_percent` (`8` here) as the GPU busy Vital — it is the correct
  system-wide number and much cheaper than summing fdinfo.

---

## Finding 29 — Battery `power_now` is not system power draw

### Evidence

```
$ cat /sys/class/power_supply/BAT1/status         # Discharging
$ cat /sys/class/power_supply/BAT1/power_now      # 570000   (= 0.57 W)
$ cat /sys/class/power_supply/ACAD/online         # 0
$ cat /sys/class/hwmon/hwmon8/power1_average /sys/class/hwmon/hwmon8/power1_label
4083000                                            # 4.08 W
PPT
$ cat /sys/class/powercap/intel-rapl:0/name
package-0
```

0.57 W while discharging, with Chromium and fifteen MCP servers running, is not
credible — and the iGPU alone reports 4.08 W. `power_now` on this platform is
unreliable and, on AC, is ~0 by definition.

Meanwhile `intel-rapl` is present (the powercap interface is used by AMD too):
`intel-rapl:0` / `package-0` gives CPU package energy in `energy_uj`.

### Verdict

**Needs change.**

### Recommendation

Compose `vitals.power.watts` from the best available source, in order:

1. `delta(/sys/class/powercap/intel-rapl:0/energy_uj) / interval / 1e6` (CPU
   package) **+** `/sys/class/hwmon/<amdgpu>/power1_average / 1e6` (GPU PPT).
   This is the "how hard is the SoC working" number and it is meaningful on AC.
2. `BAT*/power_now`, or `current_now × voltage_now` when `power_now` is absent,
   only while `status == Discharging`.
3. `available: false`.

Note `energy_uj` wraps at `max_energy_range_uj` — handle the wrap. And on some
kernels `energy_uj` is root-only (CVE-2020-8694 mitigation); check readability at
startup and fall back rather than emitting zeros.

Also: `fan1_input` reads `0` on `hwmon1` (`acpi_fan`) — the fan is genuinely off.
`available: true, rpm: 0` is correct here; just make sure "0 rpm" does not render
as "sensor missing".

---

## Finding 30 — The QML fallback cannot `watchChanges` on `/proc`

ADR-0001 says the bar widget reads `/proc/stat`, `/proc/meminfo` and hwmon
directly so it works without the binary.

### Evidence

```
$ stat -c '%n size=%s' /proc/stat /proc/meminfo /proc/pressure/cpu /sys/class/hwmon/hwmon9/temp1_input
/proc/stat size=0
/proc/meminfo size=0
/proc/pressure/cpu size=0
/sys/class/hwmon/hwmon9/temp1_input size=4096
```

`/proc` files report size 0 and are not backed by an inode that
`QFileSystemWatcher` can watch. Quickshell's `FileView { watchChanges: true }`
will never fire on them.

### Verdict

**Needs change** — a small one, but it will silently produce a frozen bar widget.

### Recommendation

In the fallback widget use an explicit `Timer` (2-5 s is plenty for a bar) that
calls `fileView.reload()`, and never `watchChanges` on anything under `/proc` or
`/sys`. Keep the fallback to `/proc/stat` (aggregate CPU) and `/proc/meminfo`
only — do not attempt hwmon enumeration in QML, since finding 14 shows the index
is not stable and the enumeration is 18 directories deep in string handling on
the UI thread.

---

# Consolidated change list

Ordered by cost of getting it wrong.

**Correctness — must fix before any implementation:**

1. Job rule → `pid == pgid && tty != 0 && pid != sid`; group by `(sid, pgid)` (findings 1-3)
2. `/proc/<pid>/stat` parse via last `") "` (finding 5)
3. App coalescing across scopes by ppid (finding 6)
4. Zombie filtering (finding 9)
5. Bucket rules with an explicit fallthrough (finding 8)
6. `serde_json` + control-char sanitization + `from_utf8_lossy` (finding 22)
7. Bounded, cached, char-boundary-truncated `cmdline` (finding 23)

**User-visible behaviour:**

8. Pressure: temperature as throttle multiplier, not a `max()` term (finding 14)
9. Pressure: delete the swap-fraction term, use `pswpin` (finding 15)
10. Pressure: recalibrate divisors, add hysteresis, downsample by max (finding 16)
11. Culprit by dominant term, using per-cgroup `io.pressure` (finding 17)
12. Pause via `systemctl freeze`, not SIGSTOP (finding 13)
13. Stop via `--no-block` + `state: "stopping"` (finding 12)
14. Name resolution: Desktop ID → exe basename → Description → comm (findings 4, 7)
15. Pin identity by stable key, not display name (finding 7)
16. VRAM handling on APUs (finding 28)
17. Power from RAPL + amdgpu PPT (finding 29)

**Contract:**

18. Persist the History ring to `$XDG_STATE_HOME` (finding 18)
19. Read settings from `shell.shellConfig`; single writer via the service (findings 19, 20)
20. `Text.PlainText` on every sampler-supplied string (finding 22)
21. Timer-driven reload in the QML fallback (finding 30)

**Security posture:**

22. Never auto-build; print the `cargo build` command (finding 25)
23. Commit `Cargo.lock`, minimise dependencies, argv-array spawn (finding 25)
24. Strict stdin grammar in the sampler (finding 25)
25. `.desktop` `[Desktop Entry]`-only parsing with icon validation (finding 24)

**Honesty of the spec:**

26. Ports: narrow the promise; handle `tcp6`, EACCES, containers (findings 11, 26)
27. GPU: three states (`-1` / `null` / number), gfx only, clamped (finding 10)
28. Two-tier sampling; fdinfo at reduced rate; revisit the < 1% CPU budget (finding 27)

---

# Appendix — implementation status at review time

`sampler/` and the QML appeared in the working tree while this review was in
progress (`git log` shows only `CONTEXT.md` and the ADR committed). Spot-checks
against the live code, so the findings can be triaged rather than re-derived:

**Already correct — no action:**

| Finding | Evidence in code |
|---|---|
| 5 (stat parsing) | `src/proc.rs:193` `let close = s.rfind(')')?;` then `s[close + 1..].split_whitespace()` |
| 22 (JSON) | `Cargo.toml` uses `serde_json`; `src/main.rs:398` `serde_json::to_string(&tick)` |
| 23 (truncation) | `src/proc.rs:306` `truncate_chars` via `s.chars().take(max)`, with a `héllo` boundary test at line 576 |
| 23 (cmdline cost) | `src/proc.rs:264` `cmdline(&mut self, pid, start_ticks)` — cached per `(pid, start_ticks)` |
| 12 (blocking stop) | `src/actions.rs:173` `systemctl_async` spawns off-thread; comment cites the polkit stall |
| 8 (login session scope) | `src/proc.rs:146` `is_login_session_scope` already special-cases `session-N.scope` |
| 10 (GPU parse) | `src/apps.rs:446` dedupes on `drm-client-id`, reads `drm-engine-gfx`; test fixture at line 944 uses real amdgpu output |

**Live in the code, needs the change described above:**

| Finding | Evidence in code |
|---|---|
| **1, 2** | `src/proc.rs:371` `is_job_leader` ships the exact rule shown to be broken: `p.pid == p.pgid && p.tty_nr != 0 && !is_shell(&p.comm) && parent_comm.map(is_shell)`. `ProcInfo` **has no `sid` field** — the fix requires adding field 6 of `/proc/<pid>/stat` to the struct. |
| 3 | `job_members` keys off a live leader; no orphaned-group path |
| 13 | `src/actions.rs:163` uses `systemctl kill -s <sig>` for Pause — switch to `freeze`/`thaw` |
| 28 | `src/vitals.rs:188` reads `mem_info_vram_used` / `mem_info_vram_total` raw — 96% at idle on this APU |
| 29 | `src/vitals.rs` battery path only; no RAPL |
| 14, 15, 16 | pressure score lives in `src/main.rs` (`score < 0.05 => "Calm"` at line 126) |

**One new observation from the code:** `Cargo.toml` sets `panic = "abort"`. That
is at odds with the protocol's *"Never exit on a read error; skip that pid.
Processes may vanish mid-read."* A single out-of-bounds slice or `unwrap` on a
vanished process takes the whole sampler down with no unwind and no diagnostic.
Either keep `panic = "unwind"` and catch at the tick boundary, or audit every
slice and `unwrap` in the `/proc` path. `Cargo.lock` is committed — good, per
finding 25.
