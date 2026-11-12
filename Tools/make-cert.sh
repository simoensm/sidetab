#!/bin/bash
# Creates a self-signed code-signing certificate, "SideTab Local Signing", in the
# login keychain. Signing every build with the same certificate keeps macOS's
# screen recording permission across rebuilds (ad-hoc signatures change each time).
# Runs once; build.sh calls it when the certificate is missing.
set -euo pipefail

name="SideTab Local Signing"
if security find-identity -p codesigning | grep -q "$name"; then
  exit 0
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

cat > "$work/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $name
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF

/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$work/key.pem" -out "$work/cert.pem" -config "$work/cert.cnf" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$work/key.pem" -in "$work/cert.pem" \
  -name "$name" -passout pass:sidetab -out "$work/cert.p12" 2>/dev/null

security import "$work/cert.p12" -k ~/Library/Keychains/login.keychain-db \
  -P sidetab -T /usr/bin/codesign >/dev/null

# Trust it for code signing (macOS asks for your password once).
security add-trusted-cert -r trustRoot -p codeSign -k ~/Library/Keychains/login.keychain-db "$work/cert.pem" \
  || echo "Couldn't mark the certificate as trusted; signing should still work."

echo "Created the \"$name\" certificate in your login keychain."
