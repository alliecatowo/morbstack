//! Minimal timestamped logging.
//!
//! Real morbinit logs go to `/dev/console` so they show up in the VM's
//! serial console log on the host (`~/.morbstack/logs/console.log`). Every
//! other target (including `cargo test` on macOS) falls back to stderr.

use std::io::Write;
use std::sync::{Mutex, OnceLock};
use std::time::Instant;

static START: OnceLock<Instant> = OnceLock::new();
static SINK: OnceLock<Mutex<Box<dyn Write + Send>>> = OnceLock::new();

/// The instant morbinit's logging subsystem was first used. We treat this
/// as "time zero" for the monotonic timestamps we print. PID 1 calls
/// `log::log` within milliseconds of receiving control from the kernel, so
/// "ms since first log call" is a close enough proxy for "ms since boot"
/// without needing CLOCK_BOOTTIME FFI plumbing for M0.
fn start_time() -> Instant {
    *START.get_or_init(Instant::now)
}

fn sink() -> &'static Mutex<Box<dyn Write + Send>> {
    SINK.get_or_init(|| {
        #[cfg(target_os = "linux")]
        {
            if let Ok(f) = std::fs::OpenOptions::new().write(true).open("/dev/console") {
                return Mutex::new(Box::new(f) as Box<dyn Write + Send>);
            }
        }
        Mutex::new(Box::new(std::io::stderr()) as Box<dyn Write + Send>)
    })
}

/// Write a single timestamped log line. Never panics: a poisoned lock or a
/// failed write is swallowed, because logging must never be the reason
/// PID 1 dies.
pub fn log(msg: &str) {
    let elapsed_ms = start_time().elapsed().as_millis();
    let line = format!("[{:>10}ms] {}\n", elapsed_ms, msg);
    if let Ok(mut guard) = sink().lock() {
        let _ = guard.write_all(line.as_bytes());
        let _ = guard.flush();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn log_does_not_panic() {
        log("hello from a test");
        log("");
        log("line with \"quotes\" and a\nnewline");
    }
}
