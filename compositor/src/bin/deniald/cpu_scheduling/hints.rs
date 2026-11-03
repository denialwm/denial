//! Semantic CPU hints from compositor state.
//!
//! Denial knows which application the user is working with, and that the user
//! is interacting, before any frame work starts. Utilization tracking learns
//! this only after threads have already run slowly, so these hints place
//! threads directly:
//!
//! - While input arrives, and for a hold time after it, the ordinary-policy
//!   frame threads of the compositor and of the focused application request a
//!   utilization floor just above the little tier's capacity. EAS and misfit
//!   migration then place them on the big CPUs, and schedutil runs those CPUs
//!   fast. A floor acts only while its thread is runnable, so idle threads cost
//!   nothing.
//! - An application that stays unfocused is capped to the little tier's
//!   capacity. Its threads that still use the whole application CPU domain
//!   are pinned to the little CPUs. Regaining focus restores both.
//! - For the same interaction hold, a GPU that its platform lets Denial raise
//!   runs at its highest frequency. See `gpu_floor`. The shell also reports
//!   its own animations, such as an arriving banner, which no input drives;
//!   those raise only the GPU, for the animation and a short hold after it.
//!
//! Configuration is read once:
//! - DENIAL_CPU_HINTS=0 disables the CPU hints, DENIAL_GPU_HINTS=0 the GPU
//!   floor.
//! - DENIAL_CPU_HINTS_BOOST, _FOCUS and _BACKGROUND_MAX take utilization
//!   values in 0..=1024.
//! - _HOLD_MS and _DEMOTE_MS take milliseconds.
//! - _PIN=0 keeps the caps but never changes affinity.
//! - _THREADS adds comma-separated frame thread names.
use super::capacity::SchedAttr;
use super::gpu_floor::GpuFloor;
use denial_core::cpu_affinity::{self, CpuSet, Groups, Pid, sched_getaffinity, sched_setaffinity};
use std::collections::{HashMap, HashSet, VecDeque};
use std::fs;
use std::io;
use std::os::unix::fs::MetadataExt;
use std::sync::OnceLock;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::mpsc::{self, Receiver, RecvTimeoutError, Sender};
use std::time::{Duration, Instant};

const DEFAULT_HOLD: Duration = Duration::from_millis(1500);
const DEFAULT_DEMOTE_DELAY: Duration = Duration::from_millis(2000);
const DEFAULT_FOCUS_MINIMUM: u32 = 256;
const HOMOGENEOUS_BOOST: u32 = 512;
const MAX_TREE_PROCESSES: usize = 512;
/// How long a process's frame threads are reused without rescanning
/// `/proc/PID/task`. Focus that briefly visits the shell, such as an overview
/// toggle, reapplies floors to the same few threads; reading the name of every
/// thread of a browser each time costs more than the hint itself.
const FRAME_THREAD_REFRESH: Duration = Duration::from_secs(1);
const UTIL_MAX: u32 = 1024;
/// How long the GPU floor outlasts a shell animation, so back-to-back
/// animations and the frame that completes one keep the clock.
const ANIMATION_HOLD: Duration = Duration::from_millis(100);
/// A shell animation that runs this long without input is a looping
/// indicator rather than a transition, and no longer holds the GPU floor.
const ANIMATION_LIMIT: Duration = Duration::from_secs(3);

static SENDER: OnceLock<Sender<Event>> = OnceLock::new();
static EPOCH: OnceLock<Instant> = OnceLock::new();
// Input threads and the worker hand the interaction over through these two
// values without a lock, so both use sequentially consistent ordering. See
// Worker::expire for the race that this ordering closes.
static LAST_INPUT_MS: AtomicU64 = AtomicU64::new(0);
static INTERACTING: AtomicBool = AtomicBool::new(false);
/// Set once a GPU floor exists, so animation reports cost nothing elsewhere.
static GPU_FLOOR: AtomicBool = AtomicBool::new(false);
static ANIMATING: AtomicBool = AtomicBool::new(false);

enum Event {
    Focus(Option<libc::pid_t>),
    Interaction,
    Animation(bool),
}

/// Starts the hint worker. This runs on the startup thread before
/// elevation, so the worker begins life with ordinary scheduling.
pub(super) fn start() {
    let config = Config::from_env();
    if !config.cpu {
        tracing::info!("semantic CPU hints disabled by DENIAL_CPU_HINTS");
    }
    if !config.cpu && !config.gpu {
        return;
    }
    let (sender, receiver) = mpsc::channel();
    let spawn = std::thread::Builder::new()
        .name("denial-cpu-hint".into())
        .spawn(move || {
            super::normalize_current_worker("cpu-hints");
            Worker::new(config).run(receiver);
        });
    match spawn {
        Ok(_) => {
            let _ = SENDER.set(sender);
        }
        Err(error) => tracing::warn!(%error, "could not start the semantic CPU hint worker"),
    }
}

