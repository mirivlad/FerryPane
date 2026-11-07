#!/usr/bin/env bash
set -euo pipefail
umask 077
cd "$(dirname "$0")/.."

# Never release an APK with a GitHub runner's ephemeral debug keystore.
: "${FERRYPANE_ANDROID_KEYSTORE_B64:?Repository secret FERRYPANE_ANDROID_KEYSTORE_B64 is required}"
: "${FERRYPANE_ANDROID_STORE_PASSWORD:?Repository secret FERRYPANE_ANDROID_STORE_PASSWORD is required}"

KEYSTORE="$PWD/android/ferrypane-release.p12"
printf '%s' "$FERRYPANE_ANDROID_KEYSTORE_B64" | base64 --decode > "$KEYSTORE"
chmod 600 "$KEYSTORE"

expected='20BD4749485E7C1A5C0EF072077E277FEABD2389E31161B675B4FDDB7407439D'
actual="$(
  keytool -exportcert -keystore "$KEYSTORE" -storetype PKCS12     -storepass "$FERRYPANE_ANDROID_STORE_PASSWORD" -alias ferrypane |
  openssl x509 -inform DER -noout -fingerprint -sha256 |
  cut -d= -f2 | tr -d ':' | tr '[:lower:]' '[:upper:]'
)"
if [[ "$actual" != "$expected" ]]; then
  echo "::error::Android signing certificate mismatch: expected FerryPane identity"
  rm -f "$KEYSTORE"
  exit 1
fi

cat > android/key.properties <<EOF
storePassword=$FERRYPANE_ANDROID_STORE_PASSWORD
keyPassword=$FERRYPANE_ANDROID_STORE_PASSWORD
keyAlias=ferrypane
storeFile=$KEYSTORE
EOF
chmod 600 android/key.properties
echo "FerryPane permanent release certificate verified; signing configured."
