//! Validation boundary for the live VirtioFS notification receiver.
//!
//! The receiver in `live_share_receiver.rs` consumes the typed session and
//! record values in this module.  It deliberately does not claim to inject a
//! synthetic record into another process's inotify descriptor: Linux owns
//! those descriptors.  Instead, after this validation boundary has admitted a
//! host invalidation for an exact selected root, the receiver performs a
//! descriptor-confined, same-mode metadata operation on the existing VirtioFS
//! object.  That operation runs through the guest kernel and therefore emits a
//! normal filesystem notification to workloads which watch that object.
//!
//! This module remains the authority boundary.  A host pathname, FSEvents hint,
//! or arbitrary guest path cannot become a receiver operation without an
//! authenticated session, an exact live backing share, an immutable root claim,
//! and a monotonically ordered record.

use std::collections::HashSet;
use std::fmt;

/// The capability exposed through MRB0 `info` when this initramfs contains the
/// dedicated authenticated receiver.
pub const ADVERTISED_CAPABILITY: &str = "ready";

/// The reserved synchronized-share record schema. A peer must match this
/// value exactly; absent and newer versions are both rejected rather than
/// guessed at.
pub const CONTRACT_VERSION: i64 = 1;

/// The maximum number of independently scoped projects in one proposed
/// session. This matches the host planner's narrow-root bound.
pub const MAX_ROOTS: usize = 8;

/// Linux's usual `PATH_MAX` upper bound, used here before any path could reach
/// a filesystem call. It is a protocol allocation limit, not a claim that a
/// cache exists.
pub const MAX_PATH_BYTES: usize = 4_096;

/// A root identifier is an opaque protocol label, not a host or guest path.
pub const MAX_ROOT_ID_BYTES: usize = 64;

/// VirtioFS tags are protocol labels, not mount paths. Keeping the same tight
/// syntax as root identifiers means the guest can compare an immutable
/// host claim to the actual mount it created without accepting separators or
/// control characters.
pub const MAX_SHARE_TAG_BYTES: usize = 64;

/// A session identifier is 128 bits of opaque protocol data.
pub const SESSION_ID_BYTES: usize = 16;

/// The transport capability is 256 bits. Its presence is only a structural
/// prerequisite: validating these bytes is *not* authentication.
pub const CAPABILITY_BYTES: usize = 32;

/// The guest boot identifier is 128 bits. A new boot must use a new session;
/// the receiver must never accept a record from an earlier guest process.
pub const GUEST_BOOT_ID_BYTES: usize = 16;

/// One actual VirtioFS mount the lifecycle owner has verified. This is
/// deliberately passed in rather than read from a configuration file: a
/// selected root is valid only while the exact backing mount exists.
#[derive(Clone, PartialEq, Eq)]
pub struct MountedShare {
    pub tag: String,
    pub guest_path: String,
    pub read_only: bool,
}

/// The host's immutable description of one selected project root.
///
/// `guest_path` and `backing_share_path` use the same absolute spelling. The
/// receiver operates below `guest_path`; it must never infer another path from
/// a Docker bind request or a broad parent share.
#[derive(Clone, PartialEq, Eq)]
pub struct RootClaim {
    pub root_id: String,
    pub backing_share_tag: String,
    pub guest_path: String,
    pub backing_share_path: String,
    pub read_only: bool,
    pub epoch: u64,
}

/// The first message of the dedicated data-plane connection. It is decoded by
/// the guest receiver on its own vsock port; MRB0 remains request/reply control
/// traffic and is never repurposed as the event stream.
#[derive(Clone, PartialEq, Eq)]
pub struct Hello {
    pub contract_version: i64,
    pub session_id: [u8; SESSION_ID_BYTES],
    pub guest_boot_id: [u8; GUEST_BOOT_ID_BYTES],
    pub peer_capability: [u8; CAPABILITY_BYTES],
    pub roots: Vec<RootClaim>,
}