/// Called on every keyboard focus change. It receives the focused client's
/// PID, or `None` when the shell or nothing holds focus.
pub(super) fn focus_changed(pid: Option<libc::pid_t>) {
    if let Some(sender) = SENDER.get() {
        let _ = sender.send(Event::Focus(pid));
    }
}

/// Called for every user input event. Only the start of an interaction
/// reaches the worker; later events just extend its hold time.
pub(super) fn note_interaction() {
    let Some(sender) = SENDER.get() else {
        return;
    };
    LAST_INPUT_MS.store(now_ms(), Ordering::SeqCst);
    if !INTERACTING.swap(true, Ordering::SeqCst) {
        let _ = sender.send(Event::Interaction);
    }
}

/// Called when the shell starts or stops animating. Only a GPU floor uses it;
/// CPU placement follows input alone.
pub(super) fn note_animation(active: bool) {
    if !GPU_FLOOR.load(Ordering::Relaxed) {
        return;
    }
    let Some(sender) = SENDER.get() else {
        return;
    };
    if ANIMATING.swap(active, Ordering::Relaxed) != active {
        let _ = sender.send(Event::Animation(active));
    }
}

fn epoch() -> Instant {
    *EPOCH.get_or_init(Instant::now)
}

fn now_ms() -> u64 {
    epoch().elapsed().as_millis() as u64
}

#[derive(Clone, Debug, PartialEq)]
struct Config {
    cpu: bool,
    gpu: bool,
    boost: Option<u32>,
    focus: u32,
    background_max: Option<u32>,
    hold: Duration,
    demote_delay: Duration,
    pin: bool,
    extra_names: Vec<String>,
}

impl Config {
    fn from_env() -> Self {
        Self::from_lookup(|key| std::env::var(key).ok())
    }

    fn from_lookup(lookup: impl Fn(&str) -> Option<String>) -> Self {
        let utilization = |key: &str| {
            let value = lookup(key)?;
            let parsed = value.trim().parse::<u32>().ok().filter(|v| *v <= UTIL_MAX);
            if parsed.is_none() {
                tracing::warn!(%value, "{key} must be 0..=1024; using the default");
            }
            parsed
        };
        let millis = |key: &str, default: Duration| {
            lookup(key)
                .and_then(|value| value.trim().parse::<u64>().ok())
                .map_or(default, Duration::from_millis)
        };
        Self {
            cpu: lookup("DENIAL_CPU_HINTS").as_deref() != Some("0"),
            gpu: lookup("DENIAL_GPU_HINTS").as_deref() != Some("0"),
            boost: utilization("DENIAL_CPU_HINTS_BOOST"),
            focus: utilization("DENIAL_CPU_HINTS_FOCUS").unwrap_or(DEFAULT_FOCUS_MINIMUM),
            background_max: utilization("DENIAL_CPU_HINTS_BACKGROUND_MAX"),
            hold: millis("DENIAL_CPU_HINTS_HOLD_MS", DEFAULT_HOLD),
            demote_delay: millis("DENIAL_CPU_HINTS_DEMOTE_MS", DEFAULT_DEMOTE_DELAY),
            pin: lookup("DENIAL_CPU_HINTS_PIN").as_deref() != Some("0"),
            extra_names: lookup("DENIAL_CPU_HINTS_THREADS")
                .map(|names| {
                    names
                        .split(',')
                        .map(str::trim)
                        .filter(|name| !name.is_empty())
                        .map(str::to_owned)
                        .collect()
                })
                .unwrap_or_default(),
        }
    }
}

/// The application CPU domain, plus the little CPUs and their capacity when
/// the kernel reports more than one tier.
#[derive(Clone, Copy, Debug)]
struct Topology {
    domain: CpuSet,
    little: Option<(CpuSet, u32)>,
}

impl Topology {
    fn detect() -> Self {
        let explicit = super::placement::groups();
        let domain = match explicit {
            Some(groups) => groups.applications,
            None => sched_getaffinity(Pid::from_raw(std::process::id() as i32))
                .unwrap_or_else(|_| CpuSet::new()),
        };
        let capacities = (0..CpuSet::MAX_CPU)
            .filter(|&cpu| domain.is_set(cpu))
            .filter_map(|cpu| {
                fs::read_to_string(format!("/sys/devices/system/cpu/cpu{cpu}/cpu_capacity"))
                    .ok()?
                    .trim()
                    .parse::<u32>()
                    .ok()
                    .map(|capacity| (cpu, capacity))
            })
            .collect::<Vec<_>>();
        Self::from_capacities(domain, &capacities, explicit)
    }

