//! The previous sample, kept between invocations.
//!
//! This file is what lets the binary be stateless and still show a rate. It
//! replaces the whole sampler daemon: the pidfile, the `noclobber` claim, the
//! stale takeover, the TERM trap and the restart dance all existed to keep one
//! long-lived process alive purely so it could remember the last reading.

use crate::metrics::{self, Counters};
use std::io::Write;
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};

pub struct State {
    /// CLOCK_MONOTONIC nanoseconds. System-wide and unaffected by NTP, so it is
    /// comparable across two separate processes — which is the property the
    /// wall clock lacked and that made every rate off by up to 2x.
    pub ts: u128,
    pub counters: Counters,
    /// The last rates actually measured over a usable interval.
    ///
    /// tmux re-runs the status command per client redraw, not strictly on
    /// status-interval, so with several clients attached two renders can land
    /// milliseconds apart. Nothing measurable happens in 3 ms: throughput comes
    /// out 0 and CPU comes out noise. Whichever invocation lands last is what
    /// the bar shows, so those readings were visible far more often than their
    /// share of renders.
    pub rates: Option<Rates>,
    /// When the GPU was last asked, and what it said.
    ///
    /// NVML costs ~21.7 ms in a fresh process — dominated by mapping and
    /// relocating libnvidia-ml.so, which a long-lived process pays once and a
    /// stateless one would pay every refresh. Measured, that made the render
    /// path *slower* than the shell it replaces (23.3 ms against 17.8 ms), so
    /// the reading is carried across invocations and refreshed on a slower
    /// cadence than the bar itself.
    pub gpu: Option<GpuSample>,
}

/// What the bar draws for the three values that are rates rather than levels.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Rates {
    pub cpu: u32,
    pub net_in: u64,
    pub net_out: u64,
}

/// Shorter than this and there is nothing to measure: report the previous
/// reading rather than inventing a zero. Well under the 2 s refresh, so a
/// genuine interval is never mistaken for a duplicate.
pub const MIN_INTERVAL_NANOS: u128 = 200_000_000;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct GpuSample {
    pub at: u128,
    /// `None` records "asked, and this machine has no readable GPU" — which is
    /// worth remembering precisely so it is not re-asked every 2 s.
    pub reading: Option<(u32, u32)>,
}

/// How stale a GPU reading may get. At the bar's 2 s refresh this asks NVML on
/// roughly every third render, taking the average cost from 23.3 ms to ~8 ms
/// while the number on screen is at most this far behind.
pub const GPU_TTL_NANOS: u128 = 6_000_000_000;

impl State {
    /// The cached reading, if it is still fresh enough to show.
    pub fn fresh_gpu(&self, now: u128) -> Option<Option<(u32, u32)>> {
        let g = self.gpu?;
        (now >= g.at && now - g.at < GPU_TTL_NANOS).then_some(g.reading)
    }
}

/// Decide what to display, and what baseline to keep, given the previous
/// sample and a fresh set of counters.
///
/// Pure, so the thing that actually went wrong is testable: with several tmux
/// clients attached the status command is re-run per redraw rather than per
/// status-interval, and two renders landing 3 ms apart measured 3 ms of
/// traffic — zero — then published it as the reading.
///
/// Returns the rates to draw plus the `(ts, counters)` to persist. When the
/// window was too short, the previous baseline is handed back unchanged so the
/// next render measures across the gap rather than from a point already spent.
pub fn resolve(prev: Option<&State>, now_ts: u128, now: &Counters) -> (Rates, u128, Counters) {
    let measured = prev.and_then(|p| {
        let dt = now_ts.checked_sub(p.ts)?;
        if dt < MIN_INTERVAL_NANOS {
            return None;
        }
        let elapsed = dt as f64 / 1e9;
        Some(Rates {
            cpu: metrics::cpu_percent(&p.counters, now),
            net_in: metrics::rate(p.counters.net_rx, now.net_rx, elapsed),
            net_out: metrics::rate(p.counters.net_tx, now.net_tx, elapsed),
        })
    });

    // Too soon to measure: show what was last actually measured. Publishing 0
    // would be a claim about the network rather than the absence of one.
    let rates = measured
        .or_else(|| prev.and_then(|p| p.rates))
        .unwrap_or_default();

    match (measured, prev) {
        (None, Some(p)) => (rates, p.ts, p.counters),
        _ => (rates, now_ts, *now),
    }
}

pub fn path() -> PathBuf {
    let user = std::env::var("USER").unwrap_or_else(|_| "unknown".into());
    std::env::temp_dir().join(format!("tmuxm-state-{user}"))
}