/// The two durable synchronization directions. The guest-side receiver only
/// accepts `HostToGuest`; outbound guest changes require their own separate
/// authenticated sender and never re-enter this receive path.
#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Direction {
    HostToGuest,
    GuestToHost,
}

/// Internal validation header for each accepted host-to-guest invalidation.
/// The line protocol authenticates its immutable session/root claims during
/// hello; the receiver materializes those claims in this value before it
/// accepts a later record.
#[derive(Clone, PartialEq, Eq)]
pub struct RecordHeader {
    pub contract_version: i64,
    pub session_id: [u8; SESSION_ID_BYTES],
    pub guest_boot_id: [u8; GUEST_BOOT_ID_BYTES],
    pub root_id: String,
    pub epoch: u64,
    pub direction: Direction,
    pub sequence: u64,
    pub base_revision: u64,
}

/// A relative cache entry that has passed lexical containment checks.
///
/// Its field is private so a filesystem applier cannot accidentally
/// receive an unchecked path from a decoder.
#[derive(Clone, PartialEq, Eq)]
pub struct RelativePath(String);

impl RelativePath {
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

/// The result of validating a `hello`. It is deliberately not a ready cache,
/// a mount token, or an authentication result. The opaque peer capability is
/// intentionally discarded after structural validation; the receiver verifies
/// possession separately without exposing that secret in logs or diagnostics.
#[derive(Clone, PartialEq, Eq)]
pub struct ValidatedSession {
    session_id: [u8; SESSION_ID_BYTES],
    guest_boot_id: [u8; GUEST_BOOT_ID_BYTES],
    roots: Vec<ValidatedRoot>,
}

#[derive(Clone, PartialEq, Eq)]
struct ValidatedRoot {
    root_id: String,
    guest_path: String,
    epoch: u64,
    read_only: bool,
}

/// Tracks the next host-to-guest sequence the receiver expects. This
/// has no persistence and must not be mistaken for a durable cache
/// journal; it only makes the receiver reject replayed, skipped, and
/// out-of-order records before looking at their payload.
#[derive(Clone, PartialEq, Eq)]
pub struct SequenceCursor {
    next_host_to_guest: u64,
}

impl Default for SequenceCursor {
    fn default() -> Self {
        Self {
            next_host_to_guest: 1,
        }
    }
}

/// A validation failure safe to surface to a peer. It deliberately
/// contains no capability bytes or file contents.
#[derive(Clone, PartialEq, Eq)]
pub enum ValidationError {
    UnsupportedContractVersion {
        actual: i64,
    },
    ZeroSessionField(&'static str),
    TooManyRoots {
        actual: usize,
    },
    InvalidRootID(String),
    InvalidShareTag(String),
    DuplicateRootID(String),
    InvalidEpoch {
        root: String,
    },
    InvalidAbsolutePath {
        field: &'static str,
        path: String,
    },
    RootNotStrictlyInsideBackingShare {
        root: String,
        backing: String,
    },
    MissingOrChangedBackingShare {
        backing: String,
    },
    BackingShareAccessChanged {
        backing: String,
    },
    OverlappingRoots {
        first: String,
        second: String,
    },
    UnknownRoot(String),
    WrongEpoch {
        root: String,
        actual: u64,
        expected: u64,
    },
    WrongDirection,
    WrongSession,
    WrongGuestBoot,
    UnexpectedSequence {
        actual: u64,
        expected: u64,
    },
    SequenceExhausted,
    InvalidRelativePath(String),
}

impl fmt::Display for ValidationError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::UnsupportedContractVersion { actual } => {
                write!(
                    f,
                    "unsupported synchronized-share contract version {}",
                    actual
                )
            }
            Self::ZeroSessionField(field) => {
                write!(f, "synchronized-share {} must not be all zeroes", field)
            }
            Self::TooManyRoots { actual } => {
                write!(
                    f,
                    "synchronized-share hello names {} roots; limit is {}",
                    actual, MAX_ROOTS
                )
            }
            Self::InvalidRootID(root) => write!(f, "invalid synchronized-share root id {:?}", root),
            Self::InvalidShareTag(tag) => {
                write!(f, "invalid synchronized-share backing tag {:?}", tag)
            }
            Self::DuplicateRootID(root) => {
                write!(f, "duplicate synchronized-share root id {:?}", root)
            }
            Self::InvalidEpoch { root } => {
                write!(f, "synchronized-share root {:?} has zero epoch", root)
            }
            Self::InvalidAbsolutePath { field, path } => {
                write!(f, "invalid synchronized-share {} path {:?}", field, path)
            }
            Self::RootNotStrictlyInsideBackingShare { root, backing } => write!(
                f,
                "synchronized-share root {:?} is not a strict descendant of {:?}",
                root, backing
            ),
            Self::MissingOrChangedBackingShare { backing } => write!(
                f,
                "synchronized-share backing share {:?} is not mounted exactly as claimed",
                backing
            ),
            Self::BackingShareAccessChanged { backing } => write!(
                f,
                "synchronized-share backing share {:?} access mode changed",
                backing
            ),
            Self::OverlappingRoots { first, second } => write!(
                f,
                "synchronized-share roots {:?} and {:?} overlap",
                first, second
            ),
            Self::UnknownRoot(root) => write!(f, "unknown synchronized-share root id {:?}", root),
            Self::WrongEpoch {
                root,
                actual,
                expected,
            } => write!(
                f,
                "synchronized-share root {:?} has epoch {}; expected {}",
                root, actual, expected
            ),
            Self::WrongDirection => write!(f, "guest receiver accepts host-to-guest records only"),
            Self::WrongSession => write!(
                f,
                "record belongs to a different synchronized-share session"
            ),
            Self::WrongGuestBoot => write!(f, "record belongs to a different guest boot"),
            Self::UnexpectedSequence { actual, expected } => write!(
                f,
                "synchronized-share sequence {} is not the expected {}",
                actual, expected
            ),
            Self::SequenceExhausted => write!(
                f,
                "synchronized-share sequence space is exhausted; session must be replaced"
            ),
            Self::InvalidRelativePath(path) => {
                write!(f, "invalid synchronized-share relative path {:?}", path)
            }
        }
    }
}