    fn from_capacities(
        domain: CpuSet,
        capacities: &[(usize, u32)],
        explicit: Option<Groups>,
    ) -> Self {
        let minimum = capacities.iter().map(|(_, c)| *c).min();
        let maximum = capacities.iter().map(|(_, c)| *c).max();
        let little = match (explicit, minimum, maximum) {
            // An explicit platform map wins. Its capacity is that of the
            // largest little CPU, so a floor above it always leaves the tier.
            (Some(groups), _, _) => capacities
                .iter()
                .filter(|(cpu, _)| groups.little.is_set(*cpu))
                .map(|(_, c)| *c)
                .max()
                .filter(|capacity| *capacity < UTIL_MAX)
                .map(|capacity| (groups.little, capacity)),
            (None, Some(minimum), Some(maximum)) if minimum < maximum => {
                let mut little = CpuSet::new();
                for &(cpu, capacity) in capacities {
                    if capacity == minimum {
                        little.set(cpu);
                    }
                }
                Some((little, minimum))
            }
            _ => None,
        };
        Self { domain, little }
    }

    /// The smallest floor that the little tier cannot satisfy.
    fn big_floor(&self) -> u32 {
        self.little.map_or(HOMOGENEOUS_BOOST, |(_, capacity)| {
            (capacity + 1).min(UTIL_MAX)
        })
    }

    /// The little CPUs that unfocused applications may be pinned to.
    fn pin_mask(&self) -> Option<CpuSet> {
        let (little, _) = self.little?;
        let mut mask = CpuSet::new();
        for cpu in 0..CpuSet::MAX_CPU {
            if little.is_set(cpu) && self.domain.is_set(cpu) {
                mask.set(cpu);
            }
        }
        (mask.count() > 0 && mask != self.domain).then_some(mask)
    }
}

/// A process identified by PID and start time, so that a reused PID never
/// inherits another application's hints.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Hash)]
struct Process {
    pid: libc::pid_t,
    start: u64,
}

impl Process {
    fn identify(pid: libc::pid_t) -> Option<Self> {
        let stat = fs::read_to_string(format!("/proc/{pid}/stat")).ok()?;
        let (_, fields) = parse_stat(&stat)?;
        Some(Self {
            pid,
            start: fields.start,
        })
    }

    fn alive(&self) -> bool {
        Self::identify(self.pid) == Some(*self)
    }
}

struct StatFields {
    ppid: libc::pid_t,
    start: u64,
}

/// Parses the fields of `/proc/PID/stat` that follow the parenthesized
/// command name. The name may itself contain spaces and parentheses.
fn parse_stat(stat: &str) -> Option<(&str, StatFields)> {
    let open = stat.find('(')?;
    let close = stat.rfind(')')?;
    let comm = stat.get(open + 1..close)?;
    let fields = stat
        .get(close + 1..)?
        .split_whitespace()
        .collect::<Vec<_>>();
    Some((
        comm,
        StatFields {
            ppid: fields.get(1)?.parse().ok()?,
            start: fields.get(19)?.parse().ok()?,
        },
    ))
}

/// Recognizes threads whose work feeds every frame of a focused application,
/// using the names toolkits give them. The list never needs to be complete,
/// only correct.
fn frame_thread_name(name: &str, extra: &[String]) -> bool {
    flutter_frame_thread(name)
        // Mesa's gallium driver submit queue: "<process>:gdrvN".
        || name.contains(":gdrv")
        || matches!(
            name,
            "Renderer" | "RenderThread" | "QSGRenderThread" | "VizCompositorTh"
        )
        || extra.iter().any(|extra| extra == name)
}

/// Flutter engine threads are named "io.flutter[.N].ui" and
/// "io.flutter[.N].raster". Linux keeps only the first 15 bytes, so a raster
/// thread's name may be truncated.
fn flutter_frame_thread(name: &str) -> bool {
    let Some(rest) = name.strip_prefix("io.flutter.") else {
        return false;
    };
    let rest = match rest.split_once('.') {
        Some((index, tail)) if !index.is_empty() && index.bytes().all(|b| b.is_ascii_digit()) => {
            tail
        }
        _ => rest,
    };
    rest == "ui" || (rest.len() >= 2 && "raster".starts_with(rest))
}

struct Worker {
    config: Config,
    topology: Option<Topology>,
    focused: Option<Process>,
    pending: Vec<(Process, Instant)>,
    demoted: HashSet<Process>,
    frame_threads: HashMap<Process, (Instant, Vec<libc::pid_t>)>,
    boosting: bool,
    gpu: Option<GpuFloor>,
    /// When the current shell animation started, while one runs.
    animation: Option<Instant>,
    /// Until when the GPU floor outlasts the last shell animation.
    animation_hold: Option<Instant>,
    uid: u32,
    own_pid: libc::pid_t,
    warned: bool,
}

impl Worker {
    fn new(config: Config) -> Self {
        Self {
            config,
            topology: None,
            focused: None,
            pending: Vec::new(),
            demoted: HashSet::new(),
            frame_threads: HashMap::new(),
            boosting: false,
            gpu: None,
            animation: None,
            animation_hold: None,
            // SAFETY: getuid has no arguments and cannot fail.
            uid: unsafe { libc::getuid() },
            own_pid: std::process::id() as libc::pid_t,
            warned: false,
        }
    }

