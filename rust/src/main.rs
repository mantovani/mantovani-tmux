//! tmuxm — the status bar for the tmuxm tmux config.
//!
//! Two subcommands, each one process, each run by tmux on its own refresh:
//!
//!   tmuxm render <accent> <dim>   the metric block
//!   tmuxm tz                      the UTC offset
//!
//! It replaces a bash daemon and seven shell renderers that together spawned
//! fourteen processes every two seconds.

#![forbid(unsafe_op_in_unsafe_fn)]
#![deny(clippy::unwrap_used, clippy::expect_used)]

mod bar;
mod gpu;
mod metrics;
mod state;

use bar::Metrics;

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match args.first().map(String::as_str) {
        Some("render") => match (args.get(1), args.get(2)) {
            (Some(accent), Some(dim)) => print!("{}", render(accent, dim)),
            _ => usage(1),
        },
        Some("tz") => print!("{}", bar::offset(utc_offset_secs())),
        Some("-h") | Some("--help") => usage(0),
        _ => usage(1),
    }
}

fn usage(code: i32) -> ! {
    // Usage goes to stderr so a misconfigured status bar shows nothing rather
    // than printing this into the bar.
    eprintln!("usage: tmuxm render <accent-hex> <dim-hex>\n       tmuxm tz");
    std::process::exit(code)
}

/// Build one refresh.
///
/// Nothing here may panic. A status bar that vanishes is worse than one showing
/// a zero, so every reading is an `Option` and every failure degrades to the
/// same output a missing value always produced.
fn render(accent: &str, dim: &str) -> String {
    let now_counters = metrics::counters();
    let now_ts = state::now();
    let prev = state::load();

    // No previous sample — first render after boot, or after /tmp was cleared.
    // The rates read 0 and correct themselves on the next refresh 2 s later.
    let (cpu, net_in, net_out) = match &prev {
        Some(p) if now_ts > p.ts => {
            let elapsed = (now_ts - p.ts) as f64 / 1e9;
            (
                metrics::cpu_percent(&p.counters, &now_counters),
                metrics::rate(p.counters.net_rx, now_counters.net_rx, elapsed),
                metrics::rate(p.counters.net_tx, now_counters.net_tx, elapsed),
            )
        }
        _ => (0, 0, 0),
    };

    // NVML costs ~21.7 ms in a fresh process, almost all of it mapping
    // libnvidia-ml.so — a cost a daemon pays once and a stateless binary would
    // pay every refresh. Reuse the last reading while it is fresh, so the GPU
    // is asked on roughly every third render instead of every one.
    let reading = match prev.as_ref().and_then(|p| p.fresh_gpu(now_ts)) {
        Some(cached) => cached,
        None => gpu::sample(),
    };
    let gpu_at = match prev.as_ref().and_then(|p| p.fresh_gpu(now_ts)) {
        Some(_) => prev.as_ref().and_then(|p| p.gpu).map(|g| g.at).unwrap_or(now_ts),
        None => now_ts,
    };

    state::save(&state::State {
        ts: now_ts,
        counters: now_counters,
        gpu: Some(state::GpuSample { at: gpu_at, reading }),
    });

    let (gpu, vram) = match reading {
        Some((g, v)) => (Some(g), Some(v)),
        None => (None, None),
    };

    bar::block(
        accent,
        dim,
        &Metrics { cpu, mem: metrics::mem_percent().unwrap_or(0), gpu, vram, net_in, net_out },
    )
}

/// Seconds east of UTC for this machine, right now.
///
/// Read live rather than baked in at install time so a DST transition is picked
/// up on the next refresh. `tm_gmtoff` gives it directly — no timezone database
/// parsing, and no date crate.
fn utc_offset_secs() -> i64 {
    // SAFETY: `t` and `tm` are live locals; localtime_r writes only into `tm`
    // and is the reentrant form, so it needs no external synchronisation.
    unsafe {
        let t = libc::time(std::ptr::null_mut());
        let mut tm: libc::tm = std::mem::zeroed();
        if libc::localtime_r(&t, &mut tm).is_null() {
            return 0;
        }
        tm.tm_gmtoff as i64
    }
}
