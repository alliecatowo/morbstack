// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// Shared support for turning a kubeconfig's embedded client-key PEM into the byte
// layout `SecKeyCreateWithData` actually wants.
//
// k3s (and most modern issuers) hand out ECDSA client keys by default; only older
// setups issue RSA. The two are not interchangeable at the `Security` framework
// boundary: `SecKeyCreateWithData` wants PKCS#1 DER for RSA, which is exactly what
// a `-----BEGIN RSA PRIVATE KEY-----` document already contains, but it refuses SEC1
// DER for EC outright — a `-----BEGIN EC PRIVATE KEY-----` document needs to become
// Apple's own ANSI X9.63 external representation (`04 || X || Y || K`) first. This
// logic used to live only in the app's `KubernetesAPIClient`; `K8sResourceReader`
// (the daemon-owned reader) had an independent implementation that predated the fix
// and still assumed every client key was RSA, so it failed against every real k3s
// cluster. Both now share this one implementation so the bug cannot recur in only
// one of the two readers.
import Foundation
import Security

public enum KubernetesClientTLS {

    /// Strips an optional PEM envelope down to raw DER. Kubeconfig scalars are
    /// already base64-decoded by the caller; this only removes the
    /// `-----BEGIN ...-----` / `-----END ...-----` wrapper on top of that, and
    /// passes already-bare DER through unchanged.
    public static func der(from data: Data) -> Data? {
        guard let text = String(data: data, encoding: .utf8) else { return data }
        guard text.contains("-----BEGIN ") else { return data }
        let payload = text
            .split(whereSeparator: \.isNewline)
            .filter { !$0.hasPrefix("-----") }
            .joined()
        return Data(base64Encoded: payload)
    }

    /// The client key's algorithm, read from its PEM header. `-----BEGIN EC
    /// PRIVATE KEY-----` (SEC1) is what k3s issues by default; `-----BEGIN RSA
    /// PRIVATE KEY-----` (PKCS#1) is the older shape some other issuers still
    /// use. Unrecognised or unlabeled (PKCS#8 `-----BEGIN PRIVATE KEY-----`)
    /// data defaults to EC, since that is the actual default for every
    /// Morbstack-generated kubeconfig today; a mismatch fails fast in
    /// `SecKeyCreateWithData` rather than silently misreading key bytes.
    public static func keyType(from data: Data) -> CFString {
        guard let text = String(data: data, encoding: .utf8) else { return kSecAttrKeyTypeEC }
        if text.contains("-----BEGIN RSA PRIVATE KEY-----") { return kSecAttrKeyTypeRSA }
        return kSecAttrKeyTypeEC
    }

    /// The bytes `SecKeyCreateWithData` actually wants, which is not the same
    /// layout for every key type.
    ///
    /// For RSA, `der` (PKCS#1 DER, from a `-----BEGIN RSA PRIVATE KEY-----`
    /// document) already *is* that external representation — pass it straight
    /// through.
    ///
    /// For EC, `der` is the SEC1 DER a `-----BEGIN EC PRIVATE KEY-----`
    /// document contains (RFC 5915: `SEQUENCE { INTEGER version, OCTET STRING
    /// privateKey, [0] parameters OPTIONAL, [1] publicKey OPTIONAL }`), which
    /// `SecKeyCreateWithData` does not accept for an EC key at all. Apple's
    /// external representation for an EC private key is instead the ANSI
    /// X9.63 form `04 || X || Y || K` — the public point concatenated with
    /// the big-endian private scalar (see "Storing Keys as Data" in Apple's
    /// Security documentation). `K` is read out of the SEC1 document; `X ||
    /// Y` is read from the certificate's own public key via
    /// `SecCertificateCopyKey` + `SecKeyCopyExternalRepresentation` rather
    /// than hand-parsed out of the SEC1 document's optional `[1]` field,
    /// since the certificate already carries it and Apple's own code is what
    /// extracts it.
    public static func secKeyExternalRepresentation(
        der: Data, keyType: CFString, certificate: SecCertificate
    ) -> Data? {
        guard keyType == kSecAttrKeyTypeEC else { return der }
        guard let scalar = ecPrivateScalar(fromSEC1DER: der),
              let publicKey = SecCertificateCopyKey(certificate)
        else { return nil }
        var error: Unmanaged<CFError>?
        guard let publicKeyData = SecKeyCopyExternalRepresentation(publicKey, &error) as Data?
        else { return nil }
        return publicKeyData + scalar
    }

    /// Reads the raw private scalar `K` out of a SEC1 `ECPrivateKey` DER
    /// document. Only the two fixed leading fields are read — the version
    /// `INTEGER` (discarded) and the `privateKey` `OCTET STRING` — because the
    /// public half comes from the certificate instead of the document's
    /// optional `[1]` field.
    private static func ecPrivateScalar(fromSEC1DER der: Data) -> Data? {
        var reader = DERReader(remaining: der)
        guard let sequence = reader.readValue(expectedTag: 0x30) else { return nil }
        var body = DERReader(remaining: sequence)
        guard body.readValue(expectedTag: 0x02) != nil else { return nil }  // version
        return body.readValue(expectedTag: 0x04)  // privateKey OCTET STRING
    }

    /// The minimal DER TLV reader `ecPrivateScalar` needs: read one
    /// tag/length/value off the front of `remaining` at a time. This is not a
    /// general ASN.1 parser — it only reads the two fixed-position, top-level
    /// fields SEC1 guarantees are first.
    private struct DERReader {
        var remaining: Data

        mutating func readValue(expectedTag: UInt8) -> Data? {
            guard let tag = remaining.first, tag == expectedTag else { return nil }
            remaining = remaining.dropFirst()
            guard let lengthByte = remaining.first else { return nil }
            remaining = remaining.dropFirst()
            let length: Int
            if lengthByte & 0x80 == 0 {
                length = Int(lengthByte)
            } else {
                let byteCount = Int(lengthByte & 0x7F)
                guard byteCount > 0, byteCount <= 4, remaining.count >= byteCount else { return nil }
                var accumulated = 0
                for _ in 0..<byteCount {
                    accumulated = (accumulated << 8) | Int(remaining.first!)
                    remaining = remaining.dropFirst()
                }
                length = accumulated
            }
            guard length >= 0, remaining.count >= length else { return nil }
            let value = remaining.prefix(length)
            remaining = remaining.dropFirst(length)
            return Data(value)
        }
    }
}
