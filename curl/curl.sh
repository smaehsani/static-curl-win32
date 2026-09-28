#!/bin/bash
set -e
cd $(dirname $0)
############################################################
## log
TAG="CURL-X86"
############################################################

# get latest version
function get_curl_version() {
  KEYWORD="Location: https://github.com/curl/curl/releases/tag/curl-"
  VERSION=$(curl -Isk 'https://github.com/curl/curl/releases/latest' | grep -i "${KEYWORD}" | sed "s#${KEYWORD}##i" | sed 's#_#.#g' | tr -d '\r')
  echo ${VERSION}
}

# gpg verify
function verify_curl_source() {
  VERSION=$1
  echo "[${TAG}] downloading gpg public key ..."
  GPGKEY="https://daniel.haxx.se/mykey.asc"
  if [ ! -f mykey.asc ] ; then
    wget ${GPGKEY}
  fi

  echo "[${TAG}] verifying source ..."
  gpg --show-keys mykey.asc|grep '^ '|tr -d ' '|awk '{print $0":6:"}' > /tmp/ownertrust.txt
  gpg --import-ownertrust < /tmp/ownertrust.txt > /dev/null
  gpg --import mykey.asc  > /dev/null
  gpg --verify curl-${VERSION}.tar.bz2.asc curl-${VERSION}.tar.bz2
}

## download source
function get_curl_source() {
  VERSION=$1
  SOURCE="https://curl.se/download/curl-${VERSION}.tar.bz2"
  
  echo "[${TAG}] downloading source ..."
  if [ ! -f curl-${VERSION}.tar.bz2 ] ; then
    wget ${SOURCE}
  fi

  echo "[${TAG}] downloading signature file ..."
  if [ ! -f curl-${VERSION}.tar.bz2.asc ] ; then
    wget ${SOURCE}.asc
  fi
}

## build OpenSSL 3.x dynamically
function build_openssl() {
  OPENSSL_VER="3.2.4"
  echo "[${TAG}] building OpenSSL ${OPENSSL_VER} ..."
  
  if [ ! -d "openssl-${OPENSSL_VER}" ]; then
    wget "https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VER}/openssl-${OPENSSL_VER}.tar.gz"
    tar xzf openssl-${OPENSSL_VER}.tar.gz
  fi
  
  cd openssl-${OPENSSL_VER}
  export LDFLAGS="-static-libgcc"
  ./Configure mingw shared --prefix=/opt/openssl-x86 --cross-compile-prefix=i686-w64-mingw32-
  make -j$(nproc)
  make install_sw 
  cd ..

  # Force dynamic OpenSSL link by deleting the static files
  rm -f /opt/openssl-x86/lib/libcrypto.a /opt/openssl-x86/lib/libssl.a
}

## build static curl
function build_curl_source() {
  VERSION=$1
  echo "[${TAG}] preparing for build ..."
  
  if [ ! -f release.md ] ; then
cat > release.md<<EOF
# x86 curl for windows ${CURL_VERSION}
| Name | Arch | TLS Provider | TLSv1.0 | TLSv1.1 | TLSv1.2 | TLSv1.3 | sha256sum |
|------|------|--------------|---------|---------|---------|---------|-----------|
EOF
  chmod 777 release.md
  fi  
  
  echo "[${TAG}] building source ..."
  rm -rf curl-${VERSION}
  tar xf curl-${VERSION}.tar.bz2
  cd curl-${VERSION}

  arch="i686"
  
  export LDFLAGS="-static-libgcc"
  rm -f /usr/${arch}-w64-mingw32/lib/libwinpthread.dll.a || true

  export PKG_CONFIG_PATH="/opt/openssl-x86/lib/pkgconfig"
  export CFLAGS="-I/opt/openssl-x86/include"

  make clean || true
  
  # Note: HTTP, HTTPS, FILE, IPFS, and IPNS are enabled implicitly.
  # The "s" variants (FTPS, MQTTS, WSS, etc) are automatically supported 
  # because OpenSSL is enabled.
  ./configure \
     --host ${arch}-w64-mingw32 \
     --disable-shared \
     --enable-static \
     --enable-ipv6 \
     --enable-unix-sockets \
     --with-openssl=/opt/openssl-x86 \
     --with-zlib \
     --enable-dict \
     --enable-ftp \
     --enable-gopher \
     --enable-imap \
     --enable-pop3 \
     --enable-rtsp \
     --enable-smtp \
     --enable-telnet \
     --enable-tftp \
     --enable-mqtt \
     --enable-ldap \
     --enable-ldaps \
     --enable-websockets \
     --disable-smb \
     --without-libpsl

  make -j$(nproc)

  CURL="curl_${arch}_openssl3.exe"
  cp -f src/curl.exe ../${CURL}.nonstrip
  cp -f src/curl.exe ../${CURL}
  ${arch}-w64-mingw32-strip -s ../${CURL}
  
  cp /opt/openssl-x86/bin/libcrypto-3.dll ../
  cp /opt/openssl-x86/bin/libssl-3.dll ../

  SUM1=$(sha256sum ../${CURL}          | awk '{print $1}')
  SUM2=$(sha256sum ../${CURL}.nonstrip | awk '{print $1}')

cat >> ../release.md<<EOF
| ${CURL}          | ${arch} | openssl | :heavy_check_mark: | :heavy_check_mark: | :heavy_check_mark: | :heavy_check_mark: | ${SUM1} |
| ${CURL}.nonstrip | ${arch} | openssl | :heavy_check_mark: | :heavy_check_mark: | :heavy_check_mark: | :heavy_check_mark: | ${SUM2} |

## Protocols

dict file ftp ftps gopher gophers http https imap imaps ipfs ipns ldap ldaps mqtt mqtts pop3 pop3s rtsp smtp smtps telnet tftp ws wss

## Features

alt-svc AsynchDNS HSTS HTTPS-proxy IPv6 Kerberos Largefile NTLM SPNEGO SSL SSPI threadsafe UnixSockets
EOF

  cd ..
}

############################################################
apt-get update -y > /dev/null
apt-get install -y curl wget bzip2 gnupg gpg-agent mingw-w64 make gcc perl pkg-config > /dev/null
 
if [ -z ${CURL_VERSION} ] ; then
  CURL_VERSION=$(get_curl_version)
fi
echo "[${TAG}] version=${CURL_VERSION}"

get_curl_source    ${CURL_VERSION}
verify_curl_source ${CURL_VERSION}
build_openssl
build_curl_source  ${CURL_VERSION}
