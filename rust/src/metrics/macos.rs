//! macOS acquisition: Mach, sysctl and getifaddrs.
//!
//! Deliberately thin. Every value it obtains is handed straight to
//! [`super::darwin`], which holds the arithmetic and is tested on every host.
//! This file is the part that can only be compiled and run on a Mac.
//!
//! It replaces three subprocesses per sample — `iostat`, `vm_stat`, `netstat` —
//! and with them the ~1 s block inside `iostat -c 2 -w 1`, which was the reason
//! the sampler had to be a daemon on macOS at all.

#![allow(non_camel_case_types)]
// libc deprecates mach_host_self in favour of the mach2 crate. One extra
// dependency, built on every machine, for a single symbol that is not going
// anywhere, is the wrong trade — every other dependency here was rejected for
// less.
#![allow(deprecated)]

use super::darwin::{self, Iface};
use super::Counters;
use std::ffi::CStr;
use std::ptr::addr_of;

// <mach/host_info.h>. Not taken from libc, which does not expose the CPU
// flavour on every version.
const HOST_CPU_LOAD_INFO: libc::host_flavor_t = 3;
const HOST_CPU_LOAD_INFO_COUNT: libc::mach_msg_type_number_t = 4;

#[repr(C)]
#[derive(Default)]
struct host_cpu_load_info {
    /// Indexed by CPU_STATE_{USER,SYSTEM,IDLE,NICE}.
    cpu_ticks: [u32; 4],
}

fn cpu() -> (u64, u64) {
    let mut info = host_cpu_load_info::default();
    let mut count = HOST_CPU_LOAD_INFO_COUNT;
    // SAFETY: `info` is a live, correctly sized HOST_CPU_LOAD_INFO buffer and
    // `count` describes it in 32-bit words, as host_statistics64 requires.
    let rc = unsafe {
        libc::host_statistics64(
            libc::mach_host_self(),
            HOST_CPU_LOAD_INFO,
            &mut info as *mut _ as libc::host_info64_t,
            &mut count,
        )
    };
    if rc != 0 {
        return (0, 0);
    }
    darwin::cpu_ticks(info.cpu_ticks.map(u64::from))
}

fn sysctl_u64(name: &str) -> Option<u64> {
    let cname = std::ffi::CString::new(name).ok()?;
    let mut out: u64 = 0;
    let mut len = std::mem::size_of::<u64>();
    // SAFETY: `out` is a u64 and `len` says so; sysctlbyname writes at most
    // that many bytes. `cname` outlives the call.
    let rc = unsafe {
        libc::sysctlbyname(
            cname.as_ptr(),
            &mut out as *mut _ as *mut libc::c_void,
            &mut len,
            std::ptr::null_mut(),
            0,
        )
    };
    (rc == 0).then_some(out)
}

pub fn mem_percent() -> Option<u32> {
    let mut vm: libc::vm_statistics64 = unsafe { std::mem::zeroed() };
    let mut count = (std::mem::size_of::<libc::vm_statistics64>()
        / std::mem::size_of::<libc::integer_t>())
        as libc::mach_msg_type_number_t;
    // SAFETY: as above, with a zeroed vm_statistics64 and its word count.
    let rc = unsafe {
        libc::host_statistics64(
            libc::mach_host_self(),
            libc::HOST_VM_INFO64,
            &mut vm as *mut _ as libc::host_info64_t,
            &mut count,
        )
    };
    if rc != 0 {
        return None;
    }
    // SAFETY: sysconf is always safe to call with a valid name.
    let page = unsafe { libc::sysconf(libc::_SC_PAGESIZE) };
    darwin::mem_percent(
        u64::from(vm.active_count),
        u64::from(vm.wire_count),
        u64::from(vm.compressor_page_count),
        if page > 0 { page as u64 } else { 0 },
        sysctl_u64("hw.memsize")?,
    )
}

fn ifaces() -> Vec<Iface> {
    let mut head: *mut libc::ifaddrs = std::ptr::null_mut();
    // SAFETY: getifaddrs writes a list head we free below.
    if unsafe { libc::getifaddrs(&mut head) } != 0 {
        return Vec::new();
    }
    let mut out = Vec::new();
    let mut cur = head;
    // SAFETY: the list is well-formed until freeifaddrs; every dereference is
    // null-checked, and ifa_data is only read as if_data for AF_LINK entries,
    // which is what the kernel puts there.
    //
    // if_data, NOT if_data64. getifaddrs(3) on macOS fills `struct if_data` —
    // 96 bytes with 32-bit counters. if_data64 is 128 bytes and comes from
    // sysctl(NET_RT_IFLIST2); reading one as the other puts ifi_ibytes on the
    // wrong offset, where it reads a constant zero. That shipped: the bar
    // showed 0 B/s through a 40 MB download while en0 really moved 31 MB.
    //
    // Both structs are #[repr(packed)], so every field is copied out with
    // read_unaligned rather than referenced — taking a reference to a packed
    // field is undefined behaviour even if it is never dereferenced.
    unsafe {
        while !cur.is_null() {
            let e = &*cur;
            cur = e.ifa_next;
            if e.ifa_addr.is_null() || e.ifa_data.is_null() {
                continue;
            }
            if i32::from((*e.ifa_addr).sa_family) != libc::AF_LINK {
                continue;
            }
            let dl = e.ifa_addr as *const libc::sockaddr_dl;
            let data = e.ifa_data as *const libc::if_data;
            let Ok(name) = CStr::from_ptr(e.ifa_name).to_str() else {
                continue;
            };
            out.push(Iface {
                name: name.to_string(),
                if_type: addr_of!((*dl).sdl_type).read_unaligned(),
                rx: u64::from(addr_of!((*data).ifi_ibytes).read_unaligned()),
                tx: u64::from(addr_of!((*data).ifi_obytes).read_unaligned()),
            });
        }
        libc::freeifaddrs(head);
    }
    out
}

pub fn counters() -> Counters {
    let (cpu_idle, cpu_total) = cpu();
    let (net_rx, net_tx) = darwin::sum_net(&ifaces());
    Counters {
        cpu_idle,
        cpu_total,
        net_rx,
        net_tx,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The layer that shipped broken: pure arithmetic lives in `darwin.rs` and
    /// is covered from any host, so nothing exercised the structs these
    /// syscalls fill. Reading `ifa_data` as the wrong type is invisible to a
    /// unit test and to `cargo clippy`, and it survived CI on macos-latest.
    ///
    /// Asserts against the kernel rather than a fixture: any machine running
    /// this has moved bytes over some interface since boot, and a counter that
    /// reads zero across the board is the signature of that bug.
    #[test]
    fn getifaddrs_yields_real_counters() {
        let all = ifaces();
        assert!(!all.is_empty(), "getifaddrs returned nothing at all");
        assert!(
            all.iter().any(|i| i.rx > 0),
            "every interface reported rx=0 — ifa_data is being read as the \
             wrong struct (if_data64 instead of if_data)"
        );
        // lo0 always has traffic and is never physical, so it proves the walk
        // sees counters even when the filter later discards them.
        assert!(
            all.iter().any(|i| i.name == "lo0" && i.rx > 0),
            "lo0 had no counters; the walk is not reading if_data correctly"
        );
    }

    /// mem_percent is arithmetic over values only a Mac can supply.
    #[test]
    fn memory_reads_a_plausible_percentage() {
        let pct = mem_percent().expect("host_statistics64/sysctl failed");
        assert!(pct > 0 && pct <= 100, "implausible memory reading: {pct}");
    }
}
