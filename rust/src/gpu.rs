//! NVIDIA readings via NVML, loaded at runtime.
//!
//! NVML is the library `nvidia-smi` itself is built on, so this reads the same
//! numbers without the 23 ms fork. It is opened with `dlopen` rather than
//! linked, so a machine with no driver simply reports nothing and the binary
//! still runs.
//!
//! NVIDIA on Linux and nothing else. An Intel or AMD iGPU is skipped
//! deliberately, not lazily: what its sysfs offers is clock frequency, not
//! utilisation, and a segment meaning something different per machine is worse
//! than no segment.

// Off Linux there is no NVML to call, so the sysfs helpers below have no
// caller but the tests. Built anyway, so they stay compiled and covered.
#![cfg_attr(not(target_os = "linux"), allow(dead_code))]

use std::path::{Path, PathBuf};

/// `(utilisation %, VRAM used %)`, or `None` on any machine that cannot answer.
pub fn sample() -> Option<(u32, u32)> {
    imp::sample()
}

/// NVIDIA display controllers straight out of sysfs: vendor `0x10de`, PCI class
/// `03xx`.
///
/// Deliberately not derived from `nvidia-smi --query-gpu=pci.bus_id`, which
/// prints an 8-digit domain (`00000000:01:00.0`) where sysfs writes four
/// (`0000:01:00.0`). sysfs already knows the answer, and knows it without
/// loading the driver.
pub fn nvidia_pci_devices(root: &Path) -> Vec<PathBuf> {
    let Ok(entries) = std::fs::read_dir(root) else {
        return Vec::new();
    };
    let mut out: Vec<PathBuf> = entries
        .flatten()
        .map(|e| e.path())
        .filter(|d| {
            let read = |f: &str| std::fs::read_to_string(d.join(f)).ok();
            let (Some(v), Some(c)) = (read("vendor"), read("class")) else {
                return false;
            };
            v.trim() == "0x10de" && c.trim().starts_with("0x03")
        })
        .collect();
    out.sort();
    out
}

/// True when there is at least one NVIDIA device and every one of them is
/// parked.
///
/// A Max-Q dGPU drops to D3cold when idle. Touching NVML wakes it, and doing
/// that every 2 s would hold it awake for a whole session — a real battery cost
/// for a reading that is 0% anyway. An empty list is *not* "all suspended":
/// with no sysfs entries we know nothing and must ask NVML.
pub fn all_suspended(devices: &[PathBuf]) -> bool {
    !devices.is_empty()
        && devices.iter().all(|d| {
            std::fs::read_to_string(d.join("power/runtime_status"))
                .map(|s| s.trim() == "suspended")
                .unwrap_or(false)
        })
}

fn sysfs_root() -> PathBuf {
    // Overridable so the suite gets the same answer on every machine; nothing
    // but tests ever sets it.
    std::env::var_os("NVIDIA_SYSFS_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/sys/bus/pci/devices"))
}

/// Fold several cards into one pair of numbers: utilisation is the **busiest**
/// card ("is anything running?"), VRAM is **pooled** ("is there room left?").
/// A card that cannot report is skipped rather than counted as idle.
pub fn fold(cards: &[(u32, u64, u64)]) -> Option<(u32, u32)> {
    let mut util = 0;
    let mut used = 0u64;
    let mut total = 0u64;
    for &(u, us, t) in cards {
        util = util.max(u);
        used = used.saturating_add(us);
        total = total.saturating_add(t);
    }
    (total > 0).then(|| (util.min(100), ((used * 100) / total).min(100) as u32))
}

#[cfg(not(target_os = "linux"))]
mod imp {
    pub fn sample() -> Option<(u32, u32)> {
        None
    }
}

#[cfg(target_os = "linux")]
mod imp {
    use super::{all_suspended, fold, nvidia_pci_devices, sysfs_root};
    use std::ffi::c_void;

    type Handle = *mut c_void;
    type Init = unsafe extern "C" fn() -> i32;
    type Count = unsafe extern "C" fn(*mut u32) -> i32;
    type ByIndex = unsafe extern "C" fn(u32, *mut Handle) -> i32;
    type GetUtil = unsafe extern "C" fn(Handle, *mut Utilization) -> i32;
    type GetMem = unsafe extern "C" fn(Handle, *mut Memory) -> i32;
    type GetMemV2 = unsafe extern "C" fn(Handle, *mut MemoryV2) -> i32;

    #[repr(C)]
    #[derive(Default)]
    struct Utilization {
        gpu: u32,
        memory: u32,
    }

    #[repr(C)]
    #[derive(Default)]
    struct Memory {
        total: u64,
        free: u64,
        used: u64,
    }

