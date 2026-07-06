#!/usr/bin/env bash
set -euo pipefail

ALIAS="${ALIAS:-jmapi}"
KEY_STORE_PASSWORD="${KEY_STORE_PASSWORD:-$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32)}"
KEY_PASSWORD="${KEY_PASSWORD:-$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32)}"

keytool \
  -genkeypair \
  -v \
  -keystore signingkey.jks \
  -alias "${ALIAS}" \
  -keyalg RSA \
  -keysize 2048 \
  -validity 10000 \
  -storepass "${KEY_STORE_PASSWORD}" \
  -keypass "${KEY_PASSWORD}" \
  -dname "CN=JM API Extension,O=Personal,C=CN"

base64 -w 0 signingkey.jks > signingkey.jks.base64
SIGNING_KEYSTORE_BASE64="$(cat signingkey.jks.base64)"

cat <<EOF

Add these GitHub Actions secrets:
SIGNING_KEYSTORE_BASE64=${SIGNING_KEYSTORE_BASE64}
ALIAS=${ALIAS}
KEY_STORE_PASSWORD=${KEY_STORE_PASSWORD}
KEY_PASSWORD=${KEY_PASSWORD}
EOF

