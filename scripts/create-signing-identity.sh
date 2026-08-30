#!/usr/bin/env bash
# Create a local self-signed certificate so the Keychain stops re-prompting.
#
# Why this exists: an ad-hoc signature's designated requirement is the binary's
# own cdhash, and that changes on EVERY build. macOS therefore treats each
# rebuild as a brand new application, and the keychain ACL — which matched the
# old hash — asks for your password again. "Always Allow" only ever authorises
# the exact build you clicked it on, which during development means a prompt
# every few minutes.
#
# A certificate-based requirement is stable across rebuilds. One prompt, once.
#
# This is a DEVELOPMENT certificate: not a Developer ID, not notarised, nothing
# leaves your machine.
set -euo pipefail

NAME="Runway Dev"
KEYCHAIN="${HOME}/Library/Keychains/login.keychain-db"

if [[ "${EUID}" -eq 0 ]]; then
  echo "Do not run this with sudo — the certificate belongs in your login keychain." >&2
  exit 1
fi

if security find-certificate -c "${NAME}" >/dev/null 2>&1; then
  echo "'${NAME}' already exists — nothing to do."
  exit 0
fi

WORKDIR="$(mktemp -d)"
trap 'rm -rf "${WORKDIR}"' EXIT

cat > "${WORKDIR}/config" <<'CONFIG'
[ req ]
distinguished_name = dn
x509_extensions    = ext
prompt             = no

[ dn ]
CN = Runway Dev

[ ext ]
basicConstraints = critical,CA:false
keyUsage         = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CONFIG

echo "Generating a self-signed code-signing certificate…"
openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout "${WORKDIR}/key.pem" \
  -out "${WORKDIR}/cert.pem" \
  -days 3650 \
  -config "${WORKDIR}/config" >/dev/null 2>&1

openssl pkcs12 -export \
  -inkey "${WORKDIR}/key.pem" \
  -in "${WORKDIR}/cert.pem" \
  -name "${NAME}" \
  -passout pass: \
  -out "${WORKDIR}/identity.p12" >/dev/null 2>&1

echo "Importing into your login keychain (macOS will ask for your password)…"
security import "${WORKDIR}/identity.p12" \
  -k "${KEYCHAIN}" \
  -P "" \
  -T /usr/bin/codesign \
  -T /usr/bin/security

# Let codesign use the key without a prompt of its own.
security set-key-partition-list -S apple-tool:,apple: -k "" "${KEYCHAIN}" >/dev/null 2>&1 || true

# Trust it for code signing, otherwise codesign refuses to use it.
echo "Marking the certificate as trusted for code signing…"
security add-trusted-cert -d -r trustAsRoot -p codeSign -k "${KEYCHAIN}" "${WORKDIR}/cert.pem" \
  || echo "  (could not add trust automatically — open Keychain Access and set 'Code Signing' to 'Always Trust' on '${NAME}')"

echo
echo "Done. 'make app' will now sign with '${NAME}', and the signature survives"
echo "rebuilds — so the keychain only asks once."
