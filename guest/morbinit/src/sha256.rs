//! SHA-256, hand-rolled, because morbinit has no dependencies.
//!
//! It exists for exactly one job: the Kubernetes payload arrives over vsock
//! port 2377 as ~122 MB of raw bytes (see `k8s.rs`), and the guest has to be
//! able to say "the binary I just wrote to the persistent disk is byte-for-byte
//! the one the host meant to send" before it ever executes it. A length check
//! is not that statement — a truncated-then-padded transfer, a half-written
//! file left by a crash mid-install, and a corrupted vsock stream all have the
//! right length.
//!
//! This is the standard FIPS 180-4 construction with no cleverness: 64-byte
//! blocks, the eight working variables, the 64 round constants. It streams
//! (`update` may be called with arbitrary chunk sizes) because the caller is
//! reading a socket, not holding 122 MB in memory.
//!
//! Portable, `#![no_std]`-shaped code over plain integers, so it unit tests on
//! the macOS dev host against the published vectors.

/// The first 32 bits of the fractional parts of the cube roots of the first
/// 64 primes — the round constants from FIPS 180-4 §4.2.2.
const K: [u32; 64] = [
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
];

/// The first 32 bits of the fractional parts of the square roots of the first
/// eight primes (FIPS 180-4 §5.3.3).
const H0: [u32; 8] = [
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
];

/// A streaming SHA-256 hasher.
pub struct Sha256 {
    state: [u32; 8],
    /// Partial block carried between `update` calls.
    buffer: [u8; 64],
    buffered: usize,
    /// Total message length in bytes, for the length suffix.
    total: u64,
}

impl Default for Sha256 {
    fn default() -> Self {
        Self::new()
    }
}

impl Sha256 {
    pub fn new() -> Self {
        Self {
            state: H0,
            buffer: [0u8; 64],
            buffered: 0,
            total: 0,
        }
    }

    /// Absorb `data`. Any chunking is allowed; the result depends only on the
    /// concatenation.
    pub fn update(&mut self, mut data: &[u8]) {
        self.total = self.total.wrapping_add(data.len() as u64);

        // Top up a partial block first.
        if self.buffered > 0 {
            let want = 64 - self.buffered;
            let take = want.min(data.len());
            self.buffer[self.buffered..self.buffered + take].copy_from_slice(&data[..take]);
            self.buffered += take;
            data = &data[take..];
            if self.buffered == 64 {
                let block = self.buffer;
                self.compress(&block);
                self.buffered = 0;
            }
        }

        // Then whole blocks straight out of the caller's slice.
        while data.len() >= 64 {
            let (block, rest) = data.split_at(64);
            let mut fixed = [0u8; 64];
            fixed.copy_from_slice(block);
            self.compress(&fixed);
            data = rest;
        }

        if !data.is_empty() {
            self.buffer[..data.len()].copy_from_slice(data);
            self.buffered = data.len();
        }
    }

    /// Finish and return the 32-byte digest.
    pub fn finalize(mut self) -> [u8; 32] {
        // Padding: 0x80, then zeros, then the bit length as a big-endian u64,
        // to a 64-byte boundary.
        let bit_len = self.total.wrapping_mul(8);
        self.update_no_count(&[0x80]);
        while self.buffered != 56 {
            self.update_no_count(&[0x00]);
        }
        self.update_no_count(&bit_len.to_be_bytes());
        debug_assert_eq!(self.buffered, 0);

        let mut out = [0u8; 32];
        for (i, word) in self.state.iter().enumerate() {
            out[i * 4..i * 4 + 4].copy_from_slice(&word.to_be_bytes());
        }
        out
    }

    /// `update` without touching the length counter — used by the padding,
    /// which must not be counted as message bytes.
    fn update_no_count(&mut self, data: &[u8]) {
        for &byte in data {
            self.buffer[self.buffered] = byte;
            self.buffered += 1;
            if self.buffered == 64 {
                let block = self.buffer;
                self.compress(&block);
                self.buffered = 0;
            }
        }
    }

