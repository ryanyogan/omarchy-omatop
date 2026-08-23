# Omatop: ubiquitous language

Omatop is a system monitor for Omarchy. Its job is diagnostic: open it and
the thing eating the machine is already in front of you. The dashboard look
is the skin, not the purpose.

## Terms

**App**
A group of processes that share one launch scope (on Omarchy, one systemd
`app-*.scope` or one `.service` unit). The primary unit of the overlay.
Chromium is one App with forty Processes, not forty rows.

**Process**
A single PID inside an App. Visible only when an App is expanded.

**Job**
A process tree started from a terminal: it has its own session and a
controlling tty, and lives inside the terminal's App. A Job is shown as its
own row, identified by its command line, never merged into the terminal.
`npm run dev`, `cargo build`, `docker compose up` are Jobs.

**Recent**
The strip at the top of the overlay listing Jobs and recently launched Apps,
newest first. Recent never re-sorts by usage; rows stay where they are so
they are easy to find, search, and act on. An item is Recent if it started
in the last 30 minutes or has a listening Port.

**Port**
A TCP port an App or Job is listening on. Searchable, so `/3000` finds
whatever is on port 3000.

**Pinned**
An App the user chose to watch. Pinned Apps appear in their own strip in the
overlay and in the bar dropdown, and survive reopen and shell restart.
Identity is the App's name, not its PID.

**Bucket**
One of four structural groups every App belongs to, derived from where it
runs: User (things you launched, including Jobs), System (user and system
service units), Desktop (compositor, shell, portals, audio), Kernel (kernel
threads). Desktop is read-only: no Actions. The list is alphabetical inside
each Bucket and never re-sorts by usage.

**Tag**
An optional semantic label on an App (Browser, Development, Media, ...),
taken from its desktop entry. Absent is an honest state, never guessed.

**Vital**
A system-wide metric with a history: CPU, memory, swap, CPU temperature,
GPU busy, GPU temperature, VRAM, disk throughput, network throughput,
power draw, fan speed.

**History**
The last 120 samples of every Vital and of every App's CPU, memory and GPU
(ten minutes at the default five second refresh), kept whether or not the
overlay is open. Opening the overlay after a spike shows the spike.

**Pressure**
The derived state of the machine: Calm, Busy, or Critical. Computed from the
kernel's pressure-stall information together with temperature and swap.
Read by the bar glyph, the dropdown header, and the overlay's culprit
highlight, so all three always agree.

**Culprit**
The App currently contributing most to Pressure. Highlighted, never
auto-selected.

**Action**
Something the user does to an App or Job: Stop, Pause, Resume, Restart.
Stop and Restart confirm first; Pause and Resume do not. Restart exists only
for Services.

**Mode**
The overlay's keyboard state: Normal, Search, Confirm, Help. The key
grammar is fixed and vim-shaped; only the summon hotkey is configurable.

**Sampler**
The component that reads the system and produces Vitals, Apps, Jobs, Ports,
and History. The overlay and bar only ever render what the Sampler says.