impl std::error::Error for ValidationError {}

/// Validates the initial typed message against the exact currently mounted
/// shares. It performs no authentication, I/O, cache creation, or mount. The
/// data-plane receiver authenticates the peer separately and uses the returned
/// session only while the mount generation remains unchanged.
pub fn validate_hello(
    hello: Hello,
    mounted_shares: &[MountedShare],
) -> Result<ValidatedSession, ValidationError> {
    if hello.contract_version != CONTRACT_VERSION {
        return Err(ValidationError::UnsupportedContractVersion {
            actual: hello.contract_version,
        });
    }
    if is_all_zero(&hello.session_id) {
        return Err(ValidationError::ZeroSessionField("session id"));
    }
    if is_all_zero(&hello.guest_boot_id) {
        return Err(ValidationError::ZeroSessionField("guest boot id"));
    }
    if is_all_zero(&hello.peer_capability) {
        return Err(ValidationError::ZeroSessionField("peer capability"));
    }
    if hello.roots.is_empty() || hello.roots.len() > MAX_ROOTS {
        return Err(ValidationError::TooManyRoots {
            actual: hello.roots.len(),
        });
    }

    let mut root_ids = HashSet::with_capacity(hello.roots.len());
    for share in mounted_shares {
        validate_share_tag(&share.tag)?;
        validate_absolute_path("mounted share", &share.guest_path)?;
    }
    let mut roots = Vec::with_capacity(hello.roots.len());
    for root in hello.roots {
        validate_root_id(&root.root_id)?;
        validate_share_tag(&root.backing_share_tag)?;
        if !root_ids.insert(root.root_id.clone()) {
            return Err(ValidationError::DuplicateRootID(root.root_id));
        }
        let guest_path = validate_absolute_path("root", &root.guest_path)?;
        let backing_share_path = validate_absolute_path("backing share", &root.backing_share_path)?;
        if root.epoch == 0 {
            return Err(ValidationError::InvalidEpoch { root: root.root_id });
        }
        if !is_strict_descendant(&guest_path, &backing_share_path) {
            return Err(ValidationError::RootNotStrictlyInsideBackingShare {
                root: guest_path,
                backing: backing_share_path,
            });
        }

        let mounted = mounted_shares
            .iter()
            .find(|share| {
                share.tag == root.backing_share_tag && share.guest_path == backing_share_path
            })
            .ok_or_else(|| ValidationError::MissingOrChangedBackingShare {
                backing: backing_share_path.clone(),
            })?;
        if mounted.read_only != root.read_only {
            return Err(ValidationError::BackingShareAccessChanged {
                backing: backing_share_path,
            });
        }
        roots.push(ValidatedRoot {
            root_id: root.root_id,
            guest_path,
            epoch: root.epoch,
            read_only: root.read_only,
        });
    }

    for (index, root) in roots.iter().enumerate() {
        for other in roots.iter().skip(index + 1) {
            if is_equal_or_descendant(&root.guest_path, &other.guest_path)
                || is_equal_or_descendant(&other.guest_path, &root.guest_path)
            {
                return Err(ValidationError::OverlappingRoots {
                    first: root.guest_path.clone(),
                    second: other.guest_path.clone(),
                });
            }
        }
    }

    Ok(ValidatedSession {
        session_id: hello.session_id,
        guest_boot_id: hello.guest_boot_id,
        roots,
    })
}