    fn compress(&mut self, block: &[u8; 64]) {
        let mut w = [0u32; 64];
        for i in 0..16 {
            w[i] = u32::from_be_bytes([
                block[i * 4],
                block[i * 4 + 1],
                block[i * 4 + 2],
                block[i * 4 + 3],
            ]);
        }
        for i in 16..64 {
            let s0 = w[i - 15].rotate_right(7) ^ w[i - 15].rotate_right(18) ^ (w[i - 15] >> 3);
            let s1 = w[i - 2].rotate_right(17) ^ w[i - 2].rotate_right(19) ^ (w[i - 2] >> 10);
            w[i] = w[i - 16]
                .wrapping_add(s0)
                .wrapping_add(w[i - 7])
                .wrapping_add(s1);
        }

        let [mut a, mut b, mut c, mut d, mut e, mut f, mut g, mut h] = self.state;

        for i in 0..64 {
            let s1 = e.rotate_right(6) ^ e.rotate_right(11) ^ e.rotate_right(25);
            let ch = (e & f) ^ ((!e) & g);
            let temp1 = h
                .wrapping_add(s1)
                .wrapping_add(ch)
                .wrapping_add(K[i])
                .wrapping_add(w[i]);
            let s0 = a.rotate_right(2) ^ a.rotate_right(13) ^ a.rotate_right(22);
            let maj = (a & b) ^ (a & c) ^ (b & c);
            let temp2 = s0.wrapping_add(maj);

            h = g;
            g = f;
            f = e;
            e = d.wrapping_add(temp1);
            d = c;
            c = b;
            b = a;
            a = temp1.wrapping_add(temp2);
        }

        for (slot, value) in self
            .state
            .iter_mut()
            .zip([a, b, c, d, e, f, g, h].into_iter())
        {
            *slot = slot.wrapping_add(value);
        }
    }
}

/// Lower-case hex of a digest, which is the form every checksum file and
/// every line of `scripts/fetch-guest-assets.sh` uses.
pub fn hex(digest: &[u8; 32]) -> String {
    const DIGITS: &[u8; 16] = b"0123456789abcdef";
    let mut s = String::with_capacity(64);
    for byte in digest {
        s.push(DIGITS[(byte >> 4) as usize] as char);
        s.push(DIGITS[(byte & 0x0f) as usize] as char);
    }
    s
}

/// One-shot convenience: hex digest of a whole slice.
///
/// Only the tests call this — the production paths all stream, because both of
/// the things morbinit hashes are tens of megabytes. It stays because the
/// published SHA-256 vectors are stated as "the digest of this string", and a
/// test that has to build a hasher to check one is a test that is checking the
/// hasher's plumbing as much as its arithmetic.
#[cfg_attr(not(test), allow(dead_code))]
pub fn hex_of(data: &[u8]) -> String {
    let mut h = Sha256::new();
    h.update(data);
    hex(&h.finalize())
}

/// Size of the read buffer used by `hash_file`, matched to the payload
/// receiver's write chunk so both sides move the same unit of work.
const FILE_CHUNK: usize = 1024 * 1024;