/// Monotonic nanoseconds since boot.
pub fn now() -> u128 {
    let mut ts = libc::timespec {
        tv_sec: 0,
        tv_nsec: 0,
    };
    // SAFETY: `ts` is a live timespec, which is all clock_gettime writes.
    unsafe { libc::clock_gettime(libc::CLOCK_MONOTONIC, &mut ts) };
    ts.tv_sec as u128 * 1_000_000_000 + ts.tv_nsec as u128
}

pub fn load() -> Option<State> {
    parse(&std::fs::read_to_string(path()).ok()?)
}

pub fn parse(s: &str) -> Option<State> {
    let f = |key: &str| -> Option<u128> {
        s.lines()
            .find(|l| l.starts_with(key) && l.as_bytes().get(key.len()) == Some(&b' '))?
            .split_whitespace()
            .nth(1)?
            .parse()
            .ok()
    };
    Some(State {
        ts: f("ts")?,
        counters: Counters {
            cpu_idle: f("cpu_idle")? as u64,
            cpu_total: f("cpu_total")? as u64,
            net_rx: f("net_rx")? as u64,
            net_tx: f("net_tx")? as u64,
        },
        // All three or none: a partial set would mix a fresh reading with a
        // stale one and there would be no way to tell from the file.
        rates: match (f("cpu_pct"), f("rate_rx"), f("rate_tx")) {
            (Some(c), Some(rx), Some(tx)) => Some(Rates {
                cpu: c as u32,
                net_in: rx as u64,
                net_out: tx as u64,
            }),
            _ => None,
        },
        // Absent gpu_at means the GPU has never been asked. A gpu_at with no
        // reading beside it means it was asked and there is nothing there —
        // the same "omit, never zero" convention the old cache used, so a real
        // idle GPU and a missing one can still never be confused.
        gpu: f("gpu_at").map(|at| GpuSample {
            at,
            reading: match (f("gpu"), f("vram")) {
                (Some(g), Some(v)) => Some((g as u32, v as u32)),
                _ => None,
            },
        }),
    })
}

pub fn render(st: &State) -> String {
    let mut out = format!(
        "ts {}\ncpu_idle {}\ncpu_total {}\nnet_rx {}\nnet_tx {}\n",
        st.ts, st.counters.cpu_idle, st.counters.cpu_total, st.counters.net_rx, st.counters.net_tx
    );
    if let Some(r) = st.rates {
        out.push_str(&format!(
            "cpu_pct {}\nrate_rx {}\nrate_tx {}\n",
            r.cpu, r.net_in, r.net_out
        ));
    }
    if let Some(g) = st.gpu {
        out.push_str(&format!("gpu_at {}\n", g.at));
        if let Some((util, vram)) = g.reading {
            out.push_str(&format!("gpu {util}\nvram {vram}\n"));
        }
    }
    out
}

/// Write-temp-then-rename, as the cache did.
///
/// Two tmux servers can render at the same instant, so this races by design.
/// The rename makes the race harmless: a loser costs one skewed interval, never
/// a torn read. The temp name carries the pid so the two writers cannot collide
/// on the temp file itself.
pub fn save(st: &State) {
    let _ = write_atomic(&path(), &render(st));
}

/// Where the half-written file lives before the rename makes it visible.
fn tmp_path(final_path: &Path) -> PathBuf {
    final_path.with_extension(format!("tmp.{}", std::process::id()))
}

