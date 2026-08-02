//! Host directory shares: reading the map off the kernel command line and
//! deciding what to mount where.
//!
//! Morbstack exposes host directories to the guest over VirtioFS and mounts
//! each one at *the same absolute path* it has on the Mac. That is what makes
//! `docker run -v /Users/me/app:/app` work: the Docker CLI sends the literal
//! string `/Users/me/app`, dockerd resolves it against the guest's own
//! filesystem with no idea it is inside a VM, and because the host's `/Users`
//! is mounted at the guest's `/Users` the two land on the same bytes. No path
//! translation anywhere — which is also why there is nothing to get wrong in
//! the interesting cases (symlinks inside the share, `..`, nested compose
//! files with relative volume paths).
//!
//! The share map arrives on the kernel command line, one
//! `morb.share=<tag>:<percent-encoded-path>` argument per share, written by
//! the host's `MorbShares.cmdlineArguments`. The command line is available to
//! PID 1 from its first instruction — no boot-order dependency on the vsock
//! control channel, which cannot exist yet — and it carries no state between
//! boots, so changing `shared_paths` in `config.toml` takes effect on the next
//! start without rebuilding the guest image.
//!
//! Deliberately free of `#[cfg(target_os = "linux")]`: everything in this
//! module is a pure function of a string, so it is compiled and unit tested on
//! macOS too. `mounts::mount_shares` is the Linux-only half that actually
//! calls `mount(2)` on what this module decides.

/// One host directory advertised to the guest.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ShareSpec {
    /// The VirtioFS tag, e.g. `morbshare0`. This is the `source` argument to
    /// `mount -t virtiofs`.
    pub tag: String,
    /// The absolute path, on the host *and* in the guest.
    pub path: String,
    /// Mount it `MS_RDONLY`.
    ///
    /// Never set for the user's own `shared_paths` — a bind mount you cannot
    /// write to is not what `-v $PWD:/app` means. It is here for shares
    /// Morbstack makes for itself: a host directory of payload the guest only
    /// ever reads out of is read-only by nature, and the host can arrange one
    /// by setting a flag rather than by extending this protocol.
    pub read_only: bool,
}

/// A mount this guest should perform, as decided by [`mount_table`].
///
/// Split out from the mounting itself so the decision — which is all the
/// interesting logic — can be unit tested on a machine that has no `mount(2)`
/// worth speaking of.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ShareMount {
    /// Mount source: the VirtioFS tag.
    pub tag: String,
    /// Mount point, created (recursively) before mounting.
    pub target: String,
    /// `MS_NOSUID`. A setuid binary sitting in the user's home directory has
    /// no business gaining privilege inside the guest, and nothing in a
    /// developer workflow needs it.
    pub nosuid: bool,
    /// `MS_NODEV`. Same reasoning: device nodes on a shared host directory
    /// are not a thing anyone wants honoured.
    pub nodev: bool,
    /// `MS_RDONLY`. See `ShareSpec::read_only`.
    pub rdonly: bool,
}

/// The kernel command-line key carrying one share. Must match
/// `MorbShares.cmdlineKey` on the host.
pub const CMDLINE_KEY: &str = "morb.share";

/// Where the kernel publishes the command line.
pub const CMDLINE_PATH: &str = "/proc/cmdline";

/// The optional trailing marker that makes a share read-only. Must match
/// `MorbShares.readOnlyFlag` on the host.
///
/// Written with its separator so that stripping it cannot decapitate a path
/// that merely ends in the letters `ro`.
pub const READ_ONLY_SUFFIX: &str = ":ro";

/// The filesystem type. Confirmed present in the shipped guest kernel:
/// `CONFIG_VIRTIO_FS=y`, built in rather than a module (there is no module
/// tree in the initramfs to load one from).
pub const FSTYPE: &str = "virtiofs";

