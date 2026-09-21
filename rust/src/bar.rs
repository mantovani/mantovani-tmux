//! Everything that turns a number into the characters tmux draws.
//!
//! Pure functions over plain values: no I/O, no clock, no environment. That is
//! what lets the suite pin the formats directly instead of going through a
//! cache file and a stubbed `$USER`.

/// Load is encoded by the HEIGHT of the blocks, never by colour: the bar is the
/// machine's colour at 1% and at 100%. Height survives every kind of
/// colour-blindness, and keeps one machine looking like one colour.
const BLOCKS: [char; 8] = ['▁', '▂', '▃', '▄', '▅', '▆', '▇', '█'];

/// Four cells, each covering a 25-point band, integer-truncating exactly as the
/// shell did. `h == 0` is `▁`, not a blank: the floor of the bar is always four
/// visible cells, which is what keeps the width fixed.
pub fn blocks(pct: u32) -> String {
    (0..4)
        .map(|i| {
            let h = (pct as i64 - i * 25) * 8 / 25;
            BLOCKS[h.clamp(0, 7) as usize]
        })
        .collect()
}

/// A bar plus its percentage: **always 9 visible columns** (`▁▁▁▁   0%`
/// .. `████ 100%`). The status bar never jitters.
///
/// Clamps here rather than trusting its callers. Every producer already caps at
/// 100, but this is the one place all of them pass through, and the shell
/// learned the hard way that clamping the blocks while leaving the number alone
/// draws four full cells beside the caption "150%".
pub fn gauge(pct: u32) -> String {
    let pct = pct.min(100);
    format!("{} {:>3}%", blocks(pct), pct)
}

/// Throughput, **always 6 columns**: `    0B`, ` 99.3K`, `999.9K`, `  1.2M`.
/// Binary divisors, matching the thresholds. Emits no colour of its own — the
/// colour comes from the enclosing segment.
pub fn throughput(bps: u64) -> String {
    const K: u64 = 1 << 10;
    const M: u64 = 1 << 20;
    const G: u64 = 1 << 30;
    const T: u64 = 1 << 40;
    match bps {
        b if b < K => format!("{b:>5}B"),
        b if b < M => format!("{:>5.1}K", b as f64 / K as f64),
        b if b < G => format!("{:>5.1}M", b as f64 / M as f64),
        b if b < T => format!("{:>5.1}G", b as f64 / G as f64),
        b if b < 1000 * T => format!("{:>5.1}T", b as f64 / T as f64),
        // Unreachable from real hardware, but the width is a contract and a
        // ladder that runs out of tiers silently widens the field.
        _ => "999.9T".to_string(),
    }
}

/// UTC offset in the bar's shorthand: `0` at UTC with the sign dropped, `-3` on
/// a whole hour, `+5:30` otherwise. Rendered live rather than baked in at
/// install time so a DST transition is picked up on the next refresh.
pub fn offset(secs: i64) -> String {
    let (h, m) = (secs.abs() / 3600, (secs.abs() % 3600) / 60);
    if h == 0 && m == 0 {
        return "0".to_string();
    }
    let sign = if secs < 0 { '-' } else { '+' };
    if m == 0 {
        format!("{sign}{h}")
    } else {
        format!("{sign}{h}:{m:02}")
    }
}

/// Assemble the metric block tmux splices into `status-right`.
///
/// The caller's template supplies the leading `#[bg=#000000,fg=<accent>]` and
/// everything from `@#h` onward, so this emits the segments and the separators
/// between them — including a leading and trailing space, which the template
/// relies on.
///
/// `gpu`/`vram` are `None` on a machine with no readable GPU, and then no GPU
/// segment is emitted at all: not a placeholder, not a flat 0%, nothing to
/// notice. That guarantee used to be decided at install time; drawing the whole
/// block here means it can be decided per invocation instead.
pub fn block(accent: &str, dim: &str, m: &Metrics) -> String {
    let sep = format!("#[fg=#{dim}]│#[fg=#{accent}]");
    let mut out = format!(" CPU {} {sep} MEM {}", gauge(m.cpu), gauge(m.mem));
    if let (Some(g), Some(v)) = (m.gpu, m.vram) {
        out.push_str(&format!(" {sep} GPU {} {sep} VRAM {}", gauge(g), gauge(v)));
    }
    out.push_str(&format!(
        " {sep} ↓ {} ↑ {} ",
        throughput(m.net_in),
        throughput(m.net_out)
    ));
    out
}

