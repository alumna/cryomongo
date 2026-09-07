#!/usr/bin/env bash
# Download official libmongocrypt 1.20.4 prebuilts. Does not commit the .so.
# Writes cryomongo/vendor/libmongocrypt/ (gitignored).
#
# Usage:
#   scripts/vendor-libmongocrypt.sh
#   FORCE=1 scripts/vendor-libmongocrypt.sh
#
# Linux uses the nocrypto tarball (no OpenSSL in the .so). The driver registers
# OpenSSL crypto hooks. macOS universal and Windows x86_64 use the official
# names from the GitHub release. No source build in this script.
#
# Prints LIBMONGOCRYPT_VENDOR=... on success. GitHub CI can append that.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${LIBMONGOCRYPT_VERSION:-1.20.4}"
VENDOR="${ROOT}/vendor/libmongocrypt"
CACHE="${ROOT}/tmp"
SUMS="${ROOT}/scripts/libmongocrypt-${VERSION}.sha256"
BASE_URL="${LIBMONGOCRYPT_BASE_URL:-https://github.com/mongodb/libmongocrypt/releases/download/${VERSION}}"

file_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    echo "need sha256sum or shasum" >&2
    exit 1
  fi
}

have_lib() {
  [[ -e "${VENDOR}/lib/libmongocrypt.so" ||
    -e "${VENDOR}/lib/libmongocrypt.dylib" ||
    -e "${VENDOR}/lib/libmongocrypt.0.dylib" ||
    -e "${VENDOR}/lib/mongocrypt.dll" ]]
}

os="$(uname -s 2>/dev/null || echo unknown)"
os_lc="$(printf '%s' "$os" | tr '[:upper:]' '[:lower:]')"
arch="$(uname -m 2>/dev/null || echo unknown)"

asset=""
case "$os_lc" in
  linux)
    case "$arch" in
      x86_64 | amd64)
        asset="libmongocrypt-linux-x86_64-glibc_2_7-nocrypto-${VERSION}.tar.gz"
        ;;
      aarch64 | arm64)
        asset="libmongocrypt-linux-arm64-glibc_2_17-nocrypto-${VERSION}.tar.gz"
        ;;
    esac
    ;;
  darwin)
    asset="libmongocrypt-macos-universal-${VERSION}.tar.gz"
    ;;
  mingw* | msys* | cygwin* | windows_nt*)
    asset="libmongocrypt-windows-x86_64-${VERSION}.tar.gz"
    ;;
esac

if [[ -z "$asset" ]]; then
  echo "No official libmongocrypt ${VERSION} tarball for ${os} ${arch}." >&2
  echo "This script does not build from source. Set USE_SYSTEM_LIBMONGOCRYPT=true if the OS has libmongocrypt >= 1.20.0." >&2
  exit 1
fi

if [[ "${FORCE:-}" != "1" && -f "${VENDOR}/VERSION" && "$(cat "${VENDOR}/VERSION")" == "$VERSION" ]] && have_lib; then
  echo "LIBMONGOCRYPT_VENDOR=${VENDOR}"
  exit 0
fi

if [[ ! -f "$SUMS" ]]; then
  echo "missing checksum file ${SUMS}" >&2
  exit 1
fi

expected="$(awk -v f="$asset" '$2 == f { print $1; exit }' "$SUMS")"
if [[ -z "$expected" ]]; then
  echo "no SHA256 in ${SUMS} for ${asset}" >&2
  exit 1
fi

mkdir -p "$CACHE" "$VENDOR/lib"
tarball="${CACHE}/${asset}"
url="${BASE_URL}/${asset}"

if [[ ! -f "$tarball" ]]; then
  echo "Downloading libmongocrypt ${VERSION} (${asset})"
  echo "URL: ${url}"
  curl -fL --retry 5 --retry-all-errors --max-time 300 -o "${tarball}.partial" "$url"
  mv "${tarball}.partial" "$tarball"
fi

actual="$(file_sha256 "$tarball")"
if [[ "$actual" != "$expected" ]]; then
  echo "SHA256 mismatch for ${asset}" >&2
  echo "  expected ${expected}" >&2
  echo "  actual   ${actual}" >&2
  rm -f "$tarball"
  exit 1
fi

tmp_dir="$(mktemp -d "${CACHE}/libmongocrypt.XXXXXX")"
cleanup() { rm -rf "$tmp_dir"; }
trap cleanup EXIT

tar zxf "$tarball" -C "$tmp_dir"

so="$(find "$tmp_dir" -name 'libmongocrypt.so' | head -n 1)"
dylib="$(find "$tmp_dir" -name 'libmongocrypt.dylib' | head -n 1)"
# dyld loads this compat name (@rpath/libmongocrypt.0.dylib). 1.20.4 macos
# ships only libmongocrypt.dylib; we then symlink.
dylib0="$(find "$tmp_dir" -name 'libmongocrypt.0.dylib' | head -n 1)"
dll="$(find "$tmp_dir" -name 'mongocrypt.dll' | head -n 1)"

rm -f "${VENDOR}/lib/libmongocrypt.so" "${VENDOR}/lib/libmongocrypt.so.0" \
  "${VENDOR}/lib/libmongocrypt.dylib" "${VENDOR}/lib/libmongocrypt.0.dylib" \
  "${VENDOR}/lib/mongocrypt.dll" "${VENDOR}/lib/libmongocrypt.dll"

if [[ -n "$so" ]]; then
  # SONAME is libmongocrypt.so.0; the tarball ships only libmongocrypt.so.
  cp -a "$so" "${VENDOR}/lib/libmongocrypt.so"
  ln -sfn libmongocrypt.so "${VENDOR}/lib/libmongocrypt.so.0"
elif [[ -n "$dylib" ]]; then
  # Runtime ID is libmongocrypt.0.dylib; Crystal -lmongocrypt links this file.
  cp -a "$dylib" "${VENDOR}/lib/libmongocrypt.dylib"
  if [[ -n "$dylib0" ]]; then
    # Tarball already has the compat name. Keep a file at that name.
    cp -a "$dylib0" "${VENDOR}/lib/libmongocrypt.0.dylib"
  else
    ln -sfn libmongocrypt.dylib "${VENDOR}/lib/libmongocrypt.0.dylib"
  fi
elif [[ -n "$dll" ]]; then
  cp -a "$dll" "${VENDOR}/lib/mongocrypt.dll"
  # MinGW -lmongocrypt looks for libmongocrypt.dll.
  cp -a "$dll" "${VENDOR}/lib/libmongocrypt.dll"
else
  echo "libmongocrypt archive has no shared library" >&2
  find "$tmp_dir" -type f >&2 || true
  exit 1
fi

if command -v xattr >/dev/null 2>&1; then
  # GitHub macOS curl sets quarantine; dlopen of the dylib then fails.
  xattr -cr "$VENDOR" 2>/dev/null || true
fi

printf '%s\n' "$VERSION" >"${VENDOR}/VERSION"
echo "LIBMONGOCRYPT_VENDOR=${VENDOR}"