/// Extract the share map from a kernel command line.
///
/// Malformed entries are skipped rather than fatal: the command line is also
/// carrying the kernel's own arguments, and one unparseable share must not
/// cost the guest the others. Order is preserved, which matters because
/// [`mount_table`] mounts outer paths before inner ones.
pub fn parse_cmdline(cmdline: &str) -> Vec<ShareSpec> {
    let mut specs = Vec::new();
    for token in cmdline.split_whitespace() {
        let Some(value) = token.strip_prefix(CMDLINE_KEY).and_then(|r| r.strip_prefix('=')) else {
            continue;
        };
        let Some((tag, rest)) = value.split_once(':') else {
            continue;
        };
        if tag.is_empty() {
            continue;
        }
        // Optional `:ro` suffix. Stripped before decoding, since the encoding
        // guarantees the path itself contains no bare colon.
        let (encoded, read_only) = match rest.strip_suffix(READ_ONLY_SUFFIX) {
            Some(head) => (head, true),
            None => (rest, false),
        };
        let Some(path) = decode_path(encoded) else {
            continue;
        };
        // An absolute path is the entire premise: the mount point *is* the
        // host path. Anything else is a corrupted command line.
        if !path.starts_with('/') || path == "/" {
            continue;
        }
        specs.push(ShareSpec {
            tag: tag.to_string(),
            path,
            read_only,
        });
    }
    specs
}

/// Turn advertised shares into the mounts to perform.
///
/// Sorted shortest-path-first so that a nested pair (`/Users` and
/// `/Users/me/scratch`, say) mounts the outer one first — mounting the inner
/// one first would leave it buried under the outer mount and unreachable. The
/// host planner already drops nested roots, so this is belt and braces for a
/// hand-edited command line.
///
/// Duplicate targets are collapsed, keeping the first: two devices mounted at
/// one path would shadow each other, and which one wins would depend on
/// nothing the user can see.
pub fn mount_table(specs: &[ShareSpec]) -> Vec<ShareMount> {
    let mut ordered: Vec<&ShareSpec> = specs.iter().collect();
    // Stable sort on depth, so shares at the same depth keep command-line order.
    ordered.sort_by_key(|spec| spec.path.matches('/').count());

    let mut mounts: Vec<ShareMount> = Vec::new();
    for spec in ordered {
        let target = normalize_target(&spec.path);
        if mounts.iter().any(|m| m.target == target) {
            continue;
        }
        mounts.push(ShareMount {
            tag: spec.tag.clone(),
            target,
            nosuid: true,
            nodev: true,
            rdonly: spec.read_only,
        });
    }
    mounts
}

/// Strip a trailing slash so `/Users/` and `/Users` cannot both be mounted.
/// `/` itself is never a valid target and is rejected in `parse_cmdline`.
fn normalize_target(path: &str) -> String {
    let trimmed = path.trim_end_matches('/');
    if trimmed.is_empty() {
        "/".to_string()
    } else {
        trimmed.to_string()
    }
}

/// Decode the host's percent encoding. Returns `None` on a truncated or
/// non-hex escape, or on bytes that are not valid UTF-8.
pub fn decode_path(encoded: &str) -> Option<String> {
    let bytes = encoded.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' {
            if i + 2 >= bytes.len() {
                return None;
            }
            let high = hex_value(bytes[i + 1])?;
            let low = hex_value(bytes[i + 2])?;
            out.push(high << 4 | low);
            i += 3;
        } else {
            out.push(bytes[i]);
            i += 1;
        }
    }
    String::from_utf8(out).ok()
}

/// The inverse of [`decode_path`]. Used for the `shares` field of `info`
/// replies, so the host can tell a path containing a comma or a colon from the
/// separators around it.
pub fn encode_path(path: &str) -> String {
    let mut out = String::with_capacity(path.len());
    for &byte in path.as_bytes() {
        if is_unescaped(byte) {
            out.push(byte as char);
        } else {
            out.push('%');
            out.push(hex_digit(byte >> 4));
            out.push(hex_digit(byte & 0xf));
        }
    }
    out
}

/// The byte set that survives [`encode_path`] unescaped. Must match
/// `MorbShares.unescaped` on the host.
fn is_unescaped(byte: u8) -> bool {
    byte.is_ascii_alphanumeric() || matches!(byte, b'/' | b'.' | b'_' | b'-' | b'+')
}

