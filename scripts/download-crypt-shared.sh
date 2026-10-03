#!/usr/bin/env bash
# Download MongoDB crypt_shared for auto-encryption. Does not commit the library.
# Writes cryomongo/tmp/mongo_crypt_v1.{so,dylib,dll} (gitignored).
#
# Usage:
#   scripts/download-crypt-shared.sh
#   CRYPT_SHARED_VERSION=8.0.29 scripts/download-crypt-shared.sh
#   FORCE=1 scripts/download-crypt-shared.sh
#
# Official package names (HTTP 200 on 8.0.29, 2026-09-04; do not invent):
#   linux x86_64  → mongo_crypt_shared_v1-linux-x86_64-enterprise-<distro>-<ver>.tgz
#   linux aarch64 → mongo_crypt_shared_v1-linux-aarch64-enterprise-<distro>-<ver>.tgz
#   macos arm64   → mongo_crypt_shared_v1-macos-arm64-enterprise-<ver>.tgz
#   macos x86_64  → mongo_crypt_shared_v1-macos-x86_64-enterprise-<ver>.tgz
#   windows x86_64 → mongo_crypt_shared_v1-windows-x86_64-enterprise-<ver>.zip
# Distro (linux only): Ubuntu 22.04 → ubuntu2204; 24.04 and 26.04 → ubuntu2404.
# There is no ubuntu2604 package (HTTP 403). macos_arm64 / macos_x86_64 (underscore)
# names 403; use the hyphen form. Windows .tgz 403; use .zip.
#
# x86_64 linux: download failure fails this script (CI requires live auto-encryption).
# Other platforms: if the package is missing, exit 0 without the library;
# specs already skip live auto-encryption. CRYPT_SHARED_REQUIRED=1|0 overrides.
#
# Prints CRYPT_SHARED_LIB_PATH=... on success. GitHub CI appends that to GITHUB_ENV.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="${ROOT}/tmp"
VERSION="${CRYPT_SHARED_VERSION:-8.0.29}"

host_os="$(uname -s 2>/dev/null || echo unknown)"
os_lc="$(printf '%s' "$host_os" | tr '[:upper:]' '[:lower:]')"
host_arch="$(uname -m 2>/dev/null || echo unknown)"

lib_name="mongo_crypt_v1.so"
archive_kind="tgz"
URL=""
ARCH=""
DISTRO=""

case "$os_lc" in
  linux)
    case "${CRYPT_SHARED_ARCH:-$host_arch}" in
      x86_64 | amd64) ARCH="x86_64" ;;
      aarch64 | arm64) ARCH="aarch64" ;;
      *) ARCH="${CRYPT_SHARED_ARCH:-$host_arch}" ;;
    esac
    if [[ -n "${CRYPT_SHARED_DISTRO:-}" ]]; then
      DISTRO="$CRYPT_SHARED_DISTRO"
    else
      os_id=""
      os_ver=""
      if [[ -f /etc/os-release ]]; then
        os_id="$(. /etc/os-release && printf '%s' "${ID:-}")"
        os_ver="$(. /etc/os-release && printf '%s' "${VERSION_ID:-}")"
      fi
      if [[ "$os_id" == "ubuntu" && "$os_ver" == "22.04" ]]; then
        DISTRO="ubuntu2204"
      else
        DISTRO="ubuntu2404"
      fi
    fi
    lib_name="mongo_crypt_v1.so"
    URL="${CRYPT_SHARED_URL:-https://downloads.mongodb.com/linux/mongo_crypt_shared_v1-linux-${ARCH}-enterprise-${DISTRO}-${VERSION}.tgz}"
    ;;
  darwin)
    case "${CRYPT_SHARED_ARCH:-$host_arch}" in
      arm64 | aarch64) ARCH="arm64" ;;
      x86_64 | amd64) ARCH="x86_64" ;;
      *) ARCH="${CRYPT_SHARED_ARCH:-$host_arch}" ;;
    esac
    lib_name="mongo_crypt_v1.dylib"
    URL="${CRYPT_SHARED_URL:-https://downloads.mongodb.com/osx/mongo_crypt_shared_v1-macos-${ARCH}-enterprise-${VERSION}.tgz}"
    ;;
  mingw* | msys* | cygwin* | windows_nt*)
    ARCH="x86_64"
    lib_name="mongo_crypt_v1.dll"
    archive_kind="zip"
    URL="${CRYPT_SHARED_URL:-https://downloads.mongodb.com/windows/mongo_crypt_shared_v1-windows-x86_64-enterprise-${VERSION}.zip}"
    ;;
  *)
    echo "No crypt_shared download mapping for OS ${host_os} ${host_arch}." >&2
    echo "Live auto-encryption specs will skip (crypt_shared missing)." >&2
    exit 0
    ;;
esac

OUT_LIB="${OUT_DIR}/${lib_name}"

required=0
case "${CRYPT_SHARED_REQUIRED:-}" in
  1) required=1 ;;
  0) required=0 ;;
  *)
    if [[ "$os_lc" == "linux" && "$ARCH" == "x86_64" ]]; then
      required=1
    fi
    ;;
esac

skip_missing() {
  echo "No crypt_shared package for ${os_lc} ${ARCH} ${DISTRO} ${VERSION}." >&2
  echo "Live auto-encryption specs will skip (crypt_shared missing)." >&2
  echo "URL: ${URL}" >&2
  exit 0
}

if [[ "${FORCE:-}" != "1" && -f "$OUT_LIB" ]]; then
  echo "CRYPT_SHARED_LIB_PATH=${OUT_LIB}"
  exit 0
fi

mkdir -p "$OUT_DIR"
tmp_dir="$(mktemp -d "${OUT_DIR}/crypt_shared.XXXXXX")"
cleanup() { rm -rf "$tmp_dir"; }
trap cleanup EXIT

echo "Downloading crypt_shared ${VERSION} (${os_lc} ${ARCH} ${DISTRO})"
echo "URL: ${URL}"
if ! curl -fL --retry 5 --retry-all-errors --max-time 300 -o "${tmp_dir}/crypt_shared.bin" "$URL"; then
  if [[ "$required" == "1" ]]; then
    echo "crypt_shared download failed (required on ${os_lc} ${ARCH})" >&2
    exit 1
  fi
  skip_missing
fi

if [[ "$archive_kind" == "zip" ]]; then
  unzip -q -o "${tmp_dir}/crypt_shared.bin" -d "$tmp_dir"
else
  tar zxf "${tmp_dir}/crypt_shared.bin" -C "$tmp_dir"
fi

found="$(find "$tmp_dir" \( -name 'mongo_crypt_v1.so' -o -name 'mongo_crypt_v1.dylib' -o -name 'mongo_crypt_v1.dll' \) | head -n 1)"
if [[ -z "$found" ]]; then
  echo "crypt_shared archive has no mongo_crypt_v1 library" >&2
  find "$tmp_dir" -type f >&2 || true
  if [[ "$required" == "1" ]]; then
    exit 1
  fi
  skip_missing
fi

cp -a "$found" "$OUT_LIB"
chmod a+r "$OUT_LIB"
if command -v xattr >/dev/null 2>&1; then
  xattr -cr "$OUT_LIB" 2>/dev/null || true
fi
echo "CRYPT_SHARED_LIB_PATH=${OUT_LIB}"
