//! Linux readings, straight out of /proc and /sys.
//!
//! Every parser takes a `&str` rather than a path, so the fixtures the shell
//! suite drove through `TMUXM_PROC_STAT` and friends drive these directly. The
//! environment seams are gone because a function that takes its input as an
//! argument never needed one.

use super::Counters;
use std::fs;
use std::path::Path;

pub fn counters() -> Counters {
    let (cpu_idle, cpu_total) = fs::read_to_string("/proc/stat")
        .ok()
        .and_then(|s| parse_stat(&s))
        .unwrap_or((0, 0));
    let want = phys_ifaces(Path::new("/sys/class/net"));
    let (net_rx, net_tx) = fs::read_to_string("/proc/net/dev")
        .map(|s| parse_net_dev(&s, &want))
        .unwrap_or((0, 0));
    Counters { cpu_idle, cpu_total, net_rx, net_tx }
}

pub fn mem_percent() -> Option<u32> {
    parse_meminfo(&fs::read_to_string("/proc/meminfo").ok()?)
}

/// `(idle, total)` from the aggregate `cpu ` line.
///
/// Fields 2..9 are user, nice, system, idle, iowait, irq, softirq, **steal**.
/// Steal is time the hypervisor gave to another guest; leaving it out of the
/// total made a contended VM look quiet — 10% against a true 25%. guest (10)
/// and guest_nice (11) are deliberately not summed: the kernel already counts
/// them inside user and nice, so adding them double-counts.
///
/// The trailing space in `"cpu "` matters — it is what excludes `cpu0`, `cpu1`.
pub fn parse_stat(s: &str) -> Option<(u64, u64)> {
    let line = s.lines().find(|l| l.starts_with("cpu "))?;
    let v: Vec<u64> = line
        .split_whitespace()
        .skip(1)
        .take(8)
        .map(|f| f.parse().unwrap_or(0))
        .collect();
    if v.len() < 4 {
        return None;
    }
    Some((v[3], v.iter().sum()))
}

/// Used memory as a percentage, truncated.
///
/// `MemAvailable` is the kernel's own estimate of what a new allocation could
/// get, which is a far better "free" than `MemFree` — it accounts for
/// reclaimable page cache.
pub fn parse_meminfo(s: &str) -> Option<u32> {
    let field = |k: &str| -> Option<u64> {
        s.lines()
            .find(|l| l.starts_with(k))?
            .split_whitespace()
            .nth(1)?
            .parse()
            .ok()
    };
    let total = field("MemTotal:")?;
    let avail = field("MemAvailable:")?;
    if total == 0 {
        return None;
    }
    Some((total.saturating_sub(avail) * 100 / total) as u32)
}

/// Interfaces backed by real hardware: they have a `device` symlink, virtual
/// ones (lo, docker0, veth*, br-*, bond0, tun0, wg0, VLAN sub-interfaces) do
/// not. Read fresh every render so hotplug — USB tethering, a docked NIC — is
/// picked up without anything to restart.
pub fn phys_ifaces(root: &Path) -> Vec<String> {
    let Ok(entries) = fs::read_dir(root) else {
        return Vec::new();
    };
    let mut out: Vec<String> = entries
        .flatten()
        .filter(|e| e.path().join("device").exists())
        .filter_map(|e| e.file_name().into_string().ok())
        .collect();
    out.sort();
    out
}

/// `(rx_bytes, tx_bytes)` summed over the physical interfaces.
///
/// Summing every interface double-counts: a packet to a container or over a VPN
/// crosses the overlay device (docker0, veth*, tun0) *and* the physical NIC it
/// leaves through. Counting only hardware still measures overlay traffic,
/// because it has to cross a NIC to reach the network at all.
///
/// An empty `want` means no hardware interface exists — we are inside a
/// container or a netns, where eth0 is itself a veth. Nothing can be
/// double-counted there, so sum every non-`lo` interface rather than reporting
/// a flat zero.
///
/// The shell had to fight this file's formatting: it right-pads the name into a
/// 6-char column, so `    lo:` arrives with leading whitespace and `enp1s0:`
/// does not. Splitting on `/[ :]+/` made an empty first field for short names
/// only, shifting every column by one and reading RX/TX *packets* as bytes on
/// exactly the interfaces carrying real traffic. Splitting the name off at the
/// colon and letting whitespace handle the rest cannot reproduce that.
pub fn parse_net_dev(s: &str, want: &[String]) -> (u64, u64) {
    let filter = !want.is_empty();
    let mut rx = 0u64;
    let mut tx = 0u64;
    for line in s.lines().skip(2) {
        let Some((name, rest)) = line.split_once(':') else { continue };
        let name = name.trim();
        if name == "lo" {
            continue;
        }
        if filter && !want.iter().any(|w| w == name) {
            continue;
        }
        let f: Vec<&str> = rest.split_whitespace().collect();
        if f.len() < 9 {
            continue;
        }
        rx += f[0].parse::<u64>().unwrap_or(0);
        tx += f[8].parse::<u64>().unwrap_or(0);
    }
    (rx, tx)
}