    fn run(mut self, receiver: Receiver<Event>) {
        if self.config.gpu {
            self.gpu = GpuFloor::discover();
            GPU_FLOOR.store(self.gpu.is_some(), Ordering::Relaxed);
        }
        if !self.config.cpu && self.gpu.is_none() {
            return;
        }
        loop {
            let event = match self.next_deadline() {
                Some(deadline) => {
                    receiver.recv_timeout(deadline.saturating_duration_since(Instant::now()))
                }
                None => receiver.recv().map_err(|_| RecvTimeoutError::Disconnected),
            };
            match event {
                Ok(Event::Focus(pid)) => self.focus(pid),
                Ok(Event::Interaction) => self.interaction_started(),
                Ok(Event::Animation(active)) => self.animation(active),
                Err(RecvTimeoutError::Timeout) => {}
                Err(RecvTimeoutError::Disconnected) => return,
            }
            self.expire();
            self.update_gpu();
        }
    }

    fn topology(&mut self) -> Topology {
        if let Some(topology) = self.topology {
            return topology;
        }
        let topology = Topology::detect();
        tracing::info!(
            little = %topology.little.map_or_else(|| "none".into(), |(mask, _)| cpu_affinity::cpu_list(&mask)),
            little_capacity = topology.little.map(|(_, capacity)| capacity),
            boost = self.boost_for(&topology),
            focus = self.config.focus,
            background_max = self.background_max_for(&topology),
            hold_ms = self.config.hold.as_millis() as u64,
            pin = self.config.pin && topology.pin_mask().is_some(),
            "semantic CPU hints active"
        );
        self.topology = Some(topology);
        topology
    }

    fn boost_for(&self, topology: &Topology) -> u32 {
        self.config.boost.unwrap_or_else(|| topology.big_floor())
    }

    fn background_max_for(&self, topology: &Topology) -> u32 {
        self.config
            .background_max
            .or(topology.little.map(|(_, capacity)| capacity))
            .unwrap_or(UTIL_MAX)
    }

    fn pin_mask(&self, topology: &Topology) -> Option<CpuSet> {
        self.config.pin.then(|| topology.pin_mask()).flatten()
    }

    fn idle_floor(&self) -> u32 {
        self.config
            .focus
            .max(super::capacity::configured().unwrap_or(0))
    }

    fn interaction_deadline(&self) -> Instant {
        epoch() + Duration::from_millis(LAST_INPUT_MS.load(Ordering::SeqCst)) + self.config.hold
    }

    fn next_deadline(&self) -> Option<Instant> {
        let interaction = self.boosting.then(|| self.interaction_deadline());
        let demotion = self.pending.iter().map(|(_, due)| *due).min();
        // A looping animation past its limit no longer holds the floor and
        // needs no wakeup until it stops; an elapsed deadline would spin.
        let animation = self
            .animation
            .map(|start| start + ANIMATION_LIMIT)
            .filter(|limit| *limit > Instant::now());
        interaction
            .into_iter()
            .chain(demotion)
            .chain(animation)
            .chain(self.animation_hold)
            .min()
    }

    fn current_floor(&self, topology: &Topology) -> u32 {
        if self.boosting {
            self.boost_for(topology)
        } else {
            self.idle_floor()
        }
    }

    fn focus(&mut self, pid: Option<libc::pid_t>) {
        if !self.config.cpu {
            return;
        }
        let topology = self.topology();
        let next = pid
            .filter(|pid| *pid > 0 && *pid != self.own_pid && self.owned(*pid))
            .and_then(Process::identify);
        if next == self.focused {
            return;
        }
        if let Some(previous) = self.focused.take() {
            // Promote at once but demote lazily: a brief trip through the
            // shell or a dialog must not churn every thread of the app.
            self.apply_frame_floor(previous, 0);
            self.pending.retain(|(process, _)| *process != previous);
            self.pending
                .push((previous, Instant::now() + self.config.demote_delay));
        }
        if let Some(process) = next {
            self.pending.retain(|(pending, _)| *pending != process);
            if self.demoted.remove(&process) {
                self.restore(process, &topology);
            }
            let floor = self.current_floor(&topology);
            self.apply_frame_floor(process, floor);
        }
        self.focused = next;
    }

    fn interaction_started(&mut self) {
        if self.boosting {
            return;
        }
        self.boosting = true;
        // The GPU first: a frame's GPU work starts later than its CPU work,
        // but a frequency change takes longer than a clamp.
        self.update_gpu();
        if self.config.cpu {
            let topology = self.topology();
            self.apply_floors(self.boost_for(&topology));
        }
    }

    fn animation(&mut self, active: bool) {
        if active {
            self.animation.get_or_insert_with(Instant::now);
            self.animation_hold = None;
        } else if self.animation.take().is_some() {
            self.animation_hold = Some(Instant::now() + ANIMATION_HOLD);
        }
    }

