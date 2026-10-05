// Public, non-secret update configuration. The matching Ed25519 PRIVATE key never enters this repository:
// it lives in the maintainer's login Keychain (service "pl.cmcr.manager.update-signing") or in a 0600 file
// outside the repository (~/.config/cmcr-manager/update-signing.key). See README › „Publikowanie wersji”.
// `scripts/release.sh` refuses to publish when the signing key does not match one of the keys below.

public enum UpdateKeys {
    /// Public GitHub repository that publishes releases ("owner/name").
    public static let repository = "dolegadolegowski/cmcr-manager"

    /// Raw Ed25519 public keys (32 bytes, base64) trusted to sign `cmcr-update.json`.
    ///
    /// Generated with `swift scripts/update-signing.swift keygen` (2026-10-05).
    ///
    /// Rotation: ship one release that lists both the old and the new key (signed with the old one),
    /// then sign later releases with the new key and drop the old one.
    public static let trustedPublicKeys: [String] = [
        "te1xZZbpM8p1XTB5pYykDp6laTwz99J4IW+E997Q5yw=",
    ]
}
