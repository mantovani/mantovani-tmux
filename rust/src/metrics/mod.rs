//! Reading the machine. One module per OS behind a common shape.
//!
//! The split is deliberate: everything that *interprets* a reading lives in
//! plain functions over plain values, and only the syscalls that *acquire* one
//! are `#[cfg]`-gated. That keeps the untestable surface small — the macOS
//! arithmetic is exercised by the suite on any host, even though its syscalls
//! can only run on a Mac.

#[cfg(target_os = "linux")]
pub mod linux;
#[cfg(target_os = "linux")]
use linux as sys;

// Compiled on every host: the macOS arithmetic is testable from Linux, only
// its syscalls are target-gated.
pub mod darwin;

#[cfg(target_os = "macos")]
pub mod macos;
#[cfg(target_os = "macos")]
use macos as sys;

/// The cumulative counters a rate is computed from. Meaningless alone — every
/// one of these is a monotonic total, and only the difference between two
/// readings says anything.
#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub struct Counters {
    pub cpu_idle: u64,
    pub cpu_total: u64,
    pub net_rx: u64,
    pub net_tx: u64,
}

/// Read every cumulative counter. Anything unreadable comes back as 0, which
/// the delta step then renders as "no movement" rather than as an error.
pub fn counters() -> Counters {
    sys::counters()
}

/// Memory is a level, not a rate, so it needs no previous sample.
pub fn mem_percent() -> Option<u32> {
    sys::mem_percent()
}

/// CPU busy percent from two cumulative readings.
///
/// A counter that went backwards means a reboot or a wrapped counter; report 0
/// rather than a spike. Division guards on `d_total == 0`, which happens on the
/// very first render when there is no previous sample at all.
pub fn cpu_percent(prev: &Counters, now: &Counters) -> u32 {
    let d_idle = now.cpu_idle.saturating_sub(prev.cpu_idle);
    let d_total = now.cpu_total.saturating_sub(prev.cpu_total);
    if d_total == 0 {
        return 0;
    }
    (100 - (d_idle * 100 / d_total).min(100)) as u32
}

/// Bytes per second between two readings.
///
/// `elapsed` is seconds as `f64` off the monotonic clock, not whole seconds off
/// the wall clock. That is the whole point: the shell divided by `date +%s`
/// differences, so a real 1.05 s interval was still divided by 2 and the
/// throughput came out at half. Measured ratios ran from 0.52 to 1.27.
pub fn rate(prev: u64, now: u64, elapsed: f64) -> u64 {
    if elapsed <= 0.0 {
        return 0;
    }
    (now.saturating_sub(prev) as f64 / elapsed) as u64
}

#[cfg(test)]
mod tests {
    use super::*;

    fn c(idle: u64, total: u64) -> Counters {
        Counters { cpu_idle: idle, cpu_total: total, ..Default::default() }
    }

    #[test]
    fn cpu_is_the_non_idle_share_of_the_delta() {
        assert_eq!(cpu_percent(&c(900, 1000), &c(1800, 2000)), 10);
        assert_eq!(cpu_percent(&c(0, 0), &c(50, 100)), 50);
        assert_eq!(cpu_percent(&c(0, 0), &c(0, 100)), 100);
        assert_eq!(cpu_percent(&c(0, 0), &c(100, 100)), 0);
    }

    #[test]
    fn cpu_degrades_rather_than_spikes() {
        assert_eq!(cpu_percent(&c(0, 0), &c(0, 0)), 0, "no previous sample");
        assert_eq!(cpu_percent(&c(500, 900), &c(0, 0)), 0, "counter went backwards");
    }

    #[test]
    fn rate_uses_real_elapsed_time_not_whole_seconds() {
        assert_eq!(rate(0, 2000, 2.0), 1000);
        // The defect this rewrite exists to fix: a 1.05 s interval divided as
        // if it were 2 s reported half the real throughput.
        assert_eq!(rate(0, 2100, 1.05), 2000, "not 1050");
        assert_eq!(rate(0, 1000, 0.0), 0, "no division by zero");
        assert_eq!(rate(5000, 1000, 2.0), 0, "counter reset, not a huge spike");
    }
}
