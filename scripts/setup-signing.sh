#!/bin/zsh
# Creates (once) a local self-signed code-signing identity in its own keychain (~/.fala-signing).
# A stable identity keeps macOS privacy permissions (Accessibility, Microphone) across rebuilds;
# ad-hoc signatures change with every build and macOS treats each build as a new app.
set -euo pipefail
D=$HOME/.fala-signing
K=$D/fala.keychain-db
NAME="Fala Local Signing"

if [[ ! -f $K ]]; then
  mkdir -p $D && chmod 700 $D
  cd $D
  cat > cert.cnf <<'CNF'
[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN=Fala Local Signing
[ext]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
CNF
  openssl req -x509 -newkey rsa:2048 -nodes -keyout key.pem -out cert.pem -days 3650 -config cert.cnf 2>/dev/null
  openssl pkcs12 -export -inkey key.pem -in cert.pem -out id.p12 -passout pass:fala -name "$NAME" -legacy 2>/dev/null \
    || openssl pkcs12 -export -inkey key.pem -in cert.pem -out id.p12 -passout pass:fala -name "$NAME"
  security create-keychain -p fala $K
  security set-keychain-settings $K
  security unlock-keychain -p fala $K
  security import id.p12 -k $K -P fala -T /usr/bin/codesign -A >/dev/null
  security set-key-partition-list -S apple-tool:,apple: -s -k fala $K >/dev/null
  rm -f key.pem id.p12
fi

security unlock-keychain -p fala $K
current=$(security list-keychains -d user | tr -d '"' | xargs)
if [[ $current != *fala.keychain-db* ]]; then
  security list-keychains -d user -s ${=current} $K
fi