    /// Holds the GPU floor during input and its hold, and during a shell
    /// animation, bounded by [`ANIMATION_LIMIT`], plus [`ANIMATION_HOLD`].
    fn update_gpu(&mut self) {
        let Some(gpu) = &mut self.gpu else {
            return;
        };
        let now = Instant::now();
        self.animation_hold = self.animation_hold.filter(|until| *until > now);
        let animating = self
            .animation
            .is_some_and(|start| now < start + ANIMATION_LIMIT)
            || self.animation_hold.is_some();
        if self.boosting || animating {
            gpu.raise();
        } else {
            gpu.lower();
        }
    }

    fn apply_floors(&mut self, floor: u32) {
        self.apply_compositor_floor(floor);
        if let Some(process) = self.focused {
            self.apply_frame_floor(process, floor);
        }
    }

    fn expire(&mut self) {
        let now = Instant::now();
        if self.boosting && self.interaction_deadline() <= now {
            // Input can race with this transition. An input thread stores its
            // timestamp before it swaps INTERACTING. If the swap comes first
            // and still reads true, the re-check below sees the new timestamp
            // and keeps the boost. Otherwise the swap reads false and queues a
            // fresh Interaction event.
            INTERACTING.store(false, Ordering::SeqCst);
            if self.interaction_deadline() > now {
                INTERACTING.store(true, Ordering::SeqCst);
            } else {
                self.boosting = false;
                if self.config.cpu {
                    self.apply_floors(self.idle_floor());
                }
            }
        }
        if self.pending.iter().any(|(_, due)| *due <= now) {
            let topology = self.topology();
            let (due, waiting) = std::mem::take(&mut self.pending)
                .into_iter()
                .partition::<Vec<_>, _>(|(_, due)| *due <= now);
            self.pending = waiting;
            for (process, _) in due {
                if Some(process) != self.focused && process.alive() {
                    self.demote(process, &topology);
                    self.demoted.insert(process);
                }
            }
        }
        self.demoted.retain(Process::alive);
    }

    fn owned(&self, pid: libc::pid_t) -> bool {
        fs::metadata(format!("/proc/{pid}")).is_ok_and(|meta| meta.uid() == self.uid)
    }

    fn apply_compositor_floor(&mut self, floor: u32) {
        let registered = super::PRIORITY_THREAD_IDS
            .iter()
            .map(|slot| slot.load(Ordering::Acquire))
            .filter(|tid| *tid > 0);
        // The driver's submit queue is unregistered but submits every frame.
        let drivers = threads(self.own_pid)
            .into_iter()
            .filter(|(_, name)| name.contains(":gdrv"))
            .map(|(tid, _)| tid);
        for tid in registered.chain(drivers).collect::<Vec<_>>() {
            // A realtime compositor thread already fits only the CPUs that
            // its realtime clamp default allows. An explicit floor would
            // replace that default, so leave it to the platform policy.
            if policy(tid) == Some(libc::SCHED_OTHER) {
                let result = set_clamp(tid, Some(floor), None, true);
                self.report(result, tid, "compositor frame thread");
            }
        }
    }

    fn apply_frame_floor(&mut self, process: Process, floor: u32) {
        let now = Instant::now();
        self.frame_threads
            .retain(|_, (scanned, _)| now.duration_since(*scanned) < FRAME_THREAD_REFRESH);
        if !process.alive() {
            self.frame_threads.remove(&process);
            return;
        }
        let (scanned, tids) = self.frame_threads.remove(&process).unwrap_or_else(|| {
            let tids = threads(process.pid)
                .into_iter()
                .filter(|(tid, name)| {
                    *tid == process.pid || frame_thread_name(name, &self.config.extra_names)
                })
                .map(|(tid, _)| tid)
                .collect();
            (now, tids)
        });
        let mut exited = false;
        for &tid in &tids {
            // Leave realtime, deadline, batch and idle threads to the policy
            // their owner chose.
            match policy(tid) {
                Some(libc::SCHED_OTHER) => {}
                Some(_) => continue,
                None => {
                    exited = true;
                    continue;
                }
            }
            let result = set_clamp(tid, Some(floor), None, true);
            exited |= result
                .as_ref()
                .is_err_and(|error| error.raw_os_error() == Some(libc::ESRCH));
            self.report(result, tid, "application frame thread");
        }
        // A thread that exited invalidates the list; rescan next time.
        if !exited {
            self.frame_threads.insert(process, (scanned, tids));
        }
        tracing::debug!(pid = process.pid, floor, "applied frame-thread CPU floor");
    }

