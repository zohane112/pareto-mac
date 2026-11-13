#!/bin/bash
# The app's own signing certificate, made once and kept outside the project, in
# ~/Library/Application Support/CtrlFByMeaning/signing, so it's never zipped or shared.
#
# Why: macOS remembers the Accessibility and Screen Recording switches for an app by its
# signature. An ad-hoc signature changes with every build, so each update would quietly lose
# both permissions. A fixed certificate keeps them. It isn't Apple's Developer ID, so a
# downloaded copy still needs Open Anyway once.
#
#   source signing.sh     sets SIGN_KEYCHAIN and SIGN_ID (empty if it couldn't be made)
set -uo pipefail
SIGN_DIR="$HOME/Library/Application Support/CtrlFByMeaning/signing"
SIGN_KEYCHAIN="$SIGN_DIR/signing.keychain-db"
SIGN_ID=""

if [[ ! -f "$SIGN_KEYCHAIN" ]]; then
  mkdir -p "$SIGN_DIR"
  chmod 700 "$SIGN_DIR"
  work="$(mktemp -d)"
  cat > "$work/req.cnf" <<'EOF'
[req]
distinguished_name = dn
prompt = no
x509_extensions = ext
[dn]
CN = Ctrl+F by meaning
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF
  openssl req -x509 -newkey rsa:2048 -nodes -keyout "$work/key.pem" -out "$work/cert.pem" -days 7300 -config "$work/req.cnf" 2>/dev/null \
    && openssl pkcs12 -export -inkey "$work/key.pem" -in "$work/cert.pem" -out "$work/id.p12" -passout pass:import 2>/dev/null \
    && openssl rand -hex 24 > "$SIGN_DIR/password" && chmod 600 "$SIGN_DIR/password" \
    && security create-keychain -p "$(cat "$SIGN_DIR/password")" "$SIGN_KEYCHAIN" \
    && security set-keychain-settings "$SIGN_KEYCHAIN" \
    && security unlock-keychain -p "$(cat "$SIGN_DIR/password")" "$SIGN_KEYCHAIN" \
    && security import "$work/id.p12" -k "$SIGN_KEYCHAIN" -P import -T /usr/bin/codesign >/dev/null \
    && security set-key-partition-list -S apple-tool:,apple: -s -k "$(cat "$SIGN_DIR/password")" "$SIGN_KEYCHAIN" >/dev/null 2>&1
  rm -rf "$work"
fi

if [[ -f "$SIGN_KEYCHAIN" && -f "$SIGN_DIR/password" ]]; then
  security unlock-keychain -p "$(cat "$SIGN_DIR/password")" "$SIGN_KEYCHAIN" 2>/dev/null
  SIGN_ID="$(security find-identity -p codesigning "$SIGN_KEYCHAIN" 2>/dev/null | awk '/"Ctrl\+F by meaning"/ {print $2; exit}')"
fi
