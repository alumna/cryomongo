#!/usr/bin/env bash
# Download MongoDB crypt_shared (mongo_crypt_v1.so) for auto-encryption.
# Does not commit the .so. Writes cryomongo/tmp/mongo_crypt_v1.so (gitignored).
#
# Usage:
#   scripts/download-crypt-shared.sh
#   CRYPT_SHARED_VERSION=8.0.29 scripts/download-crypt-shared.sh
#
# Prints CRYPT_SHARED_LIB_PATH=... on success. GitHub CI appends that to GITHUB_ENV.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="${ROOT}/tmp"
OUT_SO="${OUT_DIR}/mongo_crypt_v1.so"
VERSION="${CRYPT_SHARED_VERSION:-8.0.29}"
ARCH="${CRYPT_SHARED_ARCH:-x86_64}"

# Ubuntu 24.04 GitHub runners and this 26.04 host: use the 24.04 Enterprise package.
# Newer glibc can load that .so.
DISTRO="${CRYPT_SHARED_DISTRO:-ubuntu2404}"

URL="${CRYPT_SHARED_URL:-https://downloads.mongodb.com/linux/mongo_crypt_shared_v1-linux-${ARCH}-enterprise-${DISTRO}-${VERSION}.tgz}"

if [[ -f "$OUT_SO" ]]; then
  echo "CRYPT_SHARED_LIB_PATH=${OUT_SO}"
  exit 0
fi

mkdir -p "$OUT_DIR"
tmp_dir="$(mktemp -d "${OUT_DIR}/crypt_shared.XXXXXX")"
cleanup() { rm -rf "$tmp_dir"; }
trap cleanup EXIT

echo "Downloading crypt_shared ${VERSION} (${DISTRO} ${ARCH})"
echo "URL: ${URL}"
curl -fL --retry 5 --retry-all-errors --max-time 300 -o "${tmp_dir}/crypt_shared.tgz" "$URL"
tar zxf "${tmp_dir}/crypt_shared.tgz" -C "$tmp_dir"

so="$(find "$tmp_dir" -name 'mongo_crypt_v1.so' | head -n 1)"
if [[ -z "$so" ]]; then
  echo "crypt_shared archive has no mongo_crypt_v1.so" >&2
  find "$tmp_dir" -type f >&2 || true
  exit 1
fi

cp -a "$so" "$OUT_SO"
chmod a+r "$OUT_SO"
echo "CRYPT_SHARED_LIB_PATH=${OUT_SO}"
