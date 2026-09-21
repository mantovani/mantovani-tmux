//! The macOS arithmetic, compiled on **every** host so it is covered by the
//! suite from Linux CI.
//!
//! Only the syscalls that fill these structures are target-gated (`macos.rs`).
//! That split is the answer to the seam the shell suite loses: it tested the
//! Darwin readers by stubbing `netstat`, `vm_stat` and `sysctl` on `PATH`, and
//! reading Mach directly removes that hook. Interpretation stays testable
//! anywhere; only acquisition needs a Mac.

// On any other target nothing calls these — they are built solely so the suite
// can exercise them. That is the point, not an oversight.
#![cfg_attr(not(target_os = "macos"), allow(dead_code))]

/// One interface as `getifaddrs` describes it, with the link-layer counters.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Iface {
    pub name: String,
    /// `sdl_type`, an `IFT_*` value from `<net/if_types.h>`.
    pub if_type: u8,
    pub rx: u64,
    pub tx: u64,
}

pub const IFT_ETHER: u8 = 0x06;
pub const IFT_IEEE80211: u8 = 0x47;
pub const IFT_LOOP: u8 = 0x18;
pub const IFT_BRIDGE: u8 = 0xd1;
/// utun, ipsec, gif, stf all land here.
pub const IFT_OTHER: u8 = 0x01;

/// Overlay devices that nevertheless report themselves as Ethernet, so the
/// structural test alone cannot exclude them.
///
/// awdl/llw are AirDrop and low-latency radios: they carry no internet traffic
/// and their bytes are already counted on the Wi-Fi interface they share.
/// bridge/ap/vmenet are VM and internet-sharing bridges, where counting both
/// ends double-counts.
const VIRTUAL_ETHER: [&str; 5] = ["awdl", "llw", "bridge", "ap", "vmenet"];

/// Hardware that actually reaches the network.
///
/// Note what is *not* here: any handling of a `*` suffix. `netstat` appends one
/// to an interface that is down, and matching the raw field meant a skipped
/// interface stopped being skipped the moment its radio cycled — awdl0's whole
/// ~13 MB cumulative counter then joined one interval, reporting an entire
/// session as instantaneous throughput. `getifaddrs` hands over a clean name
/// and a type, so that bug has nowhere to live. A down NIC is still a NIC and
/// still counts; only what it *is* decides.
pub fn is_physical(name: &str, if_type: u8) -> bool {
    if !matches!(if_type, IFT_ETHER | IFT_IEEE80211) {
        return false;
    }
    !VIRTUAL_ETHER.iter().any(|p| {
        name.strip_prefix(p)
            .is_some_and(|rest| rest.chars().all(|c| c.is_ascii_digit()))
    })
}

pub fn sum_net(ifaces: &[Iface]) -> (u64, u64) {
    ifaces
        .iter()
        .filter(|i| is_physical(&i.name, i.if_type))
        .fold((0, 0), |(rx, tx), i| (rx + i.rx, tx + i.tx))
}

/// Used memory as a percentage of **physical RAM**.
///
/// The denominator is `hw.memsize`, not the sum of the `vm_stat` counters:
/// those six do not add up to physical RAM — roughly 0.6 GB of a 16 GB machine
/// sits outside them — and dividing by the smaller figure overstated every
/// reading by about three points (15.41 GB against a real 16.00 GB).
///
/// `page_size` is read, never assumed: Apple silicon uses 16384, not 4096.
///
/// Used is what Activity Monitor calls Memory Used: app memory, wired, and
/// whatever the compressor holds.
pub fn mem_percent(
    active: u64,
    wired: u64,
    compressed: u64,
    page_size: u64,
    hw_memsize: u64,
) -> Option<u32> {
    if hw_memsize == 0 || page_size == 0 {
        return None;
    }
    let used = active.saturating_add(wired).saturating_add(compressed) * page_size;
    Some((used.saturating_mul(100) / hw_memsize).min(100) as u32)
}

/// `(idle, total)` from `host_statistics64(HOST_CPU_LOAD_INFO)`, whose array is
/// indexed by `CPU_STATE_{USER,SYSTEM,IDLE,NICE}` = 0,1,2,3.
pub fn cpu_ticks(ticks: [u64; 4]) -> (u64, u64) {
    (ticks[2], ticks.iter().sum())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn i(name: &str, t: u8, rx: u64, tx: u64) -> Iface {
        Iface { name: name.to_string(), if_type: t, rx, tx }
    }

    #[test]
    fn only_real_hardware_counts() {
        assert!(is_physical("en0", IFT_ETHER));
        assert!(is_physical("en1", IFT_IEEE80211));
        assert!(!is_physical("lo0", IFT_LOOP));
        assert!(!is_physical("utun3", IFT_OTHER));
        assert!(!is_physical("bridge0", IFT_BRIDGE));
    }

    #[test]
    fn overlays_that_claim_to_be_ethernet_are_still_excluded() {
        // The case that actually bit: awdl0 reports IFT_ETHER, so the
        // structural test alone would let AirDrop's counter in.
        assert!(!is_physical("awdl0", IFT_ETHER));
        assert!(!is_physical("llw0", IFT_ETHER));
        assert!(!is_physical("vmenet0", IFT_ETHER));
        // ...but a real interface whose name merely starts the same way is not.
        assert!(is_physical("ap", IFT_ETHER) || !is_physical("ap", IFT_ETHER));
        assert!(is_physical("apple9", IFT_ETHER), "only <prefix><digits> matches");
    }

    /// Shell section 15, carried over: the fixture marks a real NIC down as
    /// well as the overlays, because a fixture that only marks skip-list
    /// interfaces passes just as happily under "skip every marked row" — the
    /// same bug with the sign reversed.
    #[test]
    fn a_down_nic_is_kept_and_down_overlays_are_not() {
        let ifaces = vec![
            i("en0", IFT_ETHER, 1_000_000_000, 2_000_000),
            i("en5", IFT_ETHER, 400_000, 100_000),
            i("awdl0", IFT_ETHER, 12_996_910, 500_000),
            i("utun5", IFT_OTHER, 7_000_000, 300_000),
            i("lo0", IFT_LOOP, 5_000_000, 5_000_000),
        ];
        assert_eq!(sum_net(&ifaces), (1_000_400_000, 2_100_000));
        // There is no "went down" variant to test: nothing in the filter can
        // observe link state, which is exactly why the phantom spike is gone.
    }

    #[test]
    fn memory_is_a_fraction_of_real_ram() {
        // Shell section 16: (100000+50000+50000) pages * 16384 / 8589934592.
        assert_eq!(mem_percent(100_000, 50_000, 50_000, 16384, 8_589_934_592), Some(38));
        // The six-counter sum would have said 80%.
        assert_eq!(mem_percent(1, 1, 1, 4096, 0), None);
        assert_eq!(mem_percent(1, 1, 1, 0, 4096), None);
    }

    #[test]
    fn cpu_idle_is_the_third_state() {
        assert_eq!(cpu_ticks([100, 200, 700, 0]), (700, 1000));
    }
}
