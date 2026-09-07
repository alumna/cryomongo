#!/usr/bin/env bash
# Official MongoDB Community 8.0.x plus mongosh for GitHub macOS arm64.
# Writes cryomongo/tmp/mongodb/bin/{mongod,mongos,mongosh} (gitignored).
#
# Linux CI uses scripts/docker-topology.sh. This script refuses Linux so it
# cannot take over a local mongod.
#
# URLs checked HTTP 200 on 2026-09-04 (do not invent names):
#   https://fastdl.mongodb.org/osx/mongodb-macos-arm64-8.0.29.tgz
#   https://downloads.mongodb.com/compass/mongosh-2.10.0-darwin-arm64.zip
#
# Usage:
#   scripts/download-mongodb-community.sh
#   FORCE=1 scripts/download-mongodb-community.sh

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${ROOT}/tmp/mongodb"
CACHE="${ROOT}/tmp"
VERSION="${MONGODB_VERSION:-8.0.29}"
MONGOSH_VERSION="${MONGOSH_VERSION:-2.10.0}"

os="$(uname -s 2>/dev/null || echo unknown)"
arch="$(uname -m 2>/dev/null || echo unknown)"

if [[ "$os" != "Darwin" ]]; then
  echo "scripts/download-mongodb-community.sh is for GitHub macOS arm64." >&2
  echo "Linux CI uses scripts/docker-topology.sh." >&2
  echo "Windows GitHub is leftover (the driver does not compile)." >&2
  exit 1
fi

if [[ "$arch" != "arm64" ]]; then
  echo "No Community MongoDB ${VERSION} download in this script for Darwin ${arch}." >&2
  echo "GitHub Wave 29 pins macos-15 and macos-26 (arm64). Intel macos-*-large is skipped." >&2
  exit 1
fi

MONGO_URL="${MONGODB_DOWNLOAD_URL:-https://fastdl.mongodb.org/osx/mongodb-macos-arm64-${VERSION}.tgz}"
MONGOSH_URL="${MONGOSH_DOWNLOAD_URL:-https://downloads.mongodb.com/compass/mongosh-${MONGOSH_VERSION}-darwin-arm64.zip}"

have_bins() {
  [[ -x "${OUT}/bin/mongod" && -x "${OUT}/bin/mongos" && -x "${OUT}/bin/mongosh" ]]
}

if [[ "${FORCE:-}" != "1" && -f "${OUT}/VERSION" && "$(cat "${OUT}/VERSION")" == "${VERSION}+mongosh-${MONGOSH_VERSION}" ]] && have_bins; then
  echo "MONGODB_BIN=${OUT}/bin"
  exit 0
fi

mkdir -p "$CACHE" "${OUT}/bin"
tmp_dir="$(mktemp -d "${CACHE}/mongodb-dl.XXXXXX")"
cleanup() { rm -rf "$tmp_dir"; }
trap cleanup EXIT

echo "Downloading MongoDB Community ${VERSION} (macos arm64)"
echo "URL: ${MONGO_URL}"
curl -fL --retry 5 --retry-all-errors --max-time 600 -o "${tmp_dir}/mongodb.tgz" "$MONGO_URL"
tar zxf "${tmp_dir}/mongodb.tgz" -C "$tmp_dir"
mongod="$(find "$tmp_dir" -type f -name mongod | head -n 1)"
mongos="$(find "$tmp_dir" -type f -name mongos | head -n 1)"
if [[ -z "$mongod" || -z "$mongos" ]]; then
  echo "MongoDB archive has no mongod/mongos" >&2
  find "$tmp_dir" -type f | head >&2 || true
  exit 1
fi
cp -a "$mongod" "${OUT}/bin/mongod"
cp -a "$mongos" "${OUT}/bin/mongos"
chmod a+x "${OUT}/bin/mongod" "${OUT}/bin/mongos"

echo "Downloading mongosh ${MONGOSH_VERSION} (darwin-arm64)"
echo "URL: ${MONGOSH_URL}"
curl -fL --retry 5 --retry-all-errors --max-time 300 -o "${tmp_dir}/mongosh.zip" "$MONGOSH_URL"
unzip -q -o "${tmp_dir}/mongosh.zip" -d "$tmp_dir"
mongosh="$(find "$tmp_dir" -type f -name mongosh | head -n 1)"
if [[ -z "$mongosh" ]]; then
  echo "mongosh archive has no mongosh binary" >&2
  find "$tmp_dir" -type f | head >&2 || true
  exit 1
fi
cp -a "$mongosh" "${OUT}/bin/mongosh"
chmod a+x "${OUT}/bin/mongosh"

if command -v xattr >/dev/null 2>&1; then
  xattr -cr "$OUT" 2>/dev/null || true
fi

printf '%s\n' "${VERSION}+mongosh-${MONGOSH_VERSION}" >"${OUT}/VERSION"
echo "MONGODB_BIN=${OUT}/bin"
