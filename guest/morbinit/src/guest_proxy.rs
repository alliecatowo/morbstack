//! HTTP/HTTPS proxy environment for dockerd, decoded off the kernel command
//! line.
//!
//! Same transport as `shares.rs` and for the same reason (see that module's
//! docs): dockerd is spawned by `supervisor::default_services` before the
//! vsock control channel can possibly exist, so the only channel available
//! at that point in boot is the command line PID 1 was handed at its very
//! first instruction. The host encodes it with `MorbGuestProxy` and this
//! module is its guest-side twin, held together by round-trip tests on both
//! sides the same way `shares.rs`/`MorbShares` are.
//!
//! Deliberately free of `#[cfg(target_os = "linux")]`: everything here is a
//! pure function of a string, so it compiles and is unit tested on macOS too.
//! `mounts::advertised_proxy_env` is the Linux-only half that actually reads
//! `/proc/cmdline`.

use crate::shares::decode_path;
#[cfg(test)]
use crate::shares::encode_path;

/// The kernel command-line key carrying one proxy field. Must match
/// `MorbGuestProxy.cmdlineKey` on the host.
pub const CMDLINE_KEY: &str = "morb.proxy";

const HTTP_KEY: &str = "http";
const HTTPS_KEY: &str = "https";
const NO_PROXY_KEY: &str = "noproxy";

/// What was decided for dockerd's process environment. Each field is
/// percent-decoded exactly as the host wrote it — a proxy URL such as
/// `http://user:pass@proxy.corp:8080` round-trips byte for byte.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ProxyEnv {
    pub http: Option<String>,
    pub https: Option<String>,
    pub no_proxy: Option<String>,
}

impl ProxyEnv {
    /// `true` when at least one of the three fields is set — i.e. dockerd is
    /// actually being launched with something in its proxy environment.
    pub fn is_empty(&self) -> bool {
        self.http.is_none() && self.https.is_none() && self.no_proxy.is_none()
    }

    /// Environment variable pairs to layer onto dockerd's process.
    ///
    /// Both cases of each name are set. Go's `net/http.ProxyFromEnvironment`
    /// — what dockerd's own outbound registry pulls use — checks `HTTP_PROXY`
    /// before falling back to `http_proxy`, but a container's own entrypoint
    /// script, or a build step that shells out, conventionally only checks
    /// the lower-case form. Setting both means "the proxy Morbstack
    /// discovered" behaves the same regardless of which convention the
    /// process downstream happens to follow.
    pub fn env_vars(&self) -> Vec<(&'static str, String)> {
        let mut out = Vec::new();
        if let Some(v) = &self.http {
            out.push(("HTTP_PROXY", v.clone()));
            out.push(("http_proxy", v.clone()));
        }
        if let Some(v) = &self.https {
            out.push(("HTTPS_PROXY", v.clone()));
            out.push(("https_proxy", v.clone()));
        }
        if let Some(v) = &self.no_proxy {
            out.push(("NO_PROXY", v.clone()));
            out.push(("no_proxy", v.clone()));
        }
        out
    }
}

/// Extract the proxy environment from a kernel command line.
///
/// Malformed or unrecognised `morb.proxy=` entries are skipped rather than
/// fatal, matching `shares::parse_cmdline`'s tolerance: the command line also
/// carries the kernel's own arguments, and one bad token must not cost the
/// guest the others.
pub fn parse_cmdline(cmdline: &str) -> ProxyEnv {
    let mut env = ProxyEnv::default();
    for token in cmdline.split_whitespace() {
        let Some(value) = token
            .strip_prefix(CMDLINE_KEY)
            .and_then(|r| r.strip_prefix('='))
        else {
            continue;
        };
        let Some((key, encoded)) = value.split_once(':') else {
            continue;
        };
        let Some(decoded) = decode_path(encoded) else {
            continue;
        };
        match key {
            HTTP_KEY => env.http = Some(decoded),
            HTTPS_KEY => env.https = Some(decoded),
            NO_PROXY_KEY => env.no_proxy = Some(decoded),
            _ => continue,
        }
    }
    env
}