    fn demote(&mut self, process: Process, topology: &Topology) {
        let maximum = self.background_max_for(topology);
        let pin = self.pin_mask(topology);
        if maximum >= UTIL_MAX && pin.is_none() {
            return;
        }
        let mut capped = 0usize;
        let mut pinned = 0usize;
        for pid in self.tree(process.pid) {
            for (tid, _) in threads(pid) {
                let Some(attr) = get_attr(tid) else { continue };
                let policy = attr.sched_policy as libc::c_int;
                if !matches!(
                    policy,
                    libc::SCHED_OTHER | libc::SCHED_BATCH | libc::SCHED_IDLE
                ) {
                    continue;
                }
                if maximum < UTIL_MAX {
                    // The kernel rejects a maximum below the current minimum.
                    let minimum = (attr.sched_util_min > maximum).then_some(0);
                    // No reset-on-fork here: threads created while the
                    // application is in the background inherit the cap.
                    let result = set_clamp(tid, minimum, Some(maximum), false);
                    capped += usize::from(result.is_ok());
                    self.report(result, tid, "background thread");
                }
                if let (Some(little), Some(task)) = (pin, Pid::from_raw(tid))
                    // Only threads still using the whole domain: never
                    // override an affinity the application chose itself.
                    && sched_getaffinity(Some(task)).is_ok_and(|mask| mask == topology.domain)
                    && sched_setaffinity(Some(task), &little).is_ok()
                {
                    pinned += 1;
                }
            }
        }
        tracing::debug!(
            pid = process.pid,
            capped,
            pinned,
            maximum,
            "moved unfocused application to the little CPUs"
        );
    }

    fn restore(&mut self, process: Process, topology: &Topology) {
        let maximum = self.background_max_for(topology);
        let pin = self.pin_mask(topology);
        for pid in self.tree(process.pid) {
            for (tid, _) in threads(pid) {
                if maximum < UTIL_MAX
                    && get_attr(tid).is_some_and(|attr| attr.sched_util_max == maximum)
                {
                    let result = set_clamp(tid, None, Some(UTIL_MAX), false);
                    self.report(result, tid, "restored thread");
                }
                if let (Some(little), Some(task)) = (pin, Pid::from_raw(tid))
                    && sched_getaffinity(Some(task)).is_ok_and(|mask| mask == little)
                {
                    let _ = sched_setaffinity(Some(task), &topology.domain);
                }
            }
        }
        tracing::debug!(pid = process.pid, "restored focused application CPU domain");
    }

    /// Returns the process and its same-user descendants, such as browser
    /// content processes or a terminal's jobs. The walk is bounded so a fork
    /// storm cannot stall the worker.
    fn tree(&self, root: libc::pid_t) -> Vec<libc::pid_t> {
        let mut children: HashMap<libc::pid_t, Vec<libc::pid_t>> = HashMap::new();
        if let Ok(entries) = fs::read_dir("/proc") {
            for entry in entries.flatten() {
                let Some(pid) = entry
                    .file_name()
                    .to_str()
                    .and_then(|name| name.parse::<libc::pid_t>().ok())
                else {
                    continue;
                };
                let Ok(stat) = fs::read_to_string(entry.path().join("stat")) else {
                    continue;
                };
                if let Some((_, fields)) = parse_stat(&stat) {
                    children.entry(fields.ppid).or_default().push(pid);
                }
            }
        }
        let mut tree = Vec::new();
        let mut queue = VecDeque::from([root]);
        while let Some(pid) = queue.pop_front() {
            if tree.len() >= MAX_TREE_PROCESSES {
                break;
            }
            if pid == self.own_pid || !self.owned(pid) {
                continue;
            }
            tree.push(pid);
            queue.extend(children.get(&pid).into_iter().flatten());
        }
        tree
    }

    fn report(&mut self, result: io::Result<()>, tid: libc::pid_t, role: &'static str) {
        match result {
            Ok(()) => {}
            Err(error) if error.raw_os_error() == Some(libc::ESRCH) => {}
            Err(error) if !self.warned => {
                self.warned = true;
                tracing::warn!(
                    %error,
                    tid,
                    role,
                    "could not apply a semantic CPU hint; further failures are logged at debug level"
                );
            }
            Err(error) => tracing::debug!(%error, tid, role, "could not apply a semantic CPU hint"),
        }
    }
}

fn threads(pid: libc::pid_t) -> Vec<(libc::pid_t, String)> {
    let Ok(tasks) = fs::read_dir(format!("/proc/{pid}/task")) else {
        return Vec::new();
    };
    tasks
        .flatten()
        .filter_map(|task| {
            let tid = task.file_name().to_str()?.parse().ok()?;
            let name = fs::read_to_string(task.path().join("comm")).ok()?;
            Some((tid, name.trim_end().to_owned()))
        })
        .collect()
}

fn policy(tid: libc::pid_t) -> Option<libc::c_int> {
    get_attr(tid).map(|attr| attr.sched_policy as libc::c_int)
}

fn get_attr(tid: libc::pid_t) -> Option<SchedAttr> {
    let mut attr = SchedAttr::default();
    let size = std::mem::size_of::<SchedAttr>() as u32;
    // SAFETY: attr is a writable sched_attr of the advertised size.
    let result = unsafe { libc::syscall(libc::SYS_sched_getattr, tid, &mut attr, size, 0) };
    (result == 0).then_some(attr)
}