impl ValidatedSession {
    /// Validates a host-to-guest record header and advances only the in-memory
    /// sequence cursor. Payload handling remains intentionally absent: after a
    /// real transport exists it must validate digests and the durable journal
    /// before it can acknowledge a record.
    pub fn validate_next_inbound_header(
        &self,
        cursor: &mut SequenceCursor,
        header: &RecordHeader,
    ) -> Result<(), ValidationError> {
        if header.contract_version != CONTRACT_VERSION {
            return Err(ValidationError::UnsupportedContractVersion {
                actual: header.contract_version,
            });
        }
        if header.session_id != self.session_id {
            return Err(ValidationError::WrongSession);
        }
        if header.guest_boot_id != self.guest_boot_id {
            return Err(ValidationError::WrongGuestBoot);
        }
        if header.direction != Direction::HostToGuest {
            return Err(ValidationError::WrongDirection);
        }
        let root = self
            .roots
            .iter()
            .find(|root| root.root_id == header.root_id)
            .ok_or_else(|| ValidationError::UnknownRoot(header.root_id.clone()))?;
        if root.epoch != header.epoch {
            return Err(ValidationError::WrongEpoch {
                root: header.root_id.clone(),
                actual: header.epoch,
                expected: root.epoch,
            });
        }
        if header.sequence != cursor.next_host_to_guest {
            return Err(ValidationError::UnexpectedSequence {
                actual: header.sequence,
                expected: cursor.next_host_to_guest,
            });
        }
        cursor.next_host_to_guest = cursor
            .next_host_to_guest
            .checked_add(1)
            .ok_or(ValidationError::SequenceExhausted)?;
        Ok(())
    }

    /// Validates an entry path for an already-authorized root. It returns only
    /// a lexically constrained relative path; the receiver must still use
    /// descriptor-relative filesystem operations and refuse symlink escapes.
    pub fn validate_entry_path(
        &self,
        root_id: &str,
        path: &str,
    ) -> Result<RelativePath, ValidationError> {
        if self.roots.iter().all(|root| root.root_id != root_id) {
            return Err(ValidationError::UnknownRoot(root_id.to_string()));
        }
        validate_relative_path(path)
    }