/// One refresh worth of readings. Absent optional metrics are `None`, never 0 —
/// a real idle GPU and a missing GPU must not render the same.
#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub struct Metrics {
    pub cpu: u32,
    pub mem: u32,
    pub gpu: Option<u32>,
    pub vram: Option<u32>,
    pub net_in: u64,
    pub net_out: u64,
}

#[cfg(test)]
mod tests {
    use super::*;

    // The exact strings the shell suite pinned, carried over verbatim.
    #[test]
    fn bar_height_tracks_load() {
        assert_eq!(blocks(1), "▁▁▁▁");
        assert_eq!(blocks(100), "████");
        assert_eq!(gauge(42), "█▆▁▁  42%");
        assert_eq!(gauge(25), "█▁▁▁  25%");
        assert_eq!(gauge(50), "██▁▁  50%");
        assert_eq!(gauge(0), "▁▁▁▁   0%");
    }

    #[test]
    fn gauge_is_always_nine_columns() {
        for pct in 0..=100 {
            assert_eq!(gauge(pct).chars().count(), 9, "at {pct}%");
        }
    }

    /// Shell section 17 pinned this against a cache holding junk. There is no
    /// text cache any more — every producer hands `gauge` a `u32` — so what
    /// survives is the part that still has meaning: an out-of-range reading
    /// renders as a full bar captioned 100%, never "150%".
    #[test]
    fn an_impossible_reading_clamps_rather_than_overflowing_the_caption() {
        assert_eq!(gauge(150), "████ 100%");
        assert_eq!(gauge(u32::MAX), "████ 100%");
        assert_eq!(gauge(100), "████ 100%");
    }

    #[test]
    fn throughput_is_always_six_columns() {
        assert_eq!(throughput(0), "    0B");
        assert_eq!(throughput(1023), " 1023B");
        assert_eq!(throughput(1024), "  1.0K");
        assert_eq!(throughput(101683), " 99.3K");
        assert_eq!(throughput(1258291), "  1.2M");
        assert_eq!(throughput(3_650_722_201), "  3.4G");
        assert_eq!(throughput(u64::MAX), "999.9T", "saturates, never widens");
        for b in [
            0u64,
            1,
            1023,
            1024,
            99999,
            1 << 20,
            1 << 30,
            1 << 40,
            u64::MAX / 2,
            u64::MAX,
        ] {
            assert_eq!(throughput(b).chars().count(), 6, "at {b} B/s");
        }
    }

    #[test]
    fn offset_matches_the_pinned_zones() {
        assert_eq!(offset(-3 * 3600), "-3"); // America/Sao_Paulo
        assert_eq!(offset(0), "0"); // UTC — sign dropped
        assert_eq!(offset(5 * 3600 + 1800), "+5:30"); // Asia/Kolkata
        assert_eq!(offset(12 * 3600 + 2700), "+12:45"); // Pacific/Chatham
        assert_eq!(offset(9 * 3600), "+9"); // Asia/Tokyo
        assert_eq!(offset(-(3 * 3600 + 1800)), "-3:30"); // negative half hour
    }

    #[test]
    fn no_gpu_emits_no_gpu_segment() {
        let m = Metrics {
            cpu: 7,
            mem: 54,
            net_in: 0,
            net_out: 0,
            ..Default::default()
        };
        let out = block("ff69b4", "7a004b", &m);
        assert!(!out.contains("GPU"), "{out}");
        assert!(!out.contains("VRAM"), "{out}");
        assert_eq!(
            out,
            " CPU ▃▁▁▁   7% #[fg=#7a004b]│#[fg=#ff69b4] MEM ██▂▁  54% \
             #[fg=#7a004b]│#[fg=#ff69b4] ↓     0B ↑     0B "
        );
    }

    #[test]
    fn gpu_machine_gets_both_segments() {
        let m = Metrics {
            cpu: 7,
            mem: 54,
            gpu: Some(9),
            vram: Some(56),
            net_in: 9631,
            net_out: 198_321,
        };
        let out = block("ff69b4", "7a004b", &m);
        assert!(out.contains(" GPU ▃▁▁▁   9% "), "{out}");
        assert!(out.contains(" VRAM ██▂▁  56% "), "{out}");
        assert!(out.contains("↓   9.4K ↑ 193.7K "), "{out}");
    }
}
