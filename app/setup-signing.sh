#!/bin/bash
# One-time setup: a STABLE self-signed code-signing identity for local dev.
#
# Why this exists
# ---------------
# This machine has no Developer ID, so build.sh otherwise ad-hoc-signs. An ad-hoc
# signature has no certificate to name, so the app's *designated requirement*
# degrades to the binary's own cdhash — which changes on every rebuild. macOS TCC
# keys each permission grant to that requirement, so every rebuild looks like a
# "different program" and macOS re-asks for permission. For this app that means the
# Accessibility grant behind the ⌘U shortcut is lost on every rebuild.
#
# Signing with a stable self-signed cert fixes it: the designated requirement then
# names the certificate's hash (constant across rebuilds) instead of the cdhash, so
# the Accessibility grant persists. (This is orthogonal to the Keychain read path,
# which shells out to /usr/bin/security and is unaffected either way.)
#
# Self-signed => untrusted on any OTHER machine. This is local-dev only; a real
# Developer ID cert is the answer if this is ever distributed. build.sh still prints
# a loud AD-HOC banner when no signing cert is present, so a non-distributable build
# is never shipped unknowingly.
#
# Idempotent: re-running when the identity already exists is a no-op.
#
# NOTE: `security find-identity -v -p codesigning` reports 0 valid identities for a
# self-signed cert and that is FINE — codesign still signs with it by name. Don't
# chase that number; check `codesign -d -r-` on a built app instead.
set -euo pipefail

SIGNING_ID="${CLAUDEUSAGEBAR_SIGNING_ID:-ClaudeUsageBar Dev}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-certificate -c "$SIGNING_ID" >/dev/null 2>&1; then
    echo "✅ Signing identity '$SIGNING_ID' already present — nothing to do."
    exit 0
fi

# Private-key material is written to a temp dir and destroyed on exit; the key lives
# in the keychain after import, never on disk.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "=== creating self-signed code-signing cert '$SIGNING_ID' ==="
openssl req -x509 -newkey rsa:2048 -days 3650 -keyout "$WORK/dev.key" \
    -out "$WORK/dev.crt" -nodes -subj "/CN=$SIGNING_ID" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=codeSigning"

openssl pkcs12 -export -legacy -in "$WORK/dev.crt" -inkey "$WORK/dev.key" \
    -out "$WORK/dev.p12" -password pass:dev

echo "=== importing into login keychain (may prompt for your login password) ==="
# -T /usr/bin/codesign pre-authorises codesign to use the key without a per-build
# prompt. macOS may still ask once to confirm the keychain change.
security import "$WORK/dev.p12" -k "$KEYCHAIN" -P dev -T /usr/bin/codesign

if security find-certificate -c "$SIGNING_ID" >/dev/null 2>&1; then
    echo "✅ '$SIGNING_ID' installed. Rebuilds will now reuse a stable identity,"
    echo "   so the Accessibility grant for ⌘U survives future builds."
else
    echo "❌ Import did not land — '$SIGNING_ID' not found after import." >&2
    exit 1
fi
