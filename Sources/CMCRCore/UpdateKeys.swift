// Public, non-secret update configuration. The matching Ed25519 PRIVATE key never enters this repository:
// it lives in the maintainer's login Keychain (service "pl.cmcr.manager.update-signing") or in a 0600 file
// outside the repository (~/.config/cmcr-manager/update-signing.key). See README › „Publikowanie wersji”.
// `scripts/release.sh` refuses to publish when the signing key does not match one of the keys below.

public enum UpdateKeys {
    /// Public GitHub repository that publishes releases ("owner/name").
    public static let repository = "dolegadolegowski/cmcr-manager"

    /// Raw Ed25519 public keys (32 bytes, base64) trusted to sign `cmcr-update.json`.
    ///
    /// PLACEHOLDER: the entry below is deliberately not valid base64, so no signature verifies and the app
    /// reports updates as "not configured" (fail closed). Replace it with the output of
    /// `swift scripts/update-signing.swift keygen` before the first release.
    ///
    /// Rotation: ship one release that lists both the old and the new key (signed with the old one),
    /// then sign later releases with the new key and drop the old one.
    public static let trustedPublicKeys: [String] = [
        "PLACEHOLDER_REPLACE_WITH_update-signing.swift_keygen_OUTPUT",
    ]
}
