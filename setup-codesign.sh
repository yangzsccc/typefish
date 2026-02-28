#!/bin/bash
# One-time setup: create a self-signed code signing certificate
# This certificate lets macOS remember Accessibility permissions across rebuilds.
# Works for TypeFish, No-Clue, and any other local dev app.
set -e

CERT_NAME="Local Dev Signing"

# Check if cert already exists
if security find-identity -v -p codesigning 2>&1 | grep -q "$CERT_NAME"; then
    echo "✅ Certificate '$CERT_NAME' already exists"
    security find-identity -v -p codesigning
    exit 0
fi

echo "🔐 Creating self-signed code signing certificate: '$CERT_NAME'"
echo "   This is a ONE-TIME setup. The cert lives in your login keychain."
echo ""

# Create certificate config
TMPDIR_CERT=$(mktemp -d)
cat > "$TMPDIR_CERT/cert.conf" << 'CERTCONF'
[ req ]
default_bits       = 2048
distinguished_name = req_dn
prompt             = no
x509_extensions    = codesign

[ req_dn ]
CN = Local Dev Signing
O  = Personal

[ codesign ]
keyUsage         = digitalSignature
extendedKeyUsage = codeSigning
CERTCONF

# Generate self-signed cert (valid 10 years)
openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$TMPDIR_CERT/key.pem" \
    -out "$TMPDIR_CERT/cert.pem" \
    -days 3650 \
    -config "$TMPDIR_CERT/cert.conf" 2>/dev/null

# Convert to p12 (needed for Keychain import)
openssl pkcs12 -export -legacy \
    -out "$TMPDIR_CERT/cert.p12" \
    -inkey "$TMPDIR_CERT/key.pem" \
    -in "$TMPDIR_CERT/cert.pem" \
    -passout pass:temppass 2>/dev/null

# Import into login keychain
security import "$TMPDIR_CERT/cert.p12" \
    -k ~/Library/Keychains/login.keychain-db \
    -P temppass \
    -T /usr/bin/codesign 2>/dev/null

# Trust the certificate for code signing
# This requires user interaction (password prompt)
echo ""
echo "⚠️  macOS will ask for your login password to trust the certificate."
echo "   This is normal and only happens once."
echo ""
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "" ~/Library/Keychains/login.keychain-db 2>/dev/null || true

# Clean up temp files
rm -rf "$TMPDIR_CERT"

echo ""
echo "✅ Certificate created! Verifying..."
security find-identity -v -p codesigning

echo ""
echo "🎯 Now do ONE more step in Keychain Access:"
echo "   1. Open Keychain Access (Cmd+Space → 'Keychain Access')"
echo "   2. Find 'Local Dev Signing' certificate"
echo "   3. Double-click it → Trust → Code Signing → set to 'Always Trust'"
echo "   4. Close (enter password when prompted)"
echo ""
echo "After that, your apps will keep Accessibility permissions across rebuilds! 🎉"