/// Hex digest of a whole file, read in chunks.
///
/// Streaming rather than slurping matters here: the Kubernetes payload is a
/// ~74 MB and a ~49 MB executable, and morbinit is PID 1 in a guest whose
/// entire root filesystem is RAM. Reading either one into a `Vec` to hash it
/// would spend the memory the cluster is about to need.
pub fn hash_file(path: &str) -> std::io::Result<String> {
    use std::io::Read;

    let mut file = std::fs::File::open(path)?;
    let mut hasher = Sha256::new();
    let mut chunk = vec![0u8; FILE_CHUNK];
    loop {
        let n = file.read(&mut chunk)?;
        if n == 0 {
            break;
        }
        hasher.update(&chunk[..n]);
    }
    Ok(hex(&hasher.finalize()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hash_file_matches_the_in_memory_digest_over_many_chunks() {
        // Bigger than FILE_CHUNK so the file path exercises its read loop
        // rather than a single read. The property under test is the one the
        // payload verifier depends on: the digest is a function of the bytes,
        // never of how the reads happened to split them.
        let data: Vec<u8> = (0..(FILE_CHUNK as u32 + 12_345))
            .map(|i| (i % 253) as u8)
            .collect();
        let path =
            std::env::temp_dir().join(format!("morbinit-sha256-hashfile-{}", std::process::id()));
        std::fs::write(&path, &data).unwrap();

        let from_file = hash_file(path.to_str().unwrap());
        let _ = std::fs::remove_file(&path);

        assert_eq!(from_file.unwrap(), hex_of(&data));
    }

    #[test]
    fn hash_file_reports_a_missing_file_rather_than_panicking() {
        // The verifier calls this on a path that may legitimately not exist
        // (nothing staged yet), and "no payload" must be an answer, not a
        // crash in PID 1.
        assert!(hash_file("/definitely/not/a/real/path/morbstack-test").is_err());
    }

    #[test]
    fn matches_the_published_vectors() {
        // FIPS 180-4 / NIST CAVP examples.
        assert_eq!(
            hex_of(b""),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        );
        assert_eq!(
            hex_of(b"abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
        assert_eq!(
            hex_of(b"abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"),
            "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
        );
    }

    #[test]
    fn a_million_a_characters() {
        // The classic long-message vector: catches a broken length counter,
        // which a short input cannot.
        let mut h = Sha256::new();
        let chunk = vec![b'a'; 1000];
        for _ in 0..1000 {
            h.update(&chunk);
        }
        assert_eq!(
            hex(&h.finalize()),
            "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0"
        );
    }

    #[test]
    fn chunking_does_not_change_the_digest() {
        // The property the install path depends on: the socket hands us
        // whatever sizes the kernel felt like, and the answer must not care.
        let data: Vec<u8> = (0..5000u32).map(|i| (i % 251) as u8).collect();
        let once = hex_of(&data);

        for chunk in [1usize, 7, 63, 64, 65, 128, 1000, 4096] {
            let mut h = Sha256::new();
            for part in data.chunks(chunk) {
                h.update(part);
            }
            assert_eq!(hex(&h.finalize()), once, "chunk size {} disagreed", chunk);
        }
    }

    #[test]
    fn block_boundary_lengths_are_padded_correctly() {
        // 55/56/57 and 63/64/65 are where the length suffix does or does not
        // fit in the final block — the classic off-by-one in a hand-rolled
        // SHA-2 padding.
        let expected = [
            (
                55usize,
                "9f4390f8d30c2dd92ec9f095b65e2b9ae9b0a925a5258e241c9f1e910f734318",
            ),
            (
                56,
                "b35439a4ac6f0948b6d6f9e3c6af0f5f590ce20f1bde7090ef7970686ec6738a",
            ),
            (
                57,
                "f13b2d724659eb3bf47f2dd6af1accc87b81f09f59f2b75e5c0bed6589dfe8c6",
            ),
            (
                63,
                "7d3e74a05d7db15bce4ad9ec0658ea98e3f06eeecf16b4c6fff2da457ddc2f34",
            ),
            (
                64,
                "ffe054fe7ae0cb6dc65c3af9b61d5209f439851db43d0ba5997337df154668eb",
            ),
            (
                65,
                "635361c48bb9eab14198e76ea8ab7f1a41685d6ad62aa9146d301d4f17eb0ae0",
            ),
        ];
        for (len, want) in expected {
            assert_eq!(hex_of(&vec![b'a'; len]), want, "length {}", len);
        }
    }
}