    /// The v2 memory struct, which splits driver-reserved memory out of `used`.
    ///
    /// This distinction is not cosmetic. v1 reports `used = total - free`, so
    /// the driver's own reservation — 390 MiB on this card — counts as memory
    /// someone is using. nvidia-smi reports the v2 figure, so v1 reads about
    /// 4.5 points higher than every other tool on the machine, including the
    /// shell implementation this replaced.
    #[repr(C)]
    #[derive(Default)]
    struct MemoryV2 {
        version: u32,
        total: u64,
        reserved: u64,
        free: u64,
        used: u64,
    }

    pub fn sample() -> Option<(u32, u32)> {
        // Parked: report idle without touching NVML, so the card stays asleep.
        if all_suspended(&nvidia_pci_devices(&sysfs_root())) {
            return Some((0, 0));
        }

        let lib = std::ffi::CString::new("libnvidia-ml.so.1").ok()?;
        // SAFETY: a valid NUL-terminated path; dlopen returns null on failure,
        // which is checked. The handle is intentionally never closed — see the
        // note on shutdown below.
        let h = unsafe { libc::dlopen(lib.as_ptr(), libc::RTLD_LAZY) };
        if h.is_null() {
            return None;
        }

        macro_rules! sym {
            ($name:literal, $ty:ty) => {{
                let n = std::ffi::CString::new($name).ok()?;
                // SAFETY: `h` is a live handle and `n` is NUL-terminated. The
                // signatures are NVML's documented ABI, declared above.
                let p = unsafe { libc::dlsym(h, n.as_ptr()) };
                if p.is_null() {
                    return None;
                }
                unsafe { std::mem::transmute::<*mut c_void, $ty>(p) }
            }};
        }

        let init = sym!("nvmlInit_v2", Init);
        let get_count = sym!("nvmlDeviceGetCount_v2", Count);
        let by_index = sym!("nvmlDeviceGetHandleByIndex_v2", ByIndex);
        let get_util = sym!("nvmlDeviceGetUtilizationRates", GetUtil);
        let get_mem = sym!("nvmlDeviceGetMemoryInfo", GetMem);
        // Preferred, but absent on older drivers, so its absence is not fatal.
        let get_mem_v2: Option<GetMemV2> = {
            let n = std::ffi::CString::new("nvmlDeviceGetMemoryInfo_v2").ok()?;
            // SAFETY: `h` is a live handle from dlopen and `n` is NUL-terminated.
            let p = unsafe { libc::dlsym(h, n.as_ptr()) };
            (!p.is_null())
                // SAFETY: the signature is NVML's documented v2 ABI.
                .then(|| unsafe { std::mem::transmute::<*mut c_void, GetMemV2>(p) })
        };

        // SAFETY: each call follows NVML's contract — init first, handles come
        // from by_index, and every out-pointer is a live local.
        unsafe {
            if init() != 0 {
                return None;
            }
            let mut n = 0u32;
            if get_count(&mut n) != 0 {
                return None;
            }
            let mut cards = Vec::new();
            for i in 0..n {
                let mut dev: Handle = std::ptr::null_mut();
                if by_index(i, &mut dev) != 0 {
                    continue;
                }
                let mut u = Utilization::default();
                if get_util(dev, &mut u) != 0 {
                    continue; // a card that cannot report is skipped, not zeroed
                }
                // v2 where the driver has it, so `used` excludes the driver's
                // own reservation and agrees with nvidia-smi.
                let mem = match get_mem_v2 {
                    Some(f) => {
                        let mut m = MemoryV2 {
                            version: (std::mem::size_of::<MemoryV2>() as u32) | (2 << 24),
                            ..Default::default()
                        };
                        (f(dev, &mut m) == 0).then_some((m.used, m.total))
                    }
                    None => None,
                };
                let mem = match mem {
                    Some(v) => Some(v),
                    None => {
                        let mut m = Memory::default();
                        (get_mem(dev, &mut m) == 0).then_some((m.used, m.total))
                    }
                };
                let Some((used, total)) = mem else { continue };
                cards.push((u.gpu, used, total));
            }
            // nvmlShutdown is deliberately NOT called. It costs ~3.5 ms of the
            // ~14 ms this whole path takes, and the process is about to exit —
            // the kernel reclaims everything it would have released.
            fold(&cards)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn one_card_reports_itself() {
        assert_eq!(fold(&[(9, 4599, 8188)]), Some((9, 56)));
        assert_eq!(fold(&[(99, 8000, 8188)]), Some((99, 97)));
    }

    #[test]
    fn several_cards_take_max_util_and_pooled_vram() {
        assert_eq!(fold(&[(10, 1000, 8000), (90, 3000, 8000)]), Some((90, 25)));
    }

    #[test]
    fn nothing_readable_is_absent_not_zero() {
        assert_eq!(fold(&[]), None);
        assert_eq!(fold(&[(0, 0, 0)]), None, "total 0 is not a reading");
    }

    #[test]
    fn an_empty_sysfs_tree_is_not_all_suspended() {
        // Otherwise a machine with no sysfs entries would silently report idle
        // instead of asking NVML.
        assert!(!all_suspended(&[]));
    }
}