/// Render `env` back onto command-line tokens. Only used by this module's own
/// round-trip tests — the host, not the guest, is the one that writes the
/// real command line — but kept next to `parse_cmdline` rather than behind
/// `#[cfg(test)]` so a host-side fixture can be regenerated here if the wire
/// format ever needs to be demonstrated guest-side.
#[cfg(test)]
fn cmdline_arguments(env: &ProxyEnv) -> Vec<String> {
    let mut out = Vec::new();
    if let Some(v) = &env.http {
        out.push(format!("{}={}:{}", CMDLINE_KEY, HTTP_KEY, encode_path(v)));
    }
    if let Some(v) = &env.https {
        out.push(format!("{}={}:{}", CMDLINE_KEY, HTTPS_KEY, encode_path(v)));
    }
    if let Some(v) = &env.no_proxy {
        out.push(format!(
            "{}={}:{}",
            CMDLINE_KEY,
            NO_PROXY_KEY,
            encode_path(v)
        ));
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn empty_cmdline_yields_empty_env() {
        assert_eq!(parse_cmdline(""), ProxyEnv::default());
        assert_eq!(
            parse_cmdline("console=hvc0 rdinit=/init"),
            ProxyEnv::default()
        );
        assert!(ProxyEnv::default().is_empty());
    }

    #[test]
    fn round_trips_a_full_proxy_configuration() {
        let env = ProxyEnv {
            http: Some("http://proxy.corp.example:8080".to_string()),
            https: Some("http://user:pass@proxy.corp.example:8443".to_string()),
            no_proxy: Some("localhost,127.0.0.1,.corp.example".to_string()),
        };
        let cmdline = cmdline_arguments(&env).join(" ");
        assert_eq!(parse_cmdline(&cmdline), env);
    }

    #[test]
    fn tolerates_being_embedded_in_a_real_command_line() {
        let cmdline = "console=hvc0 rdinit=/init morb.proxy=http:http%3A//proxy%3A8080 \
             morb.share=morbshare0:/Users quiet";
        let env = parse_cmdline(cmdline);
        assert_eq!(env.http, Some("http://proxy:8080".to_string()));
        assert_eq!(env.https, None);
        assert_eq!(env.no_proxy, None);
    }

    #[test]
    fn skips_malformed_and_unknown_entries() {
        // No `=`, no `:`, an unrecognised sub-key, and a bad percent escape —
        // none of these should panic or contaminate the fields that did parse.
        let cmdline = "morb.proxy morb.proxy=noseparator morb.proxy=bogus:val \
             morb.proxy=http:%ZZ morb.proxy=http:http%3A//ok%3A80";
        let env = parse_cmdline(cmdline);
        assert_eq!(env.http, Some("http://ok:80".to_string()));
        assert_eq!(env.https, None);
        assert_eq!(env.no_proxy, None);
    }

    #[test]
    fn last_occurrence_of_a_field_wins() {
        // Mirrors `shares::parse_cmdline`'s left-to-right overwrite behaviour
        // for a duplicated key — a hand-edited `kernel_cmdline` override is
        // the only realistic way this happens, and "last wins" is the least
        // surprising rule when it does.
        let cmdline = "morb.proxy=http:http%3A//first%3A80 morb.proxy=http:http%3A//second%3A80";
        assert_eq!(
            parse_cmdline(cmdline).http,
            Some("http://second:80".to_string())
        );
    }

    #[test]
    fn env_vars_sets_both_cases_and_only_configured_fields() {
        let env = ProxyEnv {
            http: Some("http://p:8080".to_string()),
            https: None,
            no_proxy: Some("localhost".to_string()),
        };
        let vars = env.env_vars();
        assert_eq!(
            vars,
            vec![
                ("HTTP_PROXY", "http://p:8080".to_string()),
                ("http_proxy", "http://p:8080".to_string()),
                ("NO_PROXY", "localhost".to_string()),
                ("no_proxy", "localhost".to_string()),
            ]
        );
    }

    #[test]
    fn no_configuration_produces_no_env_vars() {
        assert!(ProxyEnv::default().env_vars().is_empty());
    }
}
