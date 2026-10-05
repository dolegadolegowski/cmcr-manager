#!/bin/bash
# Creates a stable, self-signed code signing identity for CMCR Manager (no Apple Developer account needed).
#
#   scripts/make-signing-identity.sh                      → login keychain, name "CMCR Manager Code Signing"
#   scripts/make-signing-identity.sh --keychain PLIK      → another keychain file (must exist and be unlocked)
#   scripts/make-signing-identity.sh --export kopia.p12   → additionally saves a password-protected backup
#
# Why: an ad-hoc signature ("-") is tied to the exact build, so after every automatic update macOS treats
# CMCR Manager as a different app and asks again for access to the administrator password stored in the
# Keychain. With this identity the app's designated requirement becomes
#   identifier "pl.cmcr.manager" and certificate leaf = H"<certificate hash>"
# which stays the same across builds signed with the same certificate. build-app.sh picks the identity up
# automatically (or set CMCR_SIGN_IDENTITY / CMCR_SIGN_KEYCHAIN).
#
# The certificate is NOT trusted system-wide and the script never changes trust settings: code signing and
# Keychain access lists do not need trust. Gatekeeper still treats the app as unnotarized (first install:
# Ustawienia systemowe › Prywatność i ochrona › „Otwórz mimo to”), exactly like with an ad-hoc signature.
#
# Keep the identity: every release must be signed with the same certificate. Back it up with --export and
# restore on another Mac with: security import kopia.p12 -k ~/Library/Keychains/login.keychain-db -T /usr/bin/codesign
set -euo pipefail

NAME="CMCR Manager Code Signing"
KEYCHAIN=""
EXPORT=""
DAYS=3650
while [ $# -gt 0 ]; do
  case "$1" in
    --keychain) KEYCHAIN=$2; shift 2 ;;
    --name) NAME=$2; shift 2 ;;
    --export) EXPORT=$2; shift 2 ;;
    --days) DAYS=$2; shift 2 ;;
    -h|--help) sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Nieznana opcja: $1" >&2; exit 64 ;;
  esac
done
if [ -z "$KEYCHAIN" ]; then
  KEYCHAIN=$(security default-keychain -d user | tr -d ' "')
fi
[ -f "$KEYCHAIN" ] || { echo "✘ Brak pęku kluczy $KEYCHAIN" >&2; exit 1; }
OPENSSL=/usr/bin/openssl   # LibreSSL: its PKCS#12 encryption is the one `security import` understands

if security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null | grep -qF "\"$NAME\""; then
  echo "✔ Tożsamość „$NAME” już istnieje w $KEYCHAIN – nic nie zmieniono."
  security find-identity -p codesigning "$KEYCHAIN" | grep -F "\"$NAME\""
  exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
chmod 700 "$TMP"
cat > "$TMP/openssl.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
O = CMCR
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
EOF
"$OPENSSL" req -x509 -newkey rsa:3072 -sha256 -days "$DAYS" -nodes -config "$TMP/openssl.cnf" \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
P12_PASSWORD=$("$OPENSSL" rand -hex 24)
"$OPENSSL" pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" \
  -passout "pass:$P12_PASSWORD" -out "$TMP/identity.p12"
# -T: codesign may use the private key without asking every time.
security import "$TMP/identity.p12" -k "$KEYCHAIN" -f pkcs12 -P "$P12_PASSWORD" -T /usr/bin/codesign >/dev/null
echo "✔ Utworzono tożsamość „$NAME” w $KEYCHAIN"
openssl_fingerprint=$("$OPENSSL" x509 -in "$TMP/cert.pem" -noout -fingerprint -sha1 | cut -d= -f2 | tr -d ':')
echo "  SHA-1 certyfikatu: $openssl_fingerprint"

if [ -n "$EXPORT" ]; then
  echo "Hasło kopii zapasowej $EXPORT (zapamiętaj je):"
  "$OPENSSL" pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" -out "$EXPORT"
  chmod 600 "$EXPORT"
  echo "✔ Kopia zapasowa: $EXPORT (przechowuj poza repozytorium)"
fi

cat <<EOF

Dalej:
  • scripts/build-app.sh użyje tej tożsamości automatycznie.
  • Przy pierwszym podpisywaniu macOS może zapytać, czy codesign może użyć klucza – wybierz „Zawsze pozwalaj”.
  • Po pierwszym uruchomieniu aplikacji podpisanej tym certyfikatem macOS jeszcze raz zapyta o dostęp do
    zapisanego hasła administratora („Zawsze pozwalaj”); kolejne uaktualnienia nie powinny już o to pytać.
EOF