#[cfg(test)]
mod tests {
    use super::*;

    // Fixture carried over from shell section 18.
    const STAT_A: &str = "cpu  100 0 0 900 0 0 0 0 0 0\ncpu0 1 2 3\n";
    const STAT_B: &str = "cpu  200 0 0 1800 0 0 0 200 0 0\ncpu0 1 2 3\n";

    #[test]
    fn steal_counts_toward_busy_not_idle() {
        let (i0, t0) = parse_stat(STAT_A).unwrap();
        let (i1, t1) = parse_stat(STAT_B).unwrap();
        let prev = Counters { cpu_idle: i0, cpu_total: t0, ..Default::default() };
        let now = Counters { cpu_idle: i1, cpu_total: t1, ..Default::default() };
        // 900 idle of 1200 total delta => 25% busy. Omitting steal says 10%.
        assert_eq!(super::super::cpu_percent(&prev, &now), 25);
    }

    #[test]
    fn parse_stat_ignores_per_core_lines() {
        assert_eq!(parse_stat(STAT_A), Some((900, 1000)));
        assert_eq!(parse_stat("cpu0 1 2 3 4 5 6 7 8\n"), None, "no aggregate line");
    }

    #[test]
    fn parse_stat_excludes_guest_columns() {
        // guest=500, guest_nice=500 must NOT be summed; total stays 1000.
        assert_eq!(parse_stat("cpu  100 0 0 900 0 0 0 0 500 500\n"), Some((900, 1000)));
    }

    #[test]
    fn mem_is_total_minus_available() {
        let s = "MemTotal:       30135212 kB\nMemFree: 100 kB\nMemAvailable:   11479000 kB\n";
        assert_eq!(parse_meminfo(s), Some(61)); // 61.908% truncates to 61
        assert_eq!(parse_meminfo("MemTotal: 0 kB\nMemAvailable: 0 kB\n"), None);
        assert_eq!(parse_meminfo("MemTotal: 100 kB\n"), None, "no MemAvailable");
    }

    // Fixture carried over from shell section 15b: short names are left-padded,
    // long ones are not, and only wlo1/enp1s0 are physical.
    const NET_DEV: &str = "\
Inter-|   Receive                                                |  Transmit
 face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets
    lo: 5000000   100    0    0    0     0          0         0   5000000   100
  wlo1: 2000000   200    0    0    0     0          0         0   1000000   200
enp1s0: 10000000  300    0    0    0     0          0         0   3000000   300
docker0: 900000   400    0    0    0     0          0         0   400000    400
";

    #[test]
    fn throughput_reads_bytes_on_physical_interfaces_only() {
        let want = vec!["enp1s0".to_string(), "wlo1".to_string()];
        assert_eq!(parse_net_dev(NET_DEV, &want), (12_000_000, 4_000_000));
    }

    #[test]
    fn padding_does_not_shift_columns() {
        // wlo1 is padded, enp1s0 is not. If the padding shifted fields we would
        // read packets (200/300) instead of bytes on one of them.
        assert_eq!(parse_net_dev(NET_DEV, &["wlo1".to_string()]), (2_000_000, 1_000_000));
        assert_eq!(parse_net_dev(NET_DEV, &["enp1s0".to_string()]), (10_000_000, 3_000_000));
    }

    #[test]
    fn container_fallback_sums_every_non_loopback() {
        // No physical interface: sum all but lo rather than reporting zero.
        assert_eq!(parse_net_dev(NET_DEV, &[]), (12_900_000, 4_400_000));
    }

    #[test]
    fn loopback_is_never_counted() {
        assert_eq!(parse_net_dev(NET_DEV, &["lo".to_string()]), (0, 0));
    }
}