/// Updates a thread's utilization clamps without touching its policy, nice
/// value or priority. With `reset_on_fork`, an ordinary thread also gains
/// SCHED_RESET_ON_FORK, so threads it creates later start without the floor.
/// Other threads keep the reset state they already have.
fn set_clamp(
    tid: libc::pid_t,
    minimum: Option<u32>,
    maximum: Option<u32>,
    reset_on_fork: bool,
) -> io::Result<()> {
    let current = get_attr(tid).ok_or_else(io::Error::last_os_error)?;
    let policy = current.sched_policy as libc::c_int;
    let already_reset = current.sched_flags & libc::SCHED_FLAG_RESET_ON_FORK as u64 != 0;
    let mut attr = SchedAttr {
        size: std::mem::size_of::<SchedAttr>() as u32,
        ..SchedAttr::default()
    };
    let mut flags = libc::SCHED_FLAG_KEEP_PARAMS as u64;
    if reset_on_fork && !already_reset && policy == libc::SCHED_OTHER {
        // Setting RESET_ON_FORK needs an explicit policy. KEEP_PARAMS still
        // keeps the thread's nice value, read at the time of the call.
        attr.sched_policy = policy as u32;
        flags |= libc::SCHED_FLAG_RESET_ON_FORK as u64;
    } else {
        // KEEP_POLICY also keeps the current reset-on-fork state.
        flags |= libc::SCHED_FLAG_KEEP_POLICY as u64;
    }
    if let Some(minimum) = minimum {
        flags |= libc::SCHED_FLAG_UTIL_CLAMP_MIN as u64;
        attr.sched_util_min = minimum.min(UTIL_MAX);
    }
    if let Some(maximum) = maximum {
        flags |= libc::SCHED_FLAG_UTIL_CLAMP_MAX as u64;
        attr.sched_util_max = maximum.min(UTIL_MAX);
    }
    attr.sched_flags = flags;
    // SAFETY: attr is initialized and outlives the syscall. tid selects one
    // task, which the kernel checks against this process's credentials.
    if unsafe { libc::syscall(libc::SYS_sched_setattr, tid, &attr, 0) } == 0 {
        Ok(())
    } else {
        Err(io::Error::last_os_error())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn recognizes_toolkit_frame_threads_including_truncated_names() {
        let extra = vec!["MyRender".to_owned()];
        for name in [
            "io.flutter.ui",
            "io.flutter.rast",
            "io.flutter.1.ui",
            "io.flutter.1.ra",
            "firefox:gdrv0",
            "deniald:gdrv0",
            "Renderer",
            "QSGRenderThread",
            "MyRender",
        ] {
            assert!(frame_thread_name(name, &extra), "{name}");
        }
        for name in [
            "io.flutter.io",
            "io.flutter.plat",
            "io.flutter.1.io",
            "io.flutter.r",
            "io.worker.1",
            "gdrv0",
            "DartWorker",
            "firefox",
        ] {
            assert!(!frame_thread_name(name, &extra), "{name}");
        }
    }

    #[test]
    fn a_looping_animation_past_its_limit_schedules_no_wakeup() {
        let mut worker = Worker::new(Config::from_lookup(|_| None));
        worker.animation(true);
        assert!(worker.next_deadline().is_some());
        worker.animation = Some(Instant::now() - ANIMATION_LIMIT);
        assert_eq!(worker.next_deadline(), None);
        worker.animation(false);
        assert!(
            worker
                .next_deadline()
                .is_some_and(|hold| hold > Instant::now())
        );
    }

    #[test]
    fn parses_stat_with_spaces_and_parentheses_in_the_name() {
        let stat = "4242 (Web (Content) x) S 17 4242 4242 0 -1 4194560 1 0 0 0 0 0 0 0 20 0 9 0 123456 0 0";
        let (comm, fields) = parse_stat(stat).unwrap();
        assert_eq!(comm, "Web (Content) x");
        assert_eq!(fields.ppid, 17);
        assert_eq!(fields.start, 123456);
    }

    #[test]
    fn configuration_defaults_and_validation() {
        let config = Config::from_lookup(|_| None);
        assert!(config.cpu && config.gpu);
        assert_eq!(config.boost, None);
        assert_eq!(config.focus, DEFAULT_FOCUS_MINIMUM);
        assert_eq!(config.background_max, None);
        assert_eq!(config.hold, DEFAULT_HOLD);
        assert_eq!(config.demote_delay, DEFAULT_DEMOTE_DELAY);
        assert!(config.pin);
        let config = Config::from_lookup(|key| {
            Some(
                match key {
                    "DENIAL_GPU_HINTS" => "0",
                    "DENIAL_CPU_HINTS_BOOST" => "900",
                    "DENIAL_CPU_HINTS_FOCUS" => "2048",
                    "DENIAL_CPU_HINTS_BACKGROUND_MAX" => "400",
                    "DENIAL_CPU_HINTS_HOLD_MS" => "250",
                    "DENIAL_CPU_HINTS_PIN" => "0",
                    "DENIAL_CPU_HINTS_THREADS" => " Paint , ,Compositor",
                    _ => return None,
                }
                .to_owned(),
            )
        });
        assert!(config.cpu && !config.gpu);
        assert_eq!(config.boost, Some(900));
        assert_eq!(
            config.focus, DEFAULT_FOCUS_MINIMUM,
            "out-of-range value falls back"
        );
        assert_eq!(config.background_max, Some(400));
        assert_eq!(config.hold, Duration::from_millis(250));
        assert!(!config.pin);
        assert_eq!(config.extra_names, ["Paint", "Compositor"]);
    }

    #[test]
    fn floors_and_pinning_follow_the_little_tier() {
        let domain = cpu_affinity::parse_list("0-7").unwrap();
        let little_cpus = cpu_affinity::parse_list("0-5").unwrap();
        let capacities = (0..8)
            .map(|cpu| (cpu, if cpu < 6 { 762 } else { 1024 }))
            .collect::<Vec<_>>();
        let topology = Topology::from_capacities(domain, &capacities, None);
        assert_eq!(topology.little, Some((little_cpus, 762)));
        assert_eq!(topology.big_floor(), 763);
        assert_eq!(topology.pin_mask(), Some(little_cpus));

        // A domain that already excludes the big CPUs has nothing to pin.
        let narrow = Topology::from_capacities(little_cpus, &capacities[..6], None);
        assert!(narrow.little.is_none());
        assert_eq!(narrow.pin_mask(), None);

        let uniform = (0..8).map(|cpu| (cpu, 1024)).collect::<Vec<_>>();
        let topology = Topology::from_capacities(domain, &uniform, None);
        assert!(topology.little.is_none());
        assert_eq!(topology.big_floor(), HOMOGENEOUS_BOOST);
        assert_eq!(topology.pin_mask(), None);

        // An explicit map supplies the tiers when capacities are uniform, but
        // a floor cannot leave a tier the kernel rates at full capacity.
        let groups = Groups::new(
            domain,
            cpu_affinity::parse_list("6-7").unwrap(),
            little_cpus,
        )
        .unwrap();
        let topology = Topology::from_capacities(domain, &uniform, Some(groups));
        assert!(topology.little.is_none());
        let topology = Topology::from_capacities(domain, &capacities, Some(groups));
        assert_eq!(topology.little, Some((little_cpus, 762)));
    }

    #[test]
    fn clamps_another_thread_without_changing_its_policy() {
        use std::sync::mpsc::channel;
        let (tid_sender, tid_receiver) = channel();
        let (spawn_sender, spawn_receiver) = channel::<bool>();
        let (child_sender, child_receiver) = channel();
        let worker = std::thread::spawn(move || {
            // SAFETY: gettid has no arguments.
            let tid = unsafe { libc::syscall(libc::SYS_gettid) } as libc::pid_t;
            tid_sender.send(tid).unwrap();
            while spawn_receiver.recv().unwrap() {
                let child = std::thread::spawn(|| get_attr(0).unwrap().sched_util_min);
                child_sender.send(child.join().unwrap()).unwrap();
            }
        });
        let finish = || {
            spawn_sender.send(false).unwrap();
        };
        let tid = tid_receiver.recv().unwrap();
        let before = get_attr(tid).unwrap();
        match set_clamp(tid, Some(600), None, true) {
            Ok(()) => {}
            // Nix's build sandbox blocks scheduling-attribute syscalls.
            Err(error) if error.kind() == io::ErrorKind::PermissionDenied => {
                finish();
                worker.join().unwrap();
                return;
            }
            Err(error) => panic!("kernel must accept a utilization floor: {error}"),
        }
        let after = get_attr(tid).unwrap();
        assert_eq!(after.sched_util_min, 600);
        assert_eq!(after.sched_policy, before.sched_policy);
        assert_eq!(after.sched_nice, before.sched_nice);
        let reset_on_fork = libc::SCHED_FLAG_RESET_ON_FORK as u64;
        if before.sched_policy == libc::SCHED_OTHER as u32 {
            assert_ne!(after.sched_flags & reset_on_fork, 0);
            // A thread created by the floored thread starts without the floor.
            spawn_sender.send(true).unwrap();
            assert_eq!(child_receiver.recv().unwrap(), 0);
        } else {
            // Tests can inherit another policy, such as the SCHED_IDLE of a
            // build host's Nix daemon. set_clamp keeps that policy and so its
            // reset-on-fork state.
            assert_eq!(
                after.sched_flags & reset_on_fork,
                before.sched_flags & reset_on_fork
            );
        }

        set_clamp(tid, Some(0), Some(500), false).unwrap();
        let capped = get_attr(tid).unwrap();
        assert_eq!((capped.sched_util_min, capped.sched_util_max), (0, 500));
        assert_eq!(capped.sched_policy, before.sched_policy);
        set_clamp(tid, None, Some(UTIL_MAX), false).unwrap();
        assert_eq!(get_attr(tid).unwrap().sched_util_max, UTIL_MAX);
        finish();
        worker.join().unwrap();
    }
}
