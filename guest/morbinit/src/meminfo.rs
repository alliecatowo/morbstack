//! Guest memory accounting for the host's memory-balloon driver (UX-17).
//!
//! `VMManager` attaches a `VZVirtioTraditionalMemoryBalloonDeviceConfiguration`
//! but has no way to see how much memory the guest actually needs — Apple's
//! traditional balloon device is host-to-guest only; it has no host-visible
//! stats feedback channel. The only signal available at all is whatever the
//! guest is willing to report over MRB0, so this module reads the kernel's
//! own `MemTotal`/`MemAvailable` estimate from `/proc/meminfo` and hands it to
//! `control.rs`'s `info` reply.
//!
//! `MemAvailable` (not `MemFree`) is the deliberate choice: it is the kernel's
//! own estimate of memory that can be reclaimed *without* swapping — page
//! cache and slab that can be dropped or freed, on top of genuinely free
//! pages — which is exactly the definition a balloon driver needs before it
//! can safely ask the guest to give memory back. `MemFree` alone would ignore
//! reclaimable cache and make the guest look far busier than it is.
//!
//! This module only reads and parses; it does not decide a balloon target.
//! That decision is host-side (`MemoryBalloonPolicy.swift`), deliberately
//! conservative, and documented there.

/// One `/proc/meminfo` sample, both fields in kB (the file's native unit).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct MemInfo {
    pub total_kb: u64,
    pub available_kb: u64,
}

/// Parses the `MemTotal:` and `MemAvailable:` lines out of `/proc/meminfo`-shaped
/// text.
///
/// Pure and portable so it unit tests on the macOS dev host exactly like every
/// other `/proc` parser in this crate (`net.rs`'s route/resolv.conf readers,
/// `disk.rs`'s `/proc/mounts`). Tolerant of extra fields, reordering, and the
/// trailing `kB` unit suffix every kernel emits; returns `None` only when one of
/// the two required fields is absent or is not a plain non-negative integer —
/// never partial or guessed data.
pub fn parse(text: &str) -> Option<MemInfo> {
    let mut total_kb: Option<u64> = None;
    let mut available_kb: Option<u64> = None;

    for line in text.lines() {
        let Some((key, rest)) = line.split_once(':') else {
            continue;
        };
        let target = match key {
            "MemTotal" => &mut total_kb,
            "MemAvailable" => &mut available_kb,
            _ => continue,
        };
        // The value is whitespace-padded and suffixed with " kB"; take the
        // first whitespace-separated token, which is the decimal digits.
        let Some(digits) = rest.split_whitespace().next() else {
            continue;
        };
        *target = digits.parse::<u64>().ok();
    }

    match (total_kb, available_kb) {
        (Some(total_kb), Some(available_kb)) => Some(MemInfo {
            total_kb,
            available_kb,
        }),
        _ => None,
    }
}

/// Reads and parses `/proc/meminfo`. `None` on any read or parse failure —
/// this is a best-effort signal for an optional balloon policy, never
/// something worth failing a control reply over.
#[cfg(target_os = "linux")]
pub fn read() -> Option<MemInfo> {
    let text = std::fs::read_to_string("/proc/meminfo").ok()?;
    parse(&text)
}

/// There is no `/proc/meminfo` outside a Linux guest kernel; the `--serve-control`
/// dev hook and the macOS unit-test build both need a value that never panics.
#[cfg(not(target_os = "linux"))]
pub fn read() -> Option<MemInfo> {
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_a_real_looking_meminfo() {
        let text = "\
MemTotal:        8137368 kB
MemFree:         3941220 kB
MemAvailable:    6234112 kB
Buffers:          102344 kB
Cached:          2011564 kB
";
        let info = parse(text).unwrap();
        assert_eq!(info.total_kb, 8_137_368);
        assert_eq!(info.available_kb, 6_234_112);
    }

    #[test]
    fn tolerates_field_reordering() {
        let text = "MemAvailable: 100 kB\nMemTotal: 200 kB\n";
        let info = parse(text).unwrap();
        assert_eq!(info.total_kb, 200);
        assert_eq!(info.available_kb, 100);
    }

    #[test]
    fn missing_mem_available_is_none_not_a_guess() {
        // Older/stripped kernels only ever had MemFree; a balloon policy must
        // never mistake MemFree for the reclaim-aware MemAvailable estimate.
        let text = "MemTotal: 200 kB\nMemFree: 50 kB\n";
        assert!(parse(text).is_none());
    }

    #[test]
    fn missing_mem_total_is_none() {
        let text = "MemAvailable: 100 kB\n";
        assert!(parse(text).is_none());
    }

    #[test]
    fn empty_input_is_none() {
        assert!(parse("").is_none());
    }

    #[test]
    fn a_non_numeric_value_is_none_rather_than_truncated() {
        let text = "MemTotal: not-a-number kB\nMemAvailable: 100 kB\n";
        assert!(parse(text).is_none());
    }

    #[test]
    fn tolerates_a_missing_kb_suffix() {
        // Not expected from a real kernel, but the parser should not choke on
        // a bare integer either — it only takes the first token.
        let text = "MemTotal: 200\nMemAvailable: 100\n";
        let info = parse(text).unwrap();
        assert_eq!(info.total_kb, 200);
        assert_eq!(info.available_kb, 100);
    }

    #[cfg(not(target_os = "linux"))]
    #[test]
    fn read_is_none_off_linux() {
        assert!(read().is_none());
    }
}