/// Write `body` so a reader sees either the old file or the new one, never a
/// half of either.
///
/// `create_new`, not `create`: the state lives in a temp directory that is
/// world-writable on Linux, and the temp name is derived from the user and the
/// pid, so it is guessable. `File::create` is O_CREAT|O_TRUNC and *follows
/// symlinks*, so anyone able to pre-create that path could have this process
/// truncate and overwrite a file it owns. O_EXCL makes an existing path an
/// error instead of a target. macOS is not exposed — its $TMPDIR is private per
/// user — which is precisely why this would go unnoticed on the machine it was
/// written on.
///
/// The rename needs no such care: rename(2) replaces a destination symlink
/// rather than following it.
fn write_atomic(final_path: &Path, body: &str) -> std::io::Result<()> {
    let tmp = tmp_path(final_path);
    let open = || {
        std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&tmp)
    };
    let mut f = match open() {
        Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {
            // A crash between create and rename leaves a temp file behind, and
            // pids are recycled, so refusing forever is not an option. Unlink
            // does not follow symlinks, and the retry is still O_EXCL: if an
            // attacker wins the gap and re-creates the path, this fails safely
            // rather than writing through it.
            std::fs::remove_file(&tmp)?;
            open()?
        }
        other => other?,
    };
    f.write_all(body.as_bytes())?;
    match std::fs::rename(&tmp, final_path) {
        Ok(()) => Ok(()),
        Err(e) => {
            let _ = std::fs::remove_file(&tmp);
            Err(e)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A scratch directory of our own, so these never touch the real state file.
    fn scratch(tag: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("tmuxm-t-{}-{tag}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(&d).unwrap();
        d
    }

    /// The state file lives in a temp directory that is world-writable on Linux
    /// (macOS gives each user a private $TMPDIR, which is why this would never
    /// show up here). The temp name is derived from the user and the pid, so it
    /// is guessable: another user can pre-create it as a symlink and have this
    /// process truncate whatever it points at.
    #[test]
    fn a_pre_created_symlink_is_never_followed() {
        let d = scratch("symlink");
        let victim = d.join("victim");
        std::fs::write(&victim, "untouched").unwrap();

        let final_path = d.join("state");
        std::os::unix::fs::symlink(&victim, tmp_path(&final_path)).unwrap();

        let _ = write_atomic(&final_path, "state written through the link");

        assert_eq!(
            std::fs::read_to_string(&victim).unwrap(),
            "untouched",
            "the symlink was followed and someone else's file was overwritten"
        );
        let _ = std::fs::remove_dir_all(&d);
    }

    /// Nothing here is secret, but a predictable world-readable file in a shared
    /// directory is free to tighten.
    #[test]
    fn the_state_file_is_private_to_its_owner() {
        use std::os::unix::fs::PermissionsExt;
        let d = scratch("mode");
        let final_path = d.join("state");
        write_atomic(&final_path, "ts 1\n").unwrap();
        let mode = std::fs::metadata(&final_path).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o600, "state file is {mode:o}, expected 600");
        let _ = std::fs::remove_dir_all(&d);
    }

    /// A leftover temp file from a crashed run with a recycled pid must not wedge
    /// saving for good.
    #[test]
    fn a_stale_temp_file_does_not_block_saving() {
        let d = scratch("stale");
        let final_path = d.join("state");
        std::fs::write(tmp_path(&final_path), "leftover").unwrap();
        write_atomic(&final_path, "fresh").unwrap();
        assert_eq!(std::fs::read_to_string(&final_path).unwrap(), "fresh");
        let _ = std::fs::remove_dir_all(&d);
    }

    fn sample(gpu: Option<GpuSample>) -> State {
        State {
            ts: 123_456_789_000,
            counters: Counters {
                cpu_idle: 900,
                cpu_total: 1000,
                net_rx: 12_000_000,
                net_tx: 4_000_000,
            },
            rates: Some(Rates {
                cpu: 7,
                net_in: 9631,
                net_out: 198_321,
            }),
            gpu,
        }
    }

    #[test]
    fn rates_round_trip_and_are_all_or_nothing() {
        let st = sample(None);
        assert_eq!(parse(&render(&st)).unwrap().rates, st.rates);
        let mut bare = sample(None);
        bare.rates = None;
        assert_eq!(parse(&render(&bare)).unwrap().rates, None);
        // A half-written set must not be read as a reading.
        let partial = "ts 1\ncpu_idle 1\ncpu_total 2\nnet_rx 3\nnet_tx 4\ncpu_pct 9\n";
        assert_eq!(parse(partial).unwrap().rates, None);
    }

    #[test]
    fn round_trips() {
        for gpu in [
            None,
            Some(GpuSample {
                at: 5,
                reading: Some((9, 56)),
            }),
            Some(GpuSample {
                at: 5,
                reading: None,
            }),
        ] {
            let st = sample(gpu);
            let back = parse(&render(&st)).expect("round trip");
            assert_eq!(back.ts, st.ts);
            assert_eq!(back.counters, st.counters);
            assert_eq!(back.gpu, gpu);
        }
    }

    #[test]
    fn a_gpuless_machine_is_remembered_as_such() {
        // "asked, nothing there" must survive the round trip distinctly from
        // "never asked", or a machine with no GPU pays NVML on every refresh.
        let never = parse(&render(&sample(None))).unwrap();
        let asked = parse(&render(&sample(Some(GpuSample {
            at: 7,
            reading: None,
        }))))
        .unwrap();
        assert!(never.gpu.is_none());
        assert_eq!(
            asked.gpu,
            Some(GpuSample {
                at: 7,
                reading: None
            })
        );
    }

    #[test]
    fn gpu_reading_expires() {
        let st = sample(Some(GpuSample {
            at: 1_000,
            reading: Some((9, 56)),
        }));
        assert_eq!(st.fresh_gpu(1_000), Some(Some((9, 56))), "just taken");
        assert_eq!(st.fresh_gpu(1_000 + GPU_TTL_NANOS - 1), Some(Some((9, 56))));
        assert_eq!(st.fresh_gpu(1_000 + GPU_TTL_NANOS), None, "expired");
        assert_eq!(sample(None).fresh_gpu(0), None, "never sampled");
    }

    #[test]
    fn a_backward_clock_expires_rather_than_sticks() {
        // now < at can only mean the state file outlived a reboot. Re-ask
        // rather than trusting a reading from a previous boot forever.
        let st = sample(Some(GpuSample {
            at: 10_000,
            reading: Some((9, 56)),
        }));
        assert_eq!(st.fresh_gpu(5_000), None);
    }

    #[test]
    fn a_missing_or_partial_file_is_simply_no_previous_sample() {
        assert!(parse("").is_none());
        assert!(parse("ts 1\ncpu_idle 2\n").is_none(), "truncated write");
        assert!(parse("garbage\n").is_none());
    }

    #[test]
    fn key_matching_is_exact() {
        // "cpu_total" must not satisfy a lookup for "cpu_idle", and a prefix
        // like "ts_other" must not satisfy "ts".
        let s = "ts 5\ncpu_idle 1\ncpu_total 2\nnet_rx 3\nnet_tx 4\n";
        let st = parse(s).unwrap();
        assert_eq!(st.ts, 5);
        assert_eq!(st.counters.cpu_idle, 1);
        assert_eq!(st.counters.cpu_total, 2);
        assert_eq!(st.counters.net_rx, 3);
        assert_eq!(st.counters.net_tx, 4);
    }

    fn with(ts: u128, rx: u64, rates: Option<Rates>) -> State {
        State {
            ts,
            counters: Counters {
                cpu_idle: 0,
                cpu_total: 1000,
                net_rx: rx,
                net_tx: 0,
            },
            rates,
            gpu: None,
        }
    }

    #[test]
    fn a_usable_interval_is_measured() {
        let prev = with(0, 0, None);
        let now = Counters {
            cpu_idle: 500,
            cpu_total: 2000,
            net_rx: 4000,
            net_tx: 0,
        };
        let (r, ts, c) = resolve(Some(&prev), 2_000_000_000, &now);
        assert_eq!(r.net_in, 2000, "4000 B over 2 s");
        assert_eq!(ts, 2_000_000_000, "baseline advances");
        assert_eq!(c, now);
    }

    /// The reported bug: two renders 3 ms apart published 0 B/s, and whichever
    /// landed last is what the bar showed.
    #[test]
    fn a_three_millisecond_window_reuses_the_last_real_reading() {
        let last = Rates {
            cpu: 12,
            net_in: 9631,
            net_out: 198_321,
        };
        let prev = with(2_000_000_000, 4000, Some(last));
        // 3 ms later, and nothing has moved.
        let now = Counters {
            cpu_idle: 0,
            cpu_total: 1000,
            net_rx: 4000,
            net_tx: 0,
        };
        let (r, ts, c) = resolve(Some(&prev), 2_003_000_000, &now);
        assert_eq!(r, last, "shows the previous measurement, not zero");
        assert_eq!(ts, prev.ts, "baseline is kept, not spent");
        assert_eq!(c, prev.counters);
    }

    #[test]
    fn a_short_window_with_nothing_to_reuse_is_still_zero() {
        // Honest: on the very first renders there is no measurement to show.
        let prev = with(1_000_000_000, 0, None);
        let now = Counters {
            cpu_idle: 0,
            cpu_total: 1000,
            net_rx: 50,
            net_tx: 0,
        };
        let (r, _, _) = resolve(Some(&prev), 1_001_000_000, &now);
        assert_eq!(r, Rates::default());
    }

    #[test]
    fn the_first_render_ever_establishes_a_baseline() {
        let now = Counters {
            cpu_idle: 1,
            cpu_total: 2,
            net_rx: 7,
            net_tx: 8,
        };
        let (r, ts, c) = resolve(None, 500, &now);
        assert_eq!(r, Rates::default());
        assert_eq!((ts, c), (500, now));
    }

    #[test]
    fn monotonic_clock_moves_forward() {
        let a = now();
        let b = now();
        assert!(b >= a, "CLOCK_MONOTONIC went backwards: {a} -> {b}");
        assert!(a > 0);
    }
}