fn hex_value(byte: u8) -> Option<u8> {
    match byte {
        b'0'..=b'9' => Some(byte - b'0'),
        b'a'..=b'f' => Some(byte - b'a' + 10),
        b'A'..=b'F' => Some(byte - b'A' + 10),
        _ => None,
    }
}

fn hex_digit(nibble: u8) -> char {
    match nibble {
        0..=9 => (b'0' + nibble) as char,
        _ => (b'A' + nibble - 10) as char,
    }
}

/// What happened to one share, for the `shares` field of an `info` reply.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MountState {
    Mounted,
    Failed,
}

impl MountState {
    fn as_str(self) -> &'static str {
        match self {
            MountState::Mounted => "mounted",
            MountState::Failed => "failed",
        }
    }
}

/// Render the mount results for the control protocol:
/// `"<encoded-path>:<state>"` entries joined with `,`.
///
/// A flat string because MRB0's JSON encoder is single-level by construction
/// (see `jsonlite.rs`); the encoding of the path is what keeps the separators
/// unambiguous for a path that contains one. The host decodes this with
/// `MorbShares.parseGuestShares`.
pub fn encode_report(results: &[(String, MountState)]) -> String {
    results
        .iter()
        .map(|(path, state)| format!("{}:{}", encode_path(path), state.as_str()))
        .collect::<Vec<_>>()
        .join(",")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn spec(tag: &str, path: &str) -> ShareSpec {
        ShareSpec {
            tag: tag.to_string(),
            path: path.to_string(),
            read_only: false,
        }
    }

    fn ro_spec(tag: &str, path: &str) -> ShareSpec {
        ShareSpec {
            read_only: true,
            ..spec(tag, path)
        }
    }

    #[test]
    fn a_read_only_share_is_marked_and_mounted_rdonly() {
        // The seam for internal shares: a host payload directory the guest only
        // reads out of. Nothing in `shared_paths` produces one, but the whole
        // path — command line, parser, mount flags — already carries it.
        assert_eq!(
            parse_cmdline("morb.share=payload:/Users/x/payload:ro"),
            vec![ro_spec("payload", "/Users/x/payload")]
        );
        let table = mount_table(&[ro_spec("payload", "/Users/x/payload")]);
        assert!(table[0].rdonly);
        assert!(!mount_table(&[spec("morbshare0", "/Users")])[0].rdonly);
    }

    #[test]
    fn a_path_ending_in_ro_is_not_mistaken_for_the_flag() {
        // `/Users/me/ro` encodes with its slash intact, so the suffix check —
        // which looks for a literal `:ro` — cannot see it.
        assert_eq!(
            parse_cmdline("morb.share=t:/Users/me/ro"),
            vec![spec("t", "/Users/me/ro")]
        );
    }

    #[test]
    fn parses_the_shares_the_host_writes() {
        let cmdline = "console=hvc0 rdinit=/init morb.share=morbshare0:/Users \
                       morb.share=morbshare1:/Volumes morb.share=morbshare2:/private/tmp";
        assert_eq!(
            parse_cmdline(cmdline),
            vec![
                spec("morbshare0", "/Users"),
                spec("morbshare1", "/Volumes"),
                spec("morbshare2", "/private/tmp"),
            ]
        );
    }

    #[test]
    fn a_command_line_without_shares_yields_none() {
        assert!(parse_cmdline("console=hvc0 rdinit=/init").is_empty());
    }

    #[test]
    fn decodes_paths_with_spaces_and_separators() {
        // The reason the encoding exists: the command line is whitespace
        // separated, so an unencoded space would split one share into two
        // arguments and lose the tail.
        let cmdline = "morb.share=morbshare0:/Volumes/My%20Disk%3Aone%2Ctwo";
        assert_eq!(
            parse_cmdline(cmdline),
            vec![spec("morbshare0", "/Volumes/My Disk:one,two")]
        );
    }

    #[test]
    fn round_trips_every_path_shape_we_expect_to_meet() {
        for path in [
            "/Users",
            "/private/tmp",
            "/Volumes/My Disk",
            "/Users/someone/proj (copy)",
            "/Users/someone/ünïcode",
            "/Users/someone/100% real",
            "/Volumes/a:b,c",
            "/Users/someone/quote\"and\\slash",
        ] {
            let encoded = encode_path(path);
            assert!(
                !encoded.contains(' '),
                "encoded form must survive whitespace splitting: {}",
                encoded
            );
            assert_eq!(decode_path(&encoded).as_deref(), Some(path));
            let cmdline = format!("console=hvc0 {}=t0:{} quiet", CMDLINE_KEY, encoded);
            assert_eq!(parse_cmdline(&cmdline), vec![spec("t0", path)]);
        }
    }

    #[test]
    fn common_paths_stay_readable_in_proc_cmdline() {
        // Not cosmetic: the first thing anyone does when a share misbehaves is
        // `cat /proc/cmdline`, and a screenful of %2F helps nobody.
        assert_eq!(encode_path("/Users"), "/Users");
        assert_eq!(encode_path("/private/tmp"), "/private/tmp");
        assert_eq!(encode_path("/Users/me/my-app_2.0"), "/Users/me/my-app_2.0");
    }

    #[test]
    fn malformed_entries_are_skipped_not_fatal() {
        let cmdline = "morb.share=noseparator morb.share=:/Users morb.share=t:%ZZ \
                       morb.share=t:%4 morb.share=t:relative morb.share=t:%2F \
                       morb.share=good:/Users";
        // Everything above is broken in a different way — no colon, empty tag,
        // bad hex, truncated escape, not absolute, and "/" itself — and the one
        // good entry still survives.
        assert_eq!(parse_cmdline(cmdline), vec![spec("good", "/Users")]);
    }

    #[test]
    fn other_kernel_arguments_are_left_alone() {
        // `morb.shared=` and `xmorb.share=` both start with something that looks
        // like the key; neither is one.
        let cmdline = "morb.shared=/Users xmorb.share=t:/Users morb.share=t:/Users";
        assert_eq!(parse_cmdline(cmdline), vec![spec("t", "/Users")]);
    }

    #[test]
    fn mount_table_mounts_outer_paths_first() {
        let specs = vec![
            spec("morbshare0", "/Users/me/scratch"),
            spec("morbshare1", "/Users"),
        ];
        let table = mount_table(&specs);
        assert_eq!(
            table.iter().map(|m| m.target.as_str()).collect::<Vec<_>>(),
            vec!["/Users", "/Users/me/scratch"]
        );
    }

    #[test]
    fn mount_table_keeps_command_line_order_within_a_depth() {
        let specs = vec![
            spec("morbshare0", "/Users"),
            spec("morbshare1", "/Volumes"),
            spec("morbshare2", "/opt"),
        ];
        let table = mount_table(&specs);
        assert_eq!(
            table.iter().map(|m| m.tag.as_str()).collect::<Vec<_>>(),
            vec!["morbshare0", "morbshare1", "morbshare2"]
        );
    }

    #[test]
    fn mount_table_collapses_duplicate_targets() {
        let specs = vec![
            spec("morbshare0", "/Users"),
            spec("morbshare1", "/Users/"),
            spec("morbshare2", "/Volumes"),
        ];
        let table = mount_table(&specs);
        assert_eq!(table.len(), 2);
        assert_eq!(table[0].tag, "morbshare0");
        assert_eq!(table[1].target, "/Volumes");
    }

    #[test]
    fn shares_are_mounted_nosuid_and_nodev() {
        let table = mount_table(&[spec("morbshare0", "/Users")]);
        assert!(table[0].nosuid);
        assert!(table[0].nodev);
    }

    #[test]
    fn the_report_encodes_paths_so_separators_stay_unambiguous() {
        let report = encode_report(&[
            ("/Users".to_string(), MountState::Mounted),
            ("/Volumes/a,b".to_string(), MountState::Failed),
        ]);
        assert_eq!(report, "/Users:mounted,/Volumes/a%2Cb:failed");
    }

    #[test]
    fn an_empty_report_is_an_empty_string() {
        assert_eq!(encode_report(&[]), "");
    }
}
