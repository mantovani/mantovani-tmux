//! The previous sample, kept between invocations.
//!
//! This file is what lets the binary be stateless and still show a rate. It
//! replaces the whole sampler daemon: the pidfile, the `noclobber` claim, the
//! stale takeover, the TERM trap and the restart dance all existed to keep one
//! long-lived process alive purely so it could remember the last reading.

use crate::metrics::Counters;
use std::io::Write;
use std::path::PathBuf;

pub struct State {
    /// CLOCK_MONOTONIC nanoseconds. System-wide and unaffected by NTP, so it is
    /// comparable across two separate processes — which is the property the
    /// wall clock lacked and that made every rate off by up to 2x.
    pub ts: u128,
    pub counters: Counters,
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
    let final_path = path();
    let tmp = final_path.with_extension(format!("tmp.{}", std::process::id()));
    let ok = std::fs::File::create(&tmp)
        .and_then(|mut f| f.write_all(render(st).as_bytes()))
        .is_ok();
    if ok && std::fs::rename(&tmp, &final_path).is_err() {
        let _ = std::fs::remove_file(&tmp);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample(gpu: Option<GpuSample>) -> State {
        State {
            ts: 123_456_789_000,
            counters: Counters {
                cpu_idle: 900,
                cpu_total: 1000,
                net_rx: 12_000_000,
                net_tx: 4_000_000,
            },
            gpu,
        }
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

    #[test]
    fn monotonic_clock_moves_forward() {
        let a = now();
        let b = now();
        assert!(b >= a, "CLOCK_MONOTONIC went backwards: {a} -> {b}");
        assert!(a > 0);
    }
}
