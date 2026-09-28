#!/bin/bash
set -e
cd $(dirname $0)

############################################################
## log
TAG="CURL"
OPENSSL_VERSION="${OPENSSL_VERSION:-3.2.4}"
############################################################

# get latest version
function get_curl_version() {
  KEYWORD="Location: https://github.com/curl/curl/releases/tag/curl-"
  VERSION=$(curl -Isk 'https://github.com/curl/curl/releases/latest' | grep -i "${KEYWORD}" \vert{} sed "s#${KEYWORD}##i" | sed 's#_#.#g' | tr -d '\r')
  echo ${VERSION}
}

# gpg verify
function verify_curl_source() {
  VERSION=$1
  apt-get install -y gnupg gpg-agent > /dev/null

  echo "[${TAG}] downloading gpg public key ..."
  GPGKEY="https://daniel.haxx.se/mykey.asc"
  if [ ! -f mykey.asc ] ; then
    wget -q ${GPGKEY}
  fi

  echo "[${TAG}] verifying source ..."
  gpg --show-keys mykey.asc | grep '^ ' | tr -d ' ' | awk '{print $0":6:"}' > /tmp/ownertrust.txt
  gpg --import-ownertrust < /tmp/ownertrust.txt > /dev/null
  gpg --import mykey.asc > /dev/null
  gpg --verify curl-${VERSION}.tar.bz2.asc curl-${VERSION}.tar.bz2
}

## download source
function get_curl_source() {
  VERSION=$1
  SOURCE="https://curl.se/download/curl-${VERSION}.tar.bz2"
  
  echo "[${TAG}] downloading source ..."
  if [ ! -f curl-${VERSION}.tar.bz2 ] ; then
    wget -q ${SOURCE}
  fi

  echo "[${TAG}] downloading signature file ..."
  if [ ! -f curl-${VERSION}.tar.bz2.asc ] ; then
    wget -q ${SOURCE}.asc
  fi
}

## build dynamic OpenSSL 3.x import libraries
function build_openssl() {
  local arch=$1
  local target="mingw"
  if [ "$arch" = "x86_64" ]; then
    target="mingw64"
  fi

  echo "[${TAG}] preparing OpenSSL ${OPENSSL_VERSION} for${arch} ..."
  if [ ! -f "openssl-${OPENSSL_VERSION}.tar.gz" ] ; then
    wget -q "https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VERSION}/openssl-${OPENSSL_VERSION}.tar.gz" || \
    wget -q "https://www.openssl.org/source/openssl-${OPENSSL_VERSION}.tar.gz"
  fi

  rm -rf "openssl-${OPENSSL_VERSION}-${arch}"
  tar xzf "openssl-${OPENSSL_VERSION}.tar.gz"
  mv "openssl-${OPENSSL_VERSION}" "openssl-${OPENSSL_VERSION}-${arch}"
  cd "openssl-${OPENSSL_VERSION}-${arch}"

  # Configure OpenSSL as shared so curl links against DLL import libs
  ./Configure ${target} shared \
    --cross-compile-prefix=${arch}-w64-mingw32- \
    --prefix=/opt/openssl-${arch} \
    no-tests no-docs no-unit-test

  make -j$(nproc)
  make install_sw
  cd ..
}

## build static curl executable with dynamic OpenSSL support
function build_curl_source() {
  VERSION=$1
  echo "[${TAG}] preparing for build ..."
  
  if [ ! -f release.md ] ; then
cat > release.md<<EOF
# static curl for windows ${CURL_VERSION} (OpenSSL 3.x dynamic runtime)
| Name | Arch | TLS Provider | TLSv1.0 | TLSv1.1 | TLSv1.2 | TLSv1.3 | sha256sum |
|------|------|--------------|---------|---------|---------|---------|-----------|
EOF
  chmod 777 release.md
  fi  

  # install compiler and tools
  apt-get install -y mingw-w64 make perl build-essential pkg-config > /dev/null

  echo "[${TAG}] building source ..."
  rm -rf curl-${VERSION}
  tar xf curl-${VERSION}.tar.bz2

  ARCHS=("i686" "x86_64")
  for arch in ${ARCHS[@]} ; do
      # 1. Build OpenSSL 3.x shared library for this target architecture
      build_openssl ${arch}

      # 2. Build curl
      cd curl-${VERSION}
      make clean || true

      export PKG_CONFIG_PATH="/opt/openssl-${arch}/lib/pkgconfig"

      ./configure \
        --host=${arch}-w64-mingw32 \
        --disable-shared \
        --enable-static \
        --enable-ipv6 \
        --enable-unix-sockets \
        --enable-tls-srp \
        --with-openssl=/opt/openssl-${arch} \
        --with-zlib \
        --disable-ldap \
        --disable-dict \
        --disable-gopher \
        --disable-imap \
        --disable-smtp \
        --disable-rtsp \
        --disable-telnet \
        --disable-tftp \
        --disable-pop3 \
        --disable-mqtt \
        --disable-ftp \
        --disable-smb \
        --without-libpsl

      make -j$(nproc)

      CURL="curl_${arch}_openssl3.exe"
      cp -f src/curl.exe ../${CURL}.nonstrip
      cp -f src/curl.exe ../${CURL}
      ${arch}-w64-mingw32-strip -s ../${CURL}

      SUM1=$(sha256sum ../${CURL}          | awk '{print $1}')
      SUM2=$(sha256sum ../${CURL}.nonstrip | awk '{print $1}')

cat >> ../release.md<<EOF
| ${CURL}          | ${arch} \vert{} OpenSSL 3.x \vert{} :heavy_check_mark: \vert{} :heavy_check_mark: \vert{} :heavy_check_mark: \vert{} :heavy_check_mark: \vert{}${SUM1} |
| ${CURL}.nonstrip | ${arch} \vert{} OpenSSL 3.x \vert{} :heavy_check_mark: \vert{} :heavy_check_mark: \vert{} :heavy_check_mark: \vert{} :heavy_check_mark: \vert{}${SUM2} |
EOF
      cd ..
  done

cat >> release.md<<EOF

## Dynamic SSL Loading
The resulting binaries have \`libcurl\` built-in, but link dynamically against OpenSSL 3.x.
To run on Windows, place \`libcrypto-3.dll\` and \`libssl-3.dll\` (or any binary-compatible OpenSSL 3.2.4 / 3.x DLLs) in the same directory as the executable.
EOF
}

############################################################
apt-get update -y > /dev/null
apt-get install -y curl wget bzip2 > /dev/null

if [ -z ${CURL_VERSION} ] ; then
  CURL_VERSION=$(get_curl_version)
fi
echo "[${TAG}] version=${CURL_VERSION}"

get_curl_source    ${CURL_VERSION}
verify_curl_source ${CURL_VERSION}
build_curl_source  ${CURL_VERSION}