    /// Reports whether a root was declared read-only. The receiver uses
    /// this only to reject guest-to-host mutations; it does not grant host
    /// writes until the authenticated initial-sync lifecycle exists.
    pub fn root_is_read_only(&self, root_id: &str) -> Result<bool, ValidationError> {
        self.roots
            .iter()
            .find(|root| root.root_id == root_id)
            .map(|root| root.read_only)
            .ok_or_else(|| ValidationError::UnknownRoot(root_id.to_string()))
    }

    /// Resolves an already-authorized root identifier to its immutable guest
    /// mount-relative path.  The returned path must still be opened with
    /// descriptor-relative, no-follow operations by a receiver; exposing the
    /// string here is not authority to concatenate an untrusted suffix.
    pub fn guest_path_for_root(&self, root_id: &str) -> Result<&str, ValidationError> {
        self.roots
            .iter()
            .find(|root| root.root_id == root_id)
            .map(|root| root.guest_path.as_str())
            .ok_or_else(|| ValidationError::UnknownRoot(root_id.to_string()))
    }

    /// Immutable epoch from the exact accepted root claim.  A receiver must
    /// place this value in every record header instead of inventing a default;
    /// doing so makes a reconnect or mount-generation change fail closed.
    pub fn epoch_for_root(&self, root_id: &str) -> Result<u64, ValidationError> {
        self.roots
            .iter()
            .find(|root| root.root_id == root_id)
            .map(|root| root.epoch)
            .ok_or_else(|| ValidationError::UnknownRoot(root_id.to_string()))
    }
}

/// Validates a nonempty relative entry path. It is deliberately stricter than
/// a generic filesystem API: no leading slash, empty component, dot segment,
/// parent traversal, or NUL can reach the filesystem applier.
pub fn validate_relative_path(path: &str) -> Result<RelativePath, ValidationError> {
    if path.is_empty()
        || path.len() > MAX_PATH_BYTES
        || path.starts_with('/')
        || path.ends_with('/')
        || path.as_bytes().contains(&0)
    {
        return Err(ValidationError::InvalidRelativePath(path.to_string()));
    }
    for component in path.split('/') {
        if component.is_empty() || component == "." || component == ".." || component.len() > 255 {
            return Err(ValidationError::InvalidRelativePath(path.to_string()));
        }
    }
    Ok(RelativePath(path.to_string()))
}

fn validate_root_id(root_id: &str) -> Result<(), ValidationError> {
    if root_id.is_empty()
        || root_id.len() > MAX_ROOT_ID_BYTES
        || !root_id
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_'))
    {
        return Err(ValidationError::InvalidRootID(root_id.to_string()));
    }
    Ok(())
}

fn validate_share_tag(tag: &str) -> Result<(), ValidationError> {
    if tag.is_empty()
        || tag.len() > MAX_SHARE_TAG_BYTES
        || !tag
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_'))
    {
        return Err(ValidationError::InvalidShareTag(tag.to_string()));
    }
    Ok(())
}

fn validate_absolute_path(field: &'static str, path: &str) -> Result<String, ValidationError> {
    if path == "/"
        || path.len() > MAX_PATH_BYTES
        || !path.starts_with('/')
        || path.ends_with('/')
        || path.as_bytes().contains(&0)
    {
        return Err(ValidationError::InvalidAbsolutePath {
            field,
            path: path.to_string(),
        });
    }
    for component in path[1..].split('/') {
        if component.is_empty() || component == "." || component == ".." || component.len() > 255 {
            return Err(ValidationError::InvalidAbsolutePath {
                field,
                path: path.to_string(),
            });
        }
    }
    Ok(path.to_string())
}

fn is_strict_descendant(path: &str, root: &str) -> bool {
    path.len() > root.len()
        && path.starts_with(root)
        && path.as_bytes().get(root.len()) == Some(&b'/')
}

fn is_equal_or_descendant(path: &str, root: &str) -> bool {
    path == root || is_strict_descendant(path, root)
}

fn is_all_zero(bytes: &[u8]) -> bool {
    bytes.iter().all(|byte| *byte == 0)
}
